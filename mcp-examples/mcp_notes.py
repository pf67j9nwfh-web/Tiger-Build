#!/usr/bin/env python3
"""Example MCP server: a small notebook the model can write to and read from,
kept in a JSON file next to this script (or in MCP_NOTES_FILE)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_minimal import TEXT, obj, serve

PATH = os.environ.get("MCP_NOTES_FILE") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "notes-data.json")


def load():
    try:
        with open(PATH) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def save(data):
    with open(PATH, "w") as handle:
        json.dump(data, handle, indent=2)


def note_set(args):
    data = load()
    data[args["title"]] = args["text"]
    save(data)
    return "Saved %r (%d notes)." % (args["title"], len(data))


def note_get(args):
    data = load()
    if args["title"] not in data:
        raise KeyError("no note called %r" % args["title"])
    return data[args["title"]]


def note_list(args):
    data = load()
    return "\n".join("%s: %s" % (title, text[:60]) for title, text in sorted(data.items())) or "No notes yet."


def note_delete(args):
    data = load()
    if data.pop(args["title"], None) is None:
        raise KeyError("no note called %r" % args["title"])
    save(data)
    return "Deleted %r." % args["title"]


serve("example-notes", "1.0", {
    "note_set": ("Save a note under a title, replacing any note with that title.", obj({"title": TEXT, "text": TEXT}, ["title", "text"]), note_set),
    "note_get": ("Read a note by its title.", obj({"title": TEXT}, ["title"]), note_get),
    "note_list": ("List every note title with the start of its text.", obj({}), note_list),
    "note_delete": ("Delete a note by its title. This cannot be undone.", obj({"title": TEXT}, ["title"]), note_delete),
})
