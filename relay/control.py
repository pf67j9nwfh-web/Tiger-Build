#!/usr/bin/env python3
"""Local GUI/CLI service controller. Never exposed by the HTTP relay.
Usage: control.py status|start|stop|save|autostart|clear-all|clear|config
       integrations|integrations-save|settings-export|settings-import|history-import
       ssh-test|ssh-save|ssh-forget
save/autostart/clear/ssh-save read JSON on stdin. No passwords in process arguments.

macOS uses launchd. Linux uses a systemd user service when a user session
exists, otherwise the same supervisor Windows uses. Windows uses a logon
task (or a Startup shortcut) plus relay/service_host.py. Stop really stops.
Turning autostart off does not stop the process that is already running.
"""
import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from app_config import FIELDS, DEFAULT_LOCAL_URL, ensure_config_file, read_config, update_settings
from mcp_bridge import load_shell_config
from security import listen_address, relay_token, support_dir
from version import VERSION

SUPPORT = Path(support_dir())
LABEL = 'local.tigerbuild.relay'
TASK = 'Tiger Build Relay'
DOMAIN = 'gui/%d' % (os.getuid() if hasattr(os, 'getuid') else 0)
AGENT = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
MANUAL = SUPPORT / 'service.plist'
from paths import config_sh
CONFIG = Path(config_sh())
ROOT = Path(__file__).resolve().parent.parent
UNIT = Path.home() / '.config/systemd/user' / (LABEL + '.service')


def _alive(pid):
    from procutil import pid_alive
    return pid_alive(pid)


def _read_pid(name):
    try:
        return int((SUPPORT / name).read_text().strip() or '0')
    except (OSError, ValueError):
        return 0


def _kill(pid):
    if not _alive(pid):
        return
    if sys.platform == 'win32':
        subprocess.run(
            ['taskkill', '/PID', str(pid), '/T', '/F'],
            capture_output=True, timeout=15,
            startupinfo=_hidden_startup(),
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
        )
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

def launch(*args):
    return subprocess.run(['/bin/launchctl'] + list(args), capture_output=True, text=True, timeout=15)


def _systemd_env():
    env = os.environ.copy()
    runtime = env.get('XDG_RUNTIME_DIR') or ('/run/user/%d' % os.getuid())
    if os.path.isdir(runtime):
        env['XDG_RUNTIME_DIR'] = runtime
        env.setdefault('DBUS_SESSION_BUS_ADDRESS', 'unix:path=%s/bus' % runtime)
    return env


def _systemctl(*args):
    return subprocess.run(['systemctl', '--user'] + list(args), capture_output=True, text=True, timeout=20, env=_systemd_env())


def systemd_user():
    if sys.platform != 'linux':
        return False
    env = _systemd_env()
    if not os.path.isdir(env.get('XDG_RUNTIME_DIR', '')):
        return False
    result = subprocess.run(['systemctl', '--user', 'is-system-running'], capture_output=True, text=True, timeout=15, env=env)
    text = ((result.stdout or '') + (result.stderr or '')).lower()
    return result.returncode == 0 or 'running' in text or 'degraded' in text


def running_mac():
    result = launch('print', DOMAIN + '/' + LABEL)
    match = re.search(r'\bpid = (\d+)', result.stdout)
    return int(match.group(1)) if match else 0


def running_linux():
    if systemd_user() and UNIT.exists():
        result = _systemctl('show', LABEL + '.service', '-p', 'MainPID', '--value')
        try:
            pid = int((result.stdout or '').strip() or '0')
        except ValueError:
            pid = 0
        if _alive(pid):
            return pid
    pid = _read_pid('relay.pid')
    return pid if _alive(pid) else 0


def running_windows():
    pid = _read_pid('relay.pid')
    return pid if _alive(pid) else 0


def running():
    if sys.platform == 'darwin':
        return running_mac()
    if sys.platform == 'win32':
        return running_windows()
    return running_linux()


def agent_path():
    return AGENT if AGENT.exists() else MANUAL


def write_agent(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {'Label': LABEL, 'ProgramArguments': [sys.executable, str(ROOT / 'relay/chat_proxy.py')],
            'WorkingDirectory': str(ROOT), 'RunAtLoad': True, 'KeepAlive': True,
            'ThrottleInterval': 10, 'StandardErrorPath': str(SUPPORT / 'relay.log'),
            'StandardOutPath': str(SUPPORT / 'relay.log')}
    with open(path, 'wb') as f:
        plistlib.dump(data, f)
    os.chmod(path, 0o600)


def _quote(path):
    if re.search(r'[\s"]', path):
        return '"' + path.replace('"', '\\"') + '"'
    return path


def write_linux_unit():
    UNIT.parent.mkdir(parents=True, exist_ok=True)
    proxy = str(ROOT / 'relay' / 'chat_proxy.py')
    text = (
        '[Unit]\nDescription=Tiger Build Relay\nAfter=network-online.target\n\n'
        '[Service]\nType=simple\nExecStart=%s %s\nWorkingDirectory=%s\n'
        'Restart=always\nRestartSec=10\nEnvironment=TIGERBUILD_RELAY_HOME=%s\n'
        'StandardOutput=append:%s\nStandardError=append:%s\n\n'
        '[Install]\nWantedBy=default.target\n'
    ) % (_quote(sys.executable), _quote(proxy), _quote(str(ROOT)), _quote(str(SUPPORT)),
         _quote(str(SUPPORT / 'relay.log')), _quote(str(SUPPORT / 'relay.log')))
    UNIT.write_text(text)
    os.chmod(UNIT, 0o644)


def _pythonw():
    if sys.platform != 'win32':
        return sys.executable
    sibling = os.path.join(os.path.dirname(sys.executable), 'pythonw.exe')
    return sibling if os.path.isfile(sibling) else sys.executable


def _startup_dir():
    appdata = os.environ.get('APPDATA') or str(Path.home() / 'AppData' / 'Roaming')
    return Path(appdata) / 'Microsoft' / 'Windows' / 'Start Menu' / 'Programs' / 'Startup'


def _startup_cmd():
    # Written by earlier builds. A batch file keeps a console open while the relay runs.
    return _startup_dir() / (TASK + '.cmd')


def _startup_link():
    return _startup_dir() / (TASK + '.lnk')


def _remove_startup_entries():
    for entry in (_startup_cmd(), _startup_link()):
        if entry.exists():
            entry.unlink()


def _write_startup_link(host):
    """Startup-folder shortcut straight to pythonw, so no console opens at login."""
    _startup_dir().mkdir(parents=True, exist_ok=True)
    script = (
        "$ErrorActionPreference = 'Stop'; "
        "$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:TB_LINK); "
        "$s.TargetPath = $env:TB_PY; $s.Arguments = $env:TB_ARGS; "
        "$s.WorkingDirectory = $env:TB_WD; $s.Description = 'Tiger Build Relay'; $s.Save()"
    )
    result = _ps(script, {'TB_LINK': str(_startup_link()), 'TB_PY': _pythonw(),
                          'TB_ARGS': '"%s" --login' % host, 'TB_WD': str(ROOT)})
    if result.returncode or not _startup_link().is_file():
        raise RuntimeError('Could not turn on start at login. See relay.log.')
    if _startup_cmd().exists():
        _startup_cmd().unlink()


def _hidden_startup():
    if sys.platform != 'win32':
        return None
    info = subprocess.STARTUPINFO()
    info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    info.wShowWindow = 0
    return info


def _ps(script, extra):
    env = os.environ.copy()
    env.update(extra)
    return subprocess.run(
        ['powershell', '-WindowStyle', 'Hidden', '-NoProfile', '-Command', script],
        capture_output=True, text=True, timeout=40, env=env,
        startupinfo=_hidden_startup(),
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
    )


def write_windows_task(enabled):
    host = str(ROOT / 'relay' / 'service_host.py')
    extra = {
        'TB_PY': _pythonw(),
        'TB_ARGS': '"%s" --login' % host,
        'TB_WD': str(ROOT),
        'TB_TASK': TASK,
        'TB_ENABLE': '1' if enabled else '0',
    }
    script = (
        "$ErrorActionPreference = 'Stop'; "
        "$action = New-ScheduledTaskAction -Execute $env:TB_PY -Argument $env:TB_ARGS -WorkingDirectory $env:TB_WD; "
        "$trigger = New-ScheduledTaskTrigger -AtLogOn; "
        "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries "
        "-ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew; "
        "Register-ScheduledTask -TaskName $env:TB_TASK -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null; "
        "if ($env:TB_ENABLE -eq '1') { Enable-ScheduledTask -TaskName $env:TB_TASK | Out-Null } "
        "else { Disable-ScheduledTask -TaskName $env:TB_TASK | Out-Null }"
    )
    if not enabled:
        _remove_startup_entries()
    result = _ps(script, extra)
    if result.returncode:
        if not enabled and windows_task_state() not in ('', 'disabled'):
            raise RuntimeError('Could not disable the scheduled task. Start at login was not changed.')
        if enabled:
            # Logon tasks can need elevation. A Startup shortcut needs none.
            _write_startup_link(host)
        return
    _remove_startup_entries()


def windows_task_state():
    result = _ps("(Get-ScheduledTask -TaskName $env:TB_TASK -ErrorAction SilentlyContinue).State", {'TB_TASK': TASK})
    return (result.stdout or '').strip().lower()


def spawn_host():
    host = str(ROOT / 'relay' / 'service_host.py')
    if sys.platform == 'win32':
        flags = 0x00000008 | 0x00000200 | 0x08000000
        subprocess.Popen([_pythonw(), host], cwd=str(ROOT), stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=flags, close_fds=True)
    else:
        subprocess.Popen([sys.executable, host], cwd=str(ROOT), stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)


def _wait_until(predicate, attempts=30, pause=0.1):
    for _ in range(attempts):
        if predicate():
            return True
        time.sleep(pause)
    return False


def stop():
    if sys.platform == 'darwin':
        launch('bootout', DOMAIN + '/' + LABEL)
        if not _wait_until(lambda: not running(), 20):
            raise RuntimeError('launchd did not stop the relay.')
        return
    (SUPPORT / 'relay.stop').write_text('stop\n')
    if sys.platform == 'win32':
        subprocess.run(
            ['schtasks', '/End', '/TN', TASK],
            capture_output=True, timeout=20,
            startupinfo=_hidden_startup(),
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
        )
    elif systemd_user():
        _systemctl('stop', LABEL + '.service')
    time.sleep(0.6)
    _kill(_read_pid('relay-host.pid'))
    _kill(_read_pid('relay.pid'))
    if not _wait_until(lambda: not running(), 20):
        raise RuntimeError('The relay did not stop. See relay.log.')


def start():
    if running():
        return
    stop_file = SUPPORT / 'relay.stop'
    if stop_file.exists():
        stop_file.unlink()
    if sys.platform == 'darwin':
        launch('bootout', DOMAIN + '/' + LABEL)
        path = agent_path()
        write_agent(path)
        launch('enable', DOMAIN + '/' + LABEL)
        result = launch('bootstrap', DOMAIN, str(path))
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or 'Could not start relay.')
    elif sys.platform == 'linux' and systemd_user():
        write_linux_unit()
        _systemctl('daemon-reload')
        _systemctl('reset-failed', LABEL + '.service')
        result = _systemctl('start', LABEL + '.service')
        if result.returncode and not running():
            raise RuntimeError(result.stderr.strip() or 'Could not start relay.')
    else:
        spawn_host()
    if not _wait_until(running, 40, 0.2):
        raise RuntimeError('Relay failed to start. See relay.log.')


def autostart(enabled):
    if sys.platform == 'darwin':
        if enabled:
            write_agent(AGENT)
            MANUAL.unlink(missing_ok=True)
        else:
            write_agent(MANUAL)
            AGENT.unlink(missing_ok=True)
        return
    if sys.platform == 'win32':
        write_windows_task(bool(enabled))
        return
    if systemd_user():
        write_linux_unit()
        _systemctl('daemon-reload')
        result = _systemctl('enable' if enabled else 'disable', LABEL + '.service')
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or 'Could not change start-at-login.')
        return
    # No user session: a desktop autostart file is the closest equivalent.
    desktop = Path.home() / '.config' / 'autostart' / 'tiger-build-relay.desktop'
    if enabled:
        desktop.parent.mkdir(parents=True, exist_ok=True)
        desktop.write_text(
            '[Desktop Entry]\nType=Application\nName=Tiger Build Relay\n'
            'Exec=%s %s --login\nX-GNOME-Autostart-enabled=true\n' % (sys.executable, ROOT / 'relay' / 'service_host.py')
        )
    elif desktop.exists():
        desktop.unlink()


def autostart_on():
    if sys.platform == 'darwin':
        return AGENT.exists()
    if sys.platform == 'win32':
        state = windows_task_state()
        if state and state != 'disabled':
            return True
        return _startup_link().is_file() or _startup_cmd().is_file()
    if systemd_user():
        result = _systemctl('is-enabled', LABEL + '.service')
        return (result.stdout or '').strip() == 'enabled'
    return (Path.home() / '.config' / 'autostart' / 'tiger-build-relay.desktop').is_file()


def save_port(number):
    port = int(number)
    if not 1 <= port <= 65535:
        raise ValueError('Port must be between 1 and 65535.')
    text = CONFIG.read_text() if CONFIG.exists() else ''
    line = 'LISTEN_PORT="%d"' % port
    if re.search(r'^LISTEN_PORT=.*$', text, re.M):
        text = re.sub(r'^LISTEN_PORT=.*$', line, text, flags=re.M)
    else:
        text += '\n' + line + '\n'
    CONFIG.write_text(text)
    try:
        os.chmod(CONFIG, 0o600)
    except OSError:
        pass


def last_client():
    try:
        with open(SUPPORT / 'last-client.json') as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return {k: data[k] for k in ('address', 'machine', 'os', 'user', 'seen') if k in data}


def status():
    config = load_shell_config()
    data = read_config()
    address = listen_address(config)
    return {'pid': running(), 'autostart': autostart_on(), 'address': address,
            'port': int(config.get('LISTEN_PORT') or 8765),
            'url': 'http://%s:%s' % (address, config.get('LISTEN_PORT') or 8765),
            'local_url': data.get('local_url') or '', 'default_local': DEFAULT_LOCAL_URL,
            'saved': {name: bool(data.get(name)) for name, _env in FIELDS},
            'token': relay_token(config), 'log': str(SUPPORT / 'relay.log'),
            'support': str(SUPPORT), 'config': str(CONFIG),
            'tiger_host': config.get('TIGER_HOST') or '', 'tiger_user': config.get('TIGER_USER') or '',
            'tiger_home': config.get('TIGER_HOME') or '',
            'last_client': last_client(), 'version': VERSION,
            'history': str(SUPPORT / 'history/TigerBuild-history.plist'),
            'has_history': (SUPPORT / 'history/TigerBuild-history.plist').is_file()}


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    ensure_config_file(str(ROOT / '.env'))
    if cmd in ('save', 'autostart', 'clear', 'history-import', 'integrations-save', 'settings-import', 'ssh-save'):
        incoming = json.load(sys.stdin)
    if cmd in ('ssh-test', 'ssh-save', 'ssh-forget'):
        import connection
        changed = False
        if cmd == 'ssh-save':
            before = load_shell_config()
            changes = {}
            for field, name in (('host', 'TIGER_HOST'), ('user', 'TIGER_USER'), ('home', 'TIGER_HOME')):
                if field in incoming:
                    changes[name] = incoming.get(field) or ''
            config = connection.update_config(changes)
            changed = config.get('TIGER_HOST') != before.get('TIGER_HOST')
            if config.get('TIGER_HOST') and config.get('TIGER_USER'):
                connection.ensure_key(config)
                try:
                    connection.remember_host_key(config)
                except RuntimeError as exc:
                    out = status()
                    out['ssh_result'] = {'ok': False, 'code': 'hostkey', 'message': str(exc)}
                    print(json.dumps(out))
                    return
        elif cmd == 'ssh-forget':
            connection.forget_host_key()
            config = load_shell_config()
            if config.get('TIGER_HOST'):
                try:
                    connection.remember_host_key(config)
                except RuntimeError:
                    pass
        if changed and running():
            stop()
            start()
        out = status()
        out['ssh_result'] = connection.test(load_shell_config())
        print(json.dumps(out))
        return
    elif cmd == 'integrations-save':
        from integrations import write
        write(incoming, preserve_key=True)
    elif cmd == 'settings-import':
        import base64
        from config_backup import restore
        payload = base64.b64decode(incoming['data'], validate=True)
        if len(payload)>3*1024*1024: raise ValueError('Backup exceeds 3 MB.')
        wrapper = plistlib.loads(payload)
        if isinstance(wrapper,dict) and wrapper.get('format')=='TigerBuild-config':
            payload = wrapper.get('relay')
            if not isinstance(payload,bytes):raise ValueError('Missing relay backup in client export.')
        obj = restore(payload, connection=True)
        autostart(obj.get('autostart', False))
        (SUPPORT / 'models-cache.json').unlink(missing_ok=True)
        if running(): stop(); start()
    elif cmd == 'settings-export':
        import base64
        from config_backup import export
        print(json.dumps({'data': base64.b64encode(export()).decode()}))
        return
    elif cmd == 'integrations':
        from integrations import public
        print(json.dumps(public()))
        return
    elif cmd == 'history-import':
        import base64
        from history_store import save_snapshot
        save_snapshot(base64.b64decode(incoming.get('data', ''), validate=True))
    elif cmd == 'start':
        start()
    elif cmd == 'stop':
        stop()
    elif cmd == 'autostart':
        autostart(bool(incoming.get('enabled')))
    elif cmd in ('save', 'clear', 'clear-all'):
        if cmd == 'clear-all':
            incoming = {'clear_all': True}
        if cmd == 'save' and 'port' in incoming:
            save_port(incoming['port'])
        update_settings(incoming)
        if incoming.get('clear_all') is True:
            from integrations import write as reset_integrations
            reset_integrations({})
        (SUPPORT / 'models-cache.json').unlink(missing_ok=True)
        if running():
            stop()
            start()
    elif cmd not in ('status', 'config'):
        raise ValueError('Unknown command: ' + cmd)
    print(json.dumps(status()))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(json.dumps({'error': str(exc)}))
        sys.exit(1)
