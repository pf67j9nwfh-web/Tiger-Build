#!/usr/bin/env python3
"""Built-in agent toolbox / Brave Search MCP, newline JSON-RPC over stdio.
Uses integrations.json. All enabled tools can be used by other MCP clients:
  python3 agent_tools_mcp.py --provider claude
The relay uses the same handlers in-process to avoid spawning a subprocess
for simple time/notes/search operations. No credentials are sent over MCP.
"""
import json, sys
from integrations import read, auxiliary, run_auxiliary

def respond(request):
    method=request.get('method'); params=request.get('params') or {}
    if method=='initialize':
        return {'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'tiger-agent-toolbox','version':'1.4'}}
    provider=sys.argv[sys.argv.index('--provider')+1] if '--provider' in sys.argv else 'other'
    config=read();tools=auxiliary(provider,config)
    if method=='tools/list':
        return {'tools':[{'name':t['name'],'description':t['description'],'inputSchema':t['parameters']} for t in tools]}
    if method=='tools/call':
        name=params.get('name')
        if name not in [t['name'] for t in tools]:raise ValueError('Tool is not enabled.')
        try:
            text=run_auxiliary(name,params.get('arguments') or {},config)
            return {'content':[{'type':'text','text':text}],'isError':False}
        except Exception as exc:
            return {'content':[{'type':'text','text':str(exc)}],'isError':True}
    if method=='ping':return {}
    raise ValueError('Unknown MCP method.')

for line in sys.stdin:
    request={}
    try:
        request=json.loads(line)
        if request.get('id') is None:continue
        result=respond(request)
        response={'jsonrpc':'2.0','id':request['id'],'result':result}
    except Exception as exc:
        response={'jsonrpc':'2.0','id':request.get('id'),'error':{'code':-32602,'message':str(exc)}}
    sys.stdout.write(json.dumps(response)+'\n');sys.stdout.flush()
