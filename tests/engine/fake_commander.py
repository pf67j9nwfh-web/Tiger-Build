#!/usr/bin/env python3
"""A stand-in for ppc_commander.py: the MCP calls the engine makes, with canned answers. Records what it was asked."""
import json
import os
import sys

LOG = os.environ.get("FAKE_COMMANDER_LOG")
TOOLS = [
    {"name": "start_process", "description": "Run a shell command", "inputSchema": {"type": "object", "properties": {"command": {"type": "string"}, "timeout_ms": {"type": "number"}}, "additionalProperties": True}},
    {"name": "read_file", "description": "Read a file", "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
    {"name": "take_screenshot", "description": "Screenshot", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "git_read", "description": "git", "inputSchema": {"type": "object", "properties": {}}},
]


def note(line):
    if LOG:
        with open(LOG, "a") as handle:
            handle.write(line + "\n")


for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    method = message.get("method")
    mid = message.get("id")
    note("%s %s env=%s" % (method, json.dumps(message.get("params"), sort_keys=True), os.environ.get("TB_WORKSPACE_ROOT", "")))
    if mid is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        name = message["params"]["name"]
        args = message["params"].get("arguments") or {}
        if name == "start_process" and "fail" in (args.get("command") or ""):
            result = {"content": [{"type": "text", "text": "boom"}], "isError": True}
        elif name == "take_screenshot":
            result = {"content": [{"type": "text", "text": "screen"}, {"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}]}
        else:
            result = {"content": [{"type": "text", "text": "file1\nfile2\x1b[31mred\x1b[0m"}]}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
    sys.stdout.flush()
