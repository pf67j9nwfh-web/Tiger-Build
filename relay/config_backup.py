"""Versioned configuration backup: includes secrets, excludes chat history,
SSH private-key bytes, model caches, and executable code. Plist for Tiger.
Imported custom MCPs are disabled until explicitly enabled by the user.
"""
import os, plistlib, shlex, re
from app_config import read_config, write_config, apply_config, FIELDS, normalize_local_url
from integrations import read as read_integrations, validate, write as write_integrations
from mcp_bridge import load_shell_config
from paths import config_sh
from security import support_dir, token_path, relay_token
def _autostart():
    try:
        import control
        return bool(control.autostart_on())
    except Exception:
        return os.path.isfile(os.path.expanduser('~/Library/LaunchAgents/local.tigerbuild.relay.plist'))

SHELL_KEYS=('TIGER_HOST','TIGER_USER','TIGER_KEY','TIGER_KNOWN','REMOTE_COMMANDER','LISTEN_PORT','LISTEN_ADDR','ALLOWED_CLIENTS')

def export():
    config=load_shell_config()
    return plistlib.dumps({'format':'TigerBuildRelay-config','version':1,'providers':read_config(),
        'integrations':read_integrations(), 'connection':{k:config[k] for k in SHELL_KEYS if k in config},
        'relay_token':relay_token(config),
        'autostart':_autostart()},fmt=plistlib.FMT_XML)

def restore(payload, connection=False):
    if len(payload)>2*1024*1024:raise ValueError('Configuration is larger than 2 MB.')
    try:obj=plistlib.loads(payload)
    except Exception:raise ValueError('Invalid configuration plist.')
    if not isinstance(obj,dict) or obj.get('format') not in ('TigerBuildRelay-config','TigerDesk-config') or obj.get('version')!=1:
        raise ValueError('Not a supported Tiger Build Relay configuration backup.')
    providers=obj.get('providers'); integration=validate(obj.get('integrations',{}))
    if not isinstance(providers,dict):raise ValueError('Missing provider configuration.')
    for name,_env in FIELDS:
        if not isinstance(providers.get(name,''),str):raise ValueError('Provider fields must be text.')
    if providers.get('local_url'): providers['local_url']=normalize_local_url(providers['local_url'])
    # Never start an imported executable just because someone imports a file.
    for server in integration['servers']:server['enabled']=False
    config=obj.get('connection',{})
    if not isinstance(config,dict):raise ValueError('Malformed connection configuration.')
    for k,v in config.items():
        if k not in SHELL_KEYS or not isinstance(v,str) or '\n' in v or '\r' in v:raise ValueError('Invalid connection setting.')
    remote=config.get('REMOTE_COMMANDER','')
    if remote and not re.fullmatch(r'(?:\$HOME/|/)[A-Za-z0-9_./ -]+\.py',remote):
        raise ValueError('REMOTE_COMMANDER must be a Python script path, not a shell command.')
    port=int(config.get('LISTEN_PORT','8765'))
    if not 1<=port<=65535:raise ValueError('Invalid relay port.')
    token=obj.get('relay_token','')
    if not isinstance(token,str) or '\n' in token or '\r' in token:raise ValueError('Invalid relay token.')
    if connection and not token.strip():raise ValueError('Backup has no relay token; refusing to leave an old token in place.')
    current=obj.get('autostart',False)
    if type(current) is not bool:raise ValueError('Invalid autostart option.')
    write_config(providers);apply_config(providers);write_integrations(integration)
    if connection:
        path=config_sh()
        # Render only recognised values, safely quoted; no imported shell code.
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as f:
            for k,v in config.items():
                if k in ('TIGER_KEY','TIGER_KNOWN'):v=v.replace('$HOME',os.path.expanduser('~'))
                f.write(k+'='+shlex.quote(v)+'\n')
        os.chmod(path,0o600)
        if token:
            fd=os.open(token_path(),os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
            with os.fdopen(fd,'w') as f:f.write(token+'\n')
    return obj
