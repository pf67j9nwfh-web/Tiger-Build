"""A tiny stdio MCP server framework used by the example servers.

Newline-delimited JSON-RPC 2.0 on stdin and stdout, which is what the relay
speaks to custom servers. Python 3.8 or later, standard library only.
"""
import json
import sys


def serve(name, version, tools):
    """tools: {name: (description, json_schema, function(args) -> str)}"""
    def reply(mid, result=None, error=None):
        message = {"jsonrpc": "2.0", "id": mid}
        if error is not None:
            message["error"] = {"code": -32603, "message": str(error)}
        else:
            message["result"] = result
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method = message.get("method")
        mid = message.get("id")
        if mid is None:
            continue  # a notification such as notifications/initialized
        if method == "initialize":
            reply(mid, {
                "protocolVersion": (message.get("params") or {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": name, "version": version},
            })
        elif method == "ping":
            reply(mid, {})
        elif method == "tools/list":
            reply(mid, {"tools": [
                {"name": key, "description": value[0], "inputSchema": value[1]}
                for key, value in tools.items()
            ]})
        elif method == "tools/call":
            params = message.get("params") or {}
            entry = tools.get(params.get("name"))
            if entry is None:
                reply(mid, error="unknown tool %s" % params.get("name"))
                continue
            try:
                text = entry[2](params.get("arguments") or {})
                reply(mid, {"content": [{"type": "text", "text": str(text)}], "isError": False})
            except Exception as exc:  # the model sees the message and can try again
                reply(mid, {"content": [{"type": "text", "text": "error: %s" % exc}], "isError": True})
        else:
            reply(mid, error="method not found: %s" % method)


def obj(properties, required=()):
    return {"type": "object", "properties": properties, "required": list(required)}


TEXT = {"type": "string"}
NUMBER = {"type": "number"}
