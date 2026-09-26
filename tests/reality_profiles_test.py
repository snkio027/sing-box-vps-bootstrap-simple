"""New protocol must preserve all reviewed local/DNS/routing behavior."""
import copy
import json
from pathlib import Path
import unittest
import client_profiles_test as baseline

ROOT = Path(__file__).resolve().parents[1]
NEW = ROOT / 'examples/1.14.2'


def load(name):
    return json.loads((NEW / (name + '.example.json')).read_text())


def validate(platform, c):
    assert c['outbounds'][0] == {'type': 'selector', 'tag': 'vps',
                               'outbounds': ['ss2022', 'reality'], 'default': 'ss2022'}
    ss, reality = c['outbounds'][1:3]
    assert ss['tag'] == 'ss2022'
    assert reality['type'] == 'vless' and reality['tag'] == 'reality'
    assert reality['server'] == ss['server'] and reality['server_port'] == 8443
    assert reality['flow'] == 'xtls-rprx-vision' and reality['network'] == 'tcp'
    assert 'multiplex' not in reality and 'transport' not in reality
    assert reality['tls']['enabled'] is True and 'insecure' not in reality['tls']
    assert reality['tls']['utls'] == {'enabled': True, 'fingerprint': 'chrome'}
    assert reality['tls']['reality']['enabled'] is True
    if platform == 'macos':
        assert reality['bind_interface'] == 'en4'
    else:
        assert 'bind_interface' not in reality
    normalized = copy.deepcopy(c)
    normalized['outbounds'] = [copy.deepcopy(ss)] + normalized['outbounds'][3:]
    normalized['outbounds'][0]['tag'] = 'vps'
    baseline.validate(platform, normalized)
    assert normalized == baseline.load(platform), 'Protocol addition changed existing policy/cache'


class RealityProfilesTests(unittest.TestCase):
    def test_all_platforms(self):
        for platform in baseline.PLATFORMS:
            validate(platform, load(platform))

    def test_refuse_unsafe_changes(self):
        for platform in baseline.PLATFORMS:
            for mutate in (
                lambda c: c['outbounds'][0].update(default='direct'),
                lambda c: c['outbounds'][0]['outbounds'].append('direct'),
                lambda c: c['outbounds'][2].update(network='udp'),
                lambda c: c['outbounds'][2].update(multiplex={'enabled': True}),
                lambda c: c['outbounds'][2]['tls'].update(insecure=True),
                lambda c: c['route'].update(auto_detect_interface=False),
            ):
                c = load(platform)
                mutate(c)
                with self.assertRaises(AssertionError):
                    validate(platform, c)

    def test_server_client_identity(self):
        server = load('server')
        r = server['inbounds'][1]
        for platform in baseline.PLATFORMS:
            c = load(platform)
            self.assertEqual(c['outbounds'][1]['password'], server['inbounds'][0]['password'])
            self.assertEqual(c['outbounds'][2]['uuid'], r['users'][0]['uuid'])
            self.assertEqual(c['outbounds'][2]['tls']['reality']['short_id'], r['tls']['reality']['short_id'][0])
        self.assertEqual(server['route']['rules'], [{'inbound': ['reality-in'], 'network': 'udp', 'action': 'reject'}])


if __name__ == '__main__':
    unittest.main()
