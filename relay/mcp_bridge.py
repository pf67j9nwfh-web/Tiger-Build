"""Speak MCP to ppc-commander on the Tiger Mac over SSH."""

import json
import os
import queue
import threading
import shlex
import subprocess
import time


def load_shell_config():
    config = {
        "TIGER_HOST": "",
        "TIGER_USER": "",
        "TIGER_KEY": os.path.expanduser("~/.ssh/ppc_tiger_rsa"),
        "TIGER_KNOWN": os.path.expanduser("~/.ssh/ppc_tiger_known_hosts"),
        "REMOTE_COMMANDER": "$HOME/ppc-commander/ppc_commander.py",
        "LISTEN_PORT": "8765",
    }
    from paths import config_sh
    path = config_sh()
    if os.path.isfile(path):
        handle = open(path, "r")
        try:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                # Decode quoted values without executing shell expressions.
                # Backups render paths with shlex.quote, including apostrophes.
                tokens = shlex.split(value.strip(), comments=True)
                if len(tokens) != 1:
                    if not tokens:
                        value = ""
                    else:
                        raise ValueError("Invalid config value for %s" % name.strip())
                else:
                    value = tokens[0]
                name = name.strip()
                if name in ("TIGER_KEY", "TIGER_KNOWN"):
                    value = value.replace("$HOME", os.path.expanduser("~"))
                    value = value.replace("${HOME}", os.path.expanduser("~"))
                    value = os.path.expanduser(value)
                config[name] = value
        finally:
            handle.close()
    return config


def ssh_base(config):
    """The ssh program and the options Tiger's OpenSSH 5.x can talk to,
    ending with user@host. Add the remote command after it."""
    return [
        "ssh", "-T",
        "-i", config["TIGER_KEY"],
        "-o", "IdentityAgent=none",
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "PubkeyAuthentication=yes",
        "-o", "PubkeyAcceptedAlgorithms=ssh-rsa",
        "-o", "HostKeyAlgorithms=ssh-rsa",
        "-o", "KexAlgorithms=diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha1",
        "-o", "Ciphers=aes256-ctr,aes128-ctr",
        "-o", "MACs=hmac-sha1",
        "-o", "RequiredRSASize=2048",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=" + config["TIGER_KNOWN"],
        "-o", "UpdateHostKeys=no",
        "-o", "ConnectTimeout=12",
        "-o", "ServerAliveInterval=20",
        "-o", "ServerAliveCountMax=6",
        "%s@%s" % (config["TIGER_USER"], config["TIGER_HOST"]),
    ]


def ssh_command(config, root=""):
    """Run ppc-commander on the Tiger Mac. root, when given, limits its file
    tools to that folder; the setting is passed in the command, so the model
    cannot change it."""
    assignments = ""
    if root:
        assignments = "TB_WORKSPACE_ROOT=%s " % shlex.quote(root)
    remote = (
        "exec /usr/bin/env LANG=C LC_ALL=C %s/usr/bin/python -u " % assignments
        + config["REMOTE_COMMANDER"]
    )
    return ssh_base(config) + [remote]


class McpError(Exception):
    pass


MAX_REPLY_BYTES = 32 * 1024 * 1024


class McpClient(object):
    """Newline-delimited JSON-RPC over the ssh child's stdin and stdout.

    Replies are read with os.read into a buffer, so select() always reflects
    what is really waiting. The old readline() version could block past its
    timeout on a partial line, and recursed once per blank line.
    """

    def __init__(self, command):
        self.command = command
        self.proc = None
        self.next_id = 1
        self.buffer = b""

    def start(self):
        self.proc = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=getattr(self, "env", None),
            bufsize=0,
        )
        self.buffer = b""
        self.stderr_tail = b""
        self._errors = threading.Thread(target=self._pump_errors)
        self._errors.daemon = True
        self._errors.start()
        self._chunks = queue.Queue()
        self._reader = threading.Thread(target=self._pump)
        self._reader.daemon = True
        self._reader.start()
        self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "tigerbuild", "version": "1.5"},
        }, timeout=45)
        self.notify("notifications/initialized", {})

    def close(self):
        if self.proc is None:
            return
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=2)
        except Exception:
            try:
                self.proc.kill()
                self.proc.wait(timeout=2)
            except Exception:
                pass
        self.proc = None


    def _pump_errors(self):
        """Keep the last of ssh's error output. It says why a login failed."""
        try:
            while True:
                chunk = self.proc.stderr.read(4096)
                if not chunk:
                    return
                self.stderr_tail = (self.stderr_tail + chunk)[-4000:]
        except Exception:
            return

    def stderr_text(self):
        return self.stderr_tail.decode("utf-8", "replace").strip()

    def _pump(self):
        try:
            while True:
                chunk = self.proc.stdout.read(65536)
                if not chunk:
                    self._chunks.put(b"")
                    return
                self._chunks.put(chunk)
        except Exception:
            self._chunks.put(b"")

    def _read_message(self, deadline):
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                line = self.buffer[:newline].strip()
                self.buffer = self.buffer[newline + 1:]
                if not line:
                    continue
                try:
                    return json.loads(line.decode("utf-8", "replace"))
                except ValueError:
                    # A login banner or stray print is not protocol; skip it.
                    continue
            if len(self.buffer) > MAX_REPLY_BYTES:
                raise McpError("the Tiger Mac sent a reply that is too large")
            remaining = deadline - time.time()
            if remaining <= 0:
                raise McpError("the Tiger Mac did not answer")
            try:
                chunk = self._chunks.get(timeout=remaining)
            except queue.Empty:
                raise McpError("the Tiger Mac did not answer")
            if not chunk:
                raise McpError("the Tiger Mac closed the connection")
            self.buffer += chunk

    def _write(self, payload):
        try:
            self.proc.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            raise McpError("the Tiger Mac closed the connection")

    def notify(self, method, params):
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params, timeout=120):
        mid = self.next_id
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        deadline = time.time() + timeout
        while True:
            message = self._read_message(deadline)
            if not isinstance(message, dict) or message.get("id") != mid:
                continue
            if message.get("error"):
                err = message["error"]
                raise McpError(err.get("message") if isinstance(err, dict) else str(err))
            return message.get("result") or {}


def tool_summary(name, arguments):
    if not isinstance(arguments, dict):
        return name
    for key in ("path", "command", "file_path", "source", "sessionId", "pid"):
        if arguments.get(key):
            value = str(arguments.get(key)).replace("\n", " ")
            if len(value) > 80:
                value = value[:80] + "..."
            return "%s %s" % (name, value)
    return name


def result_text(result):
    if not isinstance(result, dict):
        return str(result)
    content = result.get("content") or []
    parts = []
    for item in content:
        if isinstance(item, dict) and item.get("text"):
            parts.append(item["text"])
        elif isinstance(item, str):
            parts.append(item)
    text = "\n".join(parts).strip()
    if result.get("isError"):
        text = text or "the tool failed"
    if len(text) > 8000:
        text = text[:8000] + "\n... truncated"
    return text or "ok"


def result_images(result):
    """Images a tool returned: [{"mime": ..., "data": base64}]."""
    images = []
    if not isinstance(result, dict):
        return images
    for item in result.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "image" and isinstance(item.get("data"), str):
            mime = item.get("mimeType") or "image/jpeg"
            if mime in ("image/jpeg", "image/png", "image/gif", "image/webp") and len(item["data"]) < 6000000:
                images.append({"mime": mime, "data": item["data"]})
    return images


def xai_tools_from_mcp(listed):
    tools = []
    for tool in listed.get("tools") or []:
        name = tool.get("name")
        if not name:
            continue
        schema = tool.get("inputSchema") or {"type": "object", "properties": {}}
        if not isinstance(schema, dict) or schema.get("type") != "object":
            schema = {"type": "object", "properties": {}}
        schema = dict(schema)
        schema.pop("additionalProperties", None)
        tools.append({
            "type": "function",
            "name": name,
            "description": tool.get("description") or name,
            "parameters": schema,
        })
    return tools
