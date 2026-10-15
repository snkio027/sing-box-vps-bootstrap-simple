#!/usr/bin/env python3
"""Disposable Ubuntu guest + fresh external SSH sessions; never a real VPS target."""
import hashlib
import re
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ('scripts/harden-vps.sh', 'scripts/prepare-vps.sh', 'scripts/fetch-vps-config.sh',
           'scripts/connect-vps.sh', 'tests/deployment_origin.py')
SCRIPT = '/usr/local/libexec/harden-vps.sh'
ADMIN = 'fixtureadmin'


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    mode = 'socket'
    assert os.geteuid() == 0, 'Only the disposable Linux VM runner uses root.'
    os.umask(0o077)
    output = ROOT / 'artifacts/deployment-vm'
    output.mkdir(parents=True, exist_ok=True)
    # Only sanitized summaries are placed here. The synthetic keys remain in work (0700).
    output.parent.chmod(0o755)
    output.chmod(0o755)
    assertions = []
    executions = []
    start = time.time()
    status = 'FAIL'
    error = ''
    with tempfile.TemporaryDirectory(prefix='deployment-vm-') as directory:
        work = Path(directory)
        inputs = work / 'input'
        shared = work / 'output'
        inputs.mkdir(); shared.mkdir()
        for name in SOURCES:
            p = inputs / name
            p.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, p)
        # Private keys stay on the test host. The guest only receives synthetic public keys.
        for name in ('bootstrap', 'admin'):
            run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'disposable-test-only', '-f', str(work / name)])
        shutil.copyfile(work / 'admin.pub', inputs / 'admin.pub')
        image = json.loads((ROOT / 'tests/fixtures/ubuntu-cloud-image.json').read_text())
        disk = work / 'disk.qcow2'
        digest = hashlib.sha256()
        size = 0
        with urllib.request.urlopen(image['url'], timeout=60) as src, disk.open('xb') as dst:
            while block := src.read(1024 * 1024):
                size += len(block)
                assert size <= image['size_bytes']
                digest.update(block); dst.write(block)
        assert size == image['size_bytes'] and digest.hexdigest() == image['sha256']
        run(['qemu-img', 'resize', str(disk), '20G'], stdout=subprocess.DEVNULL)
        bootstrap_key = (work / 'bootstrap.pub').read_text().strip()
        switch = ('systemctl disable --now ssh.socket; systemctl stop ssh.service; systemctl enable --now ssh.service'
                  if mode == 'service' else 'systemctl is-active --quiet ssh.socket')
        init = f'''#!/bin/bash
set -eu
mkdir -p /mnt/input /mnt/output /usr/local/libexec
mount -t 9p -o trans=virtio,version=9p2000.L,ro input /mnt/input
mount -t 9p -o trans=virtio,version=9p2000.L output /mnt/output
install -m 0755 /mnt/input/scripts/harden-vps.sh {SCRIPT}
install -m 0755 /mnt/input/scripts/prepare-vps.sh /usr/local/libexec/prepare-vps.sh
install -m 0644 /mnt/input/tests/deployment_origin.py /usr/local/libexec/deployment_origin.py
install -m 0600 /mnt/input/admin.pub /root/operator.pub
echo disposable-hardening-fixture > /root/HARDENING_DISPOSABLE_VM
{switch}
cp /etc/ssh/ssh_host_ed25519_key.pub /mnt/output/host.pub
echo ready > /mnt/output/ready
'''
        # Explicit seed; no production configuration, credentials, or whole-workspace mounts.
        user_data = '''#cloud-config
package_update: false
disable_root: false
users:
  - default
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - KEY
write_files:
  - path: /root/fixture-init.sh
    permissions: '0700'
    content: |
INIT
runcmd:
  - [bash, /root/fixture-init.sh]
'''.replace('KEY', bootstrap_key).replace('INIT', '\n'.join('      ' + line for line in init.splitlines()))
        (work / 'user-data').write_text(user_data)
        (work / 'meta-data').write_text('instance-id: hardening-fixture-' + mode + '\nlocal-hostname: hardening-fixture\n')
        run(['cloud-localds', str(work / 'seed.img'), str(work / 'user-data'), str(work / 'meta-data')])
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); proxy_port = sock.getsockname()[1]
        acceleration = 'kvm' if Path('/dev/kvm').exists() else 'tcg'
        command = ['qemu-system-x86_64', '-machine', 'q35,accel=' + acceleration,
                   '-cpu', 'host' if acceleration == 'kvm' else 'max', '-m', '1024', '-smp', '2',
                   '-display', 'none', '-monitor', 'none', '-serial', 'file:' + str(work / 'serial.log'),
                   '-drive', f'file={disk},if=virtio,format=qcow2',
                   '-drive', f'file={work / "seed.img"},if=virtio,format=raw,readonly=on',
                   '-virtfs', f'local,path={inputs},mount_tag=input,security_model=none,readonly=on',
                   '-virtfs', f'local,path={shared},mount_tag=output,security_model=none',
                   '-netdev', f'user,id=network,hostfwd=tcp:127.0.0.1:{port}-:22,hostfwd=tcp:127.0.0.1:{proxy_port}-:443',
                   '-device', 'virtio-net-pci,netdev=network']
        vm = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        base = ['ssh', '-F', '/dev/null', '-T', '-p', str(port), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                '-o', 'StrictHostKeyChecking=yes', '-o', 'HostKeyAlgorithms=ssh-ed25519',
                '-o', 'UserKnownHostsFile=' + str(work / 'known_hosts'), '-o', 'GlobalKnownHostsFile=/dev/null',
                '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ConnectTimeout=8',
                '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3']

        def ssh(cmd, *, user='root', expected=0, label='', timeout=120, auth='publickey', match=None):
            identity = work / ('bootstrap' if user == 'root' else 'admin')
            args = base + ['-i', str(identity), '-o', 'PreferredAuthentications=' + auth]
            if auth != 'publickey':
                args += ['-o', 'PubkeyAuthentication=no', '-o', 'LogLevel=DEBUG1']
            cmd = 'set -e; ' + cmd
            args += [user + '@127.0.0.1', cmd]
            p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
            executions.append({'label': label or cmd, 'user': user, 'command': cmd, 'auth': auth,
                               'exit': p.returncode, 'expected': expected})
            if p.returncode != expected:
                # All guest data is synthetic; output is bounded and never includes key file contents.
                raise AssertionError(f'{label or cmd}: exit {p.returncode}, expected {expected}')
            if match is not None:
                assert match in p.stdout + p.stderr, f'{label}: missing expected error {match}\n'
            if auth != 'publickey':
                assert 'Authentications that can continue: publickey' in p.stderr
                assert 'Authentications that can continue: publickey,password' not in p.stderr
            return p.stdout

        def passed(name):
            assertions.append(name)
            print('PASS ' + name, flush=True)

        def reboot_guest(label):
            old_boot = ssh('cat /proc/sys/kernel/random/boot_id', user=ADMIN).strip()
            # One request per deliberately scheduled test reboot; never retry the mutation.
            try:
                ssh('sudo -n systemctl reboot', user=ADMIN, label=label)
            except AssertionError:
                assert executions[-1]['exit'] == 255
            deadline = time.monotonic() + 180
            while True:
                try:
                    new_boot = ssh('cat /proc/sys/kernel/random/boot_id', user=ADMIN, label='wait for new boot', timeout=15).strip()
                    if new_boot != old_boot:
                        return
                except (AssertionError, subprocess.TimeoutExpired):
                    pass
                assert time.monotonic() < deadline, 'VM reboot recovery timed out'
                time.sleep(3)

        prepare = f'bash {SCRIPT} prepare --admin {ADMIN} --public-key /root/operator.pub --ssh-port 22'
        apply = f'sudo -n --preserve-env=SSH_CONNECTION bash {SCRIPT} apply --admin {ADMIN} --ssh-port 22 --confirm-console'
        installer = 'sudo -n bash /usr/local/libexec/prepare-vps.sh'
        # Linux test adapters replace ONLY Mac dependencies/stat/interface transport.
        # The real SSH flags, remote projection, validation, publication and client main stay intact.
        fetch_wrapper = work / 'fetch.sh'
        fetch_wrapper.write_text(r'''source "$1/scripts/fetch-vps-config.sh"; shift
require_dependencies() { :; }
file_info() { stat -c '%u %a %h' "$1"; }
file_size() { stat -c %s "$1"; }
check_interface() { :; }
proxy_command() { printf '/usr/bin/nc -4 127.0.0.1 %s' "$FIXTURE_SSH_PORT"; }
main "$@"
''')
        client_wrapper = work / 'client.sh'
        client_wrapper.write_text(r'''source "$1/scripts/connect-vps.sh"; shift
require_dependencies() { BIN=$FIXTURE_CORE; }
file_info() { stat -c '%u %a %h' "$1"; }
file_size() { stat -c %s "$1"; }
check_interface() { :; }
eval "$(declare -f check_config | sed '1s/check_config/native_check_config/')"
check_config() {
  if [[ $command != setup ]]; then
    # QEMU user networking forwards a high host port to guest TCP 443; never a public target.
    jq --argjson port "$FIXTURE_PROXY_PORT" '.outbounds[0] |= (.server="127.0.0.1" | .server_port=$port | .bind_interface="lo")' \
      "$WORK/client.json" > "$WORK/linux.json"
    mv "$WORK/linux.json" "$WORK/client.json"
  fi
  native_check_config
}
curl() {
  # Keep the production URL/TLS hostname; only dial the guest-loopback synthetic origin.
  [[ $1 == -q ]] || return 1
  shift
  command curl -q --cacert "$FIXTURE_CA" --connect-to www.cloudflare.com:443:127.0.0.1:18443 "$@"
}
main "$@"
''')
        client_home = work / 'client-home'; client_home.mkdir(mode=0o700)
        private_output = work / 'private output'; private_output.mkdir(mode=0o700)
        env = dict(os.environ, HOME=str(client_home), FIXTURE_SSH_PORT=str(port),
                   FIXTURE_PROXY_PORT=str(proxy_port), FIXTURE_CORE=str(work / 'sing-box'), FIXTURE_CA=str(work / 'origin.crt'))

        def local(args, label, expected=0):
            p = subprocess.run(args, capture_output=True, env=env, timeout=60)
            # Never export stdout/stderr from SSH transfer or private configuration checks.
            executions.append({'label': label, 'exit': p.returncode, 'expected': expected})
            if expected == 0:
                assert p.returncode == 0, label + ': nonzero exit ' + str(p.returncode)
            else:
                assert p.returncode != 0, label + ': unexpectedly succeeded'
            assert not list(private_output.glob('.fetch.*')), 'Fetch temporary directory leaked'
            # Private synthetic fields may occur only in their private files.
            if (private_output / 'first.json').exists():
                key = json.loads((private_output / 'first.json').read_text())['inbounds'][0]['password'].encode()
                assert key not in p.stdout + p.stderr, 'Secret appeared in command output'
            return p

        def fetch(name, *, known='fetch-known', admin=ADMIN, expected=0):
            return local(['bash', str(fetch_wrapper), str(ROOT), '203.0.113.7', '22', admin,
                          str(work / 'admin'), str(work / known), 'en4', str(private_output / name)],
                         'private fetch ' + name, expected)

        def setup(name='first.json'):
            local(['bash', str(client_wrapper), str(ROOT), 'setup', '203.0.113.7', str(private_output / name), 'en4'], 'client setup')

        def probe(expected=0):
            local(['bash', str(client_wrapper), str(ROOT), 'check'], 'real SS2022 HTTPS and observed guest egress', expected)

        def snapshot():
            facts = ssh('sudo -n sha256sum /etc/sing-box/config.json /home/fixtureadmin/.ssh/authorized_keys; '
                        'id; getent passwd fixtureadmin; sudo -n iptables-save; sudo -n ip6tables-save', user=ADMIN,
                        label='private comparison of config/key/account/firewall')
            return '\n'.join(re.sub(r'\[\d+:\d+\]', '[0:0]', line) for line in facts.splitlines() if not line.startswith('#'))

        try:
            deadline = time.monotonic() + 300
            while not (shared / 'ready').exists():
                assert vm.poll() is None, 'VM exited during boot'
                assert time.monotonic() < deadline, 'Guest setup timed out'
                time.sleep(2)
            host_key = (shared / 'host.pub').read_text().split()
            assert host_key[0] == 'ssh-ed25519'
            (work / 'known_hosts').write_text(f'[127.0.0.1]:{port} {host_key[0]} {host_key[1]}\n')
            (work / 'fetch-known').write_text('203.0.113.7 ' + ' '.join(host_key[:2]) + '\n')
            ssh('cloud-init status --wait >/dev/null; test ! -e /usr/local/bin/sing-box; test ! -e /var/lib/sing-box-hardening')
            passed('clean Ubuntu 24.04 socket VM, pinned host key, no previous project installation')
            ssh(prepare, label='prepare administrator')
            ssh('test "$(id -un)" = fixtureadmin; test "$(sudo -n id -u)" = 0', user=ADMIN, label='fresh administrator SSH and full sudo')
            passed('separate prepare and new external administrator SSH/sudo')
            ssh(apply, user=ADMIN, label='apply hardening', timeout=1800)
            ssh('sudo -n true; systemctl is-active --quiet ufw.service', user=ADMIN, label='new connection after hardening')
            ssh('true', expected=255, label='root login denied')
            ssh('true', user=ADMIN, auth='password', expected=255, label='password authentication denied')
            passed('hardening retains fresh key SSH; root/password denied; UFW enabled')
            ssh(installer, user=ADMIN, label='install proxy after hardening', timeout=1200)
            ssh('systemctl is-active --quiet sing-box; systemctl is-enabled --quiet sing-box', user=ADMIN)
            passed('real prepare-vps installation after host initialization')
            # Test-only origin is reachable solely inside the guest. It survives the scheduled reboot.
            ssh(r'''sudo -n bash -s <<'ORIGIN'
set -eu
umask 077
mkdir -p /root/deployment-origin
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=www.cloudflare.com \
  -addext subjectAltName=DNS:www.cloudflare.com -keyout /root/deployment-origin/key.pem \
  -out /root/deployment-origin/cert.pem >/dev/null 2>&1
cat > /etc/systemd/system/deployment-origin.service <<'UNIT'
[Unit]
Description=Disposable guest-only HTTPS fixture
[Service]
ExecStart=/usr/bin/python3 /usr/local/libexec/deployment_origin.py /root/deployment-origin/cert.pem /root/deployment-origin/key.pem
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now deployment-origin
ORIGIN
''', user=ADMIN, label='create private guest-loopback TLS origin')
            certificate = ssh('sudo -n cat /root/deployment-origin/cert.pem', user=ADMIN, label='retrieve synthetic public CA')
            (work / 'origin.crt').write_text(certificate)
            binary = subprocess.run(base + ['-i', str(work / 'admin'), ADMIN + '@127.0.0.1', 'cat /usr/local/bin/sing-box'],
                                    capture_output=True, check=True, timeout=60).stdout
            expected_hash = re.search(r'BINARY_SHA=([0-9a-f]{64})', (ROOT / 'scripts/prepare-vps.sh').read_text()).group(1)
            assert hashlib.sha256(binary).hexdigest() == expected_hash
            (work / 'sing-box').write_bytes(binary); (work / 'sing-box').chmod(0o700)
            fetch('first.json')
            projection = json.loads((private_output / 'first.json').read_text())
            assert set(projection) == {'inbounds'} and len(projection['inbounds']) == 1
            assert set(projection['inbounds'][0]) == {'type', 'method', 'network', 'listen_port', 'password'}
            assert (private_output / 'first.json').stat().st_nlink == 1
            assert (private_output / 'first.json').stat().st_mode & 0o777 == 0o600
            passed('real pinned SSH plus sudo retrieves only SS2022 fields as exclusive private file')
            setup(); probe()
            passed('production client import and real SS2022 HTTPS with TLS verification and observed guest-loopback exit')
            # Wrong known key must fail in real OpenSSH, not in a mock.
            wrong = (work / 'bootstrap.pub').read_text().split()
            (work / 'wrong-known').write_text('203.0.113.7 ' + ' '.join(wrong[:2]) + '\n')
            fetch('host-mismatch.json', known='wrong-known', expected=1)
            assert not (private_output / 'host-mismatch.json').exists()
            passed('real host-key mismatch cannot publish an output')
            broken = work / 'failed-transfer.sh'
            broken.write_text(fetch_wrapper.read_text().replace('main "$@"', '''eval "$(declare -f remote_script | sed '1s/remote_script/normal_remote_script/')"
remote_script() { normal_remote_script; printf '\\nexit 23\\n'; }
main "$@"'''))
            local(['bash', str(broken), str(ROOT), '203.0.113.7', '22', ADMIN, str(work / 'admin'),
                   str(work / 'fetch-known'), 'en4', str(private_output / 'failed-transfer.json')],
                  'real SSH nonzero after complete payload', expected=1)
            assert not (private_output / 'failed-transfer.json').exists()
            passed('real SSH nonzero after valid payload prevents publication and cleans temporary files')
            ssh('sudo -n useradd --create-home --shell /bin/bash fixturedenied; '
                'sudo -n install -d -m 700 -o fixturedenied -g fixturedenied /home/fixturedenied/.ssh; '
                'sudo -n install -m 600 -o fixturedenied -g fixturedenied /home/fixtureadmin/.ssh/authorized_keys /home/fixturedenied/.ssh/authorized_keys',
                user=ADMIN, label='create fixture user without sudo')
            ssh('true', user='fixturedenied', label='fixture key login succeeds without sudo')
            fetch('sudo-denied.json', admin='fixturedenied', expected=1)
            assert not (private_output / 'sudo-denied.json').exists()
            passed('authenticated user without passwordless sudo cannot fetch or publish')
            ssh('sudo -n bash -c "umask 077; printf fixture > /var/lib/sing-box/install-restart-required"', user=ADMIN, label='synthetic unfinished install')
            fetch('unfinished.json', expected=1)
            assert not (private_output / 'unfinished.json').exists()
            ssh('sudo -n rm /var/lib/sing-box/install-restart-required', user=ADMIN, label='remove only synthetic marker')
            passed('remote read refuses unfinished installer state')
            ssh("sudo -n systemd-run --unit=fixture-export-lock --property=RuntimeMaxSec=15 "
                "/usr/bin/flock -x /run/lock/sing-box-install.lock /usr/bin/bash -c "
                "'touch /run/fixture-export-lock-held; sleep 12'; "
                "for n in $(seq 1 30); do test ! -e /run/fixture-export-lock-held || break; sleep 0.1; done; "
                "test -e /run/fixture-export-lock-held", user=ADMIN, label='hold installer lock in guest-only fixture')
            fetch('busy.json', expected=1)
            assert not (private_output / 'busy.json').exists()
            ssh('sudo -n systemctl stop fixture-export-lock; sudo -n rm /run/fixture-export-lock-held',
                user=ADMIN, label='release only the test-owned lock holder')
            passed('active exclusive installer lock blocks shared export without publishing')
            # Real wrong-key connection proves the probe cannot bypass the proxy.
            import base64
            projection['inbounds'][0]['password'] = base64.b64encode(os.urandom(16)).decode()
            (private_output / 'wrong-key.json').write_text(json.dumps(projection))
            setup('wrong-key.json'); probe(expected=1); setup()
            passed('wrong SS2022 key cannot obtain the HTTPS trace')
            before = snapshot()
            pid = ssh('systemctl show sing-box -p MainPID --value', user=ADMIN)
            ssh('sudo -n ' + prepare, user=ADMIN, label='repeat prepare')
            ssh(apply, user=ADMIN, label='repeat hardening', timeout=1800)
            ssh(installer, user=ADMIN, label='repeat proxy installer', timeout=1200)
            assert snapshot() == before
            assert ssh('systemctl show sing-box -p MainPID --value', user=ADMIN) == pid
            passed('repeat prepare/apply/install preserves credentials, account, firewall and healthy proxy PID')
            first = (private_output / 'first.json').read_bytes()
            fetch('first.json', expected=1)
            assert (private_output / 'first.json').read_bytes() == first
            fetch('repeat.json')
            assert (private_output / 'repeat.json').read_bytes() == first
            config = client_home / 'Library/Application Support/sing-box-vps/client.json'
            saved = (config.stat().st_ino, config.stat().st_mtime_ns, config.read_bytes())
            setup('repeat.json')
            assert saved == (config.stat().st_ino, config.stat().st_mtime_ns, config.read_bytes())
            probe()
            passed('repeat fetch refuses existing output; new export and repeated import preserve key/config inode')
            reboot_guest('one controlled reboot after complete deployment')
            ssh('sudo -n true; systemctl is-active --quiet sing-box; systemctl is-active --quiet ufw; '
                'systemctl is-active --quiet apt-daily.timer; systemctl is-active --quiet apt-daily-upgrade.timer; '
                'sudo -n apt-config dump | grep -F \'Unattended-Upgrade::Automatic-Reboot "false";\'', user=ADMIN, label='post-reboot services and update policy')
            ssh('true', expected=255, label='post-reboot root denied')
            ssh('true', user=ADMIN, auth='password', expected=255, label='post-reboot password denied')
            assert snapshot() == before
            ssh('sudo -n test ! -e /run/lock/sing-box-install.lock', user=ADMIN, label='prove runtime lock cleared by reboot')
            fetch('after-reboot.json')
            assert ssh("sudo -n stat -c '%u:%a:%h:%s' /run/lock/sing-box-install.lock", user=ADMIN).strip() == '0:600:1:0'
            assert (private_output / 'after-reboot.json').read_bytes() == first
            probe()
            passed('controlled reboot preserves fresh SSH/sudo, UFW, daily updates, credentials and real proxy HTTPS')
            status = 'PASS'
        except Exception as exc:
            error = str(exc)
            print(error, flush=True)
        finally:
            vm.terminate()
            try:
                vm.wait(timeout=10)
            except subprocess.TimeoutExpired:
                vm.kill(); vm.wait(timeout=10)
            summary = {'result': status, 'exit_code': 0 if status == 'PASS' else 1,
                       'memory_mib': 1024, 'disk_bytes': 20 * 1024**3, 'architecture': 'amd64',
                       'acceleration': acceleration, 'elapsed_seconds': round(time.time() - start),
                       'assertions': assertions, 'commands': executions, 'failure': error,
                       'scope': 'Clean guest full SS2022 deployment; external Linux client with explicit Mac platform adapters',
                       'controlled_reboots': 1 if status == 'PASS' else 'see commands',
                       'mac_physical_interface': 'NOT RUN', 'public_egress': 'NOT RUN', 'mobile': 'NOT RUN', 'real_vps': 'NOT RUN',
                       'source_sha256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                         for name in (*SOURCES, 'tests/run_deployment_vm.py', 'tests/fixtures/ubuntu-cloud-image.json')}}
            (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            (output / 'result.log').write_text('\n'.join('PASS ' + s for s in assertions) + '\n' + error)
            for name in ('summary.json', 'result.log'):
                (output / name).chmod(0o644)
    assert status == 'PASS', 'Deployment VM test failed; see sanitized evidence.'


if __name__ == '__main__':
    main()
