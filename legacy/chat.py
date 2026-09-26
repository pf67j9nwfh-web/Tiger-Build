#!/usr/bin/python
# AquaChat for Mac OS X 10.4 Tiger. Python 2.3 only.
# The window content is brushed metal, like Tiger's Finder. Message bubbles
# follow iOS 6: a solid gel gradient, a gloss along the top rim, and a tail.

import math
import os
import pickle
import socket
import sys
import threading
import urllib2

import Tkinter


PAPER = "#D7DAE0"
BLUE_TOP = (126, 198, 252)
BLUE_BOTTOM = (12, 112, 222)
BLUE_EDGE = "#0A4E98"
GRAY_TOP = (252, 252, 254)
GRAY_BOTTOM = (208, 208, 216)
GRAY_EDGE = "#9E9EA6"
METAL = "#C2C2C4"


def json_escape(value):
    if value is None:
        value = u""
    if isinstance(value, str):
        try:
            value = value.decode("utf-8")
        except UnicodeError:
            value = value.decode("mac_roman", "replace")
    out = []
    for ch in value:
        code = ord(ch)
        if ch == u'"' or ch == u"\\":
            out.append(u"\\")
            out.append(ch)
        elif ch == u"\n":
            out.append(u"\\n")
        elif ch == u"\r":
            out.append(u"\\r")
        elif ch == u"\t":
            out.append(u"\\t")
        elif code < 32:
            out.append(u"\\u%04x" % code)
        else:
            out.append(ch)
    return u"".join(out).encode("utf-8")


def as_unicode(value):
    if value is None:
        return u""
    if isinstance(value, unicode):
        return value
    try:
        return value.decode("utf-8")
    except UnicodeError:
        return value.decode("mac_roman", "replace")


def support_dir():
    path = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Tiger Build")
    if not os.path.isdir(path):
        os.makedirs(path)
    return path


def chats_dir():
    path = os.path.join(support_dir(), "chats")
    if not os.path.isdir(path):
        os.makedirs(path)
    return path


def server_base():
    path = os.path.join(support_dir(), "server.txt")
    if os.path.isfile(path):
        handle = open(path, "r")
        try:
            text = handle.read().strip()
        finally:
            handle.close()
        if text:
            return text
    return "http://10.0.1.231:8765"


def mix_rgb(a, b, t):
    return (
        int(a[0] + (b[0] - a[0]) * t + 0.5),
        int(a[1] + (b[1] - a[1]) * t + 0.5),
        int(a[2] + (b[2] - a[2]) * t + 0.5),
    )


def rgb_hex(rgb):
    return "#%02x%02x%02x" % rgb


def corner_inset(row, height, radius):
    if row < radius:
        dy = radius - row
    elif row > height - radius:
        dy = row - (height - radius)
    else:
        return 0.0
    inside = radius * radius - dy * dy
    if inside < 0:
        inside = 0.0
    return radius - math.sqrt(inside)


def draw_ios6_bubble(canvas, x, y, w, h, from_user, top, bottom, edge):
    # Solid overlapping bands. A 1px stroke leaves gaps that look like PNG fringe.
    radius = h / 2.0
    if radius > 17:
        radius = 17.0
    if radius > w / 2.0:
        radius = w / 2.0
    steps = int(h)
    if steps < 8:
        steps = 8
    if from_user:
        tail = [x + w - 22, y + h - 8, x + w - 6, y + h - 2, x + w + 7, y + h + 8]
    else:
        tail = [x + 22, y + h - 8, x + 6, y + h - 2, x - 7, y + h + 8]
    outline = []
    i = 0
    while i < steps:
        inset = corner_inset(i, steps, radius)
        outline.append(x + inset)
        outline.append(y + i)
        i = i + 1
    i = steps - 1
    while i >= 0:
        inset = corner_inset(i, steps, radius)
        outline.append(x + w - inset)
        outline.append(y + i)
        i = i - 1
    canvas.create_polygon(outline, fill=edge, outline="", smooth=0)
    i = 0
    while i < steps:
        inset = corner_inset(i, steps, radius) + 1.0
        left = x + inset
        right = x + w - inset
        if right - left >= 2:
            t = float(i) / float(steps - 1)
            color = mix_rgb(top, bottom, t)
            if i < 7:
                color = mix_rgb(color, (255, 255, 255), 0.62 * ((7 - i) / 7.0))
            canvas.create_rectangle(left - 1, y + i, right + 1, y + i + 3, outline="", fill=rgb_hex(color))
        i = i + 1
    canvas.create_polygon(tail, fill=rgb_hex(bottom), outline="")


def make_metal_tile(master):
    width = 128
    height = 64
    image = Tkinter.PhotoImage(master=master, width=width, height=height)
    state = [17]

    def next_rand():
        state[0] = (state[0] * 1103515245 + 12345) & 0x7fffffff
        return state[0]

    y = 0
    while y < height:
        streak = (next_rand() % 23) - 12
        if (next_rand() % 11) == 0:
            streak = streak + 16
        row = []
        x = 0
        while x < width:
            value = 196 + streak + ((next_rand() % 9) - 4)
            if value < 168:
                value = 168
            if value > 220:
                value = 220
            row.append("#%02x%02x%02x" % (value, value, value))
            x = x + 1
        image.put("{" + " ".join(row) + "}", to=(0, y))
        y = y + 1
    return image


class StreamReader:
    def __init__(self, resp):
        self.resp = resp
        self.buf = ""

    def _fill(self, needed):
        while len(self.buf) < needed:
            chunk = self.resp.read(max(512, needed - len(self.buf)))
            if not chunk:
                break
            self.buf = self.buf + chunk

    def readline(self):
        while "\n" not in self.buf:
            chunk = self.resp.read(256)
            if not chunk:
                break
            self.buf = self.buf + chunk
        if "\n" not in self.buf:
            line = self.buf
            self.buf = ""
            return line
        line, self.buf = self.buf.split("\n", 1)
        return line

    def read_exact(self, count):
        self._fill(count)
        data = self.buf[:count]
        self.buf = self.buf[count:]
        return data


class AquaChat:
    def __init__(self, root, snapshot):
        self.root = root
        self.snapshot = snapshot
        self.persist = not snapshot
        self.server = server_base()
        self.chats = []
        self.current = None
        self.messages = []
        self.busy = False
        self.queue = []
        self.lock = threading.Lock()
        self.last_width = 0
        self.metal_w = 0
        self.metal_h = 0
        self.suspend_select = False
        self.redraw_pending = False
        self.next_number = 1
        self._fonts()
        self._build()
        if snapshot:
            self._sample_chats()
        else:
            self._load_chats()
        self.root.after(60, self._redraw)
        self.root.after(80, self._poll)

    def _fonts(self):
        self.body_font = ("Helvetica", 14)
        self.list_font = ("Lucida Grande", 12)
        self.entry_font = ("Lucida Grande", 13)
        self.header_font = ("Lucida Grande", 13, "bold")

    def _build(self):
        root = self.root
        root.title("Chat")
        root.geometry("860x660")
        root.minsize(680, 440)
        root.configure(bg=METAL)
        self.tile = make_metal_tile(root)
        self.backdrop = Tkinter.Canvas(root, highlightthickness=0, bd=0, bg=METAL)
        self.backdrop.place(x=0, y=0, relwidth=1, relheight=1)
        self.backdrop.create_text(18, 14, text="Chats", anchor="nw", font=self.header_font, fill="#222222", tags=("chrome",))
        root.bind("<Configure>", self._on_root_configure)

        self.new_button = Tkinter.Button(root, text="New Chat", command=self._new_chat)
        self.new_button.place(x=16, y=38, width=156, height=26)

        self.listbox = Tkinter.Listbox(
            root,
            font=self.list_font,
            bg="#F4F4F5",
            fg="#1A1A1A",
            selectbackground="#2D6FDB",
            selectforeground="#FFFFFF",
            relief="sunken",
            bd=1,
            highlightthickness=0,
            exportselection=0,
        )
        self.listbox.place(x=16, y=72, width=156, relheight=1, height=-124)
        self.listbox.bind("<<ListboxSelect>>", self._on_select)

        self.tools_button = Tkinter.Button(root, text="Commander: On", command=self._toggle_tools)
        self.tools_button.place(x=16, rely=1, y=-42, width=156, height=26)

        self.canvas = Tkinter.Canvas(
            root,
            bg=PAPER,
            highlightthickness=1,
            highlightbackground="#8E8E92",
            bd=0,
        )
        self.canvas.place(x=186, y=12, relwidth=1, width=-200, relheight=1, height=-64)
        self.scroll = Tkinter.Scrollbar(root, command=self.canvas.yview)
        self.scroll.place(relx=1, x=-18, y=14, width=16, relheight=1, height=-68)
        self.canvas.configure(yscrollcommand=self.scroll.set)
        self.canvas.bind("<Configure>", self._on_canvas_configure)

        self.entry = Tkinter.Entry(root, font=self.entry_font)
        self.entry.place(x=186, rely=1, y=-44, relwidth=1, width=-292, height=26)
        self.entry.bind("<Return>", self._on_return)
        self.entry.focus_set()

        self.send = Tkinter.Button(root, text="Send", command=self.send_message, default="active")
        self.send.place(relx=1, x=-98, rely=1, y=-48, width=82, height=32)
        self.root.after(30, self._retile_now)

    def _on_root_configure(self, event):
        if event.widget is not self.root:
            return
        if abs(event.width - self.metal_w) < 12 and abs(event.height - self.metal_h) < 12:
            return
        self.metal_w = event.width
        self.metal_h = event.height
        self._retile(event.width, event.height)

    def _retile_now(self):
        self._retile(self.root.winfo_width(), self.root.winfo_height())

    def _retile(self, width, height):
        if width < 10 or height < 10:
            return
        self.backdrop.delete("metal")
        tw = self.tile.width()
        th = self.tile.height()
        y = 0
        while y < height:
            x = 0
            while x < width:
                self.backdrop.create_image(x, y, image=self.tile, anchor="nw", tags=("metal",))
                x = x + tw
            y = y + th
        self.backdrop.tag_lower("metal")

    def _on_canvas_configure(self, event):
        if event.widget is not self.canvas:
            return
        if abs(event.width - self.last_width) < 2:
            return
        self.last_width = event.width
        self._redraw()

    def _on_return(self, event):
        self.send_message()
        return "break"

    def _blank_chat(self):
        number = self.next_number
        self.next_number = number + 1
        return {
            "id": str(number),
            "title": u"New Chat",
            "tools": True,
            "messages": [{"role": "assistant", "text": u"Hello. Ask me anything.", "status": False}],
        }

    def _load_chats(self):
        base = chats_dir()
        index_path = os.path.join(base, "index.pickle")
        order = []
        if os.path.isfile(index_path):
            handle = open(index_path, "rb")
            try:
                order = pickle.load(handle)
            finally:
                handle.close()
        loaded = []
        highest = 0
        for chat_id in order:
            path = os.path.join(base, chat_id + ".pickle")
            if not os.path.isfile(path):
                continue
            handle = open(path, "rb")
            try:
                chat = pickle.load(handle)
            finally:
                handle.close()
            loaded.append(chat)
            try:
                number = int(chat_id)
                if number > highest:
                    highest = number
            except ValueError:
                pass
        self.next_number = highest + 1
        if not loaded:
            loaded.append(self._blank_chat())
            self.chats = loaded
            self._save_index()
            self._save_chat(loaded[0])
        else:
            self.chats = loaded
        self._refresh_list(0)
        self._show_chat(0)

    def _sample_chats(self):
        first = self._blank_chat()
        first["title"] = u"Burn a CD"
        first["messages"] = [
            {"role": "user", "text": u"How do I burn a CD on Tiger?", "status": False},
            {"role": "assistant", "text": u"In the Finder, choose File, then New Burn Folder. Drag in what you want, then click Burn.", "status": False},
        ]
        second = self._blank_chat()
        second["title"] = u"New Chat"
        second["tools"] = False
        self.chats = [first, second]
        self._refresh_list(0)
        self._show_chat(0)
        self.entry.insert(0, "Tell me a Tiger tip")

    def _save_index(self):
        if not self.persist:
            return
        ids = []
        for chat in self.chats:
            ids.append(chat["id"])
        handle = open(os.path.join(chats_dir(), "index.pickle"), "wb")
        try:
            pickle.dump(ids, handle, 0)
        finally:
            handle.close()

    def _save_chat(self, chat):
        if not self.persist:
            return
        handle = open(os.path.join(chats_dir(), chat["id"] + ".pickle"), "wb")
        try:
            pickle.dump(chat, handle, 0)
        finally:
            handle.close()

    def _refresh_list(self, select_index):
        self.suspend_select = True
        self.listbox.delete(0, "end")
        i = 0
        while i < len(self.chats):
            self.listbox.insert("end", self.chats[i]["title"])
            i = i + 1
        if self.chats:
            if select_index < 0:
                select_index = 0
            if select_index >= len(self.chats):
                select_index = len(self.chats) - 1
            self.listbox.selection_clear(0, "end")
            self.listbox.selection_set(select_index)
            self.listbox.activate(select_index)
            self.listbox.see(select_index)
        self.suspend_select = False

    def _index_of(self, chat):
        i = 0
        while i < len(self.chats):
            if self.chats[i]["id"] == chat["id"]:
                return i
            i = i + 1
        return 0

    def _show_chat(self, index):
        if index < 0 or index >= len(self.chats):
            return
        self.current = self.chats[index]
        self.messages = self.current["messages"]
        self._sync_tools_button()
        self._redraw()
        self.canvas.update_idletasks()
        self.canvas.yview_moveto(1.0)

    def _on_select(self, event):
        if self.suspend_select:
            return
        selected = self.listbox.curselection()
        if not selected:
            return
        self._show_chat(int(selected[0]))

    def _new_chat(self):
        chat = self._blank_chat()
        self.chats.insert(0, chat)
        self._save_index()
        self._save_chat(chat)
        self._refresh_list(0)
        self._show_chat(0)
        self.entry.focus_set()

    def _tools_enabled(self, chat):
        if chat is None:
            return True
        if "tools" not in chat:
            return True
        if chat["tools"]:
            return True
        return False

    def _sync_tools_button(self):
        if self._tools_enabled(self.current):
            self.tools_button.configure(text="Commander: On")
        else:
            self.tools_button.configure(text="Commander: Off")

    def _toggle_tools(self):
        if self.current is None:
            return
        if self._tools_enabled(self.current):
            self.current["tools"] = False
        else:
            self.current["tools"] = True
        self._sync_tools_button()
        self._save_chat(self.current)

    def _note_title(self, chat, text):
        if chat["title"] != u"New Chat":
            return
        title = text.strip().replace(u"\n", u" ")
        if not title:
            return
        if len(title) > 26:
            title = title[:26] + u"..."
        chat["title"] = title
        self._refresh_list(self._index_of(chat))

    def _chat_by_id(self, chat_id):
        i = 0
        while i < len(self.chats):
            if self.chats[i]["id"] == chat_id:
                return self.chats[i]
            i = i + 1
        return None

    def _request_body(self, chat):
        parts = []
        for message in chat["messages"]:
            if message.get("status"):
                continue
            if message.get("open") and not message.get("text"):
                continue
            if message["role"] == "user":
                role = "user"
            else:
                role = "assistant"
            parts.append('{"role":"%s","content":"%s"}' % (role, json_escape(message["text"])))
        if self._tools_enabled(chat):
            flag = "true"
        else:
            flag = "false"
        return '{"messages":[%s],"tools":%s}' % (",".join(parts), flag)

    def send_message(self):
        if self.busy or self.current is None:
            return
        text = self.entry.get().strip()
        if not text:
            return
        self.entry.delete(0, "end")
        chat = self.current
        chat["messages"].append({"role": "user", "text": as_unicode(text), "status": False})
        chat["messages"].append({"role": "assistant", "text": u"", "status": False, "open": True})
        self._note_title(chat, as_unicode(text))
        self._save_chat(chat)
        body = self._request_body(chat)
        self._set_busy(True)
        self._redraw()
        self.canvas.yview_moveto(1.0)
        thread = threading.Thread(target=self._fetch, args=(body, chat["id"]))
        thread.setDaemon(True)
        thread.start()

    def _fetch(self, body, chat_id):
        socket.setdefaulttimeout(180)
        url = self.server.rstrip("/") + "/v1/chat"
        request = urllib2.Request(url, body)
        request.add_header("Content-Type", "application/json; charset=utf-8")
        request.add_header("X-AquaChat-Protocol", "frames")
        request.add_header("User-Agent", "TigerBuild/1.0")
        try:
            try:
                response = urllib2.urlopen(request)
                reader = StreamReader(response)
                while True:
                    header = reader.readline()
                    if header == "":
                        break
                    parts = header.split(" ", 1)
                    if len(parts) != 2:
                        self._enqueue(("error", chat_id, u"The chat service sent a bad stream."))
                        break
                    kind = parts[0]
                    try:
                        count = int(parts[1])
                    except ValueError:
                        self._enqueue(("error", chat_id, u"The chat service sent a bad stream."))
                        break
                    payload = reader.read_exact(count)
                    if kind == "d":
                        break
                    if kind == "e":
                        self._enqueue(("error", chat_id, as_unicode(payload)))
                    elif kind == "s":
                        self._enqueue(("status", chat_id, as_unicode(payload)))
                    elif kind == "t":
                        self._enqueue(("delta", chat_id, as_unicode(payload)))
            except urllib2.HTTPError, exc:
                detail = exc.read()
                if not detail:
                    detail = "The chat service returned HTTP %s." % exc.code
                self._enqueue(("error", chat_id, as_unicode(detail)))
            except Exception, exc:
                self._enqueue(("error", chat_id, as_unicode("Could not reach %s. %s" % (self.server, exc))))
        finally:
            self._enqueue(("done", chat_id, u""))

    def _enqueue(self, item):
        self.lock.acquire()
        try:
            self.queue.append(item)
        finally:
            self.lock.release()

    def _set_busy(self, flag):
        self.busy = flag
        if flag:
            self.send.configure(state="disabled", default="disabled")
            self.entry.configure(state="disabled")
            self.root.title("Chat - Sending...")
        else:
            self.send.configure(state="normal", default="active")
            self.entry.configure(state="normal")
            self.root.title("Chat")
            self.entry.focus_set()

    def _schedule_redraw(self):
        if self.redraw_pending:
            return
        self.redraw_pending = True
        self.root.after(60, self._flush_redraw)

    def _flush_redraw(self):
        self.redraw_pending = False
        self._redraw()
        self.canvas.yview_moveto(1.0)

    def _open_bubble(self, chat):
        messages = chat["messages"]
        i = len(messages) - 1
        while i >= 0:
            if messages[i].get("open"):
                return messages[i]
            i = i - 1
        bubble = {"role": "assistant", "text": u"", "status": False, "open": True}
        messages.append(bubble)
        return bubble

    def _add_status(self, chat, payload):
        messages = chat["messages"]
        note = {"role": "status", "text": payload, "status": True}
        if messages and messages[-1].get("open") and not messages[-1].get("text"):
            messages.insert(len(messages) - 1, note)
            return
        if messages and messages[-1].get("open") and messages[-1].get("text"):
            messages[-1]["open"] = False
        messages.append(note)

    def _apply_event(self, kind, chat_id, payload):
        chat = self._chat_by_id(chat_id)
        if chat is None:
            return
        visible = self.current is not None and self.current["id"] == chat_id
        if kind == "status":
            self._add_status(chat, payload)
            if visible:
                self._schedule_redraw()
        elif kind == "delta":
            bubble = self._open_bubble(chat)
            bubble["text"] = bubble["text"] + payload
            if visible:
                self._schedule_redraw()
        elif kind == "error":
            self._add_status(chat, payload)
            if visible:
                self._schedule_redraw()
        elif kind == "done":
            messages = chat["messages"]
            if messages and messages[-1].get("open"):
                messages[-1]["open"] = False
                if not messages[-1]["text"]:
                    messages.pop()
            self._save_chat(chat)
            self._set_busy(False)
            if visible:
                self._schedule_redraw()

    def _poll(self):
        item = None
        self.lock.acquire()
        try:
            if self.queue:
                item = self.queue.pop(0)
        finally:
            self.lock.release()
        if item is not None:
            self._apply_event(item[0], item[1], item[2])
        self.root.after(40, self._poll)

    def _redraw(self):
        canvas = self.canvas
        canvas.delete("all")
        width = canvas.winfo_width()
        if width < 80:
            width = 520
        visible = canvas.winfo_height()
        if visible < 80:
            visible = 480
        paper = canvas.create_rectangle(0, 0, width, visible, fill=PAPER, outline="")
        y = 16
        for message in self.messages:
            if message.get("status"):
                item = canvas.create_text(
                    width / 2, y, text=message["text"], anchor="n", justify="center",
                    width=width - 48, fill="#5E6268", font=("Lucida Grande", 11),
                )
                box = canvas.bbox(item)
                if box:
                    y = box[3] + 10
                else:
                    y = y + 18
                continue
            from_user = message["role"] == "user"
            max_text = width - 150
            if max_text < 160:
                max_text = width - 64
            if max_text < 80:
                max_text = 80
            display = message["text"]
            if message.get("open") and not display:
                display = u"..."
            probe = canvas.create_text(0, -2000, text=display, anchor="nw", width=max_text, font=self.body_font)
            box = canvas.bbox(probe)
            canvas.delete(probe)
            if not box:
                continue
            text_w = box[2] - box[0]
            text_h = box[3] - box[1]
            if text_w < 12:
                text_w = 12
            if text_h < 18:
                text_h = 18
            bubble_w = text_w + 32
            bubble_h = text_h + 20
            if bubble_h < 36:
                bubble_h = 36
            if from_user:
                x = width - 22 - bubble_w
                top = BLUE_TOP
                bottom = BLUE_BOTTOM
                edge = BLUE_EDGE
                text_fill = "#FFFFFF"
            else:
                x = 18
                top = GRAY_TOP
                bottom = GRAY_BOTTOM
                edge = GRAY_EDGE
                text_fill = "#1A1A1A"
            draw_ios6_bubble(canvas, x, y, bubble_w, bubble_h, from_user, top, bottom, edge)
            text_y = y + (bubble_h - text_h) / 2
            if text_y < y + 9:
                text_y = y + 9
            canvas.create_text(x + 16, text_y, text=display, anchor="nw", width=max_text, fill=text_fill, font=self.body_font)
            y = y + bubble_h + 10
        if y + 12 > visible:
            canvas.coords(paper, 0, 0, width, y + 12)
        canvas.configure(scrollregion=(0, 0, width, max(y + 12, visible)))

    def _snapshot(self):
        self.root.update()
        self._retile_now()
        self._redraw()
        self.root.update()
        os.system("/usr/sbin/screencapture -x /tmp/tigerbuild-screen.png")
        sys.stderr.write("GEOM %s %s %s %s\n" % (
            self.root.winfo_rootx(), self.root.winfo_rooty(),
            self.root.winfo_width(), self.root.winfo_height(),
        ))
        self.root.after(300, self.root.quit)


def main(argv):
    snapshot = False
    index = 1
    while index < len(argv):
        if argv[index] == "--snapshot":
            snapshot = True
        index = index + 1
    root = Tkinter.Tk()
    try:
        root.tk.call("console", "hide")
    except Tkinter.TclError:
        pass
    app = AquaChat(root, snapshot)
    if snapshot:
        root.after(700, app._snapshot)
    root.mainloop()


if __name__ == "__main__":
    main(sys.argv)
