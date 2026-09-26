"""Speak MCP to ppc-commander over the legacy SSH session."""

import json
import os
import select
import subprocess


def load_shell_config():
    config = {
        "TIGER_HOST": "",
        "TIGER_USER": "",
        "TIGER_KEY": os.path.expanduser("~/.ssh/ppc_tiger_rsa"),
        "TIGER_KNOWN": os.path.expanduser("~/.ssh/ppc_tiger_known_hosts"),
        "REMOTE_COMMANDER": "$HOME/ppc-commander/ppc_commander.py",
        "LISTEN_PORT": "8765",
    }
    path = os.environ.get("TIGERDESK_CONFIG")
    if not path:
        path = os.path.expanduser("~/Library/Application Support/TigerDesk/config.sh")
    if os.path.isfile(path):
        handle = open(path, "r")
        try:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                value = value.strip().strip('"').strip("'")
                name = name.strip()
                if name in ("TIGER_KEY", "TIGER_KNOWN"):
                    value = value.replace("$HOME", os.path.expanduser("~"))
                    value = value.replace("${HOME}", os.path.expanduser("~"))
                    value = os.path.expanduser(value)
                config[name] = value
        finally:
            handle.close()
    return config


def ssh_command(config):
    remote = (
        "exec /usr/bin/env LANG=C LC_ALL=C /usr/bin/python -u "
        + config["REMOTE_COMMANDER"]
    )
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
        "-o", "KexAlgorithms=diffie-hellman-group14-sha1,diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1",
        "-o", "Ciphers=aes128-cbc,3des-cbc,aes256-cbc",
        "-o", "MACs=hmac-sha1,hmac-md5",
        "-o", "RequiredRSASize=512",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=" + config["TIGER_KNOWN"],
        "-o", "UpdateHostKeys=no",
        "-o", "ConnectTimeout=12",
        "%s@%s" % (config["TIGER_USER"], config["TIGER_HOST"]),
        remote,
    ]


class McpError(Exception):
    pass


class McpClient(object):
    def __init__(self, command):
        self.command = command
        self.proc = None
        self.next_id = 1

    def start(self):
        self.proc = subprocess.Popen(
            self.command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "tigerbuild", "version": "1.0"},
        })
        self.notify("notifications/initialized", {})

    def close(self):
        if self.proc is None:
            return
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.kill()
        except Exception:
            pass
        self.proc = None

    def _read_message(self, timeout):
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            raise McpError("the Power Mac did not answer")
        line = self.proc.stdout.readline()
        if not line:
            raise McpError("the Power Mac closed the connection")
        line = line.strip()
        if not line:
            return self._read_message(timeout)
        return json.loads(line.decode("utf-8"))

    def notify(self, method, params):
        body = json.dumps({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }) + "\n"
        self.proc.stdin.write(body.encode("utf-8"))
        self.proc.stdin.flush()

    def request(self, method, params, timeout=120):
        mid = self.next_id
        self.next_id += 1
        body = json.dumps({
            "jsonrpc": "2.0",
            "id": mid,
            "method": method,
            "params": params,
        }) + "\n"
        self.proc.stdin.write(body.encode("utf-8"))
        self.proc.stdin.flush()
        while True:
            message = self._read_message(timeout)
            if message.get("id") == mid:
                if "error" in message and message["error"]:
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
