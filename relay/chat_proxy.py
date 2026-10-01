#!/usr/bin/env python3
"""LAN relay for Tiger Build.

Mac OS X Tiger cannot speak modern HTTPS. This process accepts plain HTTP from
Tiger Build, calls the model APIs, and, when the model asks, runs
ppc-commander tools on that Mac over SSH.
"""

import json
import os
import socket
import ssl
import sys
import threading
import plistlib
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from app_config import cached_local_models
from app_config import clean_title
from app_config import context_for
from app_config import ensure_config_file
from app_config import local_models_text
from app_config import settings_public
from app_config import update_settings
from security import TOKEN_HEADER
from security import allowed_clients
from security import client_allowed
from security import listen_address
from security import relay_token
from security import token_ok
from security import token_path
from version import VERSION
from media import create_media
from media import media_dir
from media import media_tools
from media import safe_name
from providers import AnswerStream
from providers import ensure_user_first
from providers import qwen_tool_calls
from providers import gemini_contents
from providers import normalize as normalize_provider
from providers import resolve_model
from providers import stream_round
from providers import set_live
from discovery import Discovery
from discovery import pretty_title
from discovery import _transient as transient_error
from integrations import Connections, read as integrations_config
from security import support_dir
from providers import CATALOG
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
    "You are an assistant chatting inside Tiger Build on {machine} running "
    "{os}. You have ppc-commander tools that read files, "
    "edit files, and run shell commands on that Mac. Use them when "
    "the person asks about that computer or wants something done there. "
    "Do not use them for ordinary questions. "
    "Finish the task in this turn. Do not stop halfway, and do not ask the "
    "person to type continue, even if an earlier message did. Write a whole file in one call, then compile "
    "or test. Use timeout_ms of 15000, or 20000 for a compile. "
    "You may launch GUI applications when the person asks. For a GUI, or anything "
    "that should keep running, call start_process with detach set to true so it "
    "is not tied to this chat. Use open for a Mac .app. "
    "The shell is bash and the system Python is 2.3. "
    "After the tools finish, answer in a few plain sentences."
)
MAX_TOOL_ROUNDS = 12


ENV_PATH = os.path.join(ROOT, ".env")
TOKEN = ""
ALLOWED = set()


def refresh_settings():
    """Pick up edits to .env or providers.json. Runs at the start of each request."""
    return ensure_config_file(ENV_PATH)


def load_key():
    return os.environ.get("XAI_API_KEY", "").strip()


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
    text = "The model service returned %s: %s" % (code, detail[:800])
    if "anthropic-workspace-id" in detail:
        text += (" Your Anthropic key needs its workspace ID: add it in Tiger Build "
                 "Preferences under Workspace ID (optional).")
    return text


# Which providers a saved setting affects, so their model checks start over.
SETTING_PROVIDERS = {
    "xai_api_key": ("grok",),
    "openai_api_key": ("chatgpt",),
    "anthropic_api_key": ("claude",),
    "anthropic_workspace_id": ("claude",),
    "mistral_api_key": ("mistral",),
    "muse_api_key": ("muse",),
    "gemini_api_key": ("gemini",),
}


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
            "XAI_API_KEY is not set. Add it in Tiger Build Preferences or the relay .env."
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
            "User-Agent": "TigerBuild-relay/%s" % VERSION,
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


PROBE_SYSTEM = "This is a connection check. Reply with the single word ok."
PROBE_TOOL = {
    "type": "function",
    "name": "ping",
    "description": "Connection check. Do not call it.",
    "parameters": {
        "type": "object",
        "properties": {"word": {"type": "string", "description": "Any word."}},
    },
}
DISCOVERY = None


def probe_model(provider, model, endpoint=None):
    """Raise unless this model streams a reply to a request that includes a
    tool, through the same code a Tiger Build chat uses. The stream is closed
    as soon as the model starts answering, so a check costs a few tokens."""
    log = [{"role": "user", "content": "ping"}]
    if provider == "grok":
        payload = {
            "model": model,
            "store": False,
            "input": [{"role": "system", "content": PROBE_SYSTEM}] + log,
            "tools": [PROBE_TOOL],
            "tool_choice": "auto",
        }
        events = iter_response_events(payload)
        try:
            for event in events:
                etype = event.get("type") if isinstance(event, dict) else ""
                if etype in ("error", "response.failed", "response.error"):
                    raise RuntimeError(event_error_message(event))
                item = event.get("item") if isinstance(event, dict) else None
                if text_delta(event) or etype == "response.completed" or (
                    isinstance(item, dict) and item.get("type") == "function_call"
                ):
                    return
        finally:
            events.close()
        raise RuntimeError("The model stream ended early.")
    stream = stream_round(
        provider, PROBE_SYSTEM, log, [PROBE_TOOL], {}, ssl_context(), api_error_text,
        model=model, endpoint=endpoint, probing=True,
    )
    try:
        for _piece in stream:
            return
    finally:
        stream.close()


def start_discovery(run=True):
    global DISCOVERY
    if DISCOVERY is None:
        DISCOVERY = Discovery(
            os.path.join(support_dir(), "models-cache.json"),
            probe_model, ssl_context, refresh_settings,
        )
        set_live(DISCOVERY.allowed, DISCOVERY.default, DISCOVERY.endpoint, DISCOVERY.info)
    if run:
        DISCOVERY.start()
    return DISCOVERY


_TOOL_CACHE = {"tools": None, "at": 0.0, "offline": ""}
_TOOL_LOCK = threading.Lock()
TOOL_CACHE_SECONDS = 300
OFFLINE_RETRY_SECONDS = 15


class ToolSession(object):
    """State for one request. Every HTTP request gets its own instance.

    The tool list is shared between requests. A good list is kept for five
    minutes. An offline result is retried after 15 seconds, so a Tiger Mac
    that was asleep at the first request does not stay offline until restart.
    """

    def __init__(self):
        self.config = load_shell_config()
        self.tools = None
        self.offline = ""
        self.extra = Connections()
        self.client = {}

    def set_client(self, info):
        """What Tiger Build reports about the Mac it runs on. Plain short
        strings only; anything else is ignored."""
        clean = {}
        if isinstance(info, dict):
            for key in ("machine", "os", "user", "home"):
                value = info.get(key)
                if isinstance(value, str):
                    value = " ".join(value.split())[:160]
                    if value:
                        clean[key] = value
        self.client = clean
        return clean

    def machine(self):
        return self.client.get("machine") or "a PowerPC Mac"

    def os_name(self):
        return self.client.get("os") or "Mac OS X Tiger"

    def account(self):
        return (self.config.get("TIGER_USER") or "").strip()

    def home(self):
        home = (self.config.get("TIGER_HOME") or "").strip()
        # Tools run as TIGER_USER over SSH. When Tiger Build runs as that
        # same account, the home folder it reports is the right one.
        reported = self.client.get("home") or ""
        if not home and reported.startswith("/") and self.client.get("user") == self.account():
            home = reported
        if home:
            return home.rstrip("/")
        if self.account():
            return "/Users/%s" % self.account()
        return "~"

    def media_root(self):
        return self.home() + "/Library/Application Support/Tiger Build/media"

    def definitions(self):
        if self.tools is not None:
            return self.tools
        if not self.config.get("TIGER_HOST") or not self.account():
            self.offline = "Tiger Mac tools are not configured. Set TIGER_HOST and TIGER_USER in config.sh."
            self.tools = []
            return self.tools
        with _TOOL_LOCK:
            cached = _TOOL_CACHE["tools"]
            age = time.time() - _TOOL_CACHE["at"]
            if cached is not None:
                keep = TOOL_CACHE_SECONDS if cached else OFFLINE_RETRY_SECONDS
                if age < keep:
                    self.tools = cached
                    self.offline = _TOOL_CACHE["offline"]
                    return self.tools
        client = McpClient(ssh_command(self.config))
        try:
            client.start()
            tools = xai_tools_from_mcp(client.request("tools/list", {}, timeout=30))
            offline = ""
        except Exception as exc:
            tools = []
            offline = "Tiger Mac tools are offline (%s)." % exc
            sys.stderr.write("tigerbuild-relay: %s\n" % offline)
        finally:
            client.close()
        with _TOOL_LOCK:
            _TOOL_CACHE["tools"] = tools
            _TOOL_CACHE["at"] = time.time()
            _TOOL_CACHE["offline"] = offline
        self.tools = tools
        self.offline = offline
        return tools

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

    def _stopped_early(self, output, exc):
        detail = (output or "").strip()
        if not detail and exc is not None:
            detail = str(exc).strip()
        if len(detail) > 600:
            detail = detail[:600] + "..."
        if not detail:
            return "\n\nI couldn't finish after that step."
        return "\n\nThe last command stopped with an error:\n" + detail

    def _saved_media_text(self, kind, filename):
        path = "%s/%s" % (self.media_root(), filename)
        if kind == "video":
            return "Saved the video on the Tiger Mac at %s." % path
        return "Saved the image on the Tiger Mac at %s." % path

    def _media_status(self, name):
        if name == "generate_image":
            return "Generating an image..."
        if name == "generate_video":
            return "Generating a video. This can take a minute..."
        return ""

    def _tool_event(self, call, phase, output="", failed=False, elapsed=0):
        args = self._call_args(call)
        name = call.get("name") or "tool"
        detail = args.get("command") or args.get("input") or args.get("query") or json.dumps(args,ensure_ascii=False)
        return plistlib.dumps({"id":call.get("id") or call.get("call_id") or name,"name":name,"phase":phase,
            "detail":str(detail)[:20000],"output":str(output)[:100000],
            "failed":bool(failed),"elapsed":float(elapsed)},fmt=plistlib.FMT_XML).decode()

    def _run_one_call(self, provider, call, client_holder):
        name = call.get("name") or ""
        args = self._call_args({"arguments": call.get("arguments") or "{}"})
        if not args and isinstance(call.get("arguments"), dict):
            args = call.get("arguments")
        if name in ("start_process", "interact_with_process"):
            args = self._cap_command_wait(args)
        if name == "generate_image":
            try:
                info = create_media(provider, name, args.get("prompt") or "", ssl_context())
            except Exception as exc:
                return "Generating an image...", "error: %s" % exc, None, True
            return (
                "Generating an image...",
                self._saved_media_text("image", info["filename"]),
                "image %s" % info["filename"],
                False,
            )
        if name == "generate_video":
            try:
                info = create_media(provider, name, args.get("prompt") or "", ssl_context())
            except Exception as exc:
                return "Generating a video. This can take a minute...", "error: %s" % exc, None, True
            return (
                "Generating a video. This can take a minute...",
                self._saved_media_text("video", info["filename"]),
                "video %s" % info["filename"],
                False,
            )
        if self.extra.handles(name):
            try:
                return "Running " + name, self.extra.call(name, args), None, False
            except Exception as exc:
                return "Running " + name, "error: %s" % exc, None, True
        if not self.extra.config['ppc_enabled']:
            return "PPC Commander disabled", "error: PPC Commander is disabled in relay tool configuration.", None, True
        if client_holder[0] is None:
            client_holder[0] = McpClient(ssh_command(self.config))
            client_holder[0].start()
        try:
            result = client_holder[0].request("tools/call", {"name": name, "arguments": args})
            output = result_text(result)
            failed = bool(isinstance(result, dict) and result.get("isError"))
        except Exception as exc:
            output = "error: %s" % exc
            failed = True
        return tool_summary(name, args), output, None, failed

    def iter_turn(self, messages, use_tools=True, provider="grok", model=None, system_override=None):
        """Yield ('t', text) deltas and ('s', status) lines.

        Reasoning text from the model is never forwarded. Tool rounds use the
        completed response, not the argument deltas. use_tools is per chat.
        """
        refresh_settings()
        if use_tools:
            tools = self.definitions() if self.extra.config['ppc_enabled'] else []
            tools = list(tools) + self.extra.definitions(provider)
        else:
            tools = []
        if system_override:
            system = system_override
        else:
            system = SYSTEM.replace("{machine}", self.machine()).replace("{os}", self.os_name())
        if system_override:
            use_tools = False
            tools = []
        else:
            extra = media_tools(provider)
            if extra:
                tools = list(tools) + extra
                media_root = self.media_root()
                system += (
                    " If the person asks for a picture, call generate_image. "
                    "If they ask for a video or animation, call generate_video. "
                    "Do not say a file was created unless that tool saved one. "
                    "Saved pictures and videos are files in %s on the Tiger Mac. "
                    "If the person asks to put one somewhere else, copy that file "
                    "with the shell. Do not invent a path."
                ) % media_root
        if system_override:
            pass
        elif not use_tools:
            system += (
                " ppc-commander is turned off for this chat. Do not claim you "
                "can read files or run commands on the Tiger Mac. If asked to, "
                "say those tools are off for this chat."
            )
        elif not tools:
            system += (
                " The Tiger Mac tools are offline right now. If asked to touch "
                "that computer, say you cannot reach it."
            )
        else:
            system += (
                " The account on that Mac is %s. Home is %s and the "
                "Desktop is %s/Desktop. Do not look for other users "
                "or call tools just to discover the home directory."
            ) % (self.account(), self.home(), self.home())
        if not self.extra.config['ppc_enabled']:
            system += " Built-in PPC Commander is disabled in the relay configuration. Only the other advertised tools may be used."
        if self.extra.errors:
            sys.stderr.write("tigerbuild-relay: custom MCP connection failures: %s\n" % "; ".join(self.extra.errors))
        if provider == "grok":
            system = system.replace("You are an assistant", "You are Grok", 1)
        chosen = resolve_model(provider, model)
        payload = {
            "model": chosen,
            "store": True,
            "input": [{"role": "system", "content": system}] + messages,
        }
        if provider == "grok" and not system_override and self.extra.config['grok_native_search']:
            tools = list(tools) + [{"type": "web_search"}]
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        if provider != "grok":
            try:
                yield from self._iter_foreign(provider, messages, system, tools, chosen)
            finally:
                self.extra.close()
            return
        client = None
        round_index = 0
        forced = False
        last_output = ""
        last_failed = False
        try:
            while True:
                if round_index:
                    yield ("s", "Working on the next step...")
                saw_text = False
                completed = None
                try:
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
                except Exception as exc:
                    if saw_text or last_output:
                        yield ("t", self._stopped_early(last_output if last_failed else "", exc))
                        return
                    raise
                if not isinstance(completed, dict):
                    if saw_text:
                        return
                    if last_failed:
                        yield ("t", self._stopped_early(last_output, None))
                        return
                    raise RuntimeError("The model stream ended early.")
                if completed.get("error"):
                    raise RuntimeError(event_error_message(completed))
                calls = function_calls(completed) if tools else []
                if calls and completed.get("id") and not forced and round_index < MAX_TOOL_ROUNDS:
                    client_holder = [client]
                    outputs = []
                    for call in calls:
                        announced = self._media_status(call.get("name") or "")
                        if announced:
                            yield ("s", announced)
                        yield ("a", self._tool_event(call,"start"))
                        started = time.monotonic()
                        summary, output, media, failed = self._run_one_call(
                            provider, call, client_holder
                        )
                        yield ("a", self._tool_event(call,"result",output,failed,time.monotonic()-started))
                        client = client_holder[0]
                        # Activity card already contains this tool summary.
                        if media:
                            yield ("m", media)
                        last_output = output
                        last_failed = failed
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
                    elif last_failed:
                        yield ("t", self._stopped_early(last_output, None))
                    elif last_output:
                        yield ("t", last_output)
                    elif round_index:
                        yield ("t", "Done.")
                    else:
                        raise RuntimeError("The model returned no text.")
                return
        finally:
            self.extra.close()
            if client is not None:
                client.close()

    def _iter_foreign(self, provider, messages, system, tools, model):
        log = []
        for message in messages:
            log.append({"role": message["role"], "content": message["content"]})
        client_holder = [None]
        round_index = 0
        last_output = ""
        last_failed = False
        any_text = False
        try:
            while True:
                if round_index:
                    yield ("s", "Working on the next step...")
                holder = {}
                saw_text = False
                spoken = []
                try:
                    for delta in stream_round(
                        provider, system, log, tools, holder, ssl_context(), api_error_text, model
                    ):
                        if isinstance(delta, dict) and "thinking" in delta:
                            yield ("h", delta["thinking"])
                            continue
                        if delta:
                            saw_text = True
                            any_text = True
                            spoken.append(delta)
                            yield ("t", delta)
                except Exception as exc:
                    if any_text or last_output:
                        yield ("t", self._stopped_early(last_output if last_failed else "", exc))
                        return
                    raise
                calls = holder.get("calls") or []
                if not calls or round_index >= MAX_TOOL_ROUNDS:
                    if not saw_text and last_failed:
                        yield ("t", self._stopped_early(last_output, None))
                    elif not saw_text and last_output and not any_text:
                        yield ("t", last_output)
                    elif not saw_text and not calls and not any_text and not round_index:
                        raise RuntimeError("The model returned no text.")
                    elif not saw_text and round_index and not any_text:
                        yield ("t", "Done.")
                    return
                log.append({
                    "role": "assistant",
                    "content": "".join(spoken),
                    "calls": calls,
                    "claude_blocks": holder.get("claude_blocks"),
                })
                for call in calls:
                    announced = self._media_status(call.get("name") or "")
                    if announced:
                        yield ("s", announced)
                    yield ("a", self._tool_event(call,"start"))
                    started = time.monotonic()
                    summary, output, media, failed = self._run_one_call(
                        provider, call, client_holder
                    )
                    yield ("a", self._tool_event(call,"result",output,failed,time.monotonic()-started))
                    # Activity card already contains this tool summary.
                    if media:
                        yield ("m", media)
                    last_output = output
                    last_failed = failed
                    log.append({
                        "role": "tool",
                        "id": call.get("id") or call.get("name") or "",
                        "name": call.get("name") or "",
                        "content": output,
                    })
                round_index += 1
        finally:
            if client_holder[0] is not None:
                client_holder[0].close()

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



_LAST_SEEN = {"at": 0.0}


def note_client(address, info=None):
    """Keep a small, secret-free record of the last client for the relay app."""
    now = time.time()
    record = {}
    path = os.path.join(support_dir(), "last-client.json")
    try:
        with open(path) as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        record = {}
    changed = record.get("address") != address or bool(info)
    if not changed and now - _LAST_SEEN["at"] < 30:
        return
    record["address"] = address
    record["seen"] = now
    for key in ("machine", "os", "user"):
        if info and info.get(key):
            record[key] = info[key]
    _LAST_SEEN["at"] = now
    temporary = path + ".tmp"
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(record, handle)
        os.replace(temporary, path)
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    # Tiger's CFNetwork reads until the
    # connection closes. Chunked encoding is not reliable there, so HTTP/1.0.
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

    def _authorized(self, need_token=True):
        """Only the Tiger Mac (and this Mac) may connect, and only with the token."""
        address = self.client_address[0] if self.client_address else ""
        if not client_allowed(address, ALLOWED):
            self._send(403, "This address may not use the relay.\n")
            return False
        if need_token and not token_ok(self.headers.get(TOKEN_HEADER), TOKEN):
            self._send(401, "The relay token is missing or wrong. Set it in Tiger Build Preferences.\n")
            return False
        if need_token and address not in ("127.0.0.1", "::1"):
            note_client(address)
        return True

    def _health(self):
        """Report whether the relay can actually do its job."""
        refresh_settings()
        problems = []
        keyed = []
        for provider, env_name in (
            ("grok", "XAI_API_KEY"), ("chatgpt", "OPENAI_API_KEY"),
            ("claude", "ANTHROPIC_API_KEY"), ("mistral", "MISTRAL_API_KEY"),
            ("muse", "MUSE_API_KEY"), ("gemini", "GEMINI_API_KEY"),
        ):
            if os.environ.get(env_name, "").strip():
                keyed.append(provider)
        local_line = "none"
        try:
            local_count = len(cached_local_models())
        except Exception:
            local_count = 0
        if local_count:
            local_line = "%d models" % local_count
        if not keyed and not local_count:
            # One key is enough, and so is a local server with no keys at all.
            problems.append("no provider API keys are set and the local server has no models")
        session = ToolSession()
        tools = session.definitions()
        if tools:
            tool_line = "online (%d tools)" % len(tools)
        else:
            tool_line = session.offline or "offline"
            problems.append("Tiger Mac tools are offline")
        models_line = DISCOVERY.summary() if DISCOVERY else "not loaded"
        lines = [
            ("ok " if not problems else "degraded ") + MODEL,
            "version: %s" % VERSION,
            "providers with keys: %s" % (", ".join(keyed) or "none"),
            "working models: %s" % models_line,
            "local server: %s" % local_line,
            "tiger mac tools: %s" % tool_line,
        ]
        if problems:
            lines.append("problems: %s" % "; ".join(problems))
        self._send(200 if not problems else 503, "\n".join(lines) + "\n")

    def _post_settings(self):
        refresh_settings()
        try:
            incoming = self._read_json()
            update_settings(incoming)
            if incoming.get("clear_all") is True:
                from integrations import write as reset_integrations
                reset_integrations({})
            if DISCOVERY and isinstance(incoming, dict):
                # A changed key means a new model list, and old checks no
                # longer say anything, so those providers start over.
                touched = set(SETTING_PROVIDERS[name][0] for name in SETTING_PROVIDERS) if incoming.get("clear_all") is True else set()
                for name in list(incoming.keys()) + list(incoming.get("clear") or []):
                    if name in SETTING_PROVIDERS and (name != "clear"):
                        value = incoming.get(name)
                        if name in (incoming.get("clear") or []) or (isinstance(value, str) and value.strip()):
                            touched.update(SETTING_PROVIDERS[name])
                DISCOVERY.poke(sorted(touched))
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        except Exception as exc:
            self._send(502, str(exc) + "\n")
            return
        self._send(200, settings_public())

    def _history_upload(self):
        # A single, owner-private snapshot. No caller-supplied paths.
        from history_store import save_snapshot
        try:
            size = int(self.headers.get("Content-Length") or "0")
            if size < 1 or size > 16 * 1024 * 1024:
                raise ValueError("History must be between 1 byte and 16 MB.")
            self.connection.settimeout(30)
            payload = self.rfile.read(size)
            if len(payload) != size:
                raise ValueError("Incomplete history upload.")
            save_snapshot(payload)
        except (ValueError, OSError) as exc:
            self._send(400, str(exc) + "\n")
            return
        self._send(200, "History copied to relay host.\n")

    def _history_download(self):
        from history_store import read_snapshot
        try:
            payload = read_snapshot()
        except OSError:
            self._send(404, "No history snapshot on this relay yet. Export to Relay Host first.\n")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-plist")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

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
            text = ToolSession().plain_complete(provider, requested, system, cleaned)
        except Exception as exc:
            self._send(502, str(exc) + "\n")
            return
        if path == "/v1/title":
            text = clean_title(text)
        self._send(200, text)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/health":
            # Allowed addresses only; no token so a plain curl can check it.
            if self._authorized(need_token=False):
                self._health()
            return
        if not self._authorized():
            return
        refresh_settings()
        if path in ("/v1/integrations", "/v1/config-export"):
            import plistlib
            from integrations import public
            from config_backup import export
            payload = export() if path == "/v1/config-export" else plistlib.dumps(public(), fmt=plistlib.FMT_XML)
            self.send_response(200)
            self.send_header("Content-Type", "application/x-plist")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers(); self.wfile.write(payload)
            return
        if path == "/v1/history":
            self._history_download()
            return
        if path == "/v1/models":
            self._send(200, start_discovery(False).models_text())
            return
        if path.startswith("/v1/media/"):
            name = safe_name(path[len("/v1/media/"):])
            folder = os.path.realpath(media_dir())
            file_path = os.path.realpath(os.path.join(folder, name)) if name else ""
            if (
                not name
                or not file_path.startswith(folder + os.sep)
                or not os.path.isfile(file_path)
            ):
                self._send(404, "not found\n")
                return
            handle = open(file_path, "rb")
            try:
                payload = handle.read()
            finally:
                handle.close()
            kind = "image/jpeg"
            if name.endswith(".png"):
                kind = "image/png"
            elif name.endswith(".mp4"):
                kind = "video/mp4"
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
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
            live = DISCOVERY.context(provider, model) if DISCOVERY else 0
            self._send(200, "%s\n" % (live or context_for(provider, model)))
            return
        self._send(404, "not found\n")

    def do_POST(self):
        if not self._authorized():
            return
        path = self.path.split("?", 1)[0]
        if path in ("/v1/integrations", "/v1/config-import"):
            import plistlib
            from integrations import write as write_integrations
            from config_backup import restore
            try:
                size = int(self.headers.get("Content-Length") or "0")
                if size < 1 or size > 2 * 1024 * 1024: raise ValueError("Configuration limit is 2 MB.")
                self.connection.settimeout(30)
                data = self.rfile.read(size)
                if len(data) != size: raise ValueError("Incomplete configuration upload.")
                if path == "/v1/integrations":
                    write_integrations(plistlib.loads(data), preserve_key=True)
                else:
                    # Client imports keep the running relay's address/token/SSH
                    # connection intact, so remote imports cannot lock it out.
                    restore(data, connection=False)
                    if DISCOVERY: DISCOVERY.poke(["grok","chatgpt","claude","mistral","muse","gemini"])
                self._send(200, "Configuration saved. Imported custom MCP servers stay disabled until enabled.\n")
            except Exception as exc:
                self._send(400, str(exc) + "\n")
            return
        if path == "/v1/history":
            self._history_upload()
            return
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
        streaming = self.headers.get("X-TigerBuild-Protocol") == "frames"
        session = ToolSession()
        reported = session.set_client(incoming.get("client"))
        if reported:
            note_client(self.client_address[0] if self.client_address else "", reported)
        if not streaming:
            try:
                reply = session.run_turn(cleaned, use_tools, provider, requested_model)
            except Exception as exc:
                self._send(502, str(exc))
                return
            self._send(200, reply)
            return
        self._begin_stream()
        try:
            for kind, text in session.iter_turn(cleaned, use_tools, provider, requested_model):
                if kind in ("t", "s", "m", "a", "h"):
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
    hidden = AnswerStream()
    pieces = []
    pieces.extend(hidden.add_content("Hello <think>secret"))
    pieces.extend(hidden.add_content(" thought</think> there"))
    if "".join(pieces) != "Hello  there" or hidden.finish():
        raise SystemExit("think tags leaked")
    quiet = AnswerStream()
    quiet.add_reasoning("The answer is pong.")
    if quiet.finish() != "The answer is pong.":
        raise SystemExit("reasoning fallback failed")
    wrapped = AnswerStream()
    wrapped.add_reasoning("<think>scratch</think>The answer is pong.")
    if wrapped.finish() != "The answer is pong.":
        raise SystemExit("reasoning think tags leaked")
    only = AnswerStream()
    if only.add_content("<think>secret answer</think>") or only.finish() != "secret answer":
        raise SystemExit("think-only answer was dropped")
    if media_tools("claude") or media_tools("mistral") or media_tools("local"):
        raise SystemExit("media tools were offered to a provider without them")
    if len(media_tools("grok")) != 2 or len(media_tools("muse")) != 1:
        raise SystemExit("media tool list failed")
    if safe_name("../x") or safe_name("a/b") or safe_name("ok.png") != "ok.png":
        raise SystemExit("media name check failed")
    grounded = ensure_user_first([
        {"role": "assistant", "content": "Hello. Ask me anything."},
        {"role": "user", "content": "ping"},
    ])
    if grounded[0].get("role") != "user" or grounded[2].get("content") != "ping":
        raise SystemExit("local transcript was not grounded")
    if ensure_user_first([{"role": "user", "content": "ping"}])[0]["content"] != "ping":
        raise SystemExit("user transcript was rewritten")
    marked = AnswerStream()
    shown = marked.add_content(
        "Sure.\n<tool_call>\n<function=list_directory>\n<parameter=path>\n/Users/example/Desktop\n</parameter>\n</function>\n</tool_call>"
    )
    if "".join(shown).strip() != "Sure.":
        raise SystemExit("tool markup was shown")
    parsed = qwen_tool_calls("\n".join(marked.tool_markup))
    if len(parsed) != 1 or parsed[0]["name"] != "list_directory":
        raise SystemExit("qwen tool call was not parsed")
    if json.loads(parsed[0]["arguments"]).get("path") != "/Users/example/Desktop":
        raise SystemExit("qwen tool arguments were not parsed")
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
    discovery_self_test()
    print("proxy self-test ok")


def discovery_self_test():
    import tempfile
    if pretty_title("chatgpt", "gpt-7-mini") != "7 Mini" or pretty_title("mistral", "mistral-large-latest") != "Mistral Large":
        raise SystemExit("model title failed")
    if not transient_error("The model service returned 429: slow down") or transient_error("The model service returned 404: no such model"):
        raise SystemExit("transient error check failed")
    folder = tempfile.mkdtemp()
    calls = []

    def fake_probe(provider, model, endpoint=None):
        calls.append((provider, model, endpoint))
        if model == "gpt-broken":
            raise RuntimeError("The model service returned 400: tools are not supported")
        if model == "gpt-busy":
            raise RuntimeError("The model service returned 429: rate limit")
        if model == "gpt-9-pro" and endpoint != "responses":
            raise RuntimeError("The model service returned 404: use the Responses API")

    found = Discovery(os.path.join(folder, "cache.json"), fake_probe, lambda: None)
    old_key = os.environ.get("OPENAI_API_KEY")
    os.environ["OPENAI_API_KEY"] = "test"
    try:
        found.listed["chatgpt"] = {"at": time.time(), "error": "", "models": [
            {"id": "gpt-5.5", "created": 1}, {"id": "gpt-9", "created": 9},
            {"id": "gpt-9-pro", "created": 8}, {"id": "gpt-broken", "created": 7},
            {"id": "gpt-busy", "created": 6},
        ]}
        ids = [m["id"] for m in found.usable("chatgpt")]
        if ids != ["gpt-5.5"]:
            raise SystemExit("unchecked new models were shown: %s" % ids)
        for model in ("gpt-5.5", "gpt-9", "gpt-9-pro", "gpt-broken", "gpt-busy"):
            found._check("chatgpt", model)
        ids = [m["id"] for m in found.usable("chatgpt")]
        if ids != ["gpt-9", "gpt-9-pro", "gpt-5.5"]:
            raise SystemExit("model check filter failed: %s" % ids)
        if found.endpoint("chatgpt", "gpt-9-pro") != "responses":
            raise SystemExit("responses endpoint was not remembered")
        if found.allowed("chatgpt", "../x") or not found.allowed("chatgpt", "gpt-9"):
            raise SystemExit("live allowlist failed")
        if "model\tchatgpt\tgpt-9\t9\t0\t0" not in found.models_text():
            raise SystemExit("models text failed: %r" % found.models_text())
        found.save()
        again = Discovery(os.path.join(folder, "cache.json"), fake_probe, lambda: None)
        if [m["id"] for m in again.usable("chatgpt")] != ids:
            raise SystemExit("model cache did not reload")
    finally:
        if old_key is None:
            os.environ.pop("OPENAI_API_KEY", None)
        else:
            os.environ["OPENAI_API_KEY"] = old_key
        found.pool.shutdown(wait=False)


def main(argv):
    global TOKEN, ALLOWED
    if len(argv) > 1 and argv[1] == "--self-test":
        self_test()
        return
    created = refresh_settings()
    if len(argv) > 1 and argv[1] == "--models-text":
        # The list as of the last checks, for the copy built into the app.
        sys.stdout.write(start_discovery(False).models_text())
        return
    config = load_shell_config()
    if len(argv) > 1 and argv[1] == "--write-config":
        if created:
            print("Wrote the provider config.")
        else:
            print("Provider config already exists.")
        return
    TOKEN = relay_token(config)
    if len(argv) > 1 and argv[1] == "--print-token":
        print(TOKEN)
        return
    ALLOWED = allowed_clients(config)
    port = int(config.get("LISTEN_PORT") or "8765")
    address = listen_address(config)
    if len(argv) > 1 and argv[1] == "--print-address":
        print(address)
        return
    start_discovery(True)
    if address not in ("0.0.0.0", "::"):
        # Let this Mac check its own relay on the address it listens on.
        ALLOWED.add(address)
    server = ThreadingHTTPServer((address, port), Handler)
    server.daemon_threads = True
    from paths import support_dir as _support
    pid_path = os.path.join(_support(), "relay.pid")
    handle = open(pid_path, "w")
    try:
        handle.write("%d\n" % os.getpid())
    finally:
        handle.close()
    sys.stderr.write(
        "tigerbuild-relay listening on %s:%s model %s; clients %s; token in %s\n"
        % (address, port, MODEL, ", ".join(sorted(ALLOWED)), token_path())
    )
    try:
        server.serve_forever()
    finally:
        try:
            if open(pid_path).read().strip() == str(os.getpid()):
                os.remove(pid_path)
        except OSError:
            pass


if __name__ == "__main__":
    main(sys.argv)
