#!/usr/bin/env python3
"""Private synthetic fixtures only: CLI, publication races, SSH policy and import."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = '/opt/homebrew/bin/bash' if platform.system() == 'Darwin' else '/bin/bash'


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fetch-test-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve() / 'private space'
        self.work.mkdir(mode=0o700)
        self.identity = self.work / 'identity'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.identity)], check=True)
        self.known = self.work / 'known hosts'
        pub = self.identity.with_suffix('.pub').read_text().split()
        self.known.write_text('203.0.113.7 ' + ' '.join(pub[:2]) + '\n')
        self.known.chmod(0o600)
        self.source = self.work / 'source.json'
        self.source.write_bytes((ROOT / 'examples/1.14.2/server.example.json').read_bytes())
        self.source.chmod(0o600)
        self.output = self.work / 'export.json'
        self.wrapper = self.work / 'wrapper.sh'
        self.wrapper.write_text('''source "$1/scripts/fetch-vps-config.sh"; shift
require_dependencies() { export PATH=/opt/homebrew/bin:$PATH; }
check_interface() { :; }
if [[ $(uname -s) == Linux ]]; then
  file_info() { stat -c '%u %a %h' "$1"; }
  file_size() { stat -c %s "$1"; }
fi
fetch_projection() {
  remote_script | sed -n '/^jq -e -s /,$p' | sed 's@/etc/sing-box/config.json@"$1"@' > "$WORK/project.sh"
  bash "$WORK/project.sh" "$FIXTURE_INPUT" > "$WORK/raw.json"
  [[ $FIXTURE_MODE != truncated ]] || { printf '{partial' > "$WORK/raw.json"; return 23; }
  [[ $FIXTURE_MODE != ssh_failure ]] || return 255
}
eval "$(declare -f publish_projection | sed '1s/publish_projection/original_publish/')"
publish_projection() {
  case "$FIXTURE_MODE" in
    race_file) bash -c 'printf original > "$1"' _ "$OUTPUT" ;;
    race_dir) mkdir "$OUTPUT" ;;
    race_link) ln -s "$FIXTURE_INPUT" "$OUTPUT" ;;
  esac
  original_publish
}
main "$@"
''')

    def call(self, *, mode='ok', values=None, expected=0):
        args = ['203.0.113.7', '22', 'fixtureadmin', str(self.identity), str(self.known), 'en4', str(self.output)]
        if values:
            for index, value in values.items():
                args[index] = value
        env = dict(os.environ, FIXTURE_INPUT=str(self.source), FIXTURE_MODE=mode)
        p = subprocess.run([BASH, str(self.wrapper), str(ROOT), *args], capture_output=True, text=True, env=env, timeout=30)
        if expected == 0:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0)
        source = json.loads((ROOT / 'examples/1.14.2/server.example.json').read_text())
        for secret in (source['inbounds'][0]['password'], source['inbounds'][1]['tls']['reality']['private_key']):
            self.assertNotIn(secret, p.stdout + p.stderr)
        self.assertFalse(list(self.work.glob('.fetch.*')))
        return p

    def test_minimal_dual_protocol_export(self):
        self.call()
        d = json.loads(self.output.read_text())
        self.assertEqual(list(d), ['inbounds'])
        self.assertEqual(set(d['inbounds'][0]), {'type', 'method', 'network', 'listen_port', 'password'})
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.output.stat().st_nlink, 1)
        original = self.output.read_bytes()
        self.call(expected=1)
        self.assertEqual(self.output.read_bytes(), original)

    def test_no_overwrite_under_publication_races(self):
        for mode in ('race_file', 'race_dir', 'race_link'):
            with self.subTest(mode=mode):
                original = self.source.read_bytes()
                self.call(mode=mode, expected=1)
                self.assertEqual(self.source.read_bytes(), original)
                if mode == 'race_file':
                    self.assertEqual(self.output.read_text(), 'original')
                elif mode == 'race_dir':
                    self.assertEqual(list(self.output.iterdir()), [])
                else:
                    self.assertTrue(self.output.is_symlink())
                if self.output.is_dir():
                    self.output.rmdir()
                else:
                    self.output.unlink()

    def test_transfer_failure_never_publishes(self):
        for mode in ('truncated', 'ssh_failure'):
            self.call(mode=mode, expected=1)
            self.assertFalse(self.output.exists())

    def test_invalid_projection_and_noncanonical_key(self):
        template = json.loads(self.source.read_text())
        for value in ('bad', 'AAAAAAAAAAAAAAAAAAAAAB=='):
            template['inbounds'][0]['password'] = value
            self.source.write_text(json.dumps(template))
            self.call(expected=1)
            self.assertFalse(self.output.exists())

    def test_input_and_output_path_protection(self):
        self.known.chmod(0o644)
        self.call(expected=1)
        self.known.chmod(0o600)
        self.work.chmod(0o755)
        self.call(expected=1)
        self.work.chmod(0o700)
        link = self.work / 'linked'; link.symlink_to(self.identity)
        self.call(values={3: str(link)}, expected=1)
        self.call(values={3: str(self.work / 'vps-conn.sh')}, expected=1)
        self.output.symlink_to(self.source)
        self.call(expected=1)
        self.assertTrue(self.output.is_symlink())

    def test_bad_inputs_and_missing_host_key(self):
        for index, value in ((0, '127.0.0.1'), (0, '1.2.3.4;id'), (1, '022'), (1, '65536'),
                             (2, 'root'), (2, 'a;id'), (5, 'utun1'), (6, 'relative.json')):
            self.call(values={index: value}, expected=1)
        self.call(values={0: '203.0.113.8'}, expected=1)
        self.assertFalse(self.output.exists())

    def test_port_specific_and_hashed_known_hosts(self):
        self.known.write_text(self.known.read_text().replace('203.0.113.7 ', '[203.0.113.7]:2222 '))
        self.call(values={1: '2222'})
        self.output.unlink()
        subprocess.run(['ssh-keygen', '-H', '-f', str(self.known)], capture_output=True, check=True)
        self.call(values={1: '2222'})
        self.assertTrue(self.output.is_file())

    def test_actual_ssh_argument_policy_without_connecting(self):
        script = '''source "$1/scripts/fetch-vps-config.sh"
SERVER=203.0.113.7 PORT=22 ADMIN=fixtureadmin IDENTITY=$2 WORK=$3 INTERFACE=en4
build_ssh_command
"${FETCH_SSH[@]}" -G "$SERVER"
'''
        p = subprocess.run([BASH, '-c', script, '_', str(ROOT), str(self.identity), str(self.work)], capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 0, p.stderr)
        options = dict(line.split(' ', 1) for line in p.stdout.splitlines() if ' ' in line)
        for key, value in {'batchmode': 'yes', 'identitiesonly': 'yes', 'stricthostkeychecking': 'true',
                           'passwordauthentication': 'no', 'kbdinteractiveauthentication': 'no',
                           'forwardagent': 'no', 'controlmaster': 'false', 'updatehostkeys': 'false',
                           'hostkeyalgorithms': 'ssh-ed25519', 'preferredauthentications': 'publickey'}.items():
            self.assertEqual(options[key], value, key)
        self.assertIn('/usr/bin/nc -4 -b en4', options['proxycommand'])
        self.assertEqual(options['globalknownhostsfile'], '/dev/null')

    def test_repeated_client_import_preserves_inode_and_backup(self):
        self.call()
        home = self.work / 'home'; home.mkdir(mode=0o700)
        binary = self.work / 'core'; binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
        script = '''source "$1/scripts/connect-vps.sh"; shift
require_dependencies() { export PATH=/opt/homebrew/bin:$PATH; BIN=$FIXTURE_CORE; }
check_interface() { :; }
if [[ $(uname -s) == Linux ]]; then
  file_info() { stat -c '%u %a %h' "$1"; }
  file_size() { stat -c %s "$1"; }
fi
main "$@"
'''
        env = dict(os.environ, HOME=str(home), FIXTURE_CORE=str(binary))
        args = [BASH, '-c', script, '_', str(ROOT), 'setup', '203.0.113.7', str(self.output), 'en4']
        for iteration in range(2):
            p = subprocess.run(args, capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(p.returncode, 0, p.stderr)
            config = home / 'Library/Application Support/sing-box-vps/client.json'
            if iteration == 0:
                before = (config.read_bytes(), config.stat().st_ino, config.stat().st_mtime_ns)
            else:
                self.assertEqual(before, (config.read_bytes(), config.stat().st_ino, config.stat().st_mtime_ns))
                self.assertFalse(config.with_name('client.previous.json').exists())


if __name__ == '__main__':
    unittest.main()
