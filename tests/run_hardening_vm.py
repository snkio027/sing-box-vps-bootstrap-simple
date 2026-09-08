#!/usr/bin/env python3
"""Disposable Ubuntu guest + fresh external SSH sessions; never a real VPS target."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ('scripts/harden-vps.sh',)
SCRIPT = '/usr/local/libexec/harden-vps.sh'
ADMIN = 'fixtureadmin'


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ssh-mode', choices=('socket', 'service'), required=True)
    mode = parser.parse_args().ssh_mode
    assert os.geteuid() == 0, 'Only the disposable Linux VM runner uses root.'
    os.umask(0o077)
    output = ROOT / 'artifacts' / ('hardening-vm-' + mode)
    output.mkdir(parents=True, exist_ok=True)
    # Only sanitized summaries are placed here. The synthetic keys remain in work (0700).
    output.parent.chmod(0o755)
    output.chmod(0o755)
    assertions = []
    executions = []
    start = time.time()
    status = 'FAIL'
    error = ''
    observations = {}
    with tempfile.TemporaryDirectory(prefix='hardening-vm-') as directory:
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
        acceleration = 'kvm' if Path('/dev/kvm').exists() else 'tcg'
        command = ['qemu-system-x86_64', '-machine', 'q35,accel=' + acceleration,
                   '-cpu', 'host' if acceleration == 'kvm' else 'max', '-m', '1024', '-smp', '2',
                   '-display', 'none', '-monitor', 'none', '-serial', 'file:' + str(work / 'serial.log'),
                   '-drive', f'file={disk},if=virtio,format=qcow2',
                   '-drive', f'file={work / "seed.img"},if=virtio,format=raw,readonly=on',
                   '-virtfs', f'local,path={inputs},mount_tag=input,security_model=none,readonly=on',
                   '-virtfs', f'local,path={shared},mount_tag=output,security_model=none',
                   '-netdev', f'user,id=network,hostfwd=tcp:127.0.0.1:{port}-:22',
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
            args += [user + '@127.0.0.1', cmd]
            p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
            executions.append({'label': label or cmd, 'user': user, 'command': cmd, 'auth': auth,
                               'exit': p.returncode, 'expected': expected})
            if p.returncode != expected:
                # All guest data is synthetic; output is bounded and never includes key file contents.
                raise AssertionError(f'{label or cmd}: exit {p.returncode}, expected {expected}\n{p.stdout[-6000:]}\n{p.stderr[-6000:]}')
            if match is not None:
                assert match in p.stdout + p.stderr, f'{label}: missing expected error {match}\n{p.stdout}\n{p.stderr}'
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
        try:
            deadline = time.monotonic() + 300
            while not (shared / 'ready').exists():
                assert vm.poll() is None, 'VM exited during boot'
                assert time.monotonic() < deadline, 'Guest setup timed out'
                time.sleep(2)
            host_key = (shared / 'host.pub').read_text().split()
            assert host_key[0] == 'ssh-ed25519'
            (work / 'known_hosts').write_text(f'[127.0.0.1]:{port} {host_key[0]} {host_key[1]}\n')
            ssh('test "$(cat /root/HARDENING_DISPOSABLE_VM)" = disposable-hardening-fixture; cloud-init status --wait >/dev/null')
            ssh('systemctl is-active --quiet ssh.' + ('socket' if mode == 'socket' else 'service'))
            observations['guest_environment'] = ssh('uname -srv; cat /etc/os-release; python3 --version; bash --version | head -n 1')
            passed('fresh external bootstrap SSH using ' + mode + ' listener and pinned host key')
            firewall_facts = "for p in /etc/default/ufw /etc/ufw/*.rules; do test ! -f \"$p\" || sha256sum \"$p\"; done"
            firewall_before = ssh(firewall_facts)
            ssh(prepare.replace('--ssh-port 22', '--ssh-port 2222'), expected=1, label='wrong input port', match='differs')
            ssh('test ! -e /var/lib/sing-box-hardening; ! getent passwd fixtureadmin')
            # Effective config changes alone do not change the active socket/service listener.
            ssh("printf 'Port 2222\n' > /etc/ssh/sshd_config.d/01-fixture-port.conf")
            ssh(prepare.replace('--ssh-port 22', '--ssh-port 2222'), expected=1, label='effective/actual port mismatch', match='differs')
            ssh('rm /etc/ssh/sshd_config.d/01-fixture-port.conf; test ! -e /var/lib/sing-box-hardening')
            assert ssh(firewall_facts) == firewall_before
            passed('wrong input and effective/listener mismatch fail before account/firewall writes')
            ssh("printf 'invalid\n' > /root/invalid.pub")
            ssh(prepare.replace('/root/operator.pub', '/root/invalid.pub'), expected=1, label='invalid public key')
            ssh('test ! -e /var/lib/sing-box-hardening')
            passed('invalid public key fails before administrator creation')
            # Unrelated default ubuntu account remains; target incompatible account is rejected.
            ssh('useradd --create-home --shell /usr/sbin/nologin incompatible')
            ssh(prepare.replace(ADMIN, 'incompatible'), expected=1, label='incompatible target account')
            ssh('test ! -e /var/lib/sing-box-hardening; getent passwd ubuntu >/dev/null')
            ssh(prepare, label='prepare administrator')
            ssh('test ! -e /etc/ssh/sshd_config.d/00-sing-box-hardening.conf; test ! -e /var/lib/sing-box-hardening/applied')
            passed('prepare is separate, preserves SSH policy and permits unrelated existing account')
            ssh('test "$(id -un)" = fixtureadmin; test "$(sudo -n id -u)" = 0', user=ADMIN, label='fresh administrator key and sudo')
            ssh('bash ' + SCRIPT + ' apply --admin fixtureadmin --ssh-port 22 --confirm-console', expected=1, label='root session apply rejected')
            passed('fresh administrator key connection and full NOPASSWD sudo; root apply refused')
            # An earlier drop-in that defeats the candidate must stop before changing firewall.
            ssh("printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-before.conf")
            ssh(apply, user=ADMIN, expected=1, label='ineffective SSH candidate', match='SSH policy cannot take effect')
            ssh('test ! -e /var/lib/sing-box-hardening/applying; rm /etc/ssh/sshd_config.d/00-before.conf')
            passed('SSH Include precedence conflict fails before firewall mutation')
            ssh('apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nftables >/dev/null', timeout=300)
            ssh("nft add table inet fixture_unknown; nft -j list ruleset > /root/nft-before.json")
            ssh(apply, user=ADMIN, expected=1, label='unknown native firewall', timeout=600, match='Unknown native firewall')
            ssh("nft -j list ruleset > /root/nft-after.json; cmp /root/nft-before.json /root/nft-after.json; test ! -e /var/lib/sing-box-hardening/applying; nft delete table inet fixture_unknown")
            passed('unknown native firewall is preserved and rejected')
            ssh('cp /etc/ufw/user.rules /root/fixture-user.rules; cp /etc/ufw/user6.rules /root/fixture-user6.rules; ufw allow 12345/tcp >/dev/null; sha256sum /etc/ufw/user.rules /etc/ufw/user6.rules > /root/fixture-custom.sha256')
            ssh(apply, user=ADMIN, expected=1, label='unknown stored UFW rule', match='Unmanaged UFW control')
            ssh('sha256sum -c /root/fixture-custom.sha256 >/dev/null; cp /root/fixture-user.rules /etc/ufw/user.rules; cp /root/fixture-user6.rules /etc/ufw/user6.rules')
            passed('stored custom UFW rules are refused and preserved')
            # Inject TERM immediately after real UFW configuration using a test-only wrapper.
            # Production entry has no fault/debug flags. SSH policy has not yet been published.
            wrapper = f'''#!/usr/bin/bash
source {SCRIPT}
eval "$(declare -f configure_firewall | sed '1s/configure_firewall/real_configure_firewall/')"
configure_firewall() {{ real_configure_firewall; kill -TERM "$$"; }}
main "$@"
'''
            ssh("printf %s " + shlex.quote(wrapper) + ' > /usr/local/libexec/fixture-interrupt.sh')
            ssh(apply.replace(SCRIPT, '/usr/local/libexec/fixture-interrupt.sh'), user=ADMIN, expected=143, label='TERM after UFW', timeout=600)
            ssh('test ! -e /etc/ssh/sshd_config.d/00-sing-box-hardening.conf; test -f /var/lib/sing-box-hardening/applying')
            ssh('sudo -n true', user=ADMIN, label='new login after interrupted apply')
            ssh(apply, user=ADMIN, expected=1, label='interrupted apply refuses blind retry')
            passed('interruption retains new SSH access and recovery record; blind retry refused')
            # Explicit operator-style recovery only of known fixture files; no global rule flush.
            recovery = '''set -eu
B=$(cat /var/lib/sing-box-hardening/last-backup)
test -d "$B"
ufw disable >/dev/null
for p in /etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules; do
  name=$(printf %s "$p" | tr / _)
  test -f "$B/$name"
  cp --preserve=mode,ownership "$B/$name" "$p"
done
test ! -e /etc/ssh/sshd_config.d/00-sing-box-hardening.conf
ufw status | grep -Fxq 'Status: inactive'
'''
            ssh(recovery, label='restore exact UFW files from ordinary backup')
            ssh('sudo -n true', user=ADMIN, label='new login after backup recovery')
            # ufw disable intentionally leaves empty primary chains until reboot.
            # Recover to the saved disabled policy, schedule a guest reboot, then recheck;
            # do not flush the ruleset or teach the production entry to adopt unknown chains.
            reboot_guest('controlled VM reboot after disabled-policy recovery')
            ssh('sudo -n true; sudo -n ufw status | grep -Fxq "Status: inactive"', user=ADMIN)
            ssh('rm /var/lib/sing-box-hardening/applying')
            passed('ordinary backup recovery preserves the administrator entry')
            observations['apply_output'] = ssh(apply, user=ADMIN, label='real apply', timeout=1800)
            ssh('test "$(id -un)" = fixtureadmin; test "$(sudo -n id -u)" = 0', user=ADMIN, label='new login after hardening')
            ssh('true', expected=255, label='previously working root key refused')
            for user, auth in ((ADMIN, 'password'), (ADMIN, 'keyboard-interactive'), ('root', 'password')):
                ssh('true', user=user, auth=auth, expected=255, label=user + ' ' + auth + ' refused')
            passed('apply completes and fresh SSH allows only administrator public-key authentication')
            audit = '''set -eu
sudo -n sha256sum -c /var/lib/sing-box-hardening/managed.sha256 >/dev/null
sudo -n sha256sum -c /var/lib/sing-box-hardening/ufw-files.sha256 >/dev/null
sudo -n ufw status verbose
systemctl is-enabled --quiet ufw.service
systemctl is-enabled --quiet apt-daily.timer
systemctl is-enabled --quiet apt-daily-upgrade.timer
systemctl is-active --quiet apt-daily.timer
systemctl is-active --quiet apt-daily-upgrade.timer
sudo -n apt-config dump | grep -F 'Unattended-Upgrade::Automatic-Reboot "false";'
test ! -e /usr/sbin/policy-rc.d
sudo -n bash -s <<'AUDIT'
source /usr/local/libexec/harden-vps.sh
WORK=$(mktemp -d /run/hardening-audit.XXXXXXXX)
trap 'rm -rf "$WORK"' EXIT
SSH_PORT=22
render_restart_policy > "$WORK/needrestart"
verify_firewall
verify_updates
AUDIT
'''
            ssh(audit, user=ADMIN, label='firewall and daily updates audit')
            passed('dual-stack firewall and daily updates verified; no automatic machine reboot')
            before = ssh('sudo -n sha256sum /home/fixtureadmin/.ssh/authorized_keys; id -G; sudo -n iptables-save; sudo -n ip6tables-save', user=ADMIN)
            ssh('sudo -n ' + prepare, user=ADMIN, label='repeat prepare')
            observations['repeat_apply_output'] = ssh(apply, user=ADMIN, label='repeat apply', timeout=1800)
            after = ssh('sudo -n sha256sum /home/fixtureadmin/.ssh/authorized_keys; id -G; sudo -n iptables-save; sudo -n ip6tables-save', user=ADMIN)
            # iptables-save comments contain timestamps; counters are observational.
            def stable(text):
                import re
                return '\n'.join(re.sub(r'\[\d+:\d+\]', '[0:0]', line) for line in text.splitlines() if not line.startswith('#'))
            assert stable(before) == stable(after), 'Rerun changed key/groups/rules'
            passed('repeated prepare/apply retain key, groups and exact firewall rules')
            reboot_guest('controlled VM reboot after completed hardening')
            ssh(audit, user=ADMIN, label='post-reboot firewall/update persistence')
            ssh('sudo -n true; systemctl is-active --quiet ufw.service', user=ADMIN, label='post-reboot key and sudo')
            ssh('true', expected=255, label='post-reboot root denied')
            ssh('true', user=ADMIN, auth='password', expected=255, label='post-reboot password not offered')
            passed('controlled VM reboot: new key SSH, sudo, UFW and update policy persist')
            status = 'PASS'
        except Exception as exc:
            error = str(exc)
            print(error, flush=True)
            # Do not export config/keys or the complete VM disk. Only selected diagnostic logs.
            try:
                logs = ssh('sudo -n bash -c ' + shlex.quote('B=$(cat /var/lib/sing-box-hardening/last-backup); for n in dependency-install.log ufw-apply.log security-dry-run.log security-run.log ssh-candidate-check.log sshd-check.log restart-effective.log; do test ! -f "$B/$n" || tail -n 30 "$B/$n"; done; nft -j list ruleset; ufw status verbose; /usr/sbin/sshd -t; systemctl show ssh.service ssh.socket -p ActiveState -p SubState -p RuntimeDirectory; ls -ld /run/sshd'), user=ADMIN, label='failure diagnostics')
                (output / 'diagnostics.log').write_text(logs)
            except Exception:
                pass
        finally:
            vm.terminate()
            try:
                vm.wait(timeout=10)
            except subprocess.TimeoutExpired:
                vm.kill(); vm.wait(timeout=10)
            summary = {'result': status, 'exit_code': 0 if status == 'PASS' else 1,
                       'ssh_mode': mode, 'memory_mib': 1024, 'disk_bytes': 20 * 1024**3,
                       'architecture': 'amd64', 'acceleration': acceleration,
                       'elapsed_seconds': round(time.time() - start), 'assertions': assertions,
                       'commands': executions, 'observations': observations, 'failure': error, 'real_vps': 'NOT RUN',
                       'complete_deployment': 'NOT RUN', 'private_export': 'NOT RUN',
                       'source_sha256': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                         for name in (*SOURCES, 'tests/run_hardening_vm.py', 'tests/fixtures/ubuntu-cloud-image.json')}}
            (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            (output / 'result.log').write_text('\n'.join('PASS ' + s for s in assertions) + '\n' + error)
            for name in ('summary.json', 'result.log', 'diagnostics.log'):
                if (output / name).exists():
                    (output / name).chmod(0o644)
    assert status == 'PASS', 'Hardening VM tests failed; see evidence.'


if __name__ == '__main__':
    main()
