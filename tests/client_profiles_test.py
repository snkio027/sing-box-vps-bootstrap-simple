#!/usr/bin/env python3
"""Public fixtures only: enforce the approved platform and proxy policy boundaries."""
import copy
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / 'examples/1.14.0'
PLATFORMS = ('macos', 'android', 'ios')


def load(platform):
    return json.loads((EXAMPLES / (platform + '.example.json')).read_text())


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def validate(platform, config):
    """These are project policy checks, not a replacement sing-box JSON parser."""
    assert platform in PLATFORMS
    outbound = {o['tag']: o for o in config['outbounds']}
    assert set(outbound) == {'vps', 'direct', 'local-direct'}
    vps = outbound['vps']
    assert (vps['type'], vps['method'], vps['server_port'], vps['network']) == (
        'shadowsocks', '2022-blake3-aes-128-gcm', 443, 'tcp')
    assert vps['multiplex'] == {'enabled': False}
    assert vps['server'] == '198.51.100.10'
    assert vps['password'] == 'AAECAwQFBgcICQoLDA0ODw=='  # Public, never deploy this key.
    route = config['route']
    assert route['final'] == 'vps' and route['auto_detect_interface'] is True
    assert 'default_interface' not in route
    assert route['rules'][2] == {
        'ip_cidr': ['198.51.100.10/32'], 'action': 'route', 'outbound': 'direct'}
    assert route['rules'][3] == {
        'ip_is_private': True, 'action': 'route', 'outbound': 'local-direct'}
    assert route['rules'][-1] == {
        'network': ['udp', 'icmp'], 'action': 'reject', 'method': 'default', 'no_drop': True}
    assert config['dns']['strategy'] == 'ipv4_only'
    assert config['dns']['final'] == 'dns-proxy'
    assert config['http_clients'] == [
        {'tag': 'rules-via-vps', 'engine': 'go', 'version': 2, 'detour': 'vps'}]
    assert route['default_http_client'] == 'rules-via-vps'
    assert len(route['rule_set']) == 3
    for rule_set in route['rule_set']:
        assert rule_set['http_client'] == 'rules-via-vps'
        assert rule_set['type'] == 'remote' and rule_set['format'] == 'binary'
        assert rule_set['url'].startswith('https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/')
    cache = config['experimental']['cache_file']
    assert cache['enabled'] and cache['store_fakeip'] and cache['path'] == 'cache.db'
    local_dns = next(s for s in config['dns']['servers'] if s['tag'] == 'dns-local')
    assert local_dns['type'] == 'local' and local_dns['prefer_go'] is False
    assert config['log'] == {'level': 'info', 'timestamp': True}
    tun = config['inbounds'][0]
    assert tun['type'] == 'tun' and tun['auto_route'] is True
    assert tun['dns_mode'] == 'hijack' and tun['stack'] == 'system'
    assert not any(k.startswith('route_exclude') for k in tun)
    if platform == 'macos':
        assert config['inbounds'][1] == {
            'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 17890}
        assert vps['bind_interface'] == 'en4' and local_dns['bind_interface'] == 'en4'
        assert 'bind_interface' not in outbound['local-direct']
    else:
        assert len(config['inbounds']) == 1
        assert 'strict_route' not in tun and 'interface_name' not in tun
        assert local_dns == {'type': 'local', 'tag': 'dns-local', 'prefer_go': False}
        assert config['experimental']['clash_api'] == {'default_mode': 'rule'}
        forbidden = {'bind_interface', 'inet4_bind_address', 'inet6_bind_address',
                     'external_controller', 'initial_path', 'process_name', 'process_path',
                     'include_package', 'exclude_package', 'auto_redirect'}
        for obj in objects(config):
            assert not forbidden.intersection(obj)
        for rule in config['dns']['rules']:
            if 'inbound' in rule:
                assert rule['inbound'] == ['tun-in']
        assert cache['cache_id'] == 'single-vps-1.14.0-' + platform


class ClientProfilesTests(unittest.TestCase):
    def test_all_platform_policies(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                validate(platform, load(platform))

    def test_same_routing_and_dns_policy(self):
        # Platform normalization must not change domain/IP/ad/protocol policy or rule-set origins.
        mac = load('macos')
        for platform in ('android', 'ios'):
            mobile = load(platform)
            self.assertEqual(mac['route']['rules'], mobile['route']['rules'])
            for original, adapted in zip(mac['dns']['rules'], mobile['dns']['rules']):
                normalized = copy.deepcopy(original)
                if 'inbound' in normalized:
                    normalized['inbound'] = ['tun-in']
                self.assertEqual(normalized, adapted)
            self.assertEqual(len(mac['dns']['rules']), len(mobile['dns']['rules']))
            self.assertEqual([{k: v for k, v in r.items() if k != 'initial_path'}
                              for r in mac['route']['rule_set']], mobile['route']['rule_set'])

    def rejected(self, mutate):
        for platform in ('android', 'ios'):
            config = load(platform)
            mutate(config)
            with self.subTest(platform=platform), self.assertRaises(AssertionError):
                validate(platform, config)

    def test_reject_fixed_dns_interface(self):
        self.rejected(lambda c: c['dns']['servers'][2].update(bind_interface='en4'))

    def test_reject_fixed_proxy_interface(self):
        self.rejected(lambda c: c['outbounds'][0].update(bind_interface='wlan0'))

    def test_reject_missing_interface_protection(self):
        self.rejected(lambda c: c['route'].update(auto_detect_interface=False))

    def test_reject_external_api(self):
        self.rejected(lambda c: c['experimental']['clash_api'].update(external_controller='0.0.0.0:19090'))

    def test_reject_unprovided_rule_file(self):
        self.rejected(lambda c: c['route']['rule_set'][0].update(initial_path='rules/cn.srs'))

    def test_reject_transport_expansion(self):
        self.rejected(lambda c: c['outbounds'][0].update(network='udp'))
        self.rejected(lambda c: c['outbounds'][0]['multiplex'].update(enabled=True))

    def test_reject_automatic_direct_fallback(self):
        self.rejected(lambda c: c['route'].update(final='direct'))

    def test_reject_private_network_exclusion(self):
        self.rejected(lambda c: c['inbounds'][0].update(route_exclude_address=['10.0.0.0/8']))

    def test_reject_global_udp_bypass(self):
        self.rejected(lambda c: c['route']['rules'][-1].update(action='route', outbound='direct'))

    def test_public_credentials_match_server(self):
        server = json.loads((EXAMPLES / 'server.example.json').read_text())['inbounds'][0]
        for platform in PLATFORMS:
            proxy = load(platform)['outbounds'][0]
            self.assertEqual(proxy['method'], server['method'])
            self.assertEqual(proxy['password'], server['password'])


if __name__ == '__main__':
    unittest.main()
