#!/usr/bin/env python3
"""Writes tiger-build/prices-seed.json: the token prices of the models in tiger-build/models.txt, from the LiteLLM price list.
The app starts with this and refreshes the whole list itself once a day.   python3 scripts/make-prices.py [downloaded-price-list.json]"""
import json
import os
import re
import sys
import time
import urllib.request

URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
FIELD = re.compile(r"^(?:(input|output)_cost_per_token|(cache_read_input|cache_creation_input)_token_cost)(?:_above_(\d+)k_tokens)?$")
PREFIXES = {"grok": ("xai/", ""), "chatgpt": ("", "openai/"), "claude": ("", "anthropic/"), "mistral": ("mistral/", ""), "muse": ("meta_ai/", "meta/", ""), "gemini": ("gemini/", "")}
root = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tiger-build")
raw = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else json.load(urllib.request.urlopen(URL, timeout=60))
wanted = set()
for line in open(os.path.join(root, "models.txt")):
    parts = line.rstrip("\n").split("\t")
    if parts[0] == "model":
        for prefix in PREFIXES.get(parts[1], ("",)):
            wanted.add(prefix + parts[2])
rates = {}
for name, row in raw.items():
    if name not in wanted or not isinstance(row, dict):
        continue
    fields = {}
    for key, value in row.items():
        found = FIELD.match(key)
        if found and isinstance(value, (int, float)) and not isinstance(value, bool):
            fields.setdefault(found.group(1) or found.group(2), {})[str(int(found.group(3) or 0) * 1000)] = float(value)
    if "input" in fields and "output" in fields:
        rates[name] = fields
json.dump({"at": time.time(), "rates": rates}, open(os.path.join(root, "prices-seed.json"), "w"), separators=(",", ":"))
print("%d models priced" % len(rates))
