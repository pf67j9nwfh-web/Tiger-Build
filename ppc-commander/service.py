#!/usr/bin/python
# Tiger Python 2.3 lifecycle controller. A local supervisor plus SSH sessions.
import os, sys, signal, time, socket
ROOT = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.expanduser('~/Library/Application Support/Tiger Build/commander')
PID = os.path.join(STATE, 'supervisor.pid')
DISABLED = os.path.join(STATE, 'disabled')
AGENT = os.path.expanduser('~/Library/LaunchAgents/local.tigerbuild.commander.plist')
if not os.path.isdir(STATE):
    os.makedirs(STATE, 0700)

def live():
    try:
        pid = int(open(PID).read())
        os.kill(pid, 0)
        f = os.popen('/bin/ps -p %d -o command=' % pid)
        command = f.read(); f.close()
        return command.find('service.py') >= 0 and pid or 0
    except (IOError, ValueError, OSError):
        return 0

def remove(path):
    try: os.unlink(path)
    except OSError: pass

def supervisor():
    if live(): return
    child = os.fork()
    if child: return
    os.setsid()
    fd = os.open('/dev/null', os.O_RDWR)
    for n in (0, 1, 2): os.dup2(fd, n)
    f = open(PID, 'w'); f.write(str(os.getpid())); f.close()
    def finish(sig, frame):
        remove(PID)
        os._exit(0)
    signal.signal(signal.SIGTERM, finish)
    while True: time.sleep(30)

def start():
    remove(DISABLED)
    supervisor()

def stop():
    f = open(DISABLED, 'w'); f.write('Stopped by user\n'); f.close()
    for name in os.listdir(STATE):
        if not name.startswith('session-'): continue
        try:
            pid = int(name[8:])
            f = os.popen('/bin/ps -p %d -o command=' % pid)
            command = f.read(); f.close()
            if 'ppc_commander.py' in command:
                os.kill(pid, signal.SIGTERM)
        except (ValueError, OSError): pass
        remove(os.path.join(STATE, name))
    pid = live()
    if pid:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
    remove(PID)

def autostart(enabled):
    if not enabled:
        remove(AGENT)
        return
    folder = os.path.dirname(AGENT)
    if not os.path.isdir(folder): os.makedirs(folder)
    import xml.sax.saxutils
    script = xml.sax.saxutils.escape(os.path.join(ROOT, 'service.py'))
    text = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>local.tigerbuild.commander</string>
<key>ProgramArguments</key><array><string>/usr/bin/python</string><string>%s</string><string>start</string></array>
<key>RunAtLoad</key><true/></dict></plist>''' % script
    f = open(AGENT, 'w'); f.write(text); f.close()
    os.chmod(AGENT, 0600)

cmd = len(sys.argv) > 1 and sys.argv[1] or 'status'
if cmd == 'start': start()
elif cmd == 'stop': stop()
elif cmd == 'autostart-on': autostart(True)
elif cmd == 'autostart-off': autostart(False)
elif cmd != 'status': raise ValueError('Unknown command')
print 'enabled=%d' % (not os.path.exists(DISABLED))
print 'running=%d' % bool(live())
print 'autostart=%d' % os.path.isfile(AGENT)
f = os.popen('/sbin/ifconfig'); lines = f.readlines(); f.close()
ips = []
for line in lines:
    words = line.split()
    if len(words) > 1 and words[0] == 'inet' and words[1] != '127.0.0.1': ips.append(words[1])
print 'ip=%s' % ', '.join(ips)
