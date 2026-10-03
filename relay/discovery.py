"""Live model lists for each provider, checked against this relay's call path.

At start, and every six hours, the relay asks each provider that has a key
for its model list. Models that cannot chat (images, audio, embeddings...)
are dropped by name or by the provider's own capability flags. Every
remaining model then gets one tiny streaming call that includes a tool,
sent through exactly the code Tiger Build chats use. Only models that pass
are offered to Tiger Build. Results are kept in models-cache.json so a
restart does not repeat the checks: a passing model is checked again after
a week, a failing one after two days, and a rate-limited one after an hour.

The static CATALOG in providers.py is the fallback: those models are shown
while their first check is still running, and used when a provider's model
list cannot be fetched at all.
"""

import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import providers as P

LIST_EVERY = 6 * 3600
RECHECK_OK = 7 * 86400
RECHECK_FAIL = 2 * 86400
RECHECK_TRANSIENT = 3600
MAX_PROBES_AT_ONCE = 3
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,120}$")
TRANSIENT_CODES = ("408", "409", "425", "429", "500", "502", "503", "504", "529")

KEY_ENV = {
    "grok": ("XAI_API_KEY",),
    "chatgpt": ("OPENAI_API_KEY",),
    "claude": ("ANTHROPIC_API_KEY",),
    "mistral": ("MISTRAL_API_KEY",),
    "muse": ("MUSE_API_KEY", "MODEL_API_KEY"),
    "gemini": ("GEMINI_API_KEY", "GOOGLE_API_KEY"),
}

# Names that are never chat models, whatever the provider says.
NOT_CHAT = re.compile(
    r"(embed|image|imagine|imagen|video|veo|vision-only|tts|audio|speech|"
    r"transcribe|whisper|realtime|moderation|dall-e|davinci|babbage|"
    r"search|aqa|live|lyria|robotics|computer-use|deep-research|ocr)",
    re.I,
)


def has_key(provider):
    for name in KEY_ENV.get(provider, ()):
        if os.environ.get(name, "").strip():
            return True
    return False


def _key(provider):
    for name in KEY_ENV.get(provider, ()):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return ""


def _get_json(url, headers, ssl_context, timeout=30):
    merged = {"User-Agent": "TigerBuild-relay/1.4"}
    merged.update(headers)
    request = urllib.request.Request(url, headers=merged)
    try:
        response = urllib.request.urlopen(request, timeout=timeout, context=ssl_context)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise RuntimeError("model list returned %s: %s" % (exc.code, detail))
    try:
        return json.loads(response.read().decode("utf-8", "replace"))
    finally:
        response.close()


def _iso_time(text):
    try:
        return time.mktime(time.strptime((text or "")[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return 0


def pretty_title(provider, model):
    """A short menu title for a model the static catalog does not know."""
    name = model
    for prefix in ("grok-", "gpt-", "claude-", "gemini-", "muse-"):
        if provider != "mistral" and name.startswith(prefix):
            name = name[len(prefix):]
            break
    if name.endswith("-latest"):
        name = name[: -len("-latest")]
    words = []
    for word in name.replace("_", "-").split("-"):
        if not word:
            continue
        if re.match(r"^\d", word) or re.match(r"^o\d", word):
            words.append(word)
        else:
            words.append(word[:1].upper() + word[1:])
    return " ".join(words) or model


# Each lister returns [{"id", "title", "context", "created"}] of chat
# candidates. Titles and contexts are optional; blanks are filled later.

def list_grok(ssl_context):
    data = _get_json("https://api.x.ai/v1/models",
                     {"Authorization": "Bearer " + _key("grok")}, ssl_context)
    found = []
    for item in data.get("data") or []:
        mid = item.get("id") or ""
        if mid.startswith("grok") and not NOT_CHAT.search(mid):
            found.append({"id": mid, "created": item.get("created") or 0})
    return found


def list_chatgpt(ssl_context):
    data = _get_json("https://api.openai.com/v1/models",
                     {"Authorization": "Bearer " + _key("chatgpt")}, ssl_context)
    found = []
    for item in data.get("data") or []:
        mid = item.get("id") or ""
        if not re.match(r"^(gpt-|o\d|chat-latest)", mid):
            continue
        if NOT_CHAT.search(mid) or "instruct" in mid:
            continue
        # Dated snapshots duplicate their alias: gpt-4o-2024-08-06, gpt-4-0613.
        if re.search(r"-\d{4}-\d{2}-\d{2}$", mid) or re.search(r"-\d{4}$", mid):
            continue
        found.append({"id": mid, "created": item.get("created") or 0})
    return found


def _claude_thinking_type(capabilities):
    """"adaptive", "enabled", or "" from the Models API capability list."""
    thinking = (capabilities or {}).get("thinking") if isinstance(capabilities, dict) else None
    if not isinstance(thinking, dict) or not thinking.get("supported"):
        return ""
    types = thinking.get("types") or {}
    for name in ("adaptive", "enabled"):
        if isinstance(types.get(name), dict) and types[name].get("supported"):
            return name
    return ""


def list_claude(ssl_context):
    headers = {"x-api-key": _key("claude"), "anthropic-version": "2023-06-01"}
    workspace = os.environ.get("ANTHROPIC_WORKSPACE_ID", "").strip()
    if workspace:
        headers["anthropic-workspace-id"] = workspace
    found = []
    after = ""
    for _page in range(10):
        url = "https://api.anthropic.com/v1/models?limit=100"
        if after:
            url += "&after_id=" + after
        data = _get_json(url, headers, ssl_context)
        for item in data.get("data") or []:
            mid = item.get("id") or ""
            if not mid:
                continue
            title = (item.get("display_name") or "").strip()
            if title.startswith("Claude "):
                title = title[len("Claude "):]
            found.append({
                "id": mid,
                "title": title,
                "created": _iso_time(item.get("created_at")),
                "context": int(item.get("max_input_tokens") or 0),
                "max_output": int(item.get("max_tokens") or 0),
                "thinking": _claude_thinking_type(item.get("capabilities")),
            })
        if not data.get("has_more"):
            break
        after = data.get("last_id") or ""
        if not after:
            break
    return found


def list_mistral(ssl_context):
    data = _get_json("https://api.mistral.ai/v1/models",
                     {"Authorization": "Bearer " + _key("mistral")}, ssl_context)
    entries = []
    listed = set()
    for item in data.get("data") or []:
        mid = item.get("id") or ""
        caps = item.get("capabilities") or {}
        if not mid or not caps.get("completion_chat") or not caps.get("function_calling"):
            continue
        if item.get("deprecation") or item.get("archived"):
            continue
        if NOT_CHAT.search(mid):
            continue
        entries.append(item)
        listed.add(mid)
    found = []
    for item in entries:
        mid = item["id"]
        aliases = item.get("aliases") or []
        # Keep "mistral-large-latest" and drop "mistral-large-2411" beside it.
        if not mid.endswith("-latest") and any(
            alias.endswith("-latest") and alias in listed for alias in aliases
        ):
            continue
        found.append({
            "id": mid,
            "created": item.get("created") or 0,
            "context": int(item.get("max_context_length") or 0),
        })
    return found


def list_gemini(ssl_context):
    found = []
    token = ""
    for _page in range(10):
        url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
        if token:
            url += "&pageToken=" + token
        data = _get_json(url, {"x-goog-api-key": _key("gemini")}, ssl_context)
        for item in data.get("models") or []:
            mid = (item.get("name") or "").replace("models/", "", 1)
            methods = item.get("supportedGenerationMethods") or []
            if not mid or "generateContent" not in methods or NOT_CHAT.search(mid):
                continue
            title = (item.get("displayName") or "").strip()
            if title.startswith("Gemini "):
                title = title[len("Gemini "):]
            found.append({
                "id": mid,
                "title": title,
                "context": int(item.get("inputTokenLimit") or 0),
            })
        token = data.get("nextPageToken") or ""
        if not token:
            break
    ids = set(item["id"] for item in found)
    # gemini-2.0-flash-001 duplicates gemini-2.0-flash.
    return [item for item in found
            if not (re.search(r"-\d{3}$", item["id"]) and item["id"][:-4] in ids)]


def list_muse(ssl_context):
    data = _get_json("https://api.meta.ai/v1/models",
                     {"Authorization": "Bearer " + _key("muse")}, ssl_context)
    found = []
    for item in data.get("data") or []:
        mid = item.get("id") or ""
        if mid and not NOT_CHAT.search(mid):
            found.append({"id": mid, "created": item.get("created") or 0})
    return found


LISTERS = {
    "grok": list_grok,
    "chatgpt": list_chatgpt,
    "claude": list_claude,
    "mistral": list_mistral,
    "muse": list_muse,
    "gemini": list_gemini,
}


def _transient(message):
    """Rate limits, overloads, and network trouble say nothing about the model."""
    text = message or ""
    match = re.search(r"returned (\d{3})", text)
    if match:
        return match.group(1) in TRANSIENT_CODES
    lowered = text.lower()
    return any(word in lowered for word in (
        "timed out", "timeout", "temporarily", "connection", "urlopen error",
        "rate limit", "overloaded", "unreachable", "reset by peer",
    ))


class Discovery(object):
    """Shared by every request. All state is guarded by self.lock."""

    def __init__(self, cache_path, probe, ssl_context, refresh_settings=None):
        self.cache_path = cache_path
        self.probe = probe
        self.ssl_context = ssl_context
        self.refresh_settings = refresh_settings
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.listed = {}
        self.probes = {}
        self.pending = set()
        self.pool = ThreadPoolExecutor(max_workers=MAX_PROBES_AT_ONCE)
        self.thread = None
        self.load()

    # ---- cache ----

    def load(self):
        try:
            handle = open(self.cache_path, "r")
            try:
                data = json.load(handle)
            finally:
                handle.close()
        except (IOError, ValueError):
            return
        if isinstance(data, dict):
            self.listed = data.get("listed") or {}
            self.probes = data.get("probes") or {}

    def save(self):
        with self.lock:
            data = {"listed": self.listed, "probes": self.probes}
        temporary = self.cache_path + ".tmp"
        try:
            handle = open(temporary, "w")
            try:
                json.dump(data, handle, indent=1, sort_keys=True)
            finally:
                handle.close()
            os.rename(temporary, self.cache_path)
        except (IOError, OSError):
            pass

    # ---- background work ----

    def start(self):
        if self.thread is not None:
            return
        self.thread = threading.Thread(target=self._loop, name="model-discovery")
        self.thread.daemon = True
        self.thread.start()

    def poke(self, providers=None):
        """Look again now. Named providers also lose their old check results,
        because a new key or workspace can change which models work."""
        with self.lock:
            for provider in list(self.listed):
                self.listed[provider]["at"] = 0
            for provider in providers or ():
                self.listed.pop(provider, None)
                for key in list(self.probes):
                    if key.startswith(provider + "|"):
                        del self.probes[key]
        self.wake.set()

    def _loop(self):
        while True:
            try:
                if self.refresh_settings:
                    self.refresh_settings()
                self.refresh_all()
            except Exception as exc:
                import sys
                sys.stderr.write("tigerbuild-relay: model discovery failed: %s\n" % exc)
            self.wake.wait(600)
            self.wake.clear()

    def refresh_all(self):
        now = time.time()
        for provider in LISTERS:
            if not has_key(provider):
                continue
            with self.lock:
                entry = self.listed.get(provider) or {}
            if now - float(entry.get("at") or 0) >= LIST_EVERY:
                self._list(provider)
            self._schedule_probes(provider)
        self.save()

    def _list(self, provider):
        try:
            models = LISTERS[provider](self.ssl_context())
            error = ""
        except Exception as exc:
            models = None
            error = str(exc)[:300]
        with self.lock:
            entry = self.listed.get(provider) or {}
            if models is not None:
                clean = [m for m in models if SAFE_ID.match(m.get("id") or "")]
                entry = {"at": time.time(), "models": clean, "error": ""}
            else:
                # Keep the last good list; retry the listing in an hour.
                entry["error"] = error
                entry["at"] = time.time() - LIST_EVERY + RECHECK_TRANSIENT
            self.listed[provider] = entry

    def candidates(self, provider):
        """Ids to consider: the live list, or the static catalog without one."""
        with self.lock:
            entry = self.listed.get(provider) or {}
            live = entry.get("models")
        if live:
            return [m["id"] for m in live]
        return list(P.catalog_ids(provider))

    # ---- checks ----

    def _due(self, record, now):
        if not record:
            return True
        age = now - float(record.get("at") or 0)
        if record.get("transient"):
            return age >= RECHECK_TRANSIENT
        return age >= (RECHECK_OK if record.get("ok") else RECHECK_FAIL)

    def _schedule_probes(self, provider):
        now = time.time()
        for model in self.candidates(provider):
            key = provider + "|" + model
            with self.lock:
                if key in self.pending or not self._due(self.probes.get(key), now):
                    continue
                self.pending.add(key)
            self.pool.submit(self._check, provider, model)

    def _endpoints(self, provider, model):
        if provider != "chatgpt":
            return [None]
        # Some OpenAI models only take the Responses API; try both.
        if model in P.OPENAI_RESPONSES or model.endswith("-pro"):
            return ["responses", "chat"]
        return ["chat", "responses"]

    def _check(self, provider, model):
        key = provider + "|" + model
        record = {"at": time.time(), "ok": False, "checked": True, "error": ""}
        try:
            for endpoint in self._endpoints(provider, model):
                try:
                    self.probe(provider, model, endpoint)
                except Exception as exc:
                    record["error"] = str(exc)[:300]
                    if _transient(record["error"]):
                        record["transient"] = True
                        record["checked"] = False
                        break
                    continue
                record = {"at": time.time(), "ok": True, "checked": True, "error": ""}
                if endpoint:
                    record["endpoint"] = endpoint
                break
        except Exception as exc:
            record = {"at": time.time(), "ok": False, "checked": False,
                      "transient": True, "error": str(exc)[:300]}
        finally:
            with self.lock:
                previous = self.probes.get(key) or {}
                if record.get("transient") and previous.get("checked"):
                    # Keep what we knew; only move the retry time.
                    previous = dict(previous)
                    previous["at"] = record["at"]
                    previous["transient"] = True
                    record = previous
                elif not record.get("transient"):
                    record.pop("transient", None)
                self.probes[key] = record
                self.pending.discard(key)
                still = bool(self.pending)
            if not still:
                self.save()

    # ---- answers ----

    def _verdict(self, provider, model):
        """'ok', 'failed', or 'unknown' (not checked yet, or only rate-limited)."""
        record = self.probes.get(provider + "|" + model)
        if not record or not record.get("checked"):
            # Never checked, or the only check hit a rate limit.
            return "unknown"
        return "ok" if record.get("ok") else "failed"

    def usable(self, provider):
        """[{"id", "title", "context"}] in menu order: newest unknown-to-us
        models first, then the static catalog order."""
        static_titles = dict(P.CATALOG.get(provider) or ())
        with self.lock:
            entry = self.listed.get(provider) or {}
            live = list(entry.get("models") or [])
            by_id = dict((m["id"], m) for m in live)
            ids = [m["id"] for m in live] or list(P.catalog_ids(provider))
            chosen = []
            for mid in ids:
                verdict = self._verdict(provider, mid)
                # Unchecked models are shown only if we already knew they work.
                if verdict == "ok" or (verdict == "unknown" and mid in static_titles):
                    info = by_id.get(mid) or {}
                    chosen.append({
                        "id": mid,
                        "title": static_titles.get(mid) or info.get("title") or pretty_title(provider, mid),
                        "context": int(info.get("context") or 0),
                        "created": float(info.get("created") or 0),
                    })
        order = list(P.catalog_ids(provider))
        known = [m for m in chosen if m["id"] in order]
        known.sort(key=lambda m: order.index(m["id"]))
        fresh = [m for m in chosen if m["id"] not in order]
        fresh.sort(key=lambda m: (-m["created"], m["id"]))
        return fresh + known

    def allowed(self, provider, model):
        if not model or not SAFE_ID.match(model):
            return False
        return any(m["id"] == model for m in self.usable(provider))

    def endpoint(self, provider, model):
        with self.lock:
            record = self.probes.get(provider + "|" + model) or {}
        return record.get("endpoint") or ""

    def default(self, provider):
        choices = self.usable(provider)
        if not choices:
            return ""
        preferred = P.DEFAULTS.get(provider)
        for item in choices:
            if item["id"] == preferred:
                return preferred
        return choices[0]["id"]

    def info(self, provider, model):
        """What the provider's model list says about one model (may be {})."""
        with self.lock:
            for item in (self.listed.get(provider) or {}).get("models") or []:
                if item.get("id") == model:
                    return dict(item)
        return {}

    def context(self, provider, model):
        for item in self.usable(provider):
            if item["id"] == model:
                return item["context"]
        return 0

    def checking(self):
        with self.lock:
            return len(self.pending)

    def provider_state(self, provider):
        if provider == "local":
            from app_config import local_configured
            return "ok" if local_configured() else "nokey"
        if not has_key(provider):
            return "nokey"
        if self.usable(provider):
            return "ok"
        with self.lock:
            entry = self.listed.get(provider) or {}
            pending = any(k.startswith(provider + "|") for k in self.pending)
        if pending or not entry:
            return "checking"
        return "error"

    def models_text(self):
        """Lines Tiger Build reads at launch:
             provider<TAB>id<TAB>title<TAB>state     state: ok, nokey, checking, error
             model<TAB>provider<TAB>id<TAB>title<TAB>isDefault<TAB>context
             checking<TAB>count                      only while checks are running
        """
        lines = []
        for provider, title in P.PROVIDERS:
            lines.append("provider\t%s\t%s\t%s" % (provider, title, self.provider_state(provider)))
            if provider == "local" or not has_key(provider):
                continue
            default = self.default(provider)
            for item in self.usable(provider):
                label = item["title"].replace("\t", " ").replace("\n", " ")
                lines.append("model\t%s\t%s\t%s\t%s\t%d" % (
                    provider, item["id"], label,
                    "1" if item["id"] == default else "0", item["context"]))
        pending = self.checking()
        if pending:
            lines.append("checking\t%d" % pending)
        return "\n".join(lines) + "\n"

    def summary(self):
        parts = []
        for provider, _title in P.PROVIDERS:
            if provider == "local" or not has_key(provider):
                continue
            parts.append("%s %d" % (provider, len(self.usable(provider))))
        text = ", ".join(parts) or "none"
        pending = self.checking()
        if pending:
            text += " (checking %d more)" % pending
        return text
