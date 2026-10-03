"""User-configured stdio MCP servers and built-in auxiliary tools.

Executables run on the relay computer, not the Tiger Mac. Arguments are
passed as a list, with no shell. A model tool cannot edit this file.
Imported servers stay disabled until the user enables them.
"""
import datetime
import json
import os
import re
import threading
import urllib.parse
import urllib.request

from mcp_bridge import McpClient, result_text, xai_tools_from_mcp
from security import support_dir

LOCK = threading.RLock()
DEFAULT = {
    "ppc_enabled": True,
    "toolbox_enabled": False,
    "search_enabled": False,
    "grok_native_search": True,
    "search_api_key": "",
    "tavily_api_key": "",
    "search_provider": "brave",
    # "Show model thinking" for every service; the key keeps its old name.
    "claude_thinking": True,
    # Ask before running tools: the person is asked first, for Commander and
    # for every custom server that has its own approval switch on.
    "ppc_approval": False,
    # Let the model ask another available model for a second opinion.
    "consult_enabled": True,
    # Tool rounds one reply may use before the relay stops it and says so.
    "max_tool_steps": 40,
    "servers": [],
}
FLAGS = (
    "ppc_approval",
    "consult_enabled",
    "ppc_enabled",
    "toolbox_enabled",
    "search_enabled",
    "grok_native_search",
    "claude_thinking",
)
TEXT = {"type": "string"}
AUXILIARY = (
    "agent_web_search",
    "agent_current_time",
    "agent_notes_read",
    "agent_notes_write",
)


def path():
    return os.path.join(support_dir(), "integrations.json")


def read():
    with LOCK:
        try:
            with open(path()) as handle:
                obj = json.load(handle)
        except (OSError, ValueError):
            obj = {}
        out = dict(DEFAULT)
        out.update(obj)
        return out


def validate(obj):
    if not isinstance(obj, dict):
        raise ValueError("Configuration must be an object.")
    out = dict(DEFAULT)
    for name in FLAGS:
        if name not in obj:
            continue
        if type(obj[name]) is not bool:
            raise ValueError(name + " must be true or false.")
        out[name] = obj[name]
    steps = obj.get("max_tool_steps", DEFAULT["max_tool_steps"])
    if type(steps) is not int or not 1 <= steps <= 200:
        raise ValueError("Tool steps per reply must be a whole number from 1 to 200.")
    out["max_tool_steps"] = steps
    key = obj.get("search_api_key", "")
    if not isinstance(key, str):
        raise ValueError("Search API key must be text.")
    out["search_api_key"] = key
    tavily = obj.get("tavily_api_key", "")
    if not isinstance(tavily, str):
        raise ValueError("Tavily key must be text.")
    out["tavily_api_key"] = tavily
    provider = obj.get("search_provider", "brave")
    if provider not in ("brave", "tavily"):
        raise ValueError("Search provider must be brave or tavily.")
    out["search_provider"] = provider
    servers = obj.get("servers", [])
    if not isinstance(servers, list) or len(servers) > 24:
        raise ValueError("At most 24 MCP servers allowed.")
    ids = set()
    clean = []
    for row in servers:
        if not isinstance(row, dict):
            raise ValueError("Malformed server.")
        name = row.get("id", "")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,19}", name) or name in ids:
            raise ValueError("Server IDs must be unique letters/digits/underscore, max 20 characters.")
        command = row.get("command", "")
        args = row.get("args", [])
        env = row.get("env", {})
        if not isinstance(command, str) or not os.path.isabs(command):
            raise ValueError("Use an absolute executable path.")
        if not isinstance(args, list) or any(not isinstance(item, str) for item in args):
            raise ValueError("Arguments must be a string array.")
        if not isinstance(env, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in env.items()):
            raise ValueError("Environment must be text key/value pairs.")
        enabled = row.get("enabled", False)
        if type(enabled) is not bool:
            raise ValueError("Enabled must be true or false.")
        approval = row.get("approval", False)
        if type(approval) is not bool:
            raise ValueError("Approval must be true or false.")
        title = row.get("title", "")
        if not isinstance(title, str) or len(title) > 60:
            raise ValueError("A server name must be text of at most 60 characters.")
        ids.add(name)
        clean.append({
            "id": name,
            "title": title.strip(),
            "command": command,
            "args": args,
            "env": env,
            "enabled": enabled,
            "approval": approval,
        })
    out["servers"] = clean
    return out


def write(obj, preserve_key=False):
    with LOCK:
        current = read()
        if preserve_key and not obj.get("search_api_key") and not obj.get("clear_search_key"):
            obj = dict(obj)
            obj["search_api_key"] = current["search_api_key"]
        if preserve_key and not obj.get("tavily_api_key") and not obj.get("clear_tavily_key"):
            obj = dict(obj)
            obj["tavily_api_key"] = current["tavily_api_key"]
        out = validate(obj)
        temporary = path() + ".tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(out, handle, indent=2)
        os.replace(temporary, path())
        return out


def public():
    obj = read()
    obj["search_key_saved"] = bool(obj["search_api_key"])
    obj["search_api_key"] = ""
    obj["tavily_key_saved"] = bool(obj["tavily_api_key"])
    obj["tavily_api_key"] = ""
    return obj


def catalogue():
    """What a chat can switch on or off, for Tiger Build's tools menu:
    [{id, title, approval, default}]. Only what the relay has enabled."""
    config = read()
    rows = []
    if config["ppc_enabled"]:
        rows.append({"id": "commander", "title": "Commander (this Mac)", "approval": config["ppc_approval"], "default": True})
    if config["toolbox_enabled"]:
        rows.append({"id": "toolbox", "title": "Agent toolbox", "approval": False, "default": True})
    if config["search_enabled"]:
        rows.append({"id": "search", "title": "Web search", "approval": False, "default": True})
    if config["consult_enabled"]:
        rows.append({"id": "consult", "title": "Ask other models", "approval": False, "default": False})
    for server in config["servers"]:
        if server["enabled"]:
            rows.append({"id": "mcp_" + server["id"], "title": server.get("title") or server["id"],
                         "approval": server.get("approval", False), "default": True})
    return rows


def function(name, desc, props, required=()):
    return {
        "type": "function",
        "name": name,
        "description": desc,
        "parameters": {
            "type": "object",
            "properties": props,
            "required": list(required),
        },
    }


def auxiliary(provider, config, skip=()):
    tools = []
    if config["toolbox_enabled"] and "toolbox" not in skip:
        tools.append(function("agent_current_time", "Current UTC date and time.", {}))
        tools.append(function("agent_notes_read", "Read persistent agent scratch notes on the relay host.", {}))
        tools.append(function(
            "agent_notes_write",
            "Replace persistent agent scratch notes. Never store credentials.",
            {"text": TEXT},
            ("text",),
        ))
    search_key = "tavily_api_key" if config.get("search_provider") == "tavily" else "search_api_key"
    if config["search_enabled"] and config.get(search_key) and provider != "grok" and "search" not in skip:
        tools.append(function(
            "agent_web_search",
            "Search the web using the configured Brave or Tavily service. Returns titles, links and snippets, not full pages.",
            {"query": TEXT},
            ("query",),
        ))
    return tools


def _search(query, config):
    provider = config.get("search_provider", "brave")
    key_name = "tavily_api_key" if provider == "tavily" else "search_api_key"
    key = config.get(key_name, "")
    if not config["search_enabled"] or not key:
        raise ValueError("Web search disabled or no API key.")
    if not isinstance(query, str) or not query.strip() or len(query) > 1500:
        raise ValueError("Supply a query of 1-1500 characters.")
    if provider == "tavily":
        payload = json.dumps({
            "query": query,
            "max_results": 5,
            "search_depth": "basic",
            "include_answer": False,
        }).encode()
        request = urllib.request.Request(
            "https://api.tavily.com/search",
            data=payload,
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=25) as response:
            data = json.load(response)
        rows = [
            {"title": item.get("title"), "url": item.get("url"), "description": item.get("content")}
            for item in data.get("results", [])
        ]
        return json.dumps(rows, ensure_ascii=False)
    url = "https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode({"q": query, "count": 5})
    request = urllib.request.Request(
        url,
        headers={"X-Subscription-Token": config["search_api_key"], "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        data = json.load(response)
    rows = [
        {"title": item.get("title"), "url": item.get("url"), "description": item.get("description")}
        for item in data.get("web", {}).get("results", [])
    ]
    return json.dumps(rows, ensure_ascii=False)


def run_auxiliary(name, args, config):
    if name == "agent_web_search":
        return _search(args.get("query", ""), config)
    if not config["toolbox_enabled"]:
        raise ValueError("Agent toolbox disabled.")
    if name == "agent_current_time":
        return datetime.datetime.now(datetime.timezone.utc).isoformat()
    notes = os.path.join(support_dir(), "agent-notes.txt")
    if name == "agent_notes_read":
        try:
            with open(notes) as handle:
                return handle.read(20000)
        except OSError:
            return "No notes yet."
    if name == "agent_notes_write":
        text = args.get("text")
        if not isinstance(text, str) or len(text) > 20000:
            raise ValueError("Notes limited to 20000 characters.")
        descriptor = os.open(notes, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(text)
        return "Notes saved."
    raise ValueError("Unknown auxiliary tool.")


class Connections:
    def __init__(self):
        self.clients = {}
        self.routes = {}
        self.config = read()
        self.errors = []
        self.offered = set()
        self.owners = {}

    def definitions(self, provider, skip=()):
        """Tools from the auxiliary toolbox and every enabled MCP server.
        skip names the keys the chat turned off ("toolbox", "search",
        "mcp_<id>")."""
        tools = auxiliary(provider, self.config, skip)
        for name in tools:
            self.owners[name["name"]] = "search" if name["name"] == "agent_web_search" else "toolbox"
        for server in self.config["servers"]:
            if not server["enabled"] or ("mcp_" + server["id"]) in skip:
                continue
            client = McpClient([server["command"]] + server["args"])
            client.env = dict(os.environ, **server["env"])
            try:
                client.start()
                listed = client.request("tools/list", {}, timeout=20)
                self.clients[server["id"]] = client
                for tool in xai_tools_from_mcp(listed):
                    original = tool["name"]
                    alias = "mcp_" + server["id"] + "_" + re.sub("[^A-Za-z0-9_]", "_", original)
                    if len(alias) > 64 or alias in self.routes:
                        continue
                    self.routes[alias] = (client, original)
                    self.owners[alias] = "mcp_" + server["id"]
                    tool = dict(tool)
                    tool["name"] = alias
                    tool["description"] = "[Relay MCP " + server["id"] + "] " + tool["description"]
                    tools.append(tool)
            except Exception as exc:
                client.close()
                self.errors.append(server["id"] + ": " + str(exc))
        self.offered = set(tool["name"] for tool in tools)
        return tools

    def approval_default(self, key):
        """Whether the relay's own settings ask before running this server's tools."""
        if key == "commander":
            return bool(self.config.get("ppc_approval"))
        if key.startswith("mcp_"):
            for server in self.config["servers"]:
                if "mcp_" + server["id"] == key:
                    return bool(server.get("approval"))
        return False

    def handles(self, name):
        return name in self.routes or name in AUXILIARY

    def call(self, name, args):
        if name not in self.offered:
            raise ValueError("Tool was not enabled or advertised for this request.")
        if not isinstance(args, dict):
            raise ValueError("Tool arguments must be an object.")
        if name in self.routes:
            client, original = self.routes[name]
            result = client.request("tools/call", {"name": original, "arguments": args}, timeout=90)
            if result.get("isError"):
                raise RuntimeError(result_text(result))
            return result_text(result)
        return run_auxiliary(name, args, self.config)

    def close(self):
        for client in self.clients.values():
            client.close()
        self.clients = {}
