import unittest,io,json,tempfile,os,sys
from unittest.mock import patch
import providers as P
class ThinkingTest(unittest.TestCase):
 def events(self):
  return [(None,x) for x in [
   {'type':'content_block_start','index':0,'content_block':{'type':'thinking','thinking':'','signature':''}},
   {'type':'content_block_delta','index':0,'delta':{'type':'thinking_delta','thinking':'Returned summary'}},
   {'type':'content_block_delta','index':0,'delta':{'type':'signature_delta','signature':'opaque-sig-1'}},
   {'type':'content_block_delta','index':0,'delta':{'type':'signature_delta','signature':'-2'}},
   {'type':'content_block_stop','index':0},
   {'type':'content_block_start','index':1,'content_block':{'type':'redacted_thinking','data':'opaque-encrypted'}},
   {'type':'content_block_stop','index':1},
   {'type':'content_block_start','index':2,'content_block':{'type':'tool_use','id':'t1','name':'ping','input':{}}},
   {'type':'content_block_delta','index':2,'delta':{'type':'input_json_delta','partial_json':'{"word":"ok"}'}},
   {'type':'content_block_stop','index':2}]]
 def test_signed_replay(self):
  holder={}
  with patch('providers._post_stream',return_value=io.BytesIO()),patch('providers.iter_sse',return_value=iter(self.events())),patch('integrations.read',return_value={'claude_thinking':True}):
   shown=list(P.stream_claude('dummy','claude-sonnet-4-6','system',[{'role':'user','content':'hello'}],[],holder,None,lambda x,c:x))
  self.assertEqual(shown,[{'thinking':'Returned summary'}])
  self.assertEqual(holder['claude_blocks'][0]['signature'],'opaque-sig-1-2')
  self.assertEqual(holder['claude_blocks'][1]['data'],'opaque-encrypted')
  log=[{'role':'assistant','content':'','calls':holder['calls'],'claude_blocks':holder['claude_blocks']}, {'role':'tool','id':'t1','content':'result'}]
  replay=P.anthropic_messages(log)
  self.assertEqual(replay[0]['content'],holder['claude_blocks'])
  self.assertEqual(replay[1]['content'][0]['tool_use_id'],'t1')
 def test_missing_signature(self):
  events=[x for x in self.events() if x[1].get('delta',{}).get('type')!='signature_delta']
  with patch('providers._post_stream',return_value=io.BytesIO()),patch('providers.iter_sse',return_value=iter(events)),patch('integrations.read',return_value={}):
   with self.assertRaises(RuntimeError):list(P.stream_claude('dummy','claude-sonnet-4-6','system',[],[],{},None,lambda x,c:x))
 def test_tavily(self):
  import integrations as I
  response=io.BytesIO(json.dumps({'results':[{'title':'Test','url':'https://example.com','content':'Snippet'}]}).encode())
  with patch('integrations.urllib.request.urlopen',return_value=response) as opened:
   result=json.loads(I.run_auxiliary('agent_web_search',{'query':'test'},{'search_enabled':True,'search_provider':'tavily','tavily_api_key':'dummy'}))
   self.assertEqual(opened.call_args[0][0].get_header('Authorization'),'Bearer dummy')
   self.assertEqual(result[0]['description'],'Snippet')

class DefaultsAndMistralTest(unittest.TestCase):
 def test_thinking_on_by_default(self):
  import integrations as I
  self.assertTrue(I.DEFAULT['claude_thinking'])
  self.assertTrue(I.validate({})['claude_thinking'])
  self.assertFalse(I.validate({'claude_thinking':False})['claude_thinking'])
 def _mistral(self,model,first_error):
  sent=[]
  def post(url,payload,headers,ctx,err):
   sent.append(payload.get('reasoning_effort'))
   if first_error and len(sent)==1:raise RuntimeError(first_error)
   return io.BytesIO()
  done=[(None,{'choices':[{'delta':{'content':'ok'},'finish_reason':'stop'}]})]
  with patch('providers._post_stream',side_effect=post),patch('providers.iter_sse',return_value=iter(done)),patch('integrations.read',return_value={'claude_thinking':True}):
   out=list(P.stream_openai_compatible(P.MISTRAL_URL,'k',model,'s',[{'role':'user','content':'h'}],[],{},None,lambda x,c:x))
  return sent,out
 def test_mistral_retry_without_effort(self):
  P.MISTRAL_NO_REASONING.discard('t-plain')
  sent,out=self._mistral('t-plain','400: reasoning_effort is not enabled for this model')
  self.assertEqual(sent,['high',None]);self.assertEqual(out,['ok'])
  self.assertIn('t-plain',P.MISTRAL_NO_REASONING)
  sent,_=self._mistral('t-plain',None);self.assertEqual(sent,[None])
 def test_mistral_rate_limit_not_retried(self):
  P.MISTRAL_NO_REASONING.discard('t-busy')
  with self.assertRaises(RuntimeError):self._mistral('t-busy','429: Rate limit exceeded')
  self.assertNotIn('t-busy',P.MISTRAL_NO_REASONING)

class ClaudeLimitsTest(unittest.TestCase):
 def test_listed_limits_and_thinking(self):
  import discovery as D
  caps={'thinking':{'supported':True,'types':{'enabled':{'supported':False},'adaptive':{'supported':True}}}}
  self.assertEqual(D._claude_thinking_type(caps),'adaptive')
  self.assertEqual(D._claude_thinking_type({'thinking':{'supported':True,'types':{'enabled':{'supported':True},'adaptive':{'supported':False}}}}),'enabled')
  self.assertEqual(D._claude_thinking_type({}),'')
  P.CLAUDE_LIMITS.pop('m-new',None)
  self.assertEqual(P.claude_max_tokens('m-new',{'max_output':128000}),128000)
  self.assertEqual(P.claude_max_tokens('m-new',{}),P.CLAUDE_MAX_TOKENS)
  self.assertEqual(P.claude_thinking_type('claude-new',{'thinking':'enabled'}),'enabled')
  self.assertEqual(P.claude_thinking_type('claude-new',{'thinking':''}),'')
  self.assertEqual(P.claude_thinking_type('claude-opus-5-5',{}),'adaptive')
 def test_payload_uses_live_info(self):
  sent=[]
  def post(u,p,h,c,e):sent.append(p);return io.BytesIO()
  P.set_live(None,None,None,lambda prov,m:{'max_output':128000,'thinking':'enabled'})
  try:
   with patch('providers._post_stream',side_effect=post),patch('providers.iter_sse',return_value=iter([])),patch('integrations.read',return_value={'claude_thinking':True}):
    list(P.stream_claude('k','claude-x','s',[{'role':'user','content':'h'}],[],{},None,lambda x,c:x))
  finally:P.set_live(None,None,None,None)
  self.assertEqual(sent[0]['max_tokens'],128000)
  self.assertEqual(sent[0]['thinking'],{'type':'enabled','budget_tokens':2048})
if __name__=='__main__':unittest.main()
