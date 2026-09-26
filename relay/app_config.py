"""Provider keys and the local model server.

The file lives in Application Support, not in the git tree. A .env seeds it
the first time the relay starts. Preferences from Tiger Build update it later.
"""

import json
import os
import time
import urllib.error
import urllib.request

FIELDS = (
    ("xai_api_key", "XAI_API_KEY"),
    ("openai_api_key", "OPENAI_API_KEY"),
    ("anthropic_api_key", "ANTHROPIC_API_KEY"),
    ("anthropic_workspace_id", "ANTHROPIC_WORKSPACE_ID"),
    ("mistral_api_key", "MISTRAL_API_KEY"),
    ("muse_api_key", "MUSE_API_KEY"),
    ("gemini_api_key", "GEMINI_API_KEY"),
    ("local_api_key", "LOCAL_API_KEY"),
    ("local_url", "LOCAL_MODEL_URL"),
)

DEFAULT_LOCAL_URL = "http://127.0.0.1:1234/v1"
_local_cache = {"at": 0, "models": []}


def config_path():
    override = os.environ.get("TIGER_PROVIDERS_FILE", "").strip()
    if override:
        return override
    support = os.path.join(
        os.path.expanduser("~/Library/Application Support"), "TigerDesk"
    )
    return os.path.join(support, "providers.json")


def _empty_config():
    data = {}
    for name, _env in FIELDS:
        data[name] = ""
    data["local_url"] = DEFAULT_LOCAL_URL
    return data


def read_config():
    path = config_path()
    try:
        handle = open(path, "r")
    except IOError:
        return _empty_config()
    try:
        parsed = json.load(handle)
    except ValueError:
        return _empty_config()
    finally:
        handle.close()
    data = _empty_config()
    if isinstance(parsed, dict):
        for name, _env in FIELDS:
            value = parsed.get(name)
            if isinstance(value, str):
                data[name] = value.strip()
    if not data["local_url"]:
        data["local_url"] = DEFAULT_LOCAL_URL
    return data


def write_config(data):
    path = config_path()
    folder = os.path.dirname(path)
    if not os.path.isdir(folder):
        os.makedirs(folder)
    payload = _empty_config()
    for name, _env in FIELDS:
        value = data.get(name)
        if isinstance(value, str):
            payload[name] = value.strip()
    if not payload["local_url"]:
        payload["local_url"] = DEFAULT_LOCAL_URL
    temporary = path + ".tmp"
    handle = open(temporary, "w")
    try:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    finally:
        handle.close()
    os.chmod(temporary, 0o600)
    os.rename(temporary, path)
    os.chmod(path, 0o600)
    return payload


def apply_config(data):
    for name, env_name in FIELDS:
        value = data.get(name) or ""
        if value:
            os.environ[env_name] = value


def ensure_config_file():
    """Create the config from the environment when it does not exist yet."""
    path = config_path()
    if os.path.isfile(path):
        apply_config(read_config())
        return False
    data = _empty_config()
    for name, env_name in FIELDS:
        value = os.environ.get(env_name, "").strip()
        if value:
            data[name] = value
    if not data["local_url"]:
        data["local_url"] = DEFAULT_LOCAL_URL
    write_config(data)
    apply_config(data)
    return True


def settings_public():
    data = read_config()
    lines = ["local_url=%s" % data["local_url"]]
    for name, _env in FIELDS:
        if name == "local_url":
            continue
        lines.append("%s=%s" % (name, "1" if data.get(name) else "0"))
    return "\n".join(lines) + "\n"


def update_settings(incoming):
    data = read_config()
    if not isinstance(incoming, dict):
        raise RuntimeError("Settings must be an object.")
    for name, _env in FIELDS:
        if name not in incoming:
            continue
        value = incoming.get(name)
        if not isinstance(value, str):
            continue
        value = value.strip()
        if not value:
            continue
        if name == "local_url":
            data[name] = normalize_local_url(value)
        else:
            data[name] = value
    written = write_config(data)
    apply_config(written)
    _local_cache["at"] = 0
    return written


def normalize_local_url(value):
    text = (value or "").strip().rstrip("/")
    if not text:
        return DEFAULT_LOCAL_URL
    if "://" not in text:
        text = "http://" + text
    lower = text.lower()
    if not (lower.startswith("http://") or lower.startswith("https://")):
        raise RuntimeError("The local model address must start with http:// or https://.")
    if lower.startswith("http://") or lower.startswith("https://"):
        rest = text.split("://", 1)[1]
        if not rest or " " in rest or ".." in rest:
            raise RuntimeError("The local model address is not usable.")
    if not lower.endswith("/v1"):
        text = text + "/v1"
    return text


def local_base():
    try:
        return normalize_local_url(os.environ.get("LOCAL_MODEL_URL", ""))
    except RuntimeError:
        return DEFAULT_LOCAL_URL


def local_key():
    return os.environ.get("LOCAL_API_KEY", "").strip()


def context_limit(model, local_limits=None):
    if local_limits and model in local_limits and local_limits[model]:
        return int(local_limits[model])
    if not model:
        return 32000
    if model == "gpt-4":
        return 8192
    prefixes = (
        ("gpt-4-turbo", 128000),
        ("gpt-4.1", 1047576),
        ("gpt-4o", 128000),
        ("gpt-3.5", 16385),
        ("gpt-5", 400000),
        ("gpt-6", 400000),
        ("chat-latest", 128000),
        ("o1", 200000),
        ("o3", 200000),
        ("o4", 200000),
        ("grok-", 256000),
        ("claude-", 200000),
        ("gemini-", 1048576),
        ("gemma-", 131072),
        ("muse-", 128000),
        ("ministral-", 131072),
        ("codestral", 256000),
        ("mistral", 128000),
        ("voxtral", 32768),
    )
    for prefix, limit in prefixes:
        if model.startswith(prefix):
            return limit
    return 32000


def clean_title(text):
    line = ""
    for raw in (text or "").splitlines():
        if raw.strip():
            line = raw.strip()
            break
    line = line.strip("\"'“”‘’ ").strip()
    if len(line) > 48:
        line = line[:48].rstrip()
    return line or "New Chat"


def _get_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "TigerBuild-relay/1.0"})
    response = urllib.request.urlopen(request, timeout=8)
    try:
        return json.loads(response.read().decode("utf-8", "replace"))
    finally:
        response.close()


def usable_local_models(v0_items, v1_items):
    skip = set()
    limits = {}
    for item in v0_items or []:
        if not isinstance(item, dict):
            continue
        mid = item.get("id") or ""
        kind = (item.get("type") or "").lower()
        if not mid:
            continue
        if kind == "embeddings" or "embed" in mid.lower():
            skip.add(mid)
            continue
        try:
            limits[mid] = int(item.get("max_context_length") or 0)
        except (TypeError, ValueError):
            limits[mid] = 0
    models = []
    seen = set()
    source = v1_items if v1_items else [{"id": mid} for mid in limits]
    for item in source:
        if not isinstance(item, dict):
            continue
        mid = item.get("id") or ""
        if not mid or mid in skip or mid in seen:
            continue
        if "embed" in mid.lower():
            continue
        seen.add(mid)
        title = mid.split("/")[-1] or mid
        models.append({
            "id": mid,
            "context": limits.get(mid) or 32768,
            "title": title,
        })
    return models


def list_local_models():
    base = local_base()
    origin = base[:-3] if base.endswith("/v1") else base
    v0_items = []
    v1_items = []
    errors = []
    try:
        payload = _get_json(origin + "/api/v0/models")
        if isinstance(payload, dict):
            v0_items = payload.get("data") or []
    except Exception as exc:
        errors.append(str(exc))
    try:
        payload = _get_json(base + "/models")
        if isinstance(payload, dict):
            v1_items = payload.get("data") or []
    except Exception as exc:
        errors.append(str(exc))
    models = usable_local_models(v0_items, v1_items)
    if not models and errors:
        raise RuntimeError("Cannot reach the local model server.")
    return models


def cached_local_models():
    now = time.time()
    if _local_cache["models"] and now - _local_cache["at"] < 30:
        return _local_cache["models"]
    try:
        models = list_local_models()
    except RuntimeError:
        return _local_cache["models"]
    _local_cache["at"] = now
    _local_cache["models"] = models
    return models


def local_models_text():
    try:
        models = list_local_models()
    except RuntimeError as exc:
        _local_cache["at"] = time.time()
        _local_cache["models"] = []
        return "error\t%s\n" % exc
    _local_cache["at"] = time.time()
    _local_cache["models"] = models
    lines = []
    for item in models:
        title = item["title"].replace("\t", " ").replace("\n", " ")
        lines.append("%s\t%s\t%s" % (item["id"], item["context"], title))
    return "\n".join(lines) + ("\n" if lines else "")


def context_for(provider, model):
    limits = {}
    if provider == "local":
        for item in cached_local_models():
            limits[item["id"]] = item["context"]
    return context_limit(model, limits)
