"""Provider keys and the local model server.

The file lives in Application Support, not in the git tree. A .env seeds it
the first time the relay starts. Preferences from Tiger Build update it later.
"""

import json
import os
import socket
import threading
import time
import urllib.error
import urllib.parse
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

# There is no assumed local server. LM Studio listens on port 1234 by
# default, which is only a hint shown in the apps.
DEFAULT_LOCAL_URL = ""
LOCAL_URL_EXAMPLE = "http://127.0.0.1:1234/v1"
_local_cache = {"at": 0, "models": []}


def config_path():
    override = os.environ.get("TIGER_PROVIDERS_FILE", "").strip()
    if override:
        return override
    from paths import support_dir
    return os.path.join(support_dir(), "providers.json")


def _empty_config():
    data = {}
    for name, _env in FIELDS:
        data[name] = ""
    data["local_url"] = ""
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
        else:
            os.environ.pop(env_name, None)


def read_env_file(path):
    """Parse a KEY=value file. Returns {} when it does not exist."""
    values = {}
    if not path:
        return values
    try:
        handle = open(path, "r")
    except IOError:
        return values
    try:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            name = name.strip()
            if name.startswith("export "):
                name = name[7:].strip()
            if name:
                values[name] = value.strip().strip('"').strip("'")
    finally:
        handle.close()
    return values


_env_state = {"mtime": None}
_settings_lock = threading.Lock()


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except (OSError, TypeError):
        return None


def ensure_config_file(env_path=None):
    """Load provider settings for this request.

    .env seeds providers.json the first time. After that, whichever of the
    two files was edited last wins: editing .env takes effect on the next
    request with no restart, and Preferences still writes providers.json.
    Blank .env lines never erase a saved key. Returns True when providers.json
    was created.
    """
    with _settings_lock:
        path = config_path()
        env_mtime = _mtime(env_path)
        env = {}
        if env_mtime is not None and env_mtime != _env_state["mtime"]:
            env = read_env_file(env_path)
            field_names = set(env_name for _name, env_name in FIELDS)
            for name, value in env.items():
                # XAI_MODEL and similar overrides are read from the environment.
                if name not in field_names and value:
                    os.environ[name] = value
        created = False
        if not os.path.isfile(path):
            data = _empty_config()
            if not env:
                env = read_env_file(env_path)
            for name, env_name in FIELDS:
                value = (env.get(env_name) or os.environ.get(env_name, "")).strip()
                if value:
                    data[name] = value
            write_config(data)
            created = True
        elif env:
            first_look = _env_state["mtime"] is None
            if not first_look or env_mtime > (_mtime(path) or 0):
                data = read_config()
                changed = False
                for name, env_name in FIELDS:
                    value = (env.get(env_name) or "").strip()
                    if name == "local_url" and value:
                        try:
                            value = normalize_local_url(value)
                        except RuntimeError:
                            value = ""
                    if value and value != data.get(name):
                        data[name] = value
                        changed = True
                if changed:
                    write_config(data)
                    _local_cache["at"] = 0
        _env_state["mtime"] = env_mtime
        apply_config(read_config())
        return created


def settings_public():
    """name=value lines for Tiger Build Preferences. Keys are never sent back,
    only whether each is saved. local_url is the address in use, or blank
    when no local server is set up. local_status is unset, ok N, empty, or
    offline."""
    data = read_config()
    try:
        in_use = normalize_local_url(data.get("local_url") or "")
    except RuntimeError:
        in_use = ""
    lines = [
        "local_url=%s" % in_use,
        "local_url_set=%s" % ("1" if in_use else "0"),
    ]
    if not in_use:
        lines.append("local_status=unset")
    else:
        try:
            count = len(list_local_models(timeout=2))
            lines.append("local_status=%s" % ("ok %d" % count if count else "empty"))
        except Exception:
            lines.append("local_status=offline")
    for name, _env in FIELDS:
        if name == "local_url":
            continue
        lines.append("%s=%s" % (name, "1" if data.get(name) else "0"))
    return "\n".join(lines) + "\n"


def update_settings(incoming):
    data = read_config()
    if not isinstance(incoming, dict):
        raise RuntimeError("Settings must be an object.")
    # {"clear": ["xai_api_key", ...]} removes saved values. Blank fields
    # elsewhere mean "leave as is", so this is the only way to remove one.
    clear = [name for name, _env in FIELDS] if incoming.get("clear_all") is True else (incoming.get("clear") or [])
    if not isinstance(clear, list):
        raise RuntimeError("clear must be a list of setting names.")
    known = [name for name, _env in FIELDS]
    for name in clear:
        if name not in known:
            raise RuntimeError("Unknown setting %s." % name)
        data[name] = ""
        env_name = dict(FIELDS)[name]
        os.environ.pop(env_name, None)
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


def targets_this_relay(url, listen_host, listen_port):
    """True when a local model URL would call this relay back."""
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").strip("[]").lower()
    if parsed.port:
        port = parsed.port
    elif parsed.scheme == "https":
        port = 443
    else:
        port = 80
    if port != int(listen_port):
        return False
    listen = (listen_host or "").strip("[]").lower()
    if host in ("127.0.0.1", "localhost", "::1") or host == listen:
        return True
    if listen in ("0.0.0.0", "::"):
        try:
            own = socket.gethostbyname(socket.gethostname()).lower()
        except OSError:
            own = ""
        if host and host == own:
            return True
    return False


def _listen_endpoint():
    try:
        from mcp_bridge import load_shell_config
        from security import listen_address
        config = load_shell_config()
        return listen_address(config), int(config.get("LISTEN_PORT") or 8765)
    except Exception:
        return "", 8765


def normalize_local_url(value):
    text = (value or "").strip().rstrip("/")
    if not text:
        return ""
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
    host, port = _listen_endpoint()
    if targets_this_relay(text, host, port):
        raise RuntimeError("The local model address is this relay. Use the model server's own address.")
    return text


def local_base():
    try:
        return normalize_local_url(os.environ.get("LOCAL_MODEL_URL", ""))
    except RuntimeError:
        return ""


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


def _get_json(url, timeout=8):
    request = urllib.request.Request(url, headers={"User-Agent": "TigerBuild-relay/1.3"})
    response = urllib.request.urlopen(request, timeout=timeout)
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


def local_configured():
    return bool(local_base())


def list_local_models(timeout=8):
    base = local_base()
    if not base:
        raise RuntimeError("No local model server is set up.")
    origin = base[:-3] if base.endswith("/v1") else base
    v0_items = []
    v1_items = []
    errors = []
    try:
        payload = _get_json(origin + "/api/v0/models", timeout)
        if isinstance(payload, dict):
            v0_items = payload.get("data") or []
    except Exception as exc:
        errors.append(str(exc))
    try:
        payload = _get_json(base + "/models", timeout)
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
