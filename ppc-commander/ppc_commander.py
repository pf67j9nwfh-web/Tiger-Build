#!/usr/bin/python -u
# ppc-commander: a Desktop Commander-style MCP server for Mac OS X 10.4 Tiger.
#
# This file is Python 2.3 on purpose. Tiger's system Python is 2.3.5.
# Do not use print functions, with, except-as, set(), sorted(), decorators,
# json, subprocess, hashlib, or 0o octal literals.
#
# The copy that actually runs lives on the Tiger Mac at
# ~/ppc-commander/ppc_commander.py. Edit this file on the relay Mac
# and upload it again. Stdio is the MCP stream: logs go to stderr only.

import difflib
import fnmatch
import grp
import os
import pwd
import re
import shutil
import signal
import socket
import stat as statmod
import struct
import sys
import termios
import threading
import time
import unicodedata
import urllib2

try:
    import fcntl
except ImportError:
    fcntl = None

try:
    import pty
except ImportError:
    pty = None

VERSION = '0.3.0'
MAX_MESSAGE = 16 * 1024 * 1024
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_OUTPUT_CHARS = 180000
MAX_PROCESS_OUTPUT = 1500000
HISTORY_MAX_BYTES = 150000
HISTORY_KEEP_LINES = 200
SKIP_DIRS = {
    '/dev': 1,
    '/automount': 1,
    '/.vol': 1,
    '/net': 1,
    '/Network': 1,
}

CONFIG = {}
SYSINFO = {}
SESSIONS = {}
SEARCHES = {}
SEARCH_SEQ = [0]
USAGE = {'started': '', 'tool_calls': 0, 'errors': 0, 'by_tool': {}}

DEFAULT_CONFIG = {
    'blockedCommands': [
        'mkfs', 'mkfs_hfs', 'newfs', 'newfs_hfs', 'fdisk',
        'dd', 'shutdown', 'reboot', 'halt', 'poweroff',
    ],
    'defaultShell': '/bin/bash',
    'allowedDirectories': [],
    'fileReadLineLimit': 1000,
    'fileWriteLineLimit': 1000,
    'telemetryEnabled': False,
}


# These keys decide what the model may run and touch, so the model may not
# change them. They come from config.json, which the file tools may not edit,
# and a root-owned /etc/ppc-commander.json overrides them when it exists.
LOCKED_KEYS = ['blockedCommands', 'allowedDirectories', 'defaultShell']
POLICY_PATH = '/etc/ppc-commander.json'

# Programs that run the word after them. A blocked name anywhere after one of
# these, in the same command, is treated as the program being run.
WRAPPERS = [
    'sudo', 'env', 'exec', 'nohup', 'time', 'nice', 'xargs', 'eval', 'command',
    'builtin', 'arch', 'caffeinate', 'osascript', 'perl', 'python', 'ruby',
    'sh', 'bash', 'zsh', 'csh', 'tcsh', 'ksh', 'dash', 'source', '.',
]


class ToolError(Exception):
    pass


class JsonError(Exception):
    pass


def log(msg):
    sys.stderr.write('[ppc-commander] %s\n' % msg)
    try:
        sys.stderr.flush()
    except IOError:
        pass


def script_dir():
    return os.path.dirname(os.path.abspath(__file__))


def config_path():
    return os.path.join(script_dir(), 'config.json')


def history_path():
    return os.path.join(script_dir(), 'tool-history.jsonl')


def usage_path():
    return os.path.join(script_dir(), 'usage.json')


def now_iso():
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime())


def clip(text, limit):
    if text is None:
        return ''
    if isinstance(text, unicode):
        text = text.encode('utf-8', 'replace')
    if not isinstance(text, str):
        text = str(text)
    if len(text) <= limit:
        return text
    return text[:limit] + '...(%d chars)' % len(text)


def as_str(value):
    if isinstance(value, unicode):
        return value.encode('utf-8')
    if isinstance(value, str):
        return value
    raise ToolError('expected a string')


def as_int(value):
    if isinstance(value, bool) or not isinstance(value, (int, long, float)):
        raise ToolError('expected a number')
    if isinstance(value, float):
        iv = int(value)
        if float(iv) != value:
            raise ToolError('expected an integer')
        return iv
    return int(value)


def as_bool(value):
    if isinstance(value, bool):
        return value
    raise ToolError('expected a boolean')


def need_str(args, key):
    if not isinstance(args, dict) or key not in args or args[key] is None:
        raise ToolError('missing %s' % key)
    return as_str(args[key])


def opt_str(args, key, default=None):
    if not isinstance(args, dict) or key not in args or args[key] is None:
        return default
    return as_str(args[key])


def need_int(args, key):
    if not isinstance(args, dict) or key not in args or args[key] is None:
        raise ToolError('missing %s' % key)
    return as_int(args[key])


def opt_int(args, key, default):
    if not isinstance(args, dict) or key not in args or args[key] is None:
        return default
    return as_int(args[key])


def opt_bool(args, key, default):
    if not isinstance(args, dict) or key not in args or args[key] is None:
        return default
    return as_bool(args[key])


def as_str_list(value):
    if not isinstance(value, list):
        raise ToolError('expected an array of strings')
    out = []
    for item in value:
        out.append(as_str(item))
    return out


# --- JSON (the subset MCP needs; Python 2.3 has no json module) ---

def _utf8_char(text, index):
    o = ord(text[index])
    if o < 128:
        return unichr(o), index + 1
    if (o & 0xE0) == 0xC0:
        n = 2
    elif (o & 0xF0) == 0xE0:
        n = 3
    elif (o & 0xF8) == 0xF0:
        n = 4
    else:
        return unichr(o), index + 1
    if index + n > len(text):
        raise JsonError('truncated utf-8 in string')
    chunk = text[index:index + n]
    try:
        return chunk.decode('utf-8'), index + n
    except UnicodeError:
        return unichr(o), index + 1


class JsonParser:
    def __init__(self, text):
        if isinstance(text, unicode):
            text = text.encode('utf-8')
        if not isinstance(text, str):
            raise JsonError('json input must be a string')
        if text.startswith('\xef\xbb\xbf'):
            text = text[3:]
        self.s = text
        self.i = 0
        self.n = len(text)

    def parse(self):
        value = self.value()
        self.skip()
        if self.i != self.n:
            raise JsonError('trailing data')
        return value

    def skip(self):
        while self.i < self.n and self.s[self.i] in ' \t\r\n':
            self.i += 1

    def peek(self):
        self.skip()
        if self.i >= self.n:
            return ''
        return self.s[self.i]

    def value(self):
        c = self.peek()
        if c == '':
            raise JsonError('unexpected end')
        if c == '{':
            return self.object()
        if c == '[':
            return self.array()
        if c == '"':
            return self.string()
        if c == 't':
            return self.literal('true', True)
        if c == 'f':
            return self.literal('false', False)
        if c == 'n':
            return self.literal('null', None)
        if c == '-' or c in '0123456789':
            return self.number()
        raise JsonError('unexpected %r' % c)

    def literal(self, text, value):
        self.skip()
        if self.s[self.i:self.i + len(text)] != text:
            raise JsonError('expected %s' % text)
        self.i += len(text)
        return value

    def number(self):
        self.skip()
        start = self.i
        if self.s[self.i] == '-':
            self.i += 1
        if self.i >= self.n or self.s[self.i] not in '0123456789':
            raise JsonError('bad number')
        if self.s[self.i] == '0':
            self.i += 1
        else:
            while self.i < self.n and self.s[self.i] in '0123456789':
                self.i += 1
        is_float = False
        if self.i < self.n and self.s[self.i] == '.':
            is_float = True
            self.i += 1
            if self.i >= self.n or self.s[self.i] not in '0123456789':
                raise JsonError('bad number')
            while self.i < self.n and self.s[self.i] in '0123456789':
                self.i += 1
        if self.i < self.n and self.s[self.i] in 'eE':
            is_float = True
            self.i += 1
            if self.i < self.n and self.s[self.i] in '+-':
                self.i += 1
            if self.i >= self.n or self.s[self.i] not in '0123456789':
                raise JsonError('bad number')
            while self.i < self.n and self.s[self.i] in '0123456789':
                self.i += 1
        token = self.s[start:self.i]
        if is_float:
            return float(token)
        return int(token)

    def string(self):
        self.skip()
        if self.s[self.i] != '"':
            raise JsonError('expected string')
        self.i += 1
        parts = []
        while self.i < self.n:
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return u''.join(parts).encode('utf-8')
            if c == '\\':
                self.i += 1
                if self.i >= self.n:
                    raise JsonError('bad escape')
                e = self.s[self.i]
                self.i += 1
                if e == '"':
                    parts.append(u'"')
                elif e == '\\':
                    parts.append(u'\\')
                elif e == '/':
                    parts.append(u'/')
                elif e == 'b':
                    parts.append(u'\b')
                elif e == 'f':
                    parts.append(u'\f')
                elif e == 'n':
                    parts.append(u'\n')
                elif e == 'r':
                    parts.append(u'\r')
                elif e == 't':
                    parts.append(u'\t')
                elif e == 'u':
                    hexed = self.s[self.i:self.i + 4]
                    if len(hexed) != 4:
                        raise JsonError('bad unicode escape')
                    self.i += 4
                    try:
                        parts.append(unichr(int(hexed, 16)))
                    except ValueError:
                        raise JsonError('bad unicode escape')
                else:
                    raise JsonError('bad escape')
            else:
                ch, self.i = _utf8_char(self.s, self.i)
                parts.append(ch)
        raise JsonError('unterminated string')

    def object(self):
        self.skip()
        self.i += 1
        out = {}
        if self.peek() == '}':
            self.i += 1
            return out
        while True:
            key = self.string()
            if self.peek() != ':':
                raise JsonError('expected colon')
            self.i += 1
            out[key] = self.value()
            c = self.peek()
            if c == ',':
                self.i += 1
                continue
            if c == '}':
                self.i += 1
                return out
            raise JsonError('expected comma or }')

    def array(self):
        self.skip()
        self.i += 1
        out = []
        if self.peek() == ']':
            self.i += 1
            return out
        while True:
            out.append(self.value())
            c = self.peek()
            if c == ',':
                self.i += 1
                continue
            if c == ']':
                self.i += 1
                return out
            raise JsonError('expected comma or ]')


def loads(text):
    return JsonParser(text).parse()


def _enc_string(text, parts):
    parts.append('"')
    for ch in text:
        o = ord(ch)
        if ch == u'"':
            parts.append('\\"')
        elif ch == u'\\':
            parts.append('\\\\')
        elif ch == u'\n':
            parts.append('\\n')
        elif ch == u'\r':
            parts.append('\\r')
        elif ch == u'\t':
            parts.append('\\t')
        elif o < 32 or o > 126:
            if o > 0xFFFF:
                o -= 0x10000
                parts.append('\\u%04x\\u%04x' % (0xD800 + (o >> 10), 0xDC00 + (o & 0x3FF)))
            else:
                parts.append('\\u%04x' % o)
        else:
            parts.append(chr(o))
    parts.append('"')


def _enc(obj, parts):
    if obj is None:
        parts.append('null')
        return
    if obj is True:
        parts.append('true')
        return
    if obj is False:
        parts.append('false')
        return
    if isinstance(obj, float):
        parts.append(repr(obj))
        return
    if isinstance(obj, (int, long)):
        parts.append(str(obj))
        return
    if isinstance(obj, unicode):
        _enc_string(obj, parts)
        return
    if isinstance(obj, str):
        try:
            _enc_string(obj.decode('utf-8'), parts)
        except UnicodeError:
            _enc_string(obj.decode('latin-1'), parts)
        return
    if isinstance(obj, list):
        parts.append('[')
        i = 0
        while i < len(obj):
            if i:
                parts.append(',')
            _enc(obj[i], parts)
            i += 1
        parts.append(']')
        return
    if isinstance(obj, dict):
        parts.append('{')
        first = True
        for key, value in obj.items():
            if not first:
                parts.append(',')
            first = False
            if isinstance(key, unicode):
                ukey = key
            elif isinstance(key, str):
                try:
                    ukey = key.decode('utf-8')
                except UnicodeError:
                    ukey = key.decode('latin-1')
            else:
                ukey = unicode(str(key))
            _enc_string(ukey, parts)
            parts.append(':')
            _enc(value, parts)
        parts.append('}')
        return
    raise JsonError('cannot encode %s' % type(obj))


def dumps(obj):
    parts = []
    _enc(obj, parts)
    return ''.join(parts)


# --- config, history, paths ---

def load_config():
    global CONFIG
    CONFIG = {}
    for key, value in DEFAULT_CONFIG.items():
        if isinstance(value, list):
            CONFIG[key] = list(value)
        else:
            CONFIG[key] = value
    path = config_path()
    if not os.path.isfile(path):
        save_config()
        return
    try:
        f = open(path, 'rb')
        try:
            raw = f.read()
        finally:
            f.close()
        data = loads(raw)
    except Exception, exc:
        log('config unreadable (%s); using defaults' % exc)
        return
    if isinstance(data, dict):
        for key in DEFAULT_CONFIG.keys():
            if key in data:
                CONFIG[key] = data[key]
    apply_policy()


def apply_policy():
    """Merge the root-owned policy file. It can only tighten the config."""
    try:
        info = os.stat(POLICY_PATH)
    except OSError:
        return
    if info.st_uid != 0 or (info.st_mode & 0022):
        log('ignoring %s: it must be owned by root and not writable by others' % POLICY_PATH)
        return
    try:
        f = open(POLICY_PATH, 'rb')
        try:
            policy = loads(f.read())
        finally:
            f.close()
    except Exception, exc:
        log('policy unreadable (%s)' % exc)
        return
    if not isinstance(policy, dict):
        return
    blocked = policy.get('blockedCommands')
    if isinstance(blocked, list):
        merged = list(CONFIG.get('blockedCommands', []))
        for word in blocked:
            if word not in merged:
                merged.append(word)
        CONFIG['blockedCommands'] = merged
    for key in ('allowedDirectories', 'defaultShell'):
        if key in policy:
            CONFIG[key] = policy[key]


def save_config():
    path = config_path()
    tmp = path + '.tmp'
    f = open(tmp, 'wb')
    try:
        f.write(dumps(CONFIG))
    finally:
        f.close()
    os.rename(tmp, path)


def load_usage():
    global USAGE
    USAGE = {
        'started': now_iso(),
        'tool_calls': 0,
        'errors': 0,
        'by_tool': {},
    }
    path = usage_path()
    if not os.path.isfile(path):
        return
    try:
        f = open(path, 'rb')
        try:
            data = loads(f.read())
        finally:
            f.close()
    except Exception:
        return
    if isinstance(data, dict):
        USAGE = data
        if 'by_tool' not in USAGE or not isinstance(USAGE['by_tool'], dict):
            USAGE['by_tool'] = {}


def save_usage():
    path = usage_path()
    tmp = path + '.tmp'
    try:
        f = open(tmp, 'wb')
        try:
            f.write(dumps(USAGE))
        finally:
            f.close()
        os.rename(tmp, path)
    except OSError, exc:
        log('usage save failed: %s' % exc)


def capture(cmd):
    f = os.popen(cmd + ' 2>/dev/null')
    try:
        data = f.read()
    finally:
        f.close()
    if data is None:
        return ''
    return data.strip()


def collect_sysinfo():
    SYSINFO['python'] = sys.version.replace('\n', ' ')
    SYSINFO['uname'] = capture('uname -a')
    SYSINFO['sw_vers'] = capture('sw_vers')
    SYSINFO['model'] = capture('sysctl -n hw.model')
    SYSINFO['mem'] = capture('sysctl -n hw.memsize')


def instructions():
    sw = SYSINFO.get('sw_vers', '').replace('\n', '; ')
    return (
        'ppc-commander executes on this PowerPC Mac, not on the MCP client. '
        'uname: %s. sw_vers: %s. model: %s. memory_bytes: %s. Python: %s. '
        'Default shell: %s. There is no Node.js and no ripgrep. The compiler is gcc 4.0. '
        'Excel, PDF, and DOCX tools are not available. '
        'allowedDirectories limits file tools only; an empty list means the whole filesystem. '
        'Terminal commands are not limited by that list. Disk-erase commands stay blocked. '
        'blockedCommands, allowedDirectories, and defaultShell are locked, and the file '
        'tools cannot edit ppc-commander itself. '
        'Prefer edit_block for small changes. start_process returns when output goes idle '
        'or timeout_ms elapses (capped at 120s) and leaves the process running. '
        'GUI apps are allowed. start_process with detach true runs them outside this '
        'session so they stay open after the chat moves on.'
        % (
            SYSINFO.get('uname', ''),
            sw,
            SYSINFO.get('model', ''),
            SYSINFO.get('mem', ''),
            SYSINFO.get('python', ''),
            CONFIG.get('defaultShell', '/bin/bash'),
        )
    )


def fix_mac_unicode(path):
    if os.path.exists(path) or os.path.islink(path):
        return path
    try:
        uni = path.decode('utf-8')
    except UnicodeError:
        return path
    for form in ('NFD', 'NFC'):
        try:
            alt = unicodedata.normalize(form, uni).encode('utf-8')
        except UnicodeError:
            continue
        if os.path.exists(alt) or os.path.islink(alt):
            return alt
    return path


def resolve_existing(path):
    path = os.path.normpath(path)
    if os.path.exists(path) or os.path.islink(path):
        return os.path.normpath(os.path.realpath(path))
    tail = []
    cur = path
    while cur and cur != os.sep and not os.path.exists(cur) and not os.path.islink(cur):
        tail.append(os.path.basename(cur))
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    if os.path.exists(cur) or os.path.islink(cur):
        base = os.path.realpath(cur)
    else:
        base = cur
    tail.reverse()
    for part in tail:
        base = os.path.join(base, part)
    return os.path.normpath(base)


def path_allowed(path):
    if not workspace_allows(path):
        return False
    roots = CONFIG.get('allowedDirectories', [])
    if not roots:
        return True
    if not isinstance(roots, list):
        return True
    for root in roots:
        try:
            root_s = as_str(root)
        except ToolError:
            continue
        if not root_s:
            continue
        resolved = resolve_existing(os.path.abspath(os.path.expanduser(root_s)))
        if path == resolved or path.startswith(resolved + os.sep):
            return True
    return False


def denied_message(path):
    if not workspace_allows(path):
        return (
            'path is outside this workspace\'s folder: %s. Work inside %s.'
            % (path, WORKSPACE['root'])
        )
    roots = CONFIG.get('allowedDirectories', [])
    shown = []
    if isinstance(roots, list):
        for root in roots:
            shown.append(str(root))
    return (
        'path is outside allowedDirectories: %s. allowed: %s. '
        'An empty allowedDirectories list permits every path. '
        'Terminal commands ignore this list.'
        % (path, ', '.join(shown))
    )


def protected_paths():
    return [
        os.path.realpath(script_dir()),
        os.path.realpath(os.path.abspath(__file__)),
        POLICY_PATH,
    ]


# A workspace can limit Commander to one folder. The relay passes the folder
# in TB_WORKSPACE_ROOT when it starts this program over SSH, so the model, which
# can only call tools, cannot change it. File tools are held to it exactly.
# Shell commands are held to it as well as a plain command line can be: the
# working folder is the root, and any path the command names must be inside it
# (programs in the system folders may still be run). A determined script can
# get around that, so use a separate account when the limit must be absolute.
WORKSPACE = {'root': ''}
SYSTEM_PROGRAM_DIRS = [
    '/bin', '/sbin', '/usr/bin', '/usr/sbin', '/usr/local/bin', '/usr/libexec',
    '/usr/lib', '/usr/share', '/System/Library', '/Developer/usr',
    '/Developer/SDKs', '/Developer/Library', '/dev/null', '/dev/tty', '/dev/zero',
    '/usr/include', '/Library/Frameworks',
]


def apply_workspace_root():
    root = os.environ.get('TB_WORKSPACE_ROOT', '').strip()
    WORKSPACE['root'] = ''
    if not root:
        return
    if not os.path.isabs(root):
        log('ignoring TB_WORKSPACE_ROOT: it must be an absolute path')
        return
    WORKSPACE['root'] = resolve_existing(os.path.normpath(root))


def inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def workspace_allows(path):
    root = WORKSPACE['root']
    if not root:
        return True
    return inside(path, root)


def command_paths(command):
    """The path-like words in a shell command, split on spaces, quotes and
    shell punctuation."""
    found = []
    for word in re.split(r'[\s;|&<>()=`$"\']+', command):
        if word == '':
            continue
        if word[0] in '/~' or word == '..' or word.startswith('../') or '/../' in word or word.endswith('/..'):
            found.append(word)
    return found


def workspace_command_problem(command):
    """Why this command may not run in the workspace, or None."""
    root = WORKSPACE['root']
    if not root:
        return None
    for word in command_paths(command):
        full = os.path.expanduser(word)
        if not os.path.isabs(full):
            full = os.path.join(root, full)
        full = resolve_existing(os.path.normpath(full))
        if inside(full, root):
            continue
        ok = 0
        for system in SYSTEM_PROGRAM_DIRS:
            if inside(full, system):
                ok = 1
                break
        if not ok:
            return 'the command uses %s, which is outside this workspace folder (%s)' % (word, root)
    return None


def check_writable(path):
    """File tools may not change ppc-commander itself, its config, or the policy."""
    for guarded in protected_paths():
        if path == guarded or path.startswith(guarded.rstrip(os.sep) + os.sep):
            raise ToolError(
                'ppc-commander does not let tools change its own files (%s). '
                'Edit them by hand on this Mac.' % guarded
            )
    return path


def check_path(path):
    path = fix_mac_unicode(os.path.expanduser(path))
    if not os.path.isabs(path):
        path = os.path.abspath(path)
    resolved = resolve_existing(path)
    if not path_allowed(resolved):
        raise ToolError(denied_message(resolved))
    return resolved


def normalize_command(command):
    """Undo the easy disguises before matching program names.

    Quotes and backslashes do not change which program runs (d''d, "dd", \dd),
    so they are removed. $( ), backticks, parentheses, braces, ;, &, | and
    newlines all start a new command, so they become one separator.
    """
    text = command.replace('\\\n', ' ')
    text = re.sub(r'[\'"\\]', '', text)
    text = re.sub(r'\$\(|[`(){}]', '\0', text)
    text = re.sub(r'&&|\|\||[;&|\n]', '\0', text)
    return text


def command_words(command):
    """Names that may be run as programs in this command line.

    The first word of each command counts, after VAR=value prefixes. Once a
    wrapper such as sudo, env, xargs, or sh -c appears, every later word in
    that command counts too, because the wrapper may run any of them.
    """
    found = []
    for segment in normalize_command(command).split('\0'):
        wrapped = 0
        first = 1
        for token in segment.split():
            if first and '=' in token and not token.startswith('='):
                continue
            if token.startswith('-') and not first:
                continue
            name = os.path.basename(token)
            if first or wrapped:
                found.append(name)
            if name in WRAPPERS:
                wrapped = 1
            first = 0
    return found


def command_blocked(command):
    flat = normalize_command(command).replace('\0', ' ; ')
    for text in (command, flat):
        if re.search(r'>\s*/dev/r?disk', text):
            return 'redirect to a disk device'
        if re.search(r'(?:^|\s)of=/dev/r?disk', text):
            return 'write to a disk device'
    words = command_words(command)
    if 'diskutil' in words and re.search(
        r'diskutil\s+(?:\S+\s+)*?(erase\w*|partition\w*|zero\w*|split\w*|secureErase\w*|reformat)',
        flat,
    ):
        return 'diskutil erase/partition'
    blocked = CONFIG.get('blockedCommands', [])
    if not isinstance(blocked, list):
        return None
    for word in blocked:
        try:
            name = as_str(word)
        except ToolError:
            continue
        if name and name in words:
            return name
    return None


def append_history(name, args, text, ok, dur):
    safe_args = {}
    if isinstance(args, dict):
        for key, value in args.items():
            if isinstance(value, unicode):
                value = value.encode('utf-8', 'replace')
            if isinstance(value, str):
                safe_args[key] = clip(value, 600)
            else:
                safe_args[key] = value
    else:
        safe_args = {'value': clip(args, 1500)}
    rec = {
        'time': now_iso(),
        'tool': name,
        'ok': ok,
        'duration_ms': dur,
        'arguments': safe_args,
        'output_preview': clip(text, 600),
    }
    path = history_path()
    f = open(path, 'ab')
    try:
        f.write(dumps(rec))
        f.write('\n')
    finally:
        f.close()
    try:
        if os.path.getsize(path) > HISTORY_MAX_BYTES:
            f = open(path, 'rb')
            try:
                lines = f.readlines()
            finally:
                f.close()
            if len(lines) > HISTORY_KEEP_LINES:
                f = open(path, 'wb')
                try:
                    f.writelines(lines[-HISTORY_KEEP_LINES:])
                finally:
                    f.close()
    except OSError:
        pass


def bump_usage(name, ok):
    if not USAGE.get('started'):
        USAGE['started'] = now_iso()
    USAGE['tool_calls'] = int(USAGE.get('tool_calls', 0)) + 1
    if not ok:
        USAGE['errors'] = int(USAGE.get('errors', 0)) + 1
    by_tool = USAGE.get('by_tool')
    if not isinstance(by_tool, dict):
        by_tool = {}
        USAGE['by_tool'] = by_tool
    by_tool[name] = int(by_tool.get(name, 0)) + 1
    save_usage()


def record(name, args, text, ok, dur):
    if name == 'get_recent_tool_calls':
        return
    try:
        bump_usage(name, ok)
        append_history(name, args, text, ok, dur)
    except Exception, exc:
        log('history failed: %s' % exc)


def user_name(uid):
    try:
        return pwd.getpwuid(uid)[0]
    except Exception:
        return str(uid)


def group_name(gid):
    try:
        return grp.getgrgid(gid)[0]
    except Exception:
        return str(gid)


def line_count(content):
    if content == '':
        return 0
    n = content.count('\n')
    if content.endswith('\n'):
        return n
    return n + 1


def split_lines(text):
    lines = text.split('\n')
    if text.endswith('\n') and lines and lines[-1] == '':
        lines = lines[:-1]
    return lines


def slice_lines(text, offset, length):
    lines = split_lines(text)
    total = len(lines)
    if offset < 0:
        start = total + offset
        if start < 0:
            start = 0
    else:
        start = offset
    if start > total:
        start = total
    end = start + length
    if end > total:
        end = total
    if start < 0:
        start = 0
    return lines[start:end], start, end, total


def cap_text(text):
    if len(text) <= MAX_OUTPUT_CHARS:
        return text
    return text[:MAX_OUTPUT_CHARS] + '\n... truncated at %d characters' % MAX_OUTPUT_CHARS


def read_bytes(path, offset):
    try:
        size = os.path.getsize(path)
    except OSError, exc:
        raise ToolError('cannot stat %s: %s' % (path, exc))
    f = open(path, 'rb')
    try:
        note = ''
        if offset < 0 and size > MAX_FILE_BYTES:
            f.seek(max(0, size - MAX_FILE_BYTES))
            data = f.read()
            note = 'file is %d bytes; loaded the last %d' % (size, len(data))
        else:
            data = f.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                data = data[:MAX_FILE_BYTES]
                note = 'file is %d bytes; loaded the first %d' % (size, len(data))
    finally:
        f.close()
    return data, size, note


def decode_text(data):
    try:
        return data.decode('utf-8'), 'utf-8'
    except UnicodeError:
        return data.decode('latin-1'), 'latin-1'


def hex_preview(data, count):
    chunk = data[:count]
    parts = []
    for ch in chunk:
        parts.append('%02x' % ord(ch))
    return ' '.join(parts)


# --- filesystem tools ---

def read_url(url):
    old = socket.getdefaulttimeout()
    socket.setdefaulttimeout(20)
    try:
        req = urllib2.Request(url, None, {'User-Agent': 'ppc-commander/0.1'})
        try:
            resp = urllib2.urlopen(req)
            data = resp.read(200001)
        except Exception, exc:
            raise ToolError(
                'fetch failed: %s. Tiger Python 2.3 cannot negotiate modern HTTPS.' % exc
            )
    finally:
        socket.setdefaulttimeout(old)
    header = 'url: %s\nbytes: %d' % (url, len(data))
    if '\0' in data[:4096]:
        return header + '\nbinary response\nhex: ' + hex_preview(data, 64)
    text, enc = decode_text(data)
    body = text.encode('utf-8', 'replace')
    return cap_text(header + '\nencoding: %s\n---\n' % enc + body)


def tool_read_file(args):
    path = opt_str(args, 'path', '')
    is_url = opt_bool(args, 'isUrl', False)
    if is_url or path.startswith('http://') or path.startswith('https://') or path.startswith('ftp://'):
        if not path:
            raise ToolError('missing path')
        return read_url(path)
    if not path:
        raise ToolError('missing path')
    path = check_path(path)
    if os.path.isdir(path) and not os.path.islink(path):
        raise ToolError('path is a directory: %s' % path)
    if not os.path.exists(path):
        raise ToolError('not found: %s' % path)
    offset = opt_int(args, 'offset', 0)
    length = opt_int(args, 'length', int(CONFIG.get('fileReadLineLimit', 1000)))
    if length < 1:
        length = 1
    if length > 5000:
        length = 5000
    data, size, note = read_bytes(path, offset)
    if '\0' in data[:4096]:
        return 'path: %s\nsize: %d\nbinary file\nhex: %s' % (path, size, hex_preview(data, 96))
    text, enc = decode_text(data)
    # decode_text returns unicode. slice on unicode, then encode the page.
    chunk, start, end, total = slice_lines(text, offset, length)
    body_lines = []
    i = 0
    while i < len(chunk):
        body_lines.append(chunk[i])
        i += 1
    body = u'\n'.join(body_lines).encode('utf-8', 'replace')
    header = 'path: %s\nencoding: %s\nsize: %d\nlines: %d-%d of %d' % (
        path, enc, size, start, end, total
    )
    if note:
        header += '\nnote: ' + note
    if end < total:
        header += '\nmore: pass offset %d to continue' % end
    return cap_text(header + '\n---\n' + body)


def tool_read_multiple(args):
    if not isinstance(args, dict):
        raise ToolError('missing paths')
    paths = as_str_list(args.get('paths'))
    if len(paths) > 20:
        raise ToolError('at most 20 paths')
    parts = []
    for path in paths:
        try:
            parts.append(tool_read_file({'path': path, 'offset': 0, 'length': 200}))
        except ToolError, exc:
            parts.append('path: %s\nerror: %s' % (path, exc.args[0]))
    return cap_text('\n\n'.join(parts))


def tool_write_file(args):
    path = check_writable(check_path(need_str(args, 'path')))
    content = need_str(args, 'content')
    mode = opt_str(args, 'mode', 'rewrite')
    if mode not in ('rewrite', 'append'):
        raise ToolError('mode must be rewrite or append')
    limit = int(CONFIG.get('fileWriteLineLimit', 1000))
    nlines = line_count(content)
    if nlines > limit:
        raise ToolError(
            'content has %d lines and fileWriteLineLimit is %d. '
            'Use mode "append" in chunks, or raise the limit with set_config_value.'
            % (nlines, limit)
        )
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        raise ToolError('parent directory does not exist: %s' % parent)
    if mode == 'append':
        flag = 'ab'
    else:
        flag = 'wb'
    f = open(path, flag)
    try:
        f.write(content)
    finally:
        f.close()
    return 'wrote %d bytes (%d lines, %s) to %s' % (len(content), nlines, mode, path)


def tool_create_directory(args):
    path = check_writable(check_path(need_str(args, 'path')))
    if os.path.isdir(path):
        return 'directory already exists: %s' % path
    if os.path.exists(path):
        raise ToolError('path exists and is not a directory: %s' % path)
    try:
        os.makedirs(path)
    except OSError, exc:
        if os.path.isdir(path):
            return 'directory already exists: %s' % path
        raise ToolError('mkdir failed: %s' % exc)
    return 'created %s' % path


def cmp_names(a, b):
    aa = a.lower()
    bb = b.lower()
    if aa < bb:
        return -1
    if aa > bb:
        return 1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def describe_entry(full):
    if os.path.islink(full):
        try:
            target = os.readlink(full)
        except OSError:
            target = '?'
        return 'link', target
    try:
        st = os.lstat(full)
    except OSError:
        return 'other', 'unreadable'
    if statmod.S_ISDIR(st.st_mode):
        return 'dir', ''
    return 'file', '%d bytes' % st.st_size


def tool_list_directory(args):
    path = check_path(need_str(args, 'path'))
    if not os.path.isdir(path):
        raise ToolError('not a directory: %s' % path)
    depth = opt_int(args, 'depth', 2)
    if depth < 1:
        depth = 1
    if depth > 6:
        depth = 6
    lines = ['%s' % path]
    state = {'count': 0, 'truncated': False}

    def walk(directory, levels, prefix):
        if state['truncated']:
            return
        try:
            names = os.listdir(directory)
        except OSError, exc:
            lines.append('%s[cannot list: %s]' % (prefix, exc))
            return
        names.sort(cmp_names)
        for name in names:
            if state['count'] >= 500:
                lines.append('%s... truncated at 500 entries' % prefix)
                state['truncated'] = True
                return
            full = os.path.join(directory, name)
            kind, extra = describe_entry(full)
            state['count'] += 1
            if kind == 'dir':
                lines.append('%s%s/' % (prefix, name))
                if levels > 1 and not os.path.islink(full):
                    walk(full, levels - 1, prefix + '  ')
            elif kind == 'link':
                lines.append('%s%s -> %s' % (prefix, name, extra))
            else:
                lines.append('%s%s (%s)' % (prefix, name, extra))

    walk(path, depth, '  ')
    lines.append('entries: %d' % state['count'])
    return cap_text('\n'.join(lines))


def tool_move_file(args):
    source = check_writable(check_path(need_str(args, 'source')))
    dest = check_writable(check_path(need_str(args, 'destination')))
    if not os.path.exists(source) and not os.path.islink(source):
        raise ToolError('source not found: %s' % source)
    parent = os.path.dirname(dest)
    if parent and not os.path.isdir(parent) and not os.path.isdir(dest):
        raise ToolError('destination parent does not exist: %s' % parent)
    try:
        shutil.move(source, dest)
    except Exception, exc:
        raise ToolError('move failed: %s' % exc)
    return 'moved %s to %s' % (source, dest)


def tool_get_file_info(args):
    path = check_path(need_str(args, 'path'))
    if not os.path.exists(path) and not os.path.islink(path):
        raise ToolError('not found: %s' % path)
    lines = ['path: %s' % path]
    try:
        st = os.lstat(path)
    except OSError, exc:
        raise ToolError('stat failed: %s' % exc)
    if os.path.islink(path):
        lines.append('type: symlink')
        try:
            lines.append('target: %s' % os.readlink(path))
        except OSError:
            lines.append('target: ?')
    elif statmod.S_ISDIR(st.st_mode):
        lines.append('type: directory')
    elif statmod.S_ISREG(st.st_mode):
        lines.append('type: file')
    else:
        lines.append('type: other')
    lines.append('size: %d' % st.st_size)
    lines.append('mode: %04o' % (st.st_mode & 07777))
    lines.append('links: %d' % st.st_nlink)
    lines.append('uid: %s (%s)' % (st.st_uid, user_name(st.st_uid)))
    lines.append('gid: %s (%s)' % (st.st_gid, group_name(st.st_gid)))
    lines.append('mtime: %s' % time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(st.st_mtime)))
    return '\n'.join(lines)


def edit_hint(old, text):
    old_lines = old.split('\n')
    file_lines = text.split('\n')
    if len(file_lines) > 800 or not old_lines:
        return 'old_string was not found'
    needle = old_lines[0].strip()
    if not needle:
        return 'old_string was not found'
    best = 0.0
    best_i = -1
    i = 0
    while i < len(file_lines):
        ratio = difflib.SequenceMatcher(None, needle, file_lines[i].strip()).ratio()
        if ratio > best:
            best = ratio
            best_i = i
        i += 1
    if best_i >= 0 and best >= 0.55:
        return 'old_string was not found. closest line %d (similarity %.0f%%): %s' % (
            best_i, best * 100, clip(file_lines[best_i], 180)
        )
    return 'old_string was not found'


def tool_edit_block(args):
    if opt_str(args, 'range', None) and not opt_str(args, 'old_string', None):
        raise ToolError('Excel range edits are not supported on this Mac')
    path = opt_str(args, 'file_path', None)
    if not path:
        path = opt_str(args, 'path', None)
    if not path:
        raise ToolError('missing file_path')
    path = check_writable(check_path(path))
    if 'old_string' not in args or args['old_string'] is None:
        raise ToolError('missing old_string')
    if 'new_string' not in args or args['new_string'] is None:
        raise ToolError('missing new_string')
    old = as_str(args['old_string'])
    new = as_str(args['new_string'])
    if old == '':
        raise ToolError('old_string is empty')
    expected = opt_int(args, 'expected_replacements', 1)
    if expected < 1:
        raise ToolError('expected_replacements must be >= 1')
    if not os.path.isfile(path):
        raise ToolError('not a file: %s' % path)
    data, size, note = read_bytes(path, 0)
    if note:
        raise ToolError('file is too large to edit this way (%d bytes)' % size)
    if '\0' in data[:4096]:
        raise ToolError('refusing to edit a binary file')
    text, enc = decode_text(data)
    try:
        old_u = old.decode('utf-8')
        new_u = new.decode('utf-8')
    except UnicodeError:
        old_u = old.decode('latin-1')
        new_u = new.decode('latin-1')
    count = text.count(old_u)
    used = text
    if count == 0:
        norm = text.replace(u'\r\n', u'\n').replace(u'\r', u'\n')
        old_n = old_u.replace(u'\r\n', u'\n').replace(u'\r', u'\n')
        count = norm.count(old_n)
        if count:
            used = norm
            old_u = old_n
            new_u = new_u.replace(u'\r\n', u'\n').replace(u'\r', u'\n')
    if count == 0:
        raise ToolError(edit_hint(old_u, text))
    if count != expected:
        raise ToolError('found %d matches, expected %d. Set expected_replacements to replace all of them.' % (count, expected))
    updated = used.replace(old_u, new_u, expected)
    try:
        out = updated.encode(enc)
    except UnicodeError:
        out = updated.encode('utf-8')
        enc = 'utf-8'
    f = open(path, 'wb')
    try:
        f.write(out)
    finally:
        f.close()
    return 'replaced %d match(es) in %s (%s, %d bytes)' % (expected, path, enc, len(out))


# --- search ---

def hidden_path(path, root):
    if path == root:
        return False
    if path.startswith(root + os.sep):
        rel = path[len(root) + 1:]
    else:
        rel = path
    parts = rel.split(os.sep)
    for part in parts:
        if part.startswith('.') and part not in ('.', '..'):
            return True
    return False


class SearchSession:
    def __init__(self, sid, path, pattern, search_type, file_pattern, ignore_case,
                 max_results, include_hidden, context_lines, timeout_ms, early, literal):
        self.sid = sid
        self.path = path
        self.pattern = pattern
        self.search_type = search_type
        self.file_pattern = file_pattern
        self.ignore_case = ignore_case
        self.max_results = max_results
        self.include_hidden = include_hidden
        self.context_lines = context_lines
        self.timeout_ms = timeout_ms
        self.early = early
        self.literal = literal
        self.results = []
        self.lock = threading.Lock()
        self.done = False
        self.stopped = False
        self.note = ''
        self.started = time.time()

    def add_result(self, line):
        self.lock.acquire()
        try:
            if len(self.results) >= self.max_results:
                self.note = 'max results'
                return False
            self.results.append(line)
            if len(self.results) >= self.max_results:
                self.note = 'max results'
                return False
            return True
        finally:
            self.lock.release()

    def expired(self):
        if self.stopped:
            self.note = 'stopped'
            return True
        if (time.time() - self.started) * 1000.0 >= self.timeout_ms:
            self.note = 'timeout'
            return True
        return False

    def run(self):
        try:
            self._run()
        except Exception, exc:
            self.note = 'error: %s' % exc
        self.done = True

    def _run(self):
        if self.search_type == 'content':
            try:
                pat_u = self.pattern.decode('utf-8')
            except UnicodeError:
                pat_u = self.pattern.decode('latin-1')
            if self.literal:
                pat_u = re.escape(pat_u)
            flags = 0
            if self.ignore_case:
                flags = re.IGNORECASE
            try:
                cre = re.compile(pat_u, flags)
            except re.error, exc:
                self.note = 'bad regex: %s' % exc
                return
        else:
            cre = None
        if os.path.isfile(self.path):
            roots = [self.path]
            self._scan_file(self.path, cre)
            return
        for root, dirs, files in os.walk(self.path, True, lambda err: None):
            if self.expired():
                return
            kept = []
            for name in dirs:
                full = os.path.join(root, name)
                if full in SKIP_DIRS:
                    continue
                if (not self.include_hidden) and name.startswith('.'):
                    continue
                kept.append(name)
            dirs[:] = kept
            for name in files:
                if self.expired():
                    return
                if (not self.include_hidden) and name.startswith('.'):
                    continue
                full = os.path.join(root, name)
                if not self._name_allowed(full):
                    continue
                if not self._scan_file(full, cre):
                    return

    def _name_allowed(self, path):
        if not self.file_pattern:
            return True
        base = os.path.basename(path)
        pat = self.file_pattern
        if self.ignore_case:
            base = base.lower()
            pat = pat.lower()
            path_l = path.lower()
        else:
            path_l = path
        if fnmatch.fnmatchcase(base, pat) or fnmatch.fnmatchcase(path_l, pat):
            return True
        return False

    def _file_pattern_match(self, path):
        base = os.path.basename(path)
        pat = self.pattern
        if self.ignore_case:
            base_c = base.lower()
            path_c = path.lower()
            pat_c = pat.lower()
        else:
            base_c = base
            path_c = path
            pat_c = pat
        if ('*' in pat_c) or ('?' in pat_c) or ('[' in pat_c):
            return fnmatch.fnmatchcase(base_c, pat_c) or fnmatch.fnmatchcase(path_c, pat_c), base_c == pat_c
        return (pat_c in path_c), base_c == pat_c

    def _scan_file(self, path, cre):
        if self.search_type == 'files':
            matched, exact = self._file_pattern_match(path)
            if not matched:
                return True
            if not self.add_result(path):
                return False
            if self.early and exact:
                self.note = 'exact name'
                return False
            return True
        return self._scan_content(path, cre)

    def _scan_content(self, path, cre):
        try:
            st = os.stat(path)
        except OSError:
            return True
        if not statmod.S_ISREG(st.st_mode):
            return True
        if st.st_size > 1000000:
            return True
        try:
            f = open(path, 'rb')
            try:
                data = f.read(1000001)
            finally:
                f.close()
        except OSError:
            return True
        if '\0' in data[:1024]:
            return True
        text, enc = decode_text(data)
        lines = text.split('\n')
        found = 0
        i = 0
        while i < len(lines):
            if cre.search(lines[i]):
                start = i - self.context_lines
                if start < 0:
                    start = 0
                end = i + self.context_lines + 1
                if end > len(lines):
                    end = len(lines)
                block = ['%s:%d: %s' % (path, i + 1, clip(lines[i].encode('utf-8', 'replace'), 400))]
                j = start
                while j < end:
                    if j != i:
                        block.append('%s:%d- %s' % (path, j + 1, clip(lines[j].encode('utf-8', 'replace'), 200)))
                    j += 1
                if not self.add_result('\n'.join(block)):
                    return False
                found += 1
                if found >= 40:
                    return True
            i += 1
        return True

    def page(self, offset, length):
        self.lock.acquire()
        try:
            total = len(self.results)
            done = self.done
            note = self.note
            if offset < 0:
                offset = 0
            if offset > total:
                offset = total
            end = offset + length
            if end > total:
                end = total
            chunk = list(self.results[offset:end])
        finally:
            self.lock.release()
        return chunk, offset, end, total, done, note


def tool_start_search(args):
    path = check_path(need_str(args, 'path'))
    pattern = need_str(args, 'pattern')
    if pattern == '':
        raise ToolError('pattern is empty')
    search_type = opt_str(args, 'searchType', 'files')
    if search_type not in ('files', 'content'):
        raise ToolError('searchType must be files or content')
    if not os.path.exists(path):
        raise ToolError('not found: %s' % path)
    file_pattern = opt_str(args, 'filePattern', '')
    ignore_case = opt_bool(args, 'ignoreCase', True)
    include_hidden = opt_bool(args, 'includeHidden', False)
    literal = opt_bool(args, 'literalSearch', False)
    max_results = opt_int(args, 'maxResults', 200)
    if max_results < 1:
        max_results = 1
    if max_results > 1000:
        max_results = 1000
    context = opt_int(args, 'contextLines', 2)
    if context < 0:
        context = 0
    if context > 5:
        context = 5
    timeout_ms = opt_int(args, 'timeout_ms', 15000)
    if timeout_ms < 500:
        timeout_ms = 500
    if timeout_ms > 60000:
        timeout_ms = 60000
    if 'earlyTermination' in args and args['earlyTermination'] is not None:
        early = as_bool(args['earlyTermination'])
    else:
        early = search_type == 'files'
    SEARCH_SEQ[0] += 1
    sid = 'search-%d' % SEARCH_SEQ[0]
    session = SearchSession(
        sid, path, pattern, search_type, file_pattern, ignore_case,
        max_results, include_hidden, context, timeout_ms, early, literal,
    )
    SEARCHES[sid] = session
    thread = threading.Thread(target=session.run)
    thread.setDaemon(True)
    thread.start()
    deadline = time.time() + 2.0
    while time.time() < deadline and not session.done and len(session.results) < 40:
        time.sleep(0.05)
    return format_search(session, 0, 40)


def format_search(session, offset, length):
    chunk, start, end, total, done, note = session.page(offset, length)
    if done:
        done_text = 'true'
    else:
        done_text = 'false'
    lines = [
        'sessionId: %s' % session.sid,
        'path: %s' % session.path,
        'searchType: %s' % session.search_type,
        'pattern: %s' % clip(session.pattern, 200),
        'done: %s' % done_text,
        'matched: %d' % total,
        'showing: %d-%d' % (start, end),
    ]
    if note:
        lines.append('note: %s' % note)
    lines.append('---')
    if chunk:
        lines.append('\n'.join(chunk))
    elif done:
        lines.append('no matches')
    else:
        lines.append('no matches yet')
    return cap_text('\n'.join(lines))


def tool_get_more_search_results(args):
    sid = need_str(args, 'sessionId')
    session = SEARCHES.get(sid)
    if session is None:
        raise ToolError('no search session %s' % sid)
    offset = opt_int(args, 'offset', 0)
    length = opt_int(args, 'length', 100)
    if length < 1:
        length = 1
    if length > 300:
        length = 300
    if not session.done and offset >= len(session.results):
        deadline = time.time() + 1.0
        while time.time() < deadline and not session.done:
            time.sleep(0.05)
    return format_search(session, offset, length)


def tool_stop_search(args):
    sid = need_str(args, 'sessionId')
    session = SEARCHES.get(sid)
    if session is None:
        raise ToolError('no search session %s' % sid)
    session.stopped = True
    deadline = time.time() + 1.5
    while time.time() < deadline and not session.done:
        time.sleep(0.05)
    return format_search(session, 0, 20)


def tool_list_searches(args):
    if not SEARCHES:
        return 'no searches'
    lines = []
    for sid, session in SEARCHES.items():
        if session.done:
            session_done = 'true'
        else:
            session_done = 'false'
        lines.append('%s type=%s done=%s matches=%d pattern=%s' % (
            sid,
            session.search_type,
            session_done,
            len(session.results),
            clip(session.pattern, 80),
        ))
    return '\n'.join(lines)


# --- processes ---

def decode_status(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return status


def write_all(fd, data):
    while data:
        n = os.write(fd, data)
        if not n:
            raise OSError('short write')
        data = data[n:]


class Session:
    def __init__(self, pid, fd, command):
        self.pid = pid
        self.fd = fd
        self.command = command
        self.chunks = []
        self.size = 0
        self.dropped = 0
        self.lock = threading.Lock()
        self.exited = False
        self.exit_code = None
        self.started = time.time()
        self.consumed_lines = 0

    def append(self, data):
        if not data:
            return
        data = data.replace('\r\n', '\n').replace('\r', '\n')
        self.lock.acquire()
        try:
            self.chunks.append(data)
            self.size += len(data)
            while self.size > MAX_PROCESS_OUTPUT and len(self.chunks) > 1:
                old = self.chunks.pop(0)
                self.size -= len(old)
                self.dropped += len(old)
                self.consumed_lines = 0
        finally:
            self.lock.release()

    def snapshot(self):
        self.lock.acquire()
        try:
            return ''.join(self.chunks), self.dropped, self.exited, self.exit_code, self.consumed_lines
        finally:
            self.lock.release()

    def set_consumed(self, count):
        self.lock.acquire()
        try:
            self.consumed_lines = count
        finally:
            self.lock.release()


def read_pty(session):
    while True:
        try:
            data = os.read(session.fd, 4096)
        except OSError:
            break
        if not data:
            break
        session.append(data)
    session.exited = True
    try:
        wpid, status = os.waitpid(session.pid, 0)
        session.exit_code = decode_status(status)
    except OSError:
        pass
    try:
        os.close(session.fd)
    except OSError:
        pass
    session.fd = -1


def wait_session(session, start_size, timeout_ms):
    deadline = time.time() + (timeout_ms / 1000.0)
    last_size = start_size
    last_change = time.time()
    while True:
        now = time.time()
        text, dropped, exited, code, consumed = session.snapshot()
        cur = len(text) + dropped
        if cur != last_size:
            last_size = cur
            last_change = now
        if exited:
            time.sleep(0.05)
            return
        if cur > start_size and (now - last_change) >= 0.4:
            return
        if now >= deadline:
            return
        time.sleep(0.05)


def get_session(pid):
    session = SESSIONS.get(pid)
    if session is None:
        raise ToolError(
            'no terminal session for pid %s. '
            'start_process creates sessions. list_processes shows every process, '
            'but only commander sessions have captured output.' % pid
        )
    return session


def remember_session(session):
    SESSIONS[session.pid] = session
    if len(SESSIONS) <= 40:
        return
    victims = []
    for pid, other in SESSIONS.items():
        if other.exited and other is not session:
            victims.append((other.started, pid))
    victims.sort()
    while len(SESSIONS) > 40 and victims:
        pid = victims.pop(0)[1]
        del SESSIONS[pid]


def format_session(session, body, start, end, total, note):
    text, dropped, exited, code, consumed = session.snapshot()
    lines = [
        'pid: %s' % session.pid,
        'command: %s' % clip(session.command, 400),
    ]
    if exited:
        lines.append('status: exited')
        lines.append('exit_code: %s' % code)
    else:
        lines.append('status: running')
    lines.append('elapsed_ms: %d' % int((time.time() - session.started) * 1000))
    if dropped:
        lines.append('dropped_bytes: %d' % dropped)
    if note:
        lines.append(note)
    lines.append('output_lines: %d-%d of %d (process lines are 0-based in this range)' % (start, end, total))
    lines.append('---')
    lines.append(body)
    return cap_text('\n'.join(lines))


def session_page(session, offset, length, new_only):
    text, dropped, exited, code, consumed = session.snapshot()
    lines = split_lines(text)
    total = len(lines)
    advance = False
    if new_only:
        start = consumed
        advance = True
    elif offset is None or offset == 0:
        start = consumed
        advance = True
    elif offset < 0:
        start = total + offset
        if start < 0:
            start = 0
    else:
        # Positive process offsets are 1-based so 0 can mean "new output".
        start = offset - 1
        if start < 0:
            start = 0
    if start > total:
        start = total
    end = start + length
    if end > total:
        end = total
    body = '\n'.join(lines[start:end])
    if advance:
        session.set_consumed(end)
    return body, start, end, total


def detach_command(command, shell):
    # Double-fork into a session with no terminal. The chat's SSH connection
    # can close without delivering SIGHUP to a GUI that should stay open.
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(read_fd)
            os.setsid()
            pid2 = os.fork()
            if pid2 != 0:
                try:
                    os.write(write_fd, '%d\n' % pid2)
                except Exception:
                    pass
                os._exit(0)
            try:
                os.close(write_fd)
            except OSError:
                pass
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            if WORKSPACE['root']:
                os.chdir(WORKSPACE['root'])
            devnull = os.open('/dev/null', os.O_RDWR)
            os.dup2(devnull, 0)
            os.dup2(devnull, 1)
            os.dup2(devnull, 2)
            if devnull > 2:
                os.close(devnull)
            os.execv(shell, [os.path.basename(shell), '-c', command])
        except Exception:
            os._exit(127)
    os.close(write_fd)
    data = ''
    while True:
        try:
            chunk = os.read(read_fd, 64)
        except OSError:
            break
        if not chunk:
            break
        data = data + chunk
    os.close(read_fd)
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    text = data.strip()
    if text == '':
        raise ToolError('could not detach the process')
    try:
        child = int(text)
    except ValueError:
        raise ToolError('could not detach the process')
    return child


def tool_start_process(args):
    if pty is None:
        raise ToolError('this Python has no pty module')
    command = need_str(args, 'command')
    if command.strip() == '':
        raise ToolError('command is empty')
    timeout_ms = opt_int(args, 'timeout_ms', 10000)
    if timeout_ms < 0:
        timeout_ms = 0
    if timeout_ms > 120000:
        timeout_ms = 120000
    shell = CONFIG.get('defaultShell', '/bin/bash')
    if not isinstance(shell, str):
        shell = '/bin/bash'
    chosen = opt_str(args, 'shell', None)
    if chosen:
        shell = chosen
    if not os.path.isfile(shell):
        raise ToolError('shell does not exist: %s' % shell)
    why = command_blocked(command)
    if why:
        raise ToolError('blocked command (%s). Change blockedCommands only if you mean to.' % why)
    if WORKSPACE['root'] and not os.path.isdir(WORKSPACE['root']):
        raise ToolError('this workspace is limited to %s, which does not exist on this Mac. '
                        'Change the folder in the workspace settings.' % WORKSPACE['root'])
    why = workspace_command_problem(command)
    if why:
        raise ToolError('blocked by the workspace folder limit: %s' % why)
    if opt_bool(args, 'detach', False):
        child = detach_command(command, shell)
        lines = [
            'pid: %s' % child,
            'command: %s' % clip(command, 400),
            'status: detached',
            'note: running on its own; closing the chat will not stop it',
        ]
        return cap_text('\n'.join(lines))
    pid, fd = pty.fork()
    if pid == 0:
        try:
            if WORKSPACE['root']:
                os.chdir(WORKSPACE['root'])
            os.environ['TERM'] = 'vt100'
            os.environ['LANG'] = 'C'
            os.environ['LC_ALL'] = 'C'
            os.execv(shell, [os.path.basename(shell), '-c', command])
        except Exception:
            os._exit(127)
    if fcntl is not None:
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        except Exception:
            pass
    session = Session(pid, fd, command)
    thread = threading.Thread(target=read_pty, args=(session,))
    thread.setDaemon(True)
    thread.start()
    remember_session(session)
    wait_session(session, 0, timeout_ms)
    length = int(CONFIG.get('fileReadLineLimit', 1000))
    body, start, end, total = session_page(session, None, length, True)
    note = ''
    if not session.exited:
        note = 'still running; use read_process_output or interact_with_process with this pid'
    return format_session(session, body, start, end, total, note)


def tool_interact(args):
    pid = need_int(args, 'pid')
    data = need_str(args, 'input')
    timeout_ms = opt_int(args, 'timeout_ms', 5000)
    if timeout_ms < 0:
        timeout_ms = 0
    if timeout_ms > 120000:
        timeout_ms = 120000
    session = get_session(pid)
    if session.exited or session.fd < 0:
        raise ToolError('process %s is not running' % pid)
    before, dropped, exited, code, consumed = session.snapshot()
    start_size = len(before) + dropped
    try:
        write_all(session.fd, data)
    except OSError, exc:
        raise ToolError('write failed: %s' % exc)
    wait_session(session, start_size, timeout_ms)
    length = int(CONFIG.get('fileReadLineLimit', 1000))
    body, start, end, total = session_page(session, None, length, True)
    return format_session(session, body, start, end, total, 'input sent (%d bytes)' % len(data))


def tool_read_process_output(args):
    pid = need_int(args, 'pid')
    session = get_session(pid)
    timeout_ms = opt_int(args, 'timeout_ms', 0)
    if timeout_ms > 0:
        if timeout_ms > 120000:
            timeout_ms = 120000
        text, dropped, exited, code, consumed = session.snapshot()
        wait_session(session, len(text) + dropped, timeout_ms)
    length = opt_int(args, 'length', int(CONFIG.get('fileReadLineLimit', 1000)))
    if length < 1:
        length = 1
    if length > 5000:
        length = 5000
    if 'offset' in args and args['offset'] is not None:
        offset = as_int(args['offset'])
        new_only = False
    else:
        offset = 0
        new_only = True
    if offset == 0 and not new_only:
        new_only = True
    body, start, end, total = session_page(session, offset, length, new_only or offset == 0)
    return format_session(session, body, start, end, total, '')


def tool_force_terminate(args):
    pid = need_int(args, 'pid')
    if pid <= 1 or pid == os.getpid() or pid == os.getppid():
        raise ToolError('refusing to kill pid %s' % pid)
    session = get_session(pid)
    if session.exited:
        return 'pid %s already exited with %s' % (pid, session.exit_code)
    try:
        os.kill(-pid, signal.SIGKILL)
    except OSError:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError, exc:
            raise ToolError('kill failed: %s' % exc)
    deadline = time.time() + 2.0
    while time.time() < deadline and not session.exited:
        time.sleep(0.05)
    if session.exited:
        return 'killed %s (exit_code %s)' % (pid, session.exit_code)
    return 'sent SIGKILL to %s' % pid


def tool_list_sessions(args):
    if not SESSIONS:
        return 'no terminal sessions'
    lines = []
    for pid, session in SESSIONS.items():
        if session.exited:
            state = 'exited:%s' % session.exit_code
        else:
            state = 'running'
        lines.append('pid %s %s %s' % (pid, state, clip(session.command, 160)))
    return '\n'.join(lines)


def tool_list_processes(args):
    data = capture('ps auxww')
    lines = data.split('\n')
    if len(lines) > 250:
        lines = lines[:250]
        lines.append('... truncated')
    return '\n'.join(lines)


def tool_kill_process(args):
    pid = need_int(args, 'pid')
    if pid <= 1 or pid == os.getpid() or pid == os.getppid():
        raise ToolError('refusing to kill pid %s' % pid)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError, exc:
        raise ToolError('kill failed: %s' % exc)
    session = SESSIONS.get(pid)
    if session is not None and not session.exited:
        try:
            os.kill(-pid, signal.SIGTERM)
        except OSError:
            pass
    return 'sent SIGTERM to %s' % pid


def shutdown_sessions():
    for pid, session in SESSIONS.items():
        if not session.exited:
            try:
                os.kill(-pid, signal.SIGTERM)
            except OSError:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass


# --- screenshot ---

def tool_take_screenshot(args):
    """A picture of the main display, as a small JPEG the model can look at."""
    import base64
    width = opt_int(args, 'max_width', 1024)
    if width < 320:
        width = 320
    if width > 2048:
        width = 2048
    stamp = '%d-%d' % (os.getpid(), int(time.time() * 1000))
    png = '/tmp/ppc-shot-%s.png' % stamp
    jpg = '/tmp/ppc-shot-%s.jpg' % stamp
    try:
        # Tiger's screencapture writes PNG only; sips shrinks it and makes the JPEG.
        status = os.system('/usr/sbin/screencapture -x %s >/dev/null 2>&1' % png)
        if status != 0 or not os.path.isfile(png) or os.path.getsize(png) == 0:
            raise ToolError('could not capture the screen. Someone must be logged in at this Mac, '
                            'and the display must be awake.')
        os.system('/usr/bin/sips -Z %d -s format jpeg -s formatOptions 60 %s --out %s >/dev/null 2>&1' % (width, png, jpg))
        if not os.path.isfile(jpg) or os.path.getsize(jpg) == 0:
            raise ToolError('could not shrink the screenshot')
        f = open(jpg, 'rb')
        try:
            data = f.read()
        finally:
            f.close()
        return {
            'text': 'Screenshot of the main display (%d bytes, JPEG).' % len(data),
            'image': base64.encodestring(data).replace('\n', ''),
            'mime': 'image/jpeg',
        }
    finally:
        for path in (png, jpg):
            try:
                os.unlink(path)
            except OSError:
                pass


# --- config and history tools ---

def tool_get_config(args):
    roots = CONFIG.get('allowedDirectories', [])
    if isinstance(roots, list) and len(roots) == 0:
        root_text = '(empty - file tools may use the whole filesystem)'
    else:
        root_text = dumps(roots)
    blocked = CONFIG.get('blockedCommands', [])
    if CONFIG.get('telemetryEnabled'):
        telemetry_text = 'true'
    else:
        telemetry_text = 'false'
    lines = [
        'blockedCommands: %s' % dumps(blocked),
        'defaultShell: %s' % CONFIG.get('defaultShell', ''),
        'allowedDirectories: %s' % root_text,
        'fileReadLineLimit: %s' % CONFIG.get('fileReadLineLimit', ''),
        'fileWriteLineLimit: %s' % CONFIG.get('fileWriteLineLimit', ''),
        'telemetryEnabled: %s' % telemetry_text,
        'telemetry: this server does not send telemetry anywhere',
        'python: %s' % SYSINFO.get('python', ''),
        'model: %s' % SYSINFO.get('model', ''),
        'mem_bytes: %s' % SYSINFO.get('mem', ''),
        'uname: %s' % SYSINFO.get('uname', ''),
        'sw_vers: %s' % SYSINFO.get('sw_vers', '').replace('\n', '; '),
        'version: %s' % VERSION,
    ]
    return '\n'.join(lines)


def tool_set_config_value(args):
    key = need_str(args, 'key')
    if key not in DEFAULT_CONFIG:
        raise ToolError('unknown config key %s' % key)
    if 'value' not in args:
        raise ToolError('missing value')
    value = args['value']
    if key in LOCKED_KEYS:
        raise ToolError(
            '%s is locked. It controls what tools may run and touch, so only a '
            'person can change it, by editing %s on this Mac '
            '(or %s as an administrator).' % (key, config_path(), POLICY_PATH)
        )
    if key in ('blockedCommands', 'allowedDirectories'):
        value = as_str_list(value)
        if key == 'blockedCommands':
            for word in value:
                if word == '' or (' ' in word) or ('/' in word):
                    raise ToolError('blocked command names are single words, not paths')
        CONFIG[key] = value
    elif key == 'defaultShell':
        value = as_str(value)
        if not os.path.isfile(value):
            raise ToolError('shell does not exist: %s' % value)
        CONFIG[key] = value
    elif key in ('fileReadLineLimit', 'fileWriteLineLimit'):
        value = as_int(value)
        if value < 1 or value > 100000:
            raise ToolError('%s must be from 1 to 100000' % key)
        CONFIG[key] = value
    elif key == 'telemetryEnabled':
        if as_bool(value):
            CONFIG[key] = True
        else:
            CONFIG[key] = False
    else:
        raise ToolError('unknown config key %s' % key)
    save_config()
    return 'set %s\n%s' % (key, tool_get_config({}))


def tool_get_usage_stats(args):
    lines = [
        'started: %s' % USAGE.get('started', ''),
        'tool_calls: %s' % USAGE.get('tool_calls', 0),
        'errors: %s' % USAGE.get('errors', 0),
        'by_tool: %s' % dumps(USAGE.get('by_tool', {})),
        'server: ppc-commander %s' % VERSION,
    ]
    return '\n'.join(lines)


def tool_get_recent_tool_calls(args):
    limit = opt_int(args, 'maxResults', 20)
    if limit < 1:
        limit = 1
    if limit > 100:
        limit = 100
    tool_name = opt_str(args, 'toolName', None)
    since = opt_str(args, 'since', None)
    path = history_path()
    if not os.path.isfile(path):
        return 'no tool calls yet'
    f = open(path, 'rb')
    try:
        raw_lines = f.readlines()
    finally:
        f.close()
    rows = []
    for raw in raw_lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = loads(raw)
        except JsonError:
            continue
        if not isinstance(rec, dict):
            continue
        if tool_name and rec.get('tool') != tool_name:
            continue
        if since and str(rec.get('time', '')) < since:
            continue
        rows.append(rec)
    if len(rows) > limit:
        rows = rows[-limit:]
    rows.reverse()
    if not rows:
        return 'no matching tool calls'
    parts = []
    for rec in rows:
        if rec.get('ok'):
            ok_text = 'true'
        else:
            ok_text = 'false'
        parts.append(
            '%s %s ok=%s %sms\nargs: %s\noutput: %s'
            % (
                rec.get('time', ''),
                rec.get('tool', ''),
                ok_text,
                rec.get('duration_ms', ''),
                dumps(rec.get('arguments', {})),
                rec.get('output_preview', ''),
            )
        )
    return cap_text('\n\n'.join(parts))


def prop(kind, description):
    return {'type': kind, 'description': description}


def tool_defs():
    return [
        {
            'name': 'take_screenshot',
            'description': (
                'Take a screenshot of this Mac\'s main display and return it as an image, to see what an '
                'application or window looks like. It needs someone logged in at the console.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {'max_width': prop('number', 'Widest the picture may be, in pixels. Default 1024.')},
                'additionalProperties': True,
            },
        },
        {
            'name': 'get_config',
            'description': 'Show ppc-commander configuration and what this Mac is running.',
            'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': True},
        },
        {
            'name': 'set_config_value',
            'description': (
                'Set one config key: fileReadLineLimit, fileWriteLineLimit, or telemetryEnabled '
                '(stored only; nothing is sent). blockedCommands, allowedDirectories, and '
                'defaultShell are locked and can only be changed by a person on this Mac.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'key': prop('string', 'Config key'),
                    'value': {'description': 'New value: string, number, boolean, or array of strings'},
                },
                'required': ['key', 'value'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'read_file',
            'description': (
                'Read a text file on this Mac. offset is a 0-based line number; '
                'negative offset reads from the end (like tail). length defaults to fileReadLineLimit. '
                'Also fetches http, https, or ftp URLs. Excel, PDF, and DOCX are not parsed. '
                'Modern HTTPS usually fails on Tiger.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'path': prop('string', 'Filesystem path or URL'),
                    'isUrl': prop('boolean', 'Set true to fetch path as a URL'),
                    'offset': prop('number', '0-based line offset; negative means from the end'),
                    'length': prop('number', 'Maximum lines to return'),
                },
                'required': ['path'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'read_multiple_files',
            'description': 'Read up to 20 text files. Each file returns at most 200 lines.',
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'paths': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Paths on this Mac'},
                },
                'required': ['paths'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'write_file',
            'description': (
                'Create or overwrite a text file, or append to it. mode is "rewrite" or "append". '
                'Refuses content larger than fileWriteLineLimit.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'path': prop('string', 'Destination path'),
                    'content': prop('string', 'File bytes as text'),
                    'mode': prop('string', 'rewrite (default) or append'),
                },
                'required': ['path', 'content'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'create_directory',
            'description': 'Create a directory, including parents. Existing directories are fine.',
            'inputSchema': {
                'type': 'object',
                'properties': {'path': prop('string', 'Directory path')},
                'required': ['path'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'list_directory',
            'description': 'List a directory. depth defaults to 2 and is capped at 6. Listings stop at 500 entries.',
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'path': prop('string', 'Directory path'),
                    'depth': prop('number', 'How many levels to descend, default 2'),
                },
                'required': ['path'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'move_file',
            'description': 'Move or rename a file or directory.',
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'source': prop('string', 'Existing path'),
                    'destination': prop('string', 'New path'),
                },
                'required': ['source', 'destination'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'get_file_info',
            'description': 'Stat a file, directory, or symlink.',
            'inputSchema': {
                'type': 'object',
                'properties': {'path': prop('string', 'Path')},
                'required': ['path'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'edit_block',
            'description': (
                'Replace an exact snippet in a text file. old_string must match the file exactly '
                'expected_replacements times (default 1). Newlines are retried in normalized form if needed. '
                'Excel ranges are not supported.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'file_path': prop('string', 'File to edit'),
                    'old_string': prop('string', 'Exact text to replace'),
                    'new_string': prop('string', 'Replacement text; empty deletes the match'),
                    'expected_replacements': prop('number', 'How many matches to replace, default 1'),
                },
                'required': ['file_path', 'old_string', 'new_string'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'start_search',
            'description': (
                'Search this Mac. searchType "files" matches names (glob if the pattern has * ? or [, '
                'otherwise a substring). searchType "content" uses a Python regular expression unless '
                'literalSearch is true. There is no ripgrep. Returns a sessionId for later pages.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'path': prop('string', 'File or directory to search'),
                    'pattern': prop('string', 'Name substring/glob, or content regex'),
                    'searchType': prop('string', 'files (default) or content'),
                    'filePattern': prop('string', 'Optional filename glob for content search'),
                    'ignoreCase': prop('boolean', 'Default true'),
                    'maxResults': prop('number', 'Stop after this many matches, default 200'),
                    'includeHidden': prop('boolean', 'Descend into dotfiles, default false'),
                    'contextLines': prop('number', 'Context lines around a content match, max 5'),
                    'timeout_ms': prop('number', 'Search budget, default 15000, max 60000'),
                    'earlyTermination': prop('boolean', 'Stop files search on an exact basename match'),
                    'literalSearch': prop('boolean', 'Treat a content pattern as plain text'),
                },
                'required': ['path', 'pattern'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'get_more_search_results',
            'description': 'Read another page of a search started by start_search.',
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'sessionId': prop('string', 'sessionId from start_search'),
                    'offset': prop('number', '0-based result offset'),
                    'length': prop('number', 'How many results, default 100'),
                },
                'required': ['sessionId'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'stop_search',
            'description': 'Stop a running search.',
            'inputSchema': {
                'type': 'object',
                'properties': {'sessionId': prop('string', 'sessionId from start_search')},
                'required': ['sessionId'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'list_searches',
            'description': 'List search sessions started in this server process.',
            'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': True},
        },
        {
            'name': 'start_process',
            'description': (
                'Run a shell command on this Mac under bash -c, on a pseudo-terminal. '
                'Returns when the process exits, when output has been idle for about 0.4s, '
                'or when timeout_ms elapses (capped at 120000). The process keeps running after a timeout. '
                'Set detach true for a GUI or anything that should keep running after this call: '
                'it is started in its own session, with no terminal, and closing the chat does not stop it. '
                'Use open for a Mac .app. '
                'Include a trailing newline yourself when talking to an interactive program later.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'command': prop('string', 'Shell command'),
                    'timeout_ms': prop('number', 'How long to wait for the first output'),
                    'shell': prop('string', 'Optional shell path, default /bin/bash'),
                    'detach': prop('boolean', 'Start outside this chat so a GUI can keep running'),
                },
                'required': ['command', 'timeout_ms'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'interact_with_process',
            'description': (
                'Write input to a process started by start_process. The bytes are sent as-is; '
                'include the newline if the program expects Enter.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'pid': prop('number', 'pid from start_process'),
                    'input': prop('string', 'Bytes to write'),
                    'timeout_ms': prop('number', 'How long to wait for new output'),
                },
                'required': ['pid', 'input'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'read_process_output',
            'description': (
                'Read captured output. Omit offset (or pass 0) for lines since the last read. '
                'A positive offset is a 1-based absolute line. A negative offset reads from the end.'
            ),
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'pid': prop('number', 'pid from start_process'),
                    'timeout_ms': prop('number', 'Wait this long for more output first'),
                    'offset': prop('number', '0 = new output, positive = 1-based line, negative = tail'),
                    'length': prop('number', 'Maximum lines'),
                },
                'required': ['pid'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'force_terminate',
            'description': 'SIGKILL a process started by start_process.',
            'inputSchema': {
                'type': 'object',
                'properties': {'pid': prop('number', 'pid from start_process')},
                'required': ['pid'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'list_sessions',
            'description': 'List terminal sessions started by this server.',
            'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': True},
        },
        {
            'name': 'list_processes',
            'description': 'Run ps auxww on this Mac.',
            'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': True},
        },
        {
            'name': 'kill_process',
            'description': 'Send SIGTERM to any pid this user may signal. Refuses pid 1 and this server.',
            'inputSchema': {
                'type': 'object',
                'properties': {'pid': prop('number', 'Process id')},
                'required': ['pid'],
                'additionalProperties': True,
            },
        },
        {
            'name': 'get_usage_stats',
            'description': 'Local counts of tool calls made to this server. Nothing is uploaded.',
            'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': True},
        },
        {
            'name': 'get_recent_tool_calls',
            'description': 'Recent local tool-call history with truncated arguments and output.',
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'maxResults': prop('number', 'How many calls, default 20, max 100'),
                    'toolName': prop('string', 'Optional tool name filter'),
                    'since': prop('string', 'Optional ISO timestamp; return calls at or after it'),
                },
                'additionalProperties': True,
            },
        },
    ]


HANDLERS = {
    'get_config': tool_get_config,
    'set_config_value': tool_set_config_value,
    'read_file': tool_read_file,
    'read_multiple_files': tool_read_multiple,
    'write_file': tool_write_file,
    'create_directory': tool_create_directory,
    'list_directory': tool_list_directory,
    'move_file': tool_move_file,
    'get_file_info': tool_get_file_info,
    'edit_block': tool_edit_block,
    'start_search': tool_start_search,
    'get_more_search_results': tool_get_more_search_results,
    'stop_search': tool_stop_search,
    'list_searches': tool_list_searches,
    'start_process': tool_start_process,
    'interact_with_process': tool_interact,
    'read_process_output': tool_read_process_output,
    'force_terminate': tool_force_terminate,
    'list_sessions': tool_list_sessions,
    'list_processes': tool_list_processes,
    'kill_process': tool_kill_process,
    'take_screenshot': tool_take_screenshot,
    'get_usage_stats': tool_get_usage_stats,
    'get_recent_tool_calls': tool_get_recent_tool_calls,
}


def call_tool(params):
    if not isinstance(params, dict):
        raise ToolError('invalid params')
    name = params.get('name')
    name = as_str(name)
    args = params.get('arguments', {})
    if args is None:
        args = {}
    if isinstance(args, (str, unicode)):
        args = loads(as_str(args))
    if not isinstance(args, dict):
        raise ToolError('arguments must be an object')
    started = time.time()
    try:
        if name not in HANDLERS:
            raise ToolError('unknown tool %s' % name)
        text = HANDLERS[name](args)
        ok = True
    except ToolError, exc:
        text = 'error: %s' % exc.args[0]
        ok = False
    except Exception, exc:
        text = 'error: %s' % exc
        ok = False
    dur = int((time.time() - started) * 1000)
    image = None
    if isinstance(text, dict):
        image = text
        text = image.get('text', '')
    record(name, args, text, ok, dur)
    if not isinstance(text, str):
        text = str(text)
    if ok:
        is_error = False
    else:
        is_error = True
    content = [{'type': 'text', 'text': text}]
    if image is not None and ok:
        content.insert(0, {'type': 'image', 'data': image['image'], 'mimeType': image['mime']})
    return {
        'content': content,
        'isError': is_error,
    }


def initialize_result(params):
    version = '2024-11-05'
    if isinstance(params, dict) and params.get('protocolVersion') is not None:
        try:
            version = as_str(params.get('protocolVersion'))
        except ToolError:
            version = '2024-11-05'
    return {
        'protocolVersion': version,
        'capabilities': {'tools': {'listChanged': False}},
        'serverInfo': {'name': 'ppc-commander', 'version': VERSION},
        'instructions': instructions(),
    }


def rpc_ok(mid, result):
    return {'jsonrpc': '2.0', 'id': mid, 'result': result}


def rpc_error(mid, code, message):
    return {'jsonrpc': '2.0', 'id': mid, 'error': {'code': code, 'message': message}}


def dispatch(msg):
    if not isinstance(msg, dict):
        return rpc_error(None, -32600, 'invalid request')
    method = msg.get('method', '')
    if isinstance(method, unicode):
        method = method.encode('utf-8')
    if not isinstance(method, str):
        method = str(method)
    has_id = 'id' in msg
    mid = msg.get('id', None)
    if method.startswith('notifications/') or method == 'initialized':
        return None
    if not has_id:
        return None
    params = msg.get('params', {})
    if params is None:
        params = {}
    try:
        if method == 'initialize':
            return rpc_ok(mid, initialize_result(params))
        if method == 'ping':
            return rpc_ok(mid, {})
        if method == 'logging/setLevel':
            return rpc_ok(mid, {})
        if method == 'tools/list':
            return rpc_ok(mid, {'tools': tool_defs()})
        if method == 'tools/call':
            return rpc_ok(mid, call_tool(params))
        if method == 'resources/list':
            return rpc_ok(mid, {'resources': []})
        if method == 'resources/templates/list':
            return rpc_ok(mid, {'resourceTemplates': []})
        if method == 'prompts/list':
            return rpc_ok(mid, {'prompts': []})
        return rpc_error(mid, -32601, 'method not found: %s' % method)
    except ToolError, exc:
        return rpc_error(mid, -32602, exc.args[0])
    except JsonError, exc:
        return rpc_error(mid, -32700, 'parse error: %s' % exc)
    except Exception, exc:
        return rpc_error(mid, -32603, str(exc))


def read_exact(count):
    body = ''
    while len(body) < count:
        chunk = sys.stdin.read(count - len(body))
        if chunk == '':
            raise JsonError('eof in body')
        body += chunk
    return body


def read_framed(first):
    length = None
    line = first
    while True:
        stripped = line.strip()
        if stripped == '':
            break
        colon = stripped.find(':')
        if colon != -1 and stripped[:colon].strip().lower() == 'content-length':
            try:
                length = int(stripped[colon + 1:].strip())
            except ValueError:
                raise JsonError('bad content-length')
        line = sys.stdin.readline()
        if line == '':
            raise JsonError('eof in headers')
    if length is None:
        raise JsonError('missing content-length')
    if length < 0 or length > MAX_MESSAGE:
        raise JsonError('bad content-length')
    return loads(read_exact(length))


def read_message():
    while True:
        line = sys.stdin.readline()
        if line == '':
            return None
        if line.strip() == '':
            continue
        if line.lower().startswith('content-length:'):
            return read_framed(line), 'framed'
        return loads(line.strip()), 'ndjson'


def write_message(obj, framing):
    data = dumps(obj)
    try:
        if framing == 'framed':
            sys.stdout.write('Content-Length: %d\r\n\r\n' % len(data))
            sys.stdout.write(data)
        else:
            sys.stdout.write(data)
            sys.stdout.write('\n')
        sys.stdout.flush()
    except IOError:
        shutdown_sessions()
        sys.exit(0)


def serve():
    while True:
        try:
            incoming = read_message()
        except JsonError, exc:
            log('parse error: %s' % exc)
            write_message(rpc_error(None, -32700, 'parse error: %s' % exc), 'ndjson')
            continue
        if incoming is None:
            break
        msg, framing = incoming
        reply = dispatch(msg)
        if reply is not None:
            write_message(reply, framing)
    shutdown_sessions()


def expect(name, cond, failures, detail):
    if cond:
        sys.stderr.write('PASS %s\n' % name)
        return
    sys.stderr.write('FAIL %s %s\n' % (name, detail))
    failures.append(name)


def run_self_test():
    failures = []
    sample = {
        's': 'say "hi"\n\t',
        'u': u'caf\u00e9'.encode('utf-8'),
        'n': -12,
        'f': 1.5,
        'b': True,
        'z': None,
        'a': [1, False, {'k': 'v'}],
    }
    encoded = dumps(sample)
    if '\n' in encoded:
        expect('json one line', False, failures, 'encoder emitted a raw newline')
    else:
        expect('json one line', True, failures, '')
    back = loads(encoded)
    expect('json roundtrip', back == sample, failures, repr(back))
    expect('json bool', loads('true') is True and loads('false') is False, failures, '')
    try:
        loads('{"a":1} trailing')
        expect('json trailing', False, failures, 'accepted trailing junk')
    except JsonError:
        expect('json trailing', True, failures, '')

    expect('block plain', command_blocked('echo hello') is None, failures, '')
    expect('block word', command_blocked('echo shutdown') is None, failures, command_blocked('echo shutdown'))
    expect('block shutdown', command_blocked('shutdown -h now') == 'shutdown', failures, str(command_blocked('shutdown -h now')))
    expect('block sudo chain', command_blocked('echo hi; sudo shutdown -h now') == 'shutdown', failures, '')
    expect('block dd path', command_blocked('/bin/dd if=/dev/zero of=/tmp/x bs=1 count=1') == 'dd', failures, str(command_blocked('/bin/dd if=/dev/zero of=/tmp/x bs=1 count=1')))
    expect('block diskutil list', command_blocked('diskutil list') is None, failures, str(command_blocked('diskutil list')))
    expect('block diskutil erase', command_blocked('diskutil eraseDisk JHFS+ X disk1') is not None, failures, '')
    expect('block redirect', command_blocked('echo hi > /dev/disk0') is not None, failures, '')
    for disguised in (
        "sh -c 'dd if=/dev/zero of=/tmp/x count=1'",
        "d''d if=/dev/zero of=/tmp/x",
        '\\shutdown -h now',
        'env FOO=1 halt',
        'sudo -u root reboot',
        'echo x; $(echo y); poweroff',
        'FOO=1 BAR=2 shutdown -r now',
        'echo a | xargs shutdown',
        'bash -c "diskutil eraseDisk JHFS+ X disk1"',
    ):
        expect('block %s' % disguised, command_blocked(disguised) is not None, failures, disguised)
    for fine in ('echo reboot later', 'grep -r shutdown /var/log', 'ls -la /tmp', 'diskutil list'):
        expect('allow %s' % fine, command_blocked(fine) is None, failures, str(command_blocked(fine)))
    try:
        tool_set_config_value({'key': 'blockedCommands', 'value': []})
        expect('config locked', False, failures, 'blockedCommands was changed')
    except ToolError:
        expect('config locked', 'dd' in CONFIG.get('blockedCommands', []), failures, '')
    try:
        tool_write_file({'path': config_path(), 'content': '{}'})
        expect('self protected', False, failures, 'config.json was writable')
    except ToolError:
        expect('self protected', True, failures, '')

    # Workspace folder limit.
    import tempfile
    work = os.path.realpath(tempfile.mkdtemp())
    WORKSPACE['root'] = work
    try:
        try:
            check_path(os.path.join(work, 'a.txt'))
            expect('workspace inside', True, failures, '')
        except ToolError:
            expect('workspace inside', False, failures, 'a file inside the folder was refused')
        for outside in ('/etc/hosts', os.path.join(work, '..', 'x'), '~/Desktop'):
            try:
                check_path(outside)
                expect('workspace outside %s' % outside, False, failures, 'was allowed')
            except ToolError:
                expect('workspace outside %s' % outside, True, failures, '')
        expect('workspace cmd ok', workspace_command_problem('ls -la; cat notes.txt > out.txt') is None, failures,
               str(workspace_command_problem('ls -la; cat notes.txt > out.txt')))
        expect('workspace cmd system program', workspace_command_problem('/usr/bin/gcc -o app app.c') is None, failures, '')
        expect('workspace cmd abs path', workspace_command_problem('cat /etc/passwd') is not None, failures, '')
        expect('workspace cmd home', workspace_command_problem('ls ~') is not None, failures, '')
        expect('workspace cmd dotdot', workspace_command_problem('cat ../secret') is not None, failures, '')
        expect('workspace cmd redirect', workspace_command_problem('echo x >/etc/foo') is not None, failures, '')
        expect('workspace cmd inside abs', workspace_command_problem('cat %s/a.txt' % work) is None, failures, '')
    finally:
        WORKSPACE['root'] = ''
        os.rmdir(work)
    expect('screenshot tool listed', 'take_screenshot' in [spec['name'] for spec in tool_defs()], failures, '')
    expect('screenshot handler', 'take_screenshot' in HANDLERS, failures, '')

    names = []
    for spec in tool_defs():
        names.append(spec['name'])
    missing = []
    for name in names:
        if name not in HANDLERS:
            missing.append(name)
    for name in HANDLERS.keys():
        if name not in names:
            missing.append(name)
    expect('tool table', len(missing) == 0 and len(names) == len(HANDLERS), failures, str(missing))

    reply = dispatch({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18', 'clientInfo': {'name': 'selftest', 'version': '0'}},
    })
    expect(
        'initialize',
        reply and reply.get('id') == 7 and reply['result']['protocolVersion'] == '2025-06-18',
        failures,
        repr(reply)[:300],
    )
    expect('initialized note', dispatch({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) is None, failures, '')
    listed = dispatch({'jsonrpc': '2.0', 'id': 8, 'method': 'tools/list'})
    expect('tools/list', listed and len(listed['result']['tools']) == len(HANDLERS), failures, '')

    base = '/tmp/ppc-commander-selftest-%d' % os.getpid()
    if os.path.exists(base):
        shutil.rmtree(base)
    os.makedirs(base)
    target = os.path.join(base, 'note.txt')
    try:
        wrote = tool_write_file({'path': target, 'content': 'alpha\nbeta\ngamma\n'})
        expect('write', wrote.startswith('wrote'), failures, wrote)
        read = tool_read_file({'path': target, 'offset': 1, 'length': 1})
        body = read.split('---\n', 1)[-1].strip()
        expect('read slice', body == 'beta', failures, read)
        tail = tool_read_file({'path': target, 'offset': -1, 'length': 5})
        tbody = tail.split('---\n', 1)[-1]
        expect('read tail', ('gamma' in tbody) and ('alpha' not in tbody), failures, tail)
        edited = tool_edit_block({'file_path': target, 'old_string': 'beta', 'new_string': 'BETA'})
        expect('edit', 'replaced 1' in edited, failures, edited)
        again = tool_read_file({'path': target, 'offset': 0, 'length': 10})
        expect('edit visible', 'BETA' in again, failures, again)
        info = tool_get_file_info({'path': target})
        expect('stat', 'type: file' in info, failures, info)
        listing = tool_list_directory({'path': base, 'depth': 1})
        expect('list', 'note.txt' in listing, failures, listing)
        try:
            tool_edit_block({'file_path': target, 'old_string': 'nope', 'new_string': 'x'})
            expect('edit miss', False, failures, 'should have failed')
        except ToolError:
            expect('edit miss', True, failures, '')
        old_limit = CONFIG.get('fileWriteLineLimit')
        CONFIG['fileWriteLineLimit'] = 2
        try:
            tool_write_file({'path': target, 'content': 'a\nb\nc\n'})
            expect('write limit', False, failures, 'limit not enforced')
        except ToolError, exc:
            expect('write limit', 'fileWriteLineLimit' in str(exc.args[0]), failures, str(exc.args[0]))
        CONFIG['fileWriteLineLimit'] = old_limit

        needle_dir = os.path.join(base, 'searchme')
        os.makedirs(needle_dir)
        f = open(os.path.join(needle_dir, 'hay.txt'), 'wb')
        try:
            f.write('xx PPCNEEDLE123 yy\n')
        finally:
            f.close()
        found = tool_start_search({
            'path': base,
            'pattern': 'PPCNEEDLE123',
            'searchType': 'content',
            'literalSearch': True,
        })
        expect('search', 'PPCNEEDLE123' in found and 'done: true' in found, failures, found)

        proc = tool_start_process({'command': 'echo ppc-process-ok', 'timeout_ms': 5000})
        expect('process', 'ppc-process-ok' in proc and 'status: exited' in proc, failures, proc)
        detached = tool_start_process({
            'command': 'sleep 30',
            'timeout_ms': 1000,
            'detach': True,
        })
        expect('detach status', 'status: detached' in detached, failures, detached)
        dm = re.search(r'pid: (\d+)', detached)
        if not dm:
            expect('detach pid', False, failures, detached)
        else:
            dpid = int(dm.group(1))
            alive = True
            try:
                os.kill(dpid, 0)
            except OSError:
                alive = False
            expect('detach alive', alive, failures, detached)
            try:
                os.kill(dpid, signal.SIGTERM)
            except OSError:
                pass
        m = re.search(r'pid: (\d+)', proc)
        if not m:
            expect('process pid', False, failures, proc)
        else:
            pid = int(m.group(1))
            out = tool_read_process_output({'pid': pid, 'offset': 1, 'length': 20})
            expect('process reread', 'ppc-process-ok' in out, failures, out)
        try:
            blocked = tool_start_process({'command': 'shutdown -h now', 'timeout_ms': 1000})
            expect('process blocked', False, failures, blocked)
        except ToolError, exc:
            expect('process blocked', str(exc.args[0]).find('blocked command') != -1, failures, str(exc.args[0]))
    except ToolError, exc:
        expect('tool error', False, failures, str(exc.args[0]))
    try:
        shutil.rmtree(base)
    except OSError:
        pass

    if failures:
        # The blocked-command success path above can append the name before the exception handler.
        uniq = []
        for name in failures:
            if name not in uniq:
                uniq.append(name)
        sys.stderr.write('%d failed: %s\n' % (len(uniq), ', '.join(uniq)))
        return 1
    sys.stderr.write('all passed\n')
    return 0


def main(argv):
    try:
        os.chdir(os.path.expanduser('~'))
    except OSError:
        pass
    load_config()
    apply_workspace_root()
    load_usage()
    collect_sysinfo()
    if len(argv) > 1 and argv[1] == '--self-test':
        sys.exit(run_self_test())
    # Explicit Stop in Tiger Build blocks even newly opened SSH sessions.
    state = os.path.expanduser('~/Library/Application Support/Tiger Build/commander')
    if os.path.isfile(os.path.join(state, 'disabled')):
        log('Commander is stopped. Choose Commander > Start in Tiger Build.')
        sys.exit(1)
    if not os.path.isdir(state):
        os.makedirs(state, 0700)
    marker = os.path.join(state, 'session-%s' % os.getpid())
    f = open(marker, 'w'); f.write('session'); f.close()
    def stopped(sig, frame):
        shutdown_sessions()
        try: os.unlink(marker)
        except OSError: pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, stopped)
    import atexit
    def cleanup_marker():
        try: os.unlink(marker)
        except OSError: pass
    atexit.register(cleanup_marker)
    log('ready pid=%s %s' % (os.getpid(), SYSINFO.get('uname', '')))
    try:
        serve()
    except KeyboardInterrupt:
        shutdown_sessions()
        sys.exit(0)


if __name__ == '__main__':
    main(sys.argv)
