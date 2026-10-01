"""Isolated regressions: python3 -m unittest discover -s relay -p test_integrations.py"""
import unittest,tempfile,os,sys,pathlib,plistlib,json,io
from unittest.mock import patch
from mcp_bridge import load_shell_config
import integrations as I, config_backup as B, app_config as A

class IntegrationsTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.d=self.tmp.name
        self.old_env=dict(os.environ)
        self.old=(I.support_dir,B.support_dir,B.token_path,B.relay_token)
        I.support_dir=lambda:self.d;B.support_dir=lambda:self.d
        B.token_path=lambda:self.d+'/token';B.relay_token=lambda c:'test-token'
        os.environ['TIGER_PROVIDERS_FILE']=self.d+'/providers.json';os.environ['TIGERDESK_CONFIG']=self.d+'/config.sh'
        pathlib.Path(self.d+'/config.sh').write_text('LISTEN_PORT="8765"\n')
    def tearDown(self):
        I.support_dir,B.support_dir,B.token_path,B.relay_token=self.old
        os.environ.clear();os.environ.update(self.old_env);self.tmp.cleanup()
    def test_key_deletion(self):
        I.write({'search_api_key':'dummy'})
        I.write({},preserve_key=True);self.assertEqual(I.read()['search_api_key'],'dummy')
        I.write({'clear_search_key':True},preserve_key=True);self.assertEqual(I.read()['search_api_key'],'')
    def test_flags(self):
        I.write({'toolbox_enabled':True,'search_enabled':True,'search_api_key':'dummy'})
        self.assertIn('agent_web_search',[t['name'] for t in I.auxiliary('claude',I.read())])
        self.assertNotIn('agent_web_search',[t['name'] for t in I.auxiliary('grok',I.read())])
        self.assertIn('T',I.run_auxiliary('agent_current_time',{},I.read()))
    def test_notes_limit(self):
        with self.assertRaises(ValueError):I.run_auxiliary('agent_notes_write',{'text':'x'*20001},{'toolbox_enabled':True})
    def test_validation(self):
        with self.assertRaises(ValueError):I.write({'servers':[{'id':'bad','command':'relative','args':[]}]})
        with self.assertRaises(ValueError):I.write({'search_enabled':'true'})
    def test_backup(self):
        A.update_settings({'xai_api_key':'dummy'})
        I.write({'servers':[{'id':'sample','command':sys.executable,'args':[],'enabled':True}]})
        payload=B.export();A.update_settings({'clear_all':True});B.restore(payload,connection=True)
        self.assertEqual(A.read_config()['xai_api_key'],'dummy');self.assertFalse(I.read()['servers'][0]['enabled'])
        self.assertEqual(pathlib.Path(self.d+'/token').read_text().strip(),'test-token')
    def test_invalid_backup_preserves_settings(self):
        A.update_settings({'xai_api_key':'dummy'})
        bad={'format':'TigerBuildRelay-config','version':1,'providers':{'xai_api_key':'changed'},'integrations':{},
             'connection':{'REMOTE_COMMANDER':'/tmp/evil.py; reboot'}}
        with self.assertRaises(ValueError):B.restore(plistlib.dumps(bad),connection=True)
        self.assertEqual(A.read_config()['xai_api_key'],'dummy')

    def test_search_request_and_result(self):
        config={'search_enabled':True,'search_api_key':'dummy-secret'}
        response=io.BytesIO(json.dumps({'web':{'results':[{'title':'Example','url':'https://example.com','description':'Snippet'}]}}).encode())
        with patch('integrations.urllib.request.urlopen',return_value=response) as opened:
            output=json.loads(I.run_auxiliary('agent_web_search',{'query':'test query'},config))
            req=opened.call_args[0][0]
            self.assertEqual(req.get_header('X-subscription-token'),'dummy-secret')
            self.assertIn('q=test+query',req.full_url)
            self.assertEqual(output[0]['url'],'https://example.com')
    def test_search_off_never_uses_network(self):
        with patch('integrations.urllib.request.urlopen') as opened:
            with self.assertRaises(ValueError):I.run_auxiliary('agent_web_search',{'query':'test'},{'search_enabled':False,'search_api_key':'dummy'})
            opened.assert_not_called()
    def test_unadvertised_tool_rejected(self):
        I.write({'toolbox_enabled':True,'search_enabled':True,'search_api_key':'dummy'})
        conn=I.Connections();conn.definitions('grok')
        with self.assertRaises(ValueError):conn.call('agent_web_search',{'query':'test'})
        conn.close()
    def test_quoted_paths_roundtrip(self):
        connection={'LISTEN_PORT':'8765','TIGER_HOST':'192.0.2.10','TIGER_USER':'tigeruser',
          'TIGER_KEY':"/Users/test user/O'Brien/key",'REMOTE_COMMANDER':'$HOME/ppc-commander/ppc_commander.py'}
        obj={'format':'TigerBuildRelay-config','version':1,'providers':{},'integrations':{},
          'connection':connection,'relay_token':'token','autostart':False}
        B.restore(plistlib.dumps(obj),connection=True)
        loaded=load_shell_config()
        for name,value in connection.items():self.assertEqual(loaded[name],value)

if __name__=='__main__':unittest.main()
