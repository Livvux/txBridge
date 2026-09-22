"""Protocol and inventory tests. No FXServer or external network required."""
from __future__ import annotations
import importlib.util
import json
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'tools'/f'{name}.py')
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
client=load('txbridge_cli')
audit=load('audit_upstream')
class ToolTests(unittest.TestCase):
    def test_python_matches_shared_protocol_fixture(self):
        v=json.loads((ROOT/'tests/protocol-vectors.json').read_text())
        h=client.request_headers(v['server'],v['key'],v['secret'],v['method'],v['path'],v['body'].encode(),v['idempotency'],v['timestamp'],v['nonce'])
        self.assertEqual(h['X-TxBridge-Signature'],v['requestSignature'])
    def test_body_mutation_changes_signature(self):
        a=client.request_headers('main','wordpress','a'*64,'POST','/v1/actions/announce',b'{}','abcdef0123456789','1700000000','a'*32)
        b=client.request_headers('main','wordpress','a'*64,'POST','/v1/actions/announce',b'{ }','abcdef0123456789','1700000000','a'*32)
        self.assertNotEqual(a['X-TxBridge-Signature'],b['X-TxBridge-Signature'])
    def test_https_path(self):
        self.assertEqual(client.validate_target('https://bridge.example.com/txbridge/','/v1/status'),'https://bridge.example.com/txbridge/v1/status')
    def test_external_plaintext_disallowed(self):
        with self.assertRaises(ValueError):client.validate_target('http://example.com/txbridge','/v1/status',True)
    def test_local_plaintext_requires_opt_in(self):
        with self.assertRaises(ValueError):client.validate_target('http://127.0.0.1:30120/txbridge','/v1/status')
        self.assertTrue(client.validate_target('http://127.0.0.1:30120/txbridge','/v1/status',True))
    def test_ipv6_loopback_opt_in(self):
        self.assertTrue(client.validate_target('http://[::1]:30120/txbridge','/v1/status',True))
    def test_url_and_target_injection_rejected(self):
        for base,path in [('https://u:p@example.com/txbridge','/v1/status'),('https://example.com/?x=y','/v1/status'),('https://example.com/txbridge','https://evil.example/'),('https://example.com/txbridge','/v1/../x'),('https://example.com/txbridge','/v1//status')]:
            with self.subTest(base=base,path=path):
                with self.assertRaises(ValueError):client.validate_target(base,path)
    def test_body_and_idempotency_bounds(self):
        for method,body,idem in [('POST',b'{}',''),('GET',b'{}',''),('POST',b'x'*32769,'a'*16)]:
            with self.subTest(method=method,body_length=len(body)):
                with self.assertRaises(ValueError):client.request_headers('main','wordpress','a'*64,method,'/v1/status',body,idem)
    def test_audit_ignores_comments_and_parses_dev(self):
        sample="""// router.get('/fake', apiAuthMw, routes.fake);
router.get('/player/stats', apiAuthMw, routes.player_stats);
/* router.post('/fake2', routes.fake2); */
if (txDevEnv.ENABLED) { router.post('/dev/:scope', routes.dev_post); }
"""
        self.assertEqual(audit.parse_routes(sample),{('GET','/player/stats','apiAuthMw','player_stats'),('POST','/dev/:scope','none','dev_post')})
    def test_audit_current_and_deprecated(self):
        self.assertEqual(audit.parse_events('### txAdmin:events:announcement\n## Deprecated Events\n### txAdmin:events:healedPlayer\n'),({'announcement'},{'healedPlayer'}))
    def test_route_inventory_has_unique_ids_and_classifications(self):
        routes=json.loads((ROOT/'docs/txadmin-routes.json').read_text())['routes']
        self.assertEqual(len(routes),58)
        self.assertEqual(len({r['id'] for r in routes}),58)
        self.assertEqual(sum(r['exposure']=='experimental' for r in routes),42)
        self.assertEqual(sum(r['conditional'] for r in routes),2)
        for r in routes:
            self.assertIn(r['method'],['GET','POST'])
            self.assertIn(r['exposure'],['experimental','host-status','reference-only: authentication lifecycle','blocked: private intercom','blocked: development-only'])
    def test_event_inventory_complete(self):
        events=json.loads((ROOT/'docs/txadmin-events.json').read_text())
        self.assertEqual(len(events['current']),17)
        self.assertEqual(len(events['deprecated']),3)
        lua=(ROOT/'resource/txbridge/server/events.lua').read_text()
        for event in events['current']:self.assertIn(event+'=',lua)
    def test_openapi_all_operations_signed_and_writes_have_idempotency(self):
        spec=json.loads((ROOT/'docs/openapi.json').read_text())
        self.assertEqual(spec['openapi'],'3.1.0')
        operations=[(p,m,op) for p,v in spec['paths'].items() for m,op in v.items()]
        self.assertEqual(len(operations),21)
        self.assertEqual(len({op['operationId'] for _,_,op in operations}),21)
        for path,method,op in operations:
            self.assertIn({'requestHmac':[]},op['security'])
            self.assertTrue(op['x-txbridge-scope'])
            if method=='post':
                self.assertIn({'$ref':'#/components/parameters/Idempotency'},op['parameters'])
                self.assertTrue(op['requestBody']['required'])
    def test_openapi_all_refs_resolve(self):
        spec=json.loads((ROOT/'docs/openapi.json').read_text())
        def walk(value):
            if isinstance(value,dict):
                if '$ref' in value:
                    target=spec
                    self.assertTrue(value['$ref'].startswith('#/'))
                    for key in value['$ref'][2:].split('/'):target=target[key]
                for item in value.values():walk(item)
            elif isinstance(value,list):
                for item in value:walk(item)
        walk(spec)
    def test_native_api_paths_match_spec(self):
        spec=json.loads((ROOT/'docs/openapi.json').read_text())
        src=(ROOT/'resource/txbridge/server/api.lua').read_text()
        for path in spec['paths']:
            if '{' not in path:self.assertIn(path,src)
        for action in ('start','stop','restart'):self.assertIn('/v1/resources/{name}/actions/'+action,spec['paths'])
    def test_database_identity_columns_are_case_sensitive(self):
        src=(ROOT/'wordpress/txbridge-wordpress/txbridge-wordpress.php').read_text()
        for column,length in [('server_id',64),('event_id',128),('event_type',128)]:
            self.assertIn(f'{column} varchar({length}) CHARACTER SET ascii COLLATE ascii_bin NOT NULL',src)
        self.assertIn('ORDER BY source_sequence DESC',src)
    def test_sources_and_scope_documented(self):
        docs=(ROOT/'docs/TXADMIN.md').read_text()
        self.assertIn('42',docs)
        self.assertIn('58',docs)
        self.assertIn('not all txAdmin source functions',docs)
        self.assertTrue((ROOT/'LICENSE').is_file())
if __name__=='__main__':unittest.main(verbosity=2)
