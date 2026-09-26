#!/usr/bin/env python3
"""LAN relay for Tiger Build.

The Power Mac cannot speak modern HTTPS. This process accepts plain HTTP from
Tiger Build, calls the model APIs, and, when the model asks, runs
ppc-commander tools on that Mac over SSH.
"""

import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from app_config import clean_title
from app_config import context_for
from app_config import ensure_config_file
from app_config import local_models_text
from app_config import settings_public
from app_config import update_settings
from providers import gemini_contents
from providers import normalize as normalize_provider
from providers import resolve_model
from providers import stream_round
from mcp_bridge import (
    McpClient,
    McpError,
    load_shell_config,
    result_text,
    ssh_command,
    tool_summary,
    xai_tools_from_mcp,
)

MODEL = "grok-4.7"
API_URL = "https://api.x.ai/v1/responses"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYSTEM = (
    "You are an assistant chatting inside Tiger Build on a Power Mac G4 running "
    "Mac OS X 10.4 Tiger. You have ppc-commander tools that read files, "
    "edit files, and run shell commands on that Power Mac. Use them when "
    "the person asks about that computer or wants something done there. "
    "Do not use them for ordinary questions. "
    "Finish the task in this turn. Do not stop halfway, and do not ask the "
    "person to type continue, even if an earlier message did. Write a whole file in one call, then compile "
    "or test. Run commands that exit. Do not start a GUI or anything that "
    "keeps running. Use timeout_ms of 15000, or 20000 for a compile. "
    "The shell is bash and the system Python is 2.3. "
    "After the tools finish, answer in a few plain sentences."
)
MAX_TOOL_ROUNDS = 12


def load_env_file():
    candidates = [
        os.path.join(ROOT, ".env"),
        os.path.expanduser("~/AquaChat/.env"),
    ]
    for path in candidates:
        try:
            handle = open(path, "r")
        except IOError:
            continue
        try:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                name = name.strip()
                if name and name not in os.environ:
                    os.environ[name] = value.strip().strip('"').strip("'")
        finally:
            handle.close()


def load_key():
    key = os.environ.get("XAI_API_KEY", "").strip()
    if key:
        return key
    candidates = [
        os.path.join(ROOT, ".env"),
        os.path.expanduser("~/AquaChat/.env"),
    ]
    for path in candidates:
        try:
            handle = open(path, "r")
        except IOError:
            continue
        try:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                if name.strip() == "XAI_API_KEY":
                    return value.strip().strip('"').strip("'")
        finally:
            handle.close()
    return ""


def ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        cafile = "/etc/ssl/cert.pem"
        if os.path.isfile(cafile):
            return ssl.create_default_context(cafile=cafile)
        return ssl.create_default_context()


def extract_text(data):
    if isinstance(data.get("output_text"), str) and data["output_text"].strip():
        return data["output_text"].strip()
    parts = []
    for item in data.get("output") or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") not in (None, "message"):
            continue
        content = item.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for piece in content:
                if isinstance(piece, dict) and piece.get("text"):
                    parts.append(piece["text"])
                elif isinstance(piece, str):
                    parts.append(piece)
    text = "\n".join(parts).strip()
    if text:
        return text
    error = data.get("error")
    if isinstance(error, dict) and error.get("message"):
        raise RuntimeError(error["message"])
    if isinstance(error, str) and error:
        raise RuntimeError(error)
    return ""


def function_calls(data):
    calls = []
    for item in data.get("output") or []:
        if isinstance(item, dict) and item.get("type") == "function_call":
            calls.append(item)
    return calls


def api_error_text(detail, code):
    try:
        parsed = json.loads(detail)
    except ValueError:
        parsed = None
    if isinstance(parsed, dict):
        err = parsed.get("error")
        if isinstance(err, dict) and err.get("message"):
            detail = err["message"]
        elif isinstance(err, str):
            detail = err
    return "The model service returned %s: %s" % (code, detail[:800])


def event_error_message(event):
    err = None
    if isinstance(event, dict):
        err = event.get("error")
        response = event.get("response")
        if err is None and isinstance(response, dict):
            err = response.get("error")
    if isinstance(err, dict) and err.get("message"):
        return err["message"]
    if isinstance(err, str) and err:
        return err
    return "The model failed."


def text_delta(event):
    if not isinstance(event, dict) or event.get("type") != "response.output_text.delta":
        return ""
    delta = event.get("delta") or ""
    if not isinstance(delta, str):
        return ""
    return delta


def events_from_lines(lines):
    for raw in lines:
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        line = raw.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        if not data:
            continue
        yield json.loads(data)


def open_stream(payload):
    key = load_key()
    if not key:
        raise RuntimeError(
            "XAI_API_KEY is not set. Add it to .env next to this project and start the relay again."
        )
    body_payload = dict(payload)
    body_payload["stream"] = True
    body = json.dumps(body_payload).encode("utf-8")
    request = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
            "User-Agent": "TigerBuild-relay/1.0",
        },
        method="POST",
    )
    try:
        return urllib.request.urlopen(request, timeout=180, context=ssl_context())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError(api_error_text(detail, exc.code))


def iter_response_events(payload):
    response = open_stream(payload)
    try:
        while True:
            raw = response.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            if not data:
                continue
            yield json.loads(data)
    finally:
        response.close()


class ToolSession(object):
    def __init__(self):
        self.config = load_shell_config()
        self.tools = None
        self.offline = ""

    def definitions(self):
        if self.tools is not None:
            return self.tools
        if not self.config.get("TIGER_HOST") or not self.config.get("TIGER_USER"):
            self.offline = "Power Mac tools are not configured."
            self.tools = []
            return self.tools
        client = McpClient(ssh_command(self.config))
        try:
            client.start()
            listed = client.request("tools/list", {})
        except Exception as exc:
            self.offline = "Power Mac tools are offline (%s)." % exc
            sys.stderr.write("tigerbuild-relay: %s\n" % self.offline)
            self.tools = []
            return self.tools
        finally:
            client.close()
        self.tools = xai_tools_from_mcp(listed)
        self.offline = ""
        return self.tools

    def _cap_command_wait(self, args):
        # A command that never prints and never exits used to block the chat
        # for the full timeout, which the model often sets to two minutes.
        capped = dict(args)
        raw = capped.get("timeout_ms")
        try:
            wait_ms = int(raw)
        except (TypeError, ValueError):
            wait_ms = 15000
        if wait_ms < 1000:
            wait_ms = 1000
        if wait_ms > 20000:
            wait_ms = 20000
        capped["timeout_ms"] = wait_ms
        return capped

    def _call_args(self, call):
        raw_args = call.get("arguments") or "{}"
        try:
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
        except ValueError:
            args = {}
        if not isinstance(args, dict):
            return {}
        return args

    def iter_turn(self, messages, use_tools=True, provider="grok", model=None, system_override=None):
        """Yield ('t', text) deltas and ('s', status) lines.

        Reasoning text from the model is never forwarded. Tool rounds use the
        completed response, not the argument deltas. use_tools is per chat.
        """
        load_env_file()
        ensure_config_file()
        if use_tools:
            tools = self.definitions()
        else:
            tools = []
        if system_override:
            system = system_override
        else:
            system = SYSTEM
        if system_override:
            use_tools = False
            tools = []
        elif not use_tools:
            system += (
                " ppc-commander is turned off for this chat. Do not claim you "
                "can read files or run commands on the Power Mac. If asked to, "
                "say those tools are off for this chat."
            )
        elif not tools:
            system += (
                " The Power Mac tools are offline right now. If asked to touch "
                "that computer, say you cannot reach it."
            )
        else:
            account = self.config.get("TIGER_USER") or "JR"
            system += (
                " The account on that Mac is %s. Home is /Users/%s and the "
                "Desktop is /Users/%s/Desktop. Do not look for other users "
                "or call tools just to discover the home directory."
            ) % (account, account, account)
        if provider == "grok":
            system = system.replace("You are an assistant", "You are Grok", 1)
        chosen = resolve_model(provider, model)
        payload = {
            "model": chosen,
            "store": True,
            "input": [{"role": "system", "content": system}] + messages,
        }
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        if provider != "grok":
            yield from self._iter_foreign(provider, messages, system, tools, chosen)
            return
        client = None
        round_index = 0
        forced = False
        last_output = ""
        try:
            while True:
                if round_index:
                    yield ("s", "Working on the next step...")
                saw_text = False
                completed = None
                for event in iter_response_events(payload):
                    etype = event.get("type") if isinstance(event, dict) else ""
                    delta = text_delta(event)
                    if delta:
                        saw_text = True
                        yield ("t", delta)
                    elif etype == "response.completed" and isinstance(event.get("response"), dict):
                        completed = event["response"]
                    elif etype in ("error", "response.failed", "response.error"):
                        raise RuntimeError(event_error_message(event))
                if not isinstance(completed, dict):
                    if saw_text:
                        return
                    raise RuntimeError("The model stream ended early.")
                if completed.get("error"):
                    raise RuntimeError(event_error_message(completed))
                calls = function_calls(completed) if tools else []
                if calls and completed.get("id") and not forced and round_index < MAX_TOOL_ROUNDS:
                    if client is None:
                        client = McpClient(ssh_command(self.config))
                        client.start()
                    outputs = []
                    for call in calls:
                        name = call.get("name") or ""
                        args = self._call_args(call)
                        if name in ("start_process", "interact_with_process"):
                            args = self._cap_command_wait(args)
                        yield ("s", tool_summary(name, args))
                        try:
                            result = client.request("tools/call", {
                                "name": name,
                                "arguments": args,
                            })
                            output = result_text(result)
                        except Exception as exc:
                            output = "error: %s" % exc
                        last_output = output
                        if round_index >= MAX_TOOL_ROUNDS - 3:
                            output += (
                                "\n\nFinish the task with the calls you have left. "
                                "Do not ask the user to type continue."
                            )
                        outputs.append({
                            "type": "function_call_output",
                            "call_id": call.get("call_id") or call.get("id"),
                            "output": output,
                        })
                    payload = {
                        "model": chosen,
                        "store": True,
                        "previous_response_id": completed.get("id"),
                        "tools": tools,
                        "tool_choice": "auto",
                        "input": outputs,
                    }
                    round_index += 1
                    continue
                if calls and completed.get("id") and not forced:
                    outputs = []
                    for call in calls:
                        outputs.append({
                            "type": "function_call_output",
                            "call_id": call.get("call_id") or call.get("id"),
                            "output": (
                                "No more tools this turn. Tell the user what "
                                "already finished. Do not ask them to type continue."
                            ),
                        })
                    payload = {
                        "model": chosen,
                        "store": True,
                        "previous_response_id": completed.get("id"),
                        "tools": tools,
                        "tool_choice": "none",
                        "input": outputs,
                    }
                    forced = True
                    continue
                if not saw_text:
                    text = ""
                    try:
                        text = extract_text(completed)
                    except RuntimeError:
                        text = ""
                    if text:
                        yield ("t", text)
                    elif last_output:
                        yield ("t", last_output)
                    elif round_index:
                        yield ("t", "Done.")
                    else:
                        raise RuntimeError("The model returned no text.")
                return
        finally:
            if client is not None:
                client.close()

    def _iter_foreign(self, provider, messages, system, tools, model):
        log = []
        for message in messages:
            log.append({"role": message["role"], "content": message["content"]})
        client = None
        round_index = 0
        last_output = ""
        try:
            while True:
                if round_index:
                    yield ("s", "Working on the next step...")
                holder = {}
                saw_text = False
                spoken = []
                for delta in stream_round(
                    provider, system, log, tools, holder, ssl_context(), api_error_text, model
                ):
                    if delta:
                        saw_text = True
                        spoken.append(delta)
                        yield ("t", delta)
                calls = holder.get("calls") or []
                if not calls or round_index >= MAX_TOOL_ROUNDS:
                    if not saw_text and last_output:
                        yield ("t", last_output)
                    elif not saw_text and not calls:
                        raise RuntimeError("The model returned no text.")
                    return
                if client is None:
                    client = McpClient(ssh_command(self.config))
                    client.start()
                log.append({
                    "role": "assistant",
                    "content": "".join(spoken),
                    "calls": calls,
                })
                for call in calls:
                    name = call.get("name") or ""
                    args = self._call_args({"arguments": call.get("arguments") or "{}"})
                    if name in ("start_process", "interact_with_process"):
                        args = self._cap_command_wait(args)
                    yield ("s", tool_summary(name, args))
                    try:
                        result = client.request("tools/call", {"name": name, "arguments": args})
                        output = result_text(result)
                    except Exception as exc:
                        output = "error: %s" % exc
                    last_output = output
                    log.append({
                        "role": "tool",
                        "id": call.get("id") or name,
                        "name": name,
                        "content": output,
                    })
                round_index += 1
        finally:
            if client is not None:
                client.close()

    def plain_complete(self, provider, model, system, messages):
        parts = []
        for kind, text in self.iter_turn(messages, False, provider, model, system):
            if kind == "t":
                parts.append(text)
        text = "".join(parts).strip()
        if not text:
            raise RuntimeError("The model returned no text.")
        return text

    def run_turn(self, messages, use_tools=True, provider="grok", model=None):
        parts = []
        statuses = []
        for kind, text in self.iter_turn(messages, use_tools, provider, model):
            if kind == "t":
                parts.append(text)
            elif kind == "s":
                statuses.append(text)
        text = "".join(parts).strip()
        if not text:
            text = "Done." if statuses else ""
            if not text:
                raise RuntimeError("The model returned no text.")
        if statuses:
            notes = "\n".join("STATUS: " + line for line in statuses)
            return notes + "\n---\n" + text
        return text


SESSION = ToolSession()


class Handler(BaseHTTPRequestHandler):
    # AquaChat on Python 2.3 reads until the connection closes. Chunked
    # encoding is not reliable there, so this response stays HTTP/1.0.
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("tigerbuild-relay: " + (fmt % args) + "\n")

    def _send(self, code, text):
        data = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _frame(self, kind, text):
        data = text.encode("utf-8")
        self.wfile.write(("%s %d\n" % (kind, len(data))).encode("ascii"))
        if data:
            self.wfile.write(data)
        self.wfile.flush()

    def _begin_stream(self):
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except Exception:
            pass
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length < 0 or length > 1000000:
            raise RuntimeError("request is too large")
        raw = self.rfile.read(length) if length else b""
        try:
            incoming = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            raise RuntimeError("request was not JSON")
        if not isinstance(incoming, dict):
            raise RuntimeError("request was not an object")
        return incoming

    def _cleaned_messages(self, incoming, require_user_end=True):
        messages = incoming.get("messages")
        if not isinstance(messages, list) or not messages:
            raise RuntimeError("messages must be a non-empty list")
        cleaned = []
        for item in messages:
            if not isinstance(item, dict):
                raise RuntimeError("each message must be an object")
            role = item.get("role")
            content = item.get("content")
            if role not in ("user", "assistant") or not isinstance(content, str):
                raise RuntimeError("messages need role user or assistant and string content")
            if content.strip() == "":
                continue
            cleaned.append({"role": role, "content": content})
        if not cleaned:
            raise RuntimeError("messages must be a non-empty list")
        if require_user_end and cleaned[-1]["role"] != "user":
            raise RuntimeError("the last message must be from the user")
        return cleaned

    def _provider_and_model(self, incoming):
        try:
            provider = normalize_provider(incoming.get("provider"))
        except RuntimeError as exc:
            raise RuntimeError(str(exc))
        requested = incoming.get("model")
        if not isinstance(requested, str):
            requested = None
        return provider, requested

    def _post_settings(self):
        load_env_file()
        ensure_config_file()
        try:
            incoming = self._read_json()
            update_settings(incoming)
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        except Exception as exc:
            self._send(502, str(exc) + "\n")
            return
        self._send(200, settings_public())

    def _post_side_task(self, path):
        try:
            incoming = self._read_json()
            cleaned = self._cleaned_messages(incoming, True)
            provider, requested = self._provider_and_model(incoming)
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        if path == "/v1/title":
            system = (
                "You name chats. Reply with a short title of at most six words. "
                "No quotes."
            )
        else:
            system = (
                "Summarize this conversation so a later reply can continue it. "
                "Keep names, decisions, file paths, and unfinished work. "
                "Write plain prose."
            )
        try:
            text = SESSION.plain_complete(provider, requested, system, cleaned)
        except Exception as exc:
            self._send(502, str(exc) + "\n")
            return
        if path == "/v1/title":
            text = clean_title(text)
        self._send(200, text)

    def do_GET(self):
        load_env_file()
        ensure_config_file()
        path, _, query = self.path.partition("?")
        if path == "/health":
            self._send(200, "ok " + MODEL + "\n")
            return
        if path == "/v1/settings":
            self._send(200, settings_public())
            return
        if path == "/v1/local-models":
            self._send(200, local_models_text())
            return
        if path == "/v1/context":
            fields = {}
            for piece in query.split("&"):
                if "=" not in piece:
                    continue
                name, value = piece.split("=", 1)
                fields[name] = value
            try:
                provider = normalize_provider(fields.get("provider"))
            except RuntimeError:
                provider = "grok"
            model = urllib.parse.unquote(fields.get("model") or "")
            self._send(200, "%s\n" % context_for(provider, model))
            return
        self._send(404, "not found\n")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/v1/settings":
            self._post_settings()
            return
        if path in ("/v1/title", "/v1/summarize"):
            self._post_side_task(path)
            return
        if path != "/v1/chat":
            self._send(404, "not found\n")
            return
        try:
            incoming = self._read_json()
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        try:
            cleaned = self._cleaned_messages(incoming, True)
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        use_tools = True
        if "tools" in incoming:
            flag = incoming.get("tools")
            if flag is False or flag == 0:
                use_tools = False
        try:
            provider = normalize_provider(incoming.get("provider"))
        except RuntimeError as exc:
            self._send(400, str(exc))
            return
        requested_model = incoming.get("model")
        if not isinstance(requested_model, str):
            requested_model = None
        streaming = self.headers.get("X-AquaChat-Protocol") == "frames"
        if not streaming:
            try:
                reply = SESSION.run_turn(cleaned, use_tools, provider, requested_model)
            except Exception as exc:
                self._send(502, str(exc))
                return
            self._send(200, reply)
            return
        self._begin_stream()
        try:
            for kind, text in SESSION.iter_turn(cleaned, use_tools, provider, requested_model):
                if kind in ("t", "s"):
                    self._frame(kind, text)
            self._frame("d", "")
        except Exception as exc:
            try:
                self._frame("e", str(exc))
                self._frame("d", "")
            except Exception:
                pass


def self_test():
    sample = {
        "output": [
            {"type": "reasoning", "summary": []},
            {
                "type": "message",
                "role": "assistant",
                "content": [{"type": "output_text", "text": "Hello from Grok."}],
            },
        ]
    }
    if extract_text(sample) != "Hello from Grok.":
        raise SystemExit("extract failed")
    calls = function_calls({
        "output": [
            {"type": "function_call", "name": "list_directory", "call_id": "c1", "arguments": "{}"},
        ]
    })
    if len(calls) != 1 or calls[0]["name"] != "list_directory":
        raise SystemExit("function call parse failed")
    lines = [
        "event: response.reasoning_summary_text.delta\n",
        '{"nope": true}\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"hidden"}\n',
        'data: {"type":"response.output_text.delta","delta":"Hello"}\n',
        'data: {"type":"response.output_text.delta","delta":" there"}\n',
        "data: [DONE]\n",
    ]
    pieces = []
    for event in events_from_lines(lines):
        delta = text_delta(event)
        if delta:
            pieces.append(delta)
    if "".join(pieces) != "Hello there":
        raise SystemExit("stream parse failed")
    if normalize_provider("Claude") != "claude" or normalize_provider("Muse") != "muse":
        raise SystemExit("provider name failed")
    if normalize_provider("Mistral") != "mistral":
        raise SystemExit("mistral name failed")
    if resolve_model("claude", "claude-fable-5-1") != "claude-fable-5-1":
        raise SystemExit("model pick failed")
    if resolve_model("grok", "grok-4.3") != "grok-4.3":
        raise SystemExit("grok model pick failed")
    if resolve_model("mistral", "codestral-latest") != "codestral-latest":
        raise SystemExit("mistral model pick failed")
    if resolve_model("chatgpt", "gpt-5.5-pro") != "gpt-5.5-pro":
        raise SystemExit("pro model was dropped")
    if resolve_model("chatgpt", "not-a-model") != "gpt-5.5":
        raise SystemExit("unknown chat model was accepted")
    if resolve_model("claude", "claude-haiku-4-5-20251001") != "claude-haiku-4-5-20251001":
        raise SystemExit("haiku model pick failed")
    if resolve_model("gemini", "../secret") != "gemini-3.8-flash":
        raise SystemExit("model allowlist failed")
    if normalize_provider("local") != "local":
        raise SystemExit("local provider name failed")
    if resolve_model("local", "qwen/qwen3.8-27b") != "qwen/qwen3.8-27b":
        raise SystemExit("local model pick failed")
    if resolve_model("local", "../secret") != "":
        raise SystemExit("local model allowlist failed")
    if clean_title('  "Four word title"  ') != "Four word title":
        raise SystemExit("title cleanup failed")
    if context_for("grok", "grok-4.7") < 1000:
        raise SystemExit("context limit missing")
    from app_config import usable_local_models
    listed = usable_local_models(
        [
            {"id": "embed-me", "type": "embeddings", "max_context_length": 2048},
            {"id": "qwen/qwen3.8-27b", "type": "vlm", "max_context_length": 262144},
        ],
        [
            {"id": "embed-me"},
            {"id": "qwen/qwen3.8-27b"},
            {"id": "text-embedding-nomic-embed-text-v1.5"},
        ],
    )
    if len(listed) != 1 or listed[0]["context"] != 262144:
        raise SystemExit("local model filter failed")
    replay = gemini_contents([
        {"role": "user", "content": "ping"},
        {
            "role": "assistant",
            "content": "",
            "calls": [{
                "id": "call_1",
                "name": "ping",
                "arguments": "{\"word\": \"pong\"}",
                "thought_signature": "sig",
            }],
        },
        {"role": "tool", "id": "call_1", "name": "ping", "content": "pong"},
    ])
    call_part = replay[1]["parts"][0]
    if call_part.get("thoughtSignature") != "sig" or call_part["functionCall"].get("id") != "call_1":
        raise SystemExit("gemini thought signature was dropped")
    if replay[2]["parts"][0]["functionResponse"].get("id") != "call_1":
        raise SystemExit("gemini tool result id was dropped")
    print("proxy self-test ok")


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        self_test()
        return
    load_env_file()
    created = ensure_config_file()
    if len(argv) > 1 and argv[1] == "--write-config":
        if created:
            print("Wrote the provider config.")
        else:
            print("Provider config already exists.")
        return
    config = load_shell_config()
    port = int(config.get("LISTEN_PORT") or "8765")
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    sys.stderr.write("tigerbuild-relay listening on 0.0.0.0:%s model %s\n" % (port, MODEL))
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
