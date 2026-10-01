#!/usr/bin/env python3
"""Stdio bridge to an MCP Streamable HTTP endpoint.

Configure as a custom MCP server: command is an absolute python3, and the
argument is this script plus the URL. MCP_AUTH_TOKEN, if set, is sent as a
bearer token. OAuth and legacy SSE endpoints are not supported. A remote
server must use HTTPS.
"""
import json
import os
import sys
import urllib.parse
import urllib.request

url = sys.argv[1] if len(sys.argv) > 1 else ""
parsed = urllib.parse.urlparse(url)
if parsed.scheme not in ("https", "http") or not parsed.hostname:
    sys.stderr.write("Specify a valid Streamable HTTP MCP URL.\n")
    sys.exit(1)
if parsed.scheme == "http" and parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
    sys.stderr.write("Non-local MCP endpoints must use HTTPS.\n")
    sys.exit(1)

session = ""
for line in sys.stdin:
    request = {}
    try:
        request = json.loads(line)
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-06-18",
        }
        if session:
            headers["Mcp-Session-Id"] = session
        token = os.environ.get("MCP_AUTH_TOKEN", "")
        if token:
            headers["Authorization"] = "Bearer " + token
        outgoing = urllib.request.Request(
            url, data=json.dumps(request).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(outgoing, timeout=60) as response:
            session = response.headers.get("Mcp-Session-Id") or session
            if request.get("id") is None:
                continue
            if response.headers.get("Content-Type", "").startswith("text/event-stream"):
                chunks = []
                message = None
                for raw in response:
                    text = raw.decode("utf-8").rstrip("\r\n")
                    if text.startswith("data:"):
                        chunks.append(text[5:].lstrip())
                    elif not text and chunks:
                        event = json.loads("\n".join(chunks))
                        chunks = []
                        if event.get("id") == request["id"]:
                            message = event
                            break
                if message is None:
                    raise ValueError("Remote MCP ended without a response.")
            else:
                message = json.load(response)
        print(json.dumps(message), flush=True)
    except Exception as exc:
        if request.get("id") is not None:
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": request["id"],
                "error": {"code": -32000, "message": str(exc)},
            }), flush=True)
