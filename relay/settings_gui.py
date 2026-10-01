#!/usr/bin/env python3
"""Settings window for Windows and Linux.

It calls relay/control.py, the same controller the Mac app uses, so the
settings are the same. Closing the window leaves the relay running.
The token is shown in the window and is not printed.
"""
import json
import os
import subprocess
import sys
import threading
import queue
import tempfile

ROWS = (
    ("xAI / Grok", "xai_api_key", True),
    ("OpenAI / ChatGPT", "openai_api_key", True),
    ("Anthropic / Claude", "anthropic_api_key", True),
    ("Workspace ID (optional)", "anthropic_workspace_id", False),
    ("Mistral", "mistral_api_key", True),
    ("Muse", "muse_api_key", True),
    ("Google / Gemini", "gemini_api_key", True),
    ("Local server URL", "local_url", False),
    ("Local API key (optional)", "local_api_key", True),
)
TOGGLES = (
    ("ppc_enabled", "ppc-commander tools"),
    ("toolbox_enabled", "Agent toolbox"),
    ("search_enabled", "Web search (Brave or Tavily)"),
    ("grok_native_search", "Grok native search"),
    ("claude_thinking", "Show model thinking"),
)


def support_home():
    override = os.environ.get("TIGERBUILD_RELAY_HOME", "").strip()
    if override:
        return override
    from paths import default_support_dir
    return default_support_dir()


def installed_control(home=None):
    folder = home or support_home()
    path = os.path.join(folder, "app", "relay", "control.py")
    return path if os.path.isfile(path) else ""


def open_folder(path):
    if sys.platform == "win32":
        os.startfile(path)  # noqa: S606 - the settings folder the user asked to see
        return
    subprocess.call(["xdg-open", path])


def command(script, action, payload=None):
    try:
        proc = subprocess.Popen(
            [sys.executable, script, action], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0) if sys.platform == 'win32' else 0,
        )
        data = json.dumps(payload).encode('utf-8') if payload is not None else b''
        try:
            out, _err = proc.communicate(data, timeout=90)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            return {'error': 'Controller timed out. Check relay.log before retrying.'}
        parsed = json.loads(out.decode('utf-8'))
        if isinstance(parsed, dict) and (proc.returncode == 0 or 'error' in parsed):
            return parsed
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {'error': 'Controller failed. Check relay.log.'}


def private_write(dest, raw):
    fd, temp = tempfile.mkstemp(prefix='.tiger-backup-', dir=os.path.dirname(os.path.abspath(dest)))
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(raw)
        os.replace(temp, dest)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    try:
        import tkinter as tk
        from tkinter import filedialog, messagebox, ttk
    except ImportError:
        folder = support_home()
        sys.stderr.write("Tiger Build Relay needs Tk to show its settings window.\n")
        sys.stderr.write("On Linux, install python3-tk and open Tiger Build Relay from the application menu.\n")
        sys.stderr.write("Settings folder: %s\n" % folder)
        return 1

    script = installed_control()
    root = tk.Tk()
    root.title("Tiger Build Relay")
    root.geometry("760x700")
    if not script:
        folder = support_home()
        tk.Label(root, text="Tiger Build Relay is not set up for this account yet.", font=("", 14, "bold")).pack(anchor="w", padx=16, pady=(16, 6))
        tk.Label(root, text="Settings will be kept in:", anchor="w").pack(fill="x", padx=16)
        box = tk.Entry(root)
        box.insert(0, folder)
        box.configure(state="readonly")
        box.pack(fill="x", padx=16, pady=6)
        tk.Label(root, text="Run setup.py from the installed package, as your own user. Then open Tiger Build Relay again.", wraplength=700, justify="left").pack(anchor="w", padx=16, pady=8)
        root.mainloop()
        return 0

    status = tk.StringVar(value="Checking…")
    address = tk.StringVar()
    token = tk.StringVar()
    tiger = tk.StringVar()
    folder = tk.StringVar()
    note = tk.StringVar()
    port = tk.StringVar(value="8765")
    auto = tk.BooleanVar()
    fields = {}
    saved = {}
    last = {}
    ready = {"ok": False}
    busy = {"on": False}

    results = queue.Queue()

    def submit(work, callback):
        def worker():
            try:
                value = work()
            except Exception:
                value = {'error': 'Operation failed. Check the file and relay.log.'}
            results.put((callback, value))
        threading.Thread(target=worker, daemon=True).start()

    def deliver():
        while True:
            try:
                callback, value = results.get_nowait()
            except queue.Empty:
                break
            try:
                callback(value)
            except tk.TclError:
                pass  # A dialog may have been closed while its request ran.
        root.after(100, deliver)

    top = ttk.Frame(root, padding=12)
    top.pack(fill="both", expand=True)
    ttk.Label(top, textvariable=status, font=("", 13, "bold")).grid(row=0, column=0, columnspan=3, sticky="w")
    ttk.Button(top, text="Start", command=lambda: run("start")).grid(row=0, column=3, padx=4)
    ttk.Button(top, text="Stop", command=lambda: run("stop")).grid(row=0, column=4)
    ttk.Checkbutton(top, text="Start relay automatically at login (no window needed)", variable=auto, command=lambda: run("autostart", {"enabled": auto.get()})).grid(row=1, column=0, columnspan=4, sticky="w", pady=6)
    ttk.Label(top, textvariable=folder).grid(row=2, column=0, columnspan=4, sticky="w")
    ttk.Button(top, text="Show Folder", command=lambda: open_folder(last.get("support") or support_home())).grid(row=2, column=4)

    ttk.Label(top, textvariable=address).grid(row=3, column=0, columnspan=4, sticky="w", pady=(12, 0))
    ttk.Button(top, text="Copy Address", command=lambda: copy(last.get("url", ""))).grid(row=3, column=4)
    ttk.Label(top, text="Port").grid(row=4, column=0, sticky="w", pady=6)
    ttk.Entry(top, textvariable=port, width=8).grid(row=4, column=1, sticky="w")
    ttk.Label(top, text="Saving a new port restarts the relay. Use the same port in Tiger Build.").grid(row=4, column=2, columnspan=3, sticky="w")
    ttk.Label(top, textvariable=token).grid(row=5, column=0, columnspan=4, sticky="w")
    ttk.Button(top, text="Copy Token", command=lambda: copy(last.get("token", ""))).grid(row=5, column=4)
    ttk.Label(top, textvariable=tiger, wraplength=700).grid(row=6, column=0, columnspan=5, sticky="w", pady=(4, 10))

    keys = ttk.LabelFrame(top, text="AI services and local server", padding=8)
    keys.grid(row=7, column=0, columnspan=5, sticky="ew")
    ttk.Label(keys, text="One API key is enough, or use only a local model server. Blank fields keep what is saved.").grid(row=0, column=0, columnspan=4, sticky="w")
    for index, (title, key, secret) in enumerate(ROWS, start=1):
        ttk.Label(keys, text=title, width=28, anchor="e").grid(row=index, column=0, sticky="e", pady=2)
        var = tk.StringVar()
        entry = ttk.Entry(keys, textvariable=var, width=42, show="*" if secret else "")
        entry.grid(row=index, column=1, sticky="w")
        if key == "local_url":
            entry.configure(width=52)
        mark = tk.StringVar()
        ttk.Label(keys, textvariable=mark, width=8).grid(row=index, column=2)
        ttk.Button(keys, text="Delete", command=lambda name=key: delete_field(name)).grid(row=index, column=3, padx=4)
        fields[key] = var
        saved[key] = mark
    ttk.Label(keys, text="The local server address is as seen from this computer. It can be this computer or another one.").grid(row=len(ROWS) + 1, column=0, columnspan=4, sticky="w", pady=(6, 0))

    buttons = ttk.Frame(top)
    buttons.grid(row=8, column=0, columnspan=5, sticky="w", pady=10)
    ttk.Label(top, textvariable=note, wraplength=720).grid(row=9, column=0, columnspan=5, sticky="w")
    top.columnconfigure(2, weight=1)

    def copy(text):
        root.clipboard_clear()
        root.clipboard_append(text or "")
        note.set("Copied.")

    def apply_result(result, action):
        busy["on"] = False
        if result.get("error"):
            note.set(str(result["error"]))
            return
        last.clear()
        last.update(result)
        pid = int(result.get("pid") or 0)
        version = result.get("version") or "1.2"
        root.title("Tiger Build Relay %s" % version)
        status.set("Version %s, running in background (PID %s)" % (version, pid) if pid else "Version %s, stopped" % version)
        address.set("Reachable address: %s" % (result.get("url") or "unknown"))
        token.set("Token: %s" % (result.get("token") or ""))
        folder.set("Settings: %s" % (result.get("support") or support_home()))
        host = result.get("tiger_host") or ""
        user = result.get("tiger_user") or ""
        line = "Tiger Mac: not set — edit config.sh in the settings folder" if not host else "Tiger Mac: %s@%s" % (user or "?", host)
        seen = result.get("last_client") if isinstance(result.get("last_client"), dict) else {}
        if seen.get("machine"):
            line += "    ·    last connected: %s" % seen.get("machine")
        else:
            line += "    ·    no Tiger Build connection seen yet"
        tiger.set(line)
        auto.set(bool(result.get("autostart")))
        flags = result.get("saved") if isinstance(result.get("saved"), dict) else {}
        for key, mark in saved.items():
            mark.set("saved" if flags.get(key) else "")
        if not ready["ok"] or action != "status":
            port.set(str(result.get("port") or 8765))
            fields["local_url"].set(result.get("local_url") or "")
            if action != "status":
                for key, var in fields.items():
                    if key != "local_url":
                        var.set("")
            ready["ok"] = True
        if action != "status":
            note.set("Saved. The relay keeps running when this window is closed.")

    def run(action, payload=None):
        if busy["on"]:
            return
        busy["on"] = True
        if action != "status":
            note.set("Working…")

        submit(lambda: command(script, action, payload), lambda result: apply_result(result, action))

    def save():
        try:
            number = int(port.get())
        except ValueError:
            number = 0
        if number < 1 or number > 65535:
            note.set("Port must be 1–65535.")
            return
        payload = {"port": number}
        for key, var in fields.items():
            value = var.get().strip()
            if value:
                payload[key] = value
        run("save", payload)

    def delete_field(name):
        if messagebox.askokcancel("Delete this setting?", "The saved value is removed from the relay."):
            run("clear", {"clear": [name]})

    def clear_all():
        if messagebox.askokcancel("Clear all API keys and local server settings?", "This affects Tiger Build too. Provider and search keys and custom MCP configuration are removed. The relay connection and history are kept."):
            run("clear-all")

    def export_settings():
        if not messagebox.askokcancel("Export all settings?", "The backup contains API keys, the relay token and MCP secrets in plaintext. Store it privately. SSH private keys and history are not included."):
            return
        dest = filedialog.asksaveasfilename(defaultextension=".plist", initialfile="TigerBuildRelay-settings.plist", filetypes=[("Property list", "*.plist")])
        if not dest:
            return

        def work():
            result = command(script, "settings-export")
            if not result.get('data'):
                return {'error': result.get('error') or 'No backup returned.'}
            import base64
            private_write(dest, base64.b64decode(result['data'], validate=True))
            return {}
        submit(work, lambda result: note.set(result.get('error') or 'Settings exported. Keep the plaintext backup private.'))

    def import_settings():
        src = filedialog.askopenfilename(filetypes=[("Property list", "*.plist"), ("All files", "*")])
        if not src:
            return
        if not messagebox.askokcancel("Replace all relay configuration?", "This restores credentials, tool settings, connection and start-at-login. Imported custom MCP servers stay disabled. The relay restarts."):
            return
        import base64
        try:
            with open(src, "rb") as handle:
                raw = handle.read(2 * 1024 * 1024 + 1)
        except OSError:
            note.set("Could not read that backup file.")
            return
        if len(raw) > 2 * 1024 * 1024:
            note.set("Backup exceeds 2 MB.")
            return
        run("settings-import", {"data": base64.b64encode(raw).decode("ascii")})

    class Tools(tk.Toplevel):
        def __init__(self, parent):
            tk.Toplevel.__init__(self, parent)
            self.title("MCP Servers & Agent Tools")
            self.geometry("720x520")
            self.rows = []
            self.toggles = {}
            frame = ttk.Frame(self, padding=12)
            frame.pack(fill="both", expand=True)
            ttk.Label(frame, text="Custom servers run on this computer, not the Tiger Mac. New servers start disabled.", wraplength=680).pack(anchor="w")
            switches = ttk.Frame(frame)
            switches.pack(anchor="w", pady=6)
            for name, title in TOGGLES:
                var = tk.BooleanVar()
                ttk.Checkbutton(switches, text=title, variable=var).pack(anchor="w")
                self.toggles[name] = var
            self.provider = tk.StringVar(value="brave")
            pick = ttk.Frame(frame)
            pick.pack(anchor="w")
            ttk.Radiobutton(pick, text="Brave", variable=self.provider, value="brave").pack(side="left")
            ttk.Radiobutton(pick, text="Tavily", variable=self.provider, value="tavily").pack(side="left")
            self.brave = tk.StringVar()
            self.tavily = tk.StringVar()
            self.clear_brave = tk.BooleanVar()
            self.clear_tavily = tk.BooleanVar()
            self._key_row(frame, "Brave key", self.brave, self.clear_brave)
            self._key_row(frame, "Tavily key", self.tavily, self.clear_tavily)
            self.list = tk.Listbox(frame, height=8)
            self.list.pack(fill="both", expand=True, pady=6)
            bar = ttk.Frame(frame)
            bar.pack(fill="x")
            ttk.Button(bar, text="Enable / Disable", command=self.toggle).pack(side="left")
            ttk.Button(bar, text="Remove", command=self.remove).pack(side="left", padx=6)
            self.sid = tk.StringVar()
            self.command = tk.StringVar()
            self.args = tk.StringVar()
            self.env = tk.StringVar()
            ttk.Entry(frame, textvariable=self.sid).pack(fill="x", pady=2)
            self.sid.set("")
            ttk.Label(frame, text="Unique ID, absolute program path, arguments JSON array, environment JSON object.").pack(anchor="w")
            ttk.Entry(frame, textvariable=self.command).pack(fill="x", pady=2)
            ttk.Entry(frame, textvariable=self.args).pack(fill="x", pady=2)
            ttk.Entry(frame, textvariable=self.env).pack(fill="x", pady=2)
            self.msg = tk.StringVar()
            ttk.Label(frame, textvariable=self.msg, wraplength=680).pack(anchor="w", pady=4)
            ttk.Button(frame, text="Add Server (disabled)", command=self.add).pack(side="left")
            ttk.Button(frame, text="Save", command=self.save).pack(side="right")
            self.after(100, self.load)

        def _key_row(self, parent, title, var, clear):
            row = ttk.Frame(parent)
            row.pack(fill="x", pady=2)
            ttk.Label(row, text=title, width=12).pack(side="left")
            ttk.Entry(row, textvariable=var, show="*", width=40).pack(side="left")
            ttk.Checkbutton(row, text="Delete saved key", variable=clear).pack(side="left", padx=6)

        def render(self):
            self.list.delete(0, "end")
            for row in self.rows:
                state = "on" if row.get("enabled") else "off"
                self.list.insert("end", "%s — %s [%s]" % (row.get("id", ""), row.get("command", ""), state))

        def load(self):
            submit(lambda: command(script, "integrations"), self.loaded)

        def loaded(self, result):
            if result.get("error"):
                self.msg.set(result["error"])
                return
            self.rows = result.get("servers") or []
            self.provider.set(result.get("search_provider") or "brave")
            for name, var in self.toggles.items():
                var.set(bool(result.get(name)))
            self.msg.set("Saved keys: Brave %s, Tavily %s. Imported servers stay disabled until you enable them." % (
                "yes" if result.get("search_key_saved") else "no",
                "yes" if result.get("tavily_key_saved") else "no",
            ))
            self.render()

        def selected(self):
            picked = self.list.curselection()
            return picked[0] if picked else -1

        def toggle(self):
            index = self.selected()
            if index < 0:
                return
            self.rows[index]["enabled"] = not bool(self.rows[index].get("enabled"))
            self.render()

        def remove(self):
            index = self.selected()
            if index < 0:
                return
            del self.rows[index]
            self.render()

        def add(self):
            try:
                args = json.loads(self.args.get() or "[]")
                env = json.loads(self.env.get() or "{}")
            except ValueError:
                self.msg.set("Arguments and environment must be JSON.")
                return
            if not self.sid.get() or not self.command.get().startswith(("/", "\\\\")) and not os.path.isabs(self.command.get()):
                self.msg.set("Specify an ID and an absolute program path.")
                return
            if not isinstance(args, list) or not isinstance(env, dict):
                self.msg.set("Arguments must be an array and environment an object.")
                return
            self.rows.append({"id": self.sid.get().strip(), "command": self.command.get().strip(), "args": args, "env": env, "enabled": False})
            self.sid.set("")
            self.command.set("")
            self.args.set("")
            self.env.set("")
            self.msg.set("Added disabled. Enable it only if you trust it, then Save.")
            self.render()

        def save(self):
            if not messagebox.askokcancel("Save tool configuration?", "Enabled custom programs run as your account when a chat uses tools. Do not enable an untrusted server."):
                return
            payload = {
                "servers": self.rows,
                "search_api_key": self.brave.get(),
                "clear_search_key": self.clear_brave.get(),
                "tavily_api_key": self.tavily.get(),
                "clear_tavily_key": self.clear_tavily.get(),
                "search_provider": self.provider.get(),
            }
            for name, var in self.toggles.items():
                payload[name] = bool(var.get())
            self.msg.set("Saving…")
            submit(lambda: command(script, "integrations-save", payload), self.saved)

        def saved(self, result):
            self.msg.set(result.get("error") or "Saved. New chats use the new tool configuration.")
            if result.get("error"):
                return
            self.brave.set("")
            self.tavily.set("")
            self.clear_brave.set(False)
            self.clear_tavily.set(False)

    ttk.Button(buttons, text="Save Configuration", command=save).pack(side="left", padx=(0, 6))
    ttk.Button(buttons, text="Clear All Settings…", command=clear_all).pack(side="left", padx=6)
    ttk.Button(buttons, text="Tools / MCP…", command=lambda: Tools(root)).pack(side="left", padx=6)
    ttk.Button(buttons, text="Export Settings…", command=export_settings).pack(side="left", padx=6)
    ttk.Button(buttons, text="Import Settings…", command=import_settings).pack(side="left", padx=6)

    def tick():
        run("status")
        root.after(5000, tick)

    root.after(100, deliver)
    run("status")
    root.after(5000, tick)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
