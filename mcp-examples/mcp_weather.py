#!/usr/bin/env python3
"""Example MCP server: weather from wttr.in, fetched with curl, so it needs no Python packages
(only curl on the relay computer, which every Mac, Linux and recent Windows has)."""
import json
import os
import subprocess
import sys
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_minimal import NUMBER, TEXT, obj, serve


def fetch(args):
    place = str(args.get("place") or "").strip()
    if not place:
        raise ValueError("Give a place, such as Chicago, 60601 or Paris,France.")
    try:
        done = subprocess.run(["curl", "-sSfL", "--max-time", "25", "https://wttr.in/%s?format=j1" % quote(place)],
                              capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        raise RuntimeError("curl is not installed on the relay computer.")
    if done.returncode != 0:
        raise RuntimeError("curl could not get the weather for %r: %s" % (place, done.stderr.strip() or "exit %d" % done.returncode))
    try:
        data = json.loads(done.stdout)
        data["current_condition"][0]
    except (ValueError, LookupError):
        raise RuntimeError("wttr.in did not return a forecast for %r." % place)
    return data


def where(data):
    area = (data.get("nearest_area") or [{}])[0]
    parts = [(area.get(key) or [{}])[0].get("value") for key in ("areaName", "region", "country")]
    return ", ".join(part for part in parts if part)


def words(item):
    return ((item.get("weatherDesc") or [{}])[0].get("value") or "").strip()


def current(args):
    data = fetch(args)
    now = data["current_condition"][0]
    return ("%s: %s, %s°F (%s°C), feels like %s°F (%s°C). Humidity %s%%, wind %s mph (%s km/h) %s, UV %s, rain %s in."
            % (where(data), words(now), now["temp_F"], now["temp_C"], now["FeelsLikeF"], now["FeelsLikeC"], now["humidity"],
               now["windspeedMiles"], now["windspeedKmph"], now["winddir16Point"], now["uvIndex"], now["precipInches"]))


def forecast(args):
    data = fetch(args)
    days = min(max(int(args.get("days") or 3), 1), 3)
    lines = [where(data)]
    for day in data.get("weather", [])[:days]:
        hours = day.get("hourly") or [{}]
        midday = hours[min(4, len(hours) - 1)]
        rain = max(int(hour.get("chanceofrain") or 0) for hour in hours)
        sun = (day.get("astronomy") or [{}])[0]
        lines.append("%s: %s, high %s°F (%s°C), low %s°F (%s°C), rain chance up to %d%%, sunrise %s, sunset %s"
                     % (day["date"], words(midday), day["maxtempF"], day["maxtempC"], day["mintempF"], day["mintempC"], rain,
                        sun.get("sunrise", "?"), sun.get("sunset", "?")))
    return "\n".join(lines)


serve("example-weather", "1.0", {
    "current_weather": ("Current conditions from wttr.in for a place (a city, postcode or 'City,Country').", obj({"place": TEXT}, ["place"]), current),
    "forecast": ("Up to three days of forecast from wttr.in for a place: conditions, highs and lows, rain chance, sunrise and sunset.",
                 obj({"place": TEXT, "days": NUMBER}, ["place"]), forecast),
})
