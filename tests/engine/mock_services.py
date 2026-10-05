#!/usr/bin/env python3
"""A stand-in for the model services: the same streaming formats, canned replies. Used by the engine tests.
    python3 mock_services.py PORT
Paths: /openai /openai-retry /anthropic /anthropic-cache /gemini /responses /local/v1/chat/completions"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEEN = []


def sse(items):
    out = b""
    for kind, data in items:
        if kind:
            out += ("event: %s\n" % kind).encode()
        out += ("data: %s\n\n" % (data if isinstance(data, str) else json.dumps(data))).encode()
    return out


def openai_chunks(tools):
    chunks = [
        {"choices": [{"delta": {"reasoning_content": "Let me think. "}}]},
        {"choices": [{"delta": {"content": "Hel"}}]},
        {"choices": [{"delta": {"content": "lo <think>hidden"}}]},
        {"choices": [{"delta": {"content": " more</think> there"}}]},
    ]
    if tools:
        chunks += [
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_1", "function": {"name": "start_process", "arguments": "{\"command\":"}}]}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "\"ls\"}"}}]}}]},
        ]
    chunks.append({"choices": [{"delta": {}, "finish_reason": "tool_calls" if tools else "stop"}]})
    chunks.append({"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20, "prompt_tokens_details": {"cached_tokens": 40}}})
    return [(None, c) for c in chunks] + [(None, "[DONE]")]


def anthropic_events(tools, thinking):
    events = [("message_start", {"type": "message_start", "message": {"usage": {"input_tokens": 50, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5, "output_tokens": 1}}})]
    index = 0
    if thinking:
        events += [
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Considering."}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "SIG"}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ]
        index = 1
    events += [
        ("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": "Hi "}}),
        ("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": "there"}}),
        ("content_block_stop", {"type": "content_block_stop", "index": index}),
    ]
    index += 1
    if tools:
        events += [
            ("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": "toolu_1", "name": "start_process", "input": {}}}),
            ("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": "{\"command\":"}}),
            ("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": "\"ls\"}"}}),
            ("content_block_stop", {"type": "content_block_stop", "index": index}),
        ]
    events.append(("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use" if tools else "end_turn"}, "usage": {"output_tokens": 33}}))
    events.append(("message_stop", {"type": "message_stop"}))
    return events


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    attempts = {}

    def log_message(self, *args):
        pass

    def send_chunked(self, status, body, ctype="text/event-stream"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        # Small pieces, split mid-line, so the reader has to reassemble them.
        step = 37
        for i in range(0, len(body), step):
            piece = body[i:i + step]
            self.wfile.write(b"%x\r\n" % len(piece) + piece + b"\r\n")
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")

    def send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/seen":
            self.send_json(200, SEEN)
            return
        if self.path == "/reset":
            SEEN.clear()
            self.attempts.clear()
            self.send_json(200, {})
            return
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) or b"{}"
        try:
            request = json.loads(raw)
        except ValueError:
            request = {"multipart": raw.decode("latin-1")[:400]}
        SEEN.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": request})
        path = self.path.split("?")[0]
        count = self.attempts[path] = self.attempts.get(path, 0) + 1
        if path in ("/mcp", "/mcp-sse"):
            method, ident = request.get("method"), request.get("id")
            if ident is None:
                self.send_response(202); self.send_header("Content-Length", "0"); self.end_headers(); return
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "mock", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": [{"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
            elif method == "tools/call":
                result = {"content": [{"type": "text", "text": "echo: " + request["params"]["arguments"].get("text", "") + " token=" + (self.headers.get("Authorization") or "none") + " session=" + (self.headers.get("Mcp-Session-Id") or "none")}]}
            else:
                result = {}
            message = json.dumps({"jsonrpc": "2.0", "id": ident, "result": result})
            if path == "/mcp-sse":
                data = ("event: message\ndata: " + message + "\n\n").encode()
                ctype = "text/event-stream"
            else:
                data = message.encode(); ctype = "application/json"
            self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Mcp-Session-Id", "sess-1")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if path == "/audio-openai":
            if "gpt-4o-mini-transcribe" in request.get("multipart", "") and count == 1:
                self.send_json(404, {"error": {"message": "model not found"}})
            else:
                self.send_json(200, {"text": " hello from the mock "})
        elif path == "/audio-gemini":
            self.send_json(200, {"candidates": [{"content": {"parts": [{"text": "gemini words"}]}}]})
        elif path in ("/openai", "/local/v1/chat/completions"):
            self.send_chunked(200, sse(openai_chunks(bool(request.get("tools")))))
        elif path == "/openai-retry":
            if count == 1:
                self.send_json(400, {"error": {"message": "Unknown parameter: stream_options"}})
            else:
                self.send_chunked(200, sse(openai_chunks(False)))
        elif path == "/slow":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            first = sse([(None, {"choices": [{"delta": {"content": "start"}}]})])
            self.wfile.write(b"%x\r\n" % len(first) + first + b"\r\n")
            self.wfile.flush()
            import time
            time.sleep(8)
        elif path in ("/loop-claude", "/loop-openai"):
            # First request asks for a tool; once a tool result is in the conversation, answer.
            text = json.dumps(request)
            answered = "tool_result" in text or '"role": "tool"' in text
            if path == "/loop-claude":
                events = anthropic_events(not answered, False)
                if answered:
                    events = [e for e in events if True]
                self.send_chunked(200, sse(events))
            else:
                self.send_chunked(200, sse(openai_chunks(not answered)))
        elif path == "/grok":
            if request.get("previous_response_id"):
                items = [("response.output_text.delta", {"type": "response.output_text.delta", "delta": "Grok done"}),
                         ("response.completed", {"type": "response.completed", "response": {"id": "r2", "output": [], "usage": {"input_tokens": 40, "output_tokens": 4}}})]
            else:
                items = [("response.output_text.delta", {"type": "response.output_text.delta", "delta": "Checking. "}),
                         ("response.completed", {"type": "response.completed", "response": {"id": "r1", "output": [{"type": "function_call", "call_id": "fc_9", "name": "start_process", "arguments": "{\"command\":\"ls\"}"}], "usage": {"input_tokens": 30, "output_tokens": 3}}})]
            self.send_chunked(200, sse(items))
        elif path == "/openai-down":
            self.send_json(429, {"error": {"message": "Rate limit reached"}})
        elif path == "/anthropic":
            self.send_chunked(200, sse(anthropic_events(bool(request.get("tools")), bool(request.get("thinking")))))
        elif path == "/anthropic-cache":
            if count == 1:
                self.send_json(400, {"error": {"message": "cache_control is not supported on this model"}})
            else:
                self.send_chunked(200, sse(anthropic_events(False, False)))
        elif path == "/anthropic-limit":
            if count == 1:
                self.send_json(400, {"error": {"message": "max_tokens: 64000 > 8192, which is the maximum allowed"}})
            else:
                self.send_chunked(200, sse(anthropic_events(False, False)))
        elif path.startswith("/gemini"):
            parts = [{"thought": True, "text": "Pondering."}, {"text": "Gem"}, {"text": "ini says hi"}]
            if request.get("tools"):
                parts.append({"functionCall": {"name": "start_process", "args": {"command": "ls"}}, "thoughtSignature": "GSIG"})
            items = [(None, {"candidates": [{"content": {"parts": parts}, "finishReason": "STOP"}], "usageMetadata": {"promptTokenCount": 70, "cachedContentTokenCount": 20, "candidatesTokenCount": 5, "thoughtsTokenCount": 3}})]
            self.send_chunked(200, sse(items))
        elif path == "/responses":
            output = []
            if request.get("tools"):
                output.append({"type": "function_call", "call_id": "fc_1", "name": "start_process", "arguments": "{\"command\":\"ls\"}"})
            items = [
                ("response.reasoning_summary_text.delta", {"type": "response.reasoning_summary_text.delta", "delta": "Summary."}),
                ("response.output_text.delta", {"type": "response.output_text.delta", "delta": "Resp"}),
                ("response.output_text.delta", {"type": "response.output_text.delta", "delta": "onse"}),
                ("response.completed", {"type": "response.completed", "response": {"id": "r1", "output": output, "usage": {"input_tokens": 30, "output_tokens": 7, "input_tokens_details": {"cached_tokens": 10}}}}),
            ]
            self.send_chunked(200, sse(items))
        else:
            self.send_json(404, {"error": {"message": "unknown path " + path}})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Handler)
    server.serve_forever()
