"""Estimated API cost.

Rates come from the community-maintained LiteLLM price list, fetched in the
background when the relay starts and again once a day. The last good copy is
kept in the settings folder so cost still works offline. Nothing here is an
invoice: it is an estimate from the token counts each service reports.

Some services charge a higher rate for the whole request once its prompt is
larger than a threshold (for example 200k tokens). The list records those as
keys like input_cost_per_token_above_200k_tokens, and cost() applies the
highest tier the request reached. Local models are free, so their cost is
None ("N/A").
"""

import json
import os
import re
import threading
import time
import urllib.request

from paths import support_dir

PRICE_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
REFRESH_SECONDS = 24 * 3600
FIELD = re.compile(
    r"^(?:(input|output)_cost_per_token|(cache_read_input|cache_creation_input)_token_cost)"
    r"(?:_above_(\d+)k_tokens)?$"
)
# Where each provider's models live in the list, in the order tried.
PREFIXES = {
    "grok": ("xai/", ""),
    "chatgpt": ("", "openai/"),
    "claude": ("", "anthropic/"),
    "mistral": ("mistral/", ""),
    "muse": ("meta_ai/", "meta/", ""),
    "gemini": ("gemini/", ""),
}

_LOCK = threading.Lock()
_STATE = {"rates": {}, "at": 0.0, "loaded": False, "started": False}


def cache_path():
    return os.path.join(support_dir(), "pricing-cache.json")


def _compact(raw):
    """Keep only the token rates, as {name: {field: {threshold_tokens: rate}}}."""
    rates = {}
    if not isinstance(raw, dict):
        return rates
    for name, row in raw.items():
        if not isinstance(row, dict) or not isinstance(name, str):
            continue
        fields = {}
        for key, value in row.items():
            found = FIELD.match(key)
            if not found or not isinstance(value, (int, float)) or isinstance(value, bool):
                continue
            tier = int(found.group(3) or 0) * 1000
            fields.setdefault(found.group(1) or found.group(2), {})[str(tier)] = float(value)
        if "input" in fields and "output" in fields:
            rates[name] = fields
    return rates


def load_cache():
    try:
        with open(cache_path()) as handle:
            blob = json.load(handle)
    except (OSError, ValueError):
        return False
    rates = blob.get("rates") if isinstance(blob, dict) else None
    if not isinstance(rates, dict) or not rates:
        return False
    with _LOCK:
        _STATE["rates"] = rates
        _STATE["at"] = float(blob.get("at") or 0)
        _STATE["loaded"] = True
    return True


def _save_cache(rates, stamp):
    temporary = cache_path() + ".tmp"
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"at": stamp, "rates": rates}, handle)
        os.replace(temporary, cache_path())
    except OSError:
        pass


def install(raw, stamp=None):
    """Use a downloaded price list. Returns how many models it priced."""
    rates = _compact(raw)
    if not rates:
        return 0
    stamp = stamp or time.time()
    with _LOCK:
        _STATE["rates"] = rates
        _STATE["at"] = stamp
        _STATE["loaded"] = True
    _save_cache(rates, stamp)
    return len(rates)


def refresh(context=None, url=PRICE_URL):
    request = urllib.request.Request(url, headers={"User-Agent": "TigerBuild-relay"})
    with urllib.request.urlopen(request, timeout=45, context=context) as response:
        raw = json.loads(response.read(20 * 1024 * 1024).decode("utf-8"))
    return install(raw)


def start(context=None):
    """Load the saved copy now, then refresh in the background when it is old."""
    with _STATE_GUARD:
        if _STATE["started"]:
            return
        _STATE["started"] = True
    load_cache()

    def work():
        while True:
            with _LOCK:
                age = time.time() - _STATE["at"]
            if age >= REFRESH_SECONDS:
                try:
                    refresh(context)
                except Exception:
                    pass
            time.sleep(3600)

    thread = threading.Thread(target=work, name="pricing", daemon=True)
    thread.start()


_STATE_GUARD = threading.Lock()


def available():
    with _LOCK:
        return bool(_STATE["rates"])


def find(provider, model):
    """The rate row for this model, or None."""
    if provider == "local" or not model:
        return None
    with _LOCK:
        rates = _STATE["rates"]
    for prefix in PREFIXES.get(provider, ("",)):
        row = rates.get(prefix + model)
        if row:
            return row
    return None


def _rate(row, field, prompt_tokens):
    """Per-token rate for field at this prompt size: the highest tier reached."""
    tiers = row.get(field)
    if not tiers:
        if field == "cache_read_input":
            return _rate(row, "input", prompt_tokens)
        if field == "cache_creation_input":
            return _rate(row, "input", prompt_tokens)
        return 0.0
    best = None
    for threshold, value in tiers.items():
        threshold = int(threshold)
        if threshold < prompt_tokens and (best is None or threshold > best[0]):
            best = (threshold, value)
    if best is None:
        return tiers.get("0", 0.0)
    return best[1]


def cost(provider, model, usage):
    """Dollars for one model call, or None when the price is unknown or free.

    usage: input (tokens not served from cache), cached (read from cache),
    written (cache writes), output. All counts are for one request, so the
    tier is chosen from that request's whole prompt size.
    """
    row = find(provider, model)
    if row is None:
        return None
    inputs = int(usage.get("input") or 0)
    cached = int(usage.get("cached") or 0)
    written = int(usage.get("written") or 0)
    output = int(usage.get("output") or 0)
    prompt = inputs + cached + written
    total = (
        inputs * _rate(row, "input", prompt)
        + cached * _rate(row, "cache_read_input", prompt)
        + written * _rate(row, "cache_creation_input", prompt)
        + output * _rate(row, "output", prompt)
    )
    return total


def summary():
    with _LOCK:
        count = len(_STATE["rates"])
        stamp = _STATE["at"]
    if not count:
        return "none"
    return "%d models, %s" % (count, time.strftime("%Y-%m-%d", time.localtime(stamp)))
