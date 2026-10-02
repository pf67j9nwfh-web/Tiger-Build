import Cocoa
import UniformTypeIdentifiers

let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let support: URL = {
    if let custom = ProcessInfo.processInfo.environment["TIGERBUILD_RELAY_HOME"], !custom.isEmpty {
        return URL(fileURLWithPath: custom)
    }
    let current = library.appendingPathComponent("Tiger Build Relay")
    let old = library.appendingPathComponent("TigerDesk")
    if !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: old.path) { return old }
    return current
}()
// Documentation screenshots: --snapshot FILE [--tools]. The token is hidden and
// the addresses and account are replaced with example values.
let snapshotPath: String? = {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { return args[i + 1] }
    return nil
}()
let snapshotTools = CommandLine.arguments.contains("--tools")
func writeSnapshot(of window: NSWindow, to path: String) {
    guard let frameView = window.contentView?.superview else { return }
    frameView.layoutSubtreeIfNeeded()
    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
let script = support.appendingPathComponent("app/relay/control.py").path
func pythonPath() -> String {
    if let file = Bundle.main.url(forResource: "python", withExtension: "txt"),
       let recorded = try? String(contentsOf: file, encoding: .utf8) {
        let path = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    for candidate in ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"] {
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return "/usr/bin/python3"
}
func command(_ action: String, _ input: [String: Any] = [:]) -> [String: Any] {
    if !FileManager.default.fileExists(atPath: script) {
        return ["error": "Run /usr/local/tiger-build-relay/scripts/setup.sh as your own user first. Then reopen Tiger Build Relay."]
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: pythonPath()); p.arguments = [script, action]
    let out = Pipe(), err = Pipe(), stdin = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = stdin
    do {
        try p.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input))
        try? stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] { return json }
        return ["error": String(data: errors, encoding: .utf8) ?? "Controller failed."]
    } catch { return ["error": error.localizedDescription] }
}
// Direct executable CLI, without creating or showing a GUI.
if CommandLine.arguments.contains("--start") || CommandLine.arguments.contains("--stop") {
    let result = command(CommandLine.arguments.contains("--stop") ? "stop" : "start")
    print(String(data: try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
    exit(result["error"] == nil ? 0 : 1)
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var status = NSTextField(labelWithString: "Checking…")
    var address = NSTextField(labelWithString: "")
    var token = NSTextField(labelWithString: "")
    var tigerMac = NSTextField(labelWithString: "")
    var folder = NSTextField(labelWithString: "")
    var message = NSTextField(labelWithString: "")
    var port = NSTextField(string: "8765")
    var auto = NSButton(checkboxWithTitle: "Start relay automatically at login (no GUI needed)", target: nil, action: nil)
    var fields: [String: NSTextField] = [:]
    var notes: [String: NSTextField] = [:]
    var last: [String: Any] = [:]
    var working = false
    var initialized = false
    var timer: Timer?
    var integrationsPanel: IntegrationPanel?
    let rows: [(String, String, Bool)] = [
        ("xAI / Grok", "xai_api_key", true), ("OpenAI / ChatGPT", "openai_api_key", true),
        ("Anthropic / Claude", "anthropic_api_key", true), ("Workspace ID (optional)", "anthropic_workspace_id", false),
        ("Mistral", "mistral_api_key", true), ("Muse", "muse_api_key", true), ("Google / Gemini", "gemini_api_key", true),
        ("Local server URL", "local_url", false), ("Local API key (optional)", "local_api_key", true)]
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appMenu = NSMenu(), slot = NSMenuItem()
        appMenu.addItem(withTitle: "Quit Tiger Build Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        slot.submenu = appMenu; menu.addItem(slot)
        let edit = NSMenu(), e = NSMenuItem(); e.title = "Edit"; e.submenu = edit
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(e)
        let history = NSMenu(title: "History"), h = NSMenuItem()
        h.title = "History"; h.submenu = history
        let export = history.addItem(withTitle: "Export Saved History As…", action: #selector(exportHistory(_:)), keyEquivalent: "")
        export.target = self
        let imp = history.addItem(withTitle: "Import History…", action: #selector(importHistory(_:)), keyEquivalent: "")
        imp.target = self
        menu.addItem(h)
        let cfg = NSMenu(title:"Configuration"), c = NSMenuItem()
        c.title="Configuration";c.submenu=cfg
        for (title,action) in [("MCP Servers & Agent Tools…",#selector(toolsPanel(_:))),
            ("Export All Settings…",#selector(exportSettings(_:))), ("Import All Settings…",#selector(importSettings(_:)))] {
            let item=cfg.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self
        }
        menu.addItem(c)
        let service=NSMenu(title:"Relay"), r=NSMenuItem();r.title="Relay";r.submenu=service
        for (title,action) in [("Start Relay",#selector(startRelay(_:))),("Stop Relay",#selector(stopRelay(_:))),
            ("Toggle Start at Login",#selector(toggleAutostart(_:))),("Copy Relay Address",#selector(copyAddress(_:))),
            ("Copy Relay Token",#selector(copyToken(_:))),("Open Log",#selector(openLog(_:))),("Open History Folder",#selector(openHistory(_:))),
            ("Open Settings Folder",#selector(openSupport(_:)))] {
            let item=service.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self
        };menu.addItem(r)
        let windowMenu=NSMenu(title:"Window"), w=NSMenuItem();w.title="Window";w.submenu=windowMenu
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowMenu.addItem(withTitle:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        menu.addItem(w);NSApp.windowsMenu=windowMenu
        let shortcuts:[String:(String,NSEvent.ModifierFlags)]=[
            "toolsPanel:":("m",[.command,.shift]),"exportSettings:":("s",[.command,.shift]),"importSettings:":("o",[.command,.shift]),
            "exportHistory:":("e",[.command]),"importHistory:":("i",[.command]),"startRelay:":("r",[.command]),"stopRelay:":("r",[.command,.shift]),
            "toggleAutostart:":("a",[.command,.option]),"copyAddress:":("l",[.command,.shift]),"copyToken:":("k",[.command,.shift]),
            "openLog:":("l",[.command]),"openHistory:":("h",[.command,.shift]),"openSupport:":("f",[.command,.shift])]
        for parent in menu.items { for item in parent.submenu?.items ?? [] {
            if let action=item.action,let combo=shortcuts[NSStringFromSelector(action)] {item.keyEquivalent=combo.0;item.keyEquivalentModifierMask=combo.1}
        }}
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 800), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tiger Build Relay"; window.center(); window.isReleasedWhenClosed = false
        let v = window.contentView!
        let icon = NSImageView(frame: NSRect(x: 24, y: 752, width: 36, height: 36))
        icon.image = NSImage(named: NSImage.applicationIconName); v.addSubview(icon)
        label("Tiger Build Relay", 70, 764, 500, 26, bold: true, size: 20)
        let tagline = label("Connects Tiger Build on Mac OS X 10.4 to current AI services and tools.", 70, 746, 600, 16, size: 11)
        tagline.textColor = .secondaryLabelColor

        let serviceBox = section("Service", NSRect(x: 20, y: 620, width: 740, height: 118))
        put(status, in: serviceBox, 16, 60, 470, 22); status.font = .boldSystemFont(ofSize: 15)
        put(button("Start", 0, 0, 100, "startRelay:"), in: serviceBox, 496, 55, 100, 30)
        put(button("Stop", 0, 0, 100, "stopRelay:"), in: serviceBox, 606, 55, 100, 30)
        put(auto, in: serviceBox, 16, 32, 560, 22); auto.target = self; auto.action = #selector(autostartChanged(_:))
        put(folder, in: serviceBox, 16, 8, 470, 18); folder.font = .systemFont(ofSize: 11); folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle; folder.isSelectable = true
        put(button("Show Folder", 0, 0, 100, "openSupport:"), in: serviceBox, 606, 2, 100, 28)

        let connection = section("Connection", NSRect(x: 20, y: 472, width: 740, height: 140))
        put(address, in: connection, 16, 84, 470, 20); address.isSelectable = true
        put(button("Copy", 0, 0, 100, "copyAddress:"), in: connection, 606, 78, 100, 30)
        let portLabel = NSTextField(labelWithString: "Port"); put(portLabel, in: connection, 16, 54, 40, 22)
        put(port, in: connection, 56, 54, 70, 22)
        let portNote = NSTextField(labelWithString: "Saving a new port restarts the relay. Use the same port in Tiger Build.")
        portNote.font = .systemFont(ofSize: 11); portNote.textColor = .secondaryLabelColor
        put(portNote, in: connection, 136, 56, 460, 18)
        put(token, in: connection, 16, 30, 570, 20); token.isSelectable = true
        token.font = .monospacedSystemFont(ofSize: 11, weight: .regular); token.lineBreakMode = .byTruncatingTail
        put(button("Copy Token", 0, 0, 100, "copyToken:"), in: connection, 606, 24, 100, 30)
        put(button("Tiger Mac…", 0, 0, 100, "tigerMacPanel:"), in: connection, 606, 0, 100, 28)
        put(tigerMac, in: connection, 16, 6, 580, 18); tigerMac.font = .systemFont(ofSize: 11)
        tigerMac.textColor = .secondaryLabelColor; tigerMac.lineBreakMode = .byTruncatingTail

        let keys = section("AI services and local server", NSRect(x: 20, y: 82, width: 740, height: 382))
        let keyNote = NSTextField(labelWithString: "One API key is enough, or use only a local model server. Blank fields keep what is saved.")
        keyNote.font = .systemFont(ofSize: 11); keyNote.textColor = .secondaryLabelColor
        put(keyNote, in: keys, 16, 330, 700, 18)
        var y: CGFloat = 296
        for (title, key, secure) in rows {
            let l = NSTextField(labelWithString: title); l.alignment = .right; put(l, in: keys, 16, y + 2, 196, 20)
            let f: NSTextField = secure ? NSSecureTextField(string: "") : NSTextField(string: "")
            put(f, in: keys, 220, y, 330, 22); fields[key] = f
            let n = NSTextField(labelWithString: ""); n.font = .systemFont(ofSize: 11); n.textColor = .systemGreen
            put(n, in: keys, 558, y + 3, 44, 18); notes[key] = n
            let b = button("Delete", 0, 0, 100, "deleteField:"); b.identifier = NSUserInterfaceItemIdentifier(key)
            put(b, in: keys, 606, y - 4, 100, 30)
            if key == "local_url" { f.placeholderString = "not set — this computer or another, e.g. http://127.0.0.1:1234/v1" }
            if key == "anthropic_workspace_id" { l.toolTip = "Only needed if your Claude key requires a workspace ID. Most keys do not."; f.toolTip = l.toolTip }
            if key == "local_api_key" { l.toolTip = "Only needed if your local model server requires a key."; f.toolTip = l.toolTip }
            y -= 32
        }
        let localNote = NSTextField(labelWithString: "The local server address is as seen from this computer. It can be this computer or another one. Delete removes it.")
        localNote.font = .systemFont(ofSize: 11); localNote.textColor = .secondaryLabelColor
        put(localNote, in: keys, 16, 8, 700, 18)

        button("Save Configuration", 20, 40, 160, "save:")
        button("Clear All Settings…", 186, 40, 160, "clearAll:")
        button("Tools / MCP…", 352, 40, 130, "toolsPanel:")
        button("Export Settings…", 488, 40, 134, "exportSettings:")
        button("Import Settings…", 628, 40, 132, "importSettings:")
        place(message, 24, 10, 732, 26); message.maximumNumberOfLines = 2; message.font = .systemFont(ofSize: 11)
        _ = v
        if snapshotPath != nil { NSApp.appearance = NSAppearance(named: .aqua) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        perform("status")
        if snapshotPath != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.perform("status") }
    }
    func section(_ title: String, _ frame: NSRect) -> NSView {
        let box = NSBox(frame: frame); box.title = title; box.titleFont = .boldSystemFont(ofSize: 12)
        box.contentViewMargins = NSSize(width: 0, height: 0)
        window.contentView!.addSubview(box)
        return box.contentView!
    }
    func put(_ view: NSView, in parent: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        view.removeFromSuperview(); view.frame = NSRect(x: x, y: y, width: w, height: h); parent.addSubview(view)
    }
    func ago(_ seconds: Double) -> String {
        let s = Int(Date().timeIntervalSince1970 - seconds)
        if s < 90 { return "just now" }
        if s < 5400 { return "\(s / 60) min ago" }
        if s < 172800 { return "\(s / 3600) h ago" }
        return "\(s / 86400) days ago"
    }
    func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { view.frame = NSRect(x:x, y:y, width:w, height:h); window.contentView!.addSubview(view) }
    @discardableResult func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let f = NSTextField(labelWithString: text); f.font = bold ? .boldSystemFont(ofSize:size) : .systemFont(ofSize:size); place(f,x,y,w,h); return f
    }
    @discardableResult func button(_ title: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ selector: String) -> NSButton {
        let b = NSButton(title:title, target:self, action:NSSelectorFromString(selector)); b.bezelStyle = .rounded; place(b,x,y,w,30); return b
    }
    func confirm(_ title: String, _ text: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
    func perform(_ action: String, _ input: [String: Any] = [:]) {
        if working { return }; working = true
        if action != "status" { message.stringValue = "Working…" }
        DispatchQueue.global().async {
            let result = command(action, input)
            DispatchQueue.main.async {
                self.working = false
                if let error = result["error"] as? String { self.message.stringValue = error; return }
                self.last = result
                let pid = result["pid"] as? Int ?? 0
                let ver = result["version"] as? String ?? "1.3"
                self.window.title = "Tiger Build Relay \(ver)"
                self.status.stringValue = pid > 0 ? "Version \(ver), running in background (PID \(pid))" : "Version \(ver), stopped"
                self.status.textColor = pid > 0 ? .systemGreen : .secondaryLabelColor
                self.address.stringValue = "Reachable address: \(result["url"] as? String ?? "unknown")"
                self.token.stringValue = "Token: \(result["token"] as? String ?? "")"
                self.folder.stringValue = "Settings: \(result["support"] as? String ?? support.path)"
                let host = result["tiger_host"] as? String ?? "", user = result["tiger_user"] as? String ?? ""
                var line = host.isEmpty ? "Tiger Mac: not set — choose Tiger Mac…" : "Tiger Mac: \(user.isEmpty ? "?" : user)@\(host)"
                if let seen = result["last_client"] as? [String: Any], let machine = seen["machine"] as? String {
                    line += "   ·   last connected: \(machine)"
                    if let os = seen["os"] as? String { line += ", \(os)" }
                    if let at = seen["seen"] as? Double { line += ", \(self.ago(at))" }
                } else { line += "   ·   no Tiger Build connection seen yet" }
                self.tigerMac.stringValue = line
                if snapshotPath != nil {
                    self.address.stringValue = "Reachable address: http://192.168.1.10:\(result["port"] as? Int ?? 8765)"
                    self.token.stringValue = "Token: ••••••••••••••••••••••••••••••••••••••••••••••••"
                    self.folder.stringValue = "Settings: ~/Library/Application Support/Tiger Build Relay"
                    self.tigerMac.stringValue = "Tiger Mac: tiger@192.168.1.20   ·   last connected: Power Mac G4 (AGP graphics), Mac OS X 10.4.11, just now"
                }
                self.auto.state = (result["autostart"] as? Bool ?? false) ? .on : .off
                let saved = result["saved"] as? [String: Bool] ?? [:]
                for (key, note) in self.notes { note.stringValue = saved[key] == true ? "saved" : "" }
                if !self.initialized || action != "status" {
                    self.port.stringValue = "\(result["port"] as? Int ?? 8765)"
                    self.fields["local_url"]?.stringValue = result["local_url"] as? String ?? ""
                    for (_,key,_) in self.rows where key != "local_url" { self.fields[key]?.stringValue = "" }
                    self.initialized = true
                }
                if let r = result["ssh_result"] as? [String: Any] { self.message.stringValue = r["message"] as? String ?? "" }
                else if action != "status" { self.message.stringValue = "Saved. The relay keeps running when this window is closed." }
                if let path = snapshotPath, action == "status" {
                    self.message.stringValue = ""
                    if snapshotTools {
                        self.integrationsPanel = IntegrationPanel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            if let w = self.integrationsPanel?.window { writeSnapshot(of: w, to: path) }
                            NSApp.terminate(nil)
                        }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { writeSnapshot(of: self.window, to: path); NSApp.terminate(nil) }
                    }
                }
            }
        }
    }
    @objc func toggleAutostart(_ sender:Any?) { perform("autostart",["enabled":!(last["autostart"] as? Bool ?? false)]) }
    @objc func copyAddress(_ sender:Any?) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(last["url"] as? String ?? "",forType:.string)}
    @objc func startRelay(_ sender: Any?) { perform("start") }
    @objc func stopRelay(_ sender: Any?) { perform("stop") }
    @objc func autostartChanged(_ sender: Any?) { perform("autostart", ["enabled": auto.state == .on]) }
    @objc func save(_ sender: Any?) {
        guard let n = Int(port.stringValue), (1...65535).contains(n) else { message.stringValue = "Port must be 1–65535."; return }
        var input: [String: Any] = ["port": n]
        for (key,field) in fields where !field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { input[key] = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines) }
        perform("save", input)
    }
    // The Tiger Mac Commander signs in to: address, account and home folder.
    @objc func tigerMacPanel(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "Tiger Mac for Commander"
        alert.informativeText = "Commander runs a Tiger Mac's tools over SSH. Tiger Build on that Mac can also set this up itself (Configuration, Connect Commander over SSH)."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
        let names = ["Address", "Account", "Home folder"]
        let values = [last["tiger_host"] as? String ?? "", last["tiger_user"] as? String ?? "", last["tiger_home"] as? String ?? ""]
        var edits: [NSTextField] = []
        for (i, name) in names.enumerated() {
            let y = CGFloat(64 - i * 30)
            let l = NSTextField(labelWithString: name); l.alignment = .right; l.frame = NSRect(x: 0, y: y + 2, width: 96, height: 20); box.addSubview(l)
            let f = NSTextField(string: values[i]); f.frame = NSRect(x: 104, y: y, width: 250, height: 24); box.addSubview(f); edits.append(f)
        }
        alert.accessoryView = box
        alert.addButton(withTitle: "Save and Test"); alert.addButton(withTitle: "Forget Saved Host Key"); alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        if answer == .alertFirstButtonReturn {
            perform("ssh-save", ["host": edits[0].stringValue, "user": edits[1].stringValue, "home": edits[2].stringValue])
        } else if answer == .alertSecondButtonReturn { perform("ssh-forget") }
    }
    @objc func deleteField(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if confirm("Delete this setting?", "The saved value is removed from the relay.") { perform("clear", ["clear": [key]]) }
    }
    @objc func clearAll(_ sender: Any?) {
        if confirm("Clear all API keys and local server settings?", "This affects Tiger Build too. All provider/search keys and custom MCP configuration are removed; built-in tools return to defaults. The relay connection and history are kept.") { perform("clear-all") }
    }
    @objc func copyToken(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(last["token"] as? String ?? "", forType:.string) }
    @objc func openSupport(_ sender: Any?) { NSWorkspace.shared.open(support) }
    @objc func openLog(_ sender: Any?) { NSWorkspace.shared.open(support.appendingPathComponent("relay.log")) }
    @objc func openHistory(_ sender: Any?) { let dir = support.appendingPathComponent("history"); try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); NSWorkspace.shared.open(dir) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportHistory(_:)) {
            return !working && FileManager.default.fileExists(atPath: support.appendingPathComponent("history/TigerBuild-history.plist").path)
        }
        if menuItem.action == #selector(importHistory(_:)) { return !working }
        return true
    }
    @objc func exportHistory(_ sender: Any?) {
        let source = support.appendingPathComponent("history/TigerBuild-history.plist")
        let panel = NSSavePanel(); panel.nameFieldStringValue = "TigerBuild-history.plist"
        panel.allowedContentTypes = [.propertyList]
        if panel.runModal() != .OK { return }
        guard let dest = panel.url else { return }
        do {
            // Atomic copy permits Save As to replace an existing destination.
            let data = try Data(contentsOf: source)
            try data.write(to: dest, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            message.stringValue = "History exported. Media files are not included."
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc func importHistory(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() != .OK { return }
        guard let source = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Import history to the relay?"
        alert.informativeText = "This replaces the relay's saved snapshot, not any Tiger Mac's current chats. Tiger Build can then import it from the server. Media file contents are not included."
        alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { return }
        do {
            let info = try source.resourceValues(forKeys: [.fileSizeKey])
            if (info.fileSize ?? 0) > 16 * 1024 * 1024 { message.stringValue = "History exceeds the 16 MB limit."; return }
            let data = try Data(contentsOf: source)
            perform("history-import", ["data": data.base64EncodedString()])
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc func toolsPanel(_ sender:Any?) { integrationsPanel=IntegrationPanel() }
    @objc func exportSettings(_ sender:Any?) {
        let a=NSAlert();a.messageText="Export all settings?";a.informativeText="The backup contains API keys, the relay token and MCP environment secrets in plaintext. Store it securely. SSH private key files and history are NOT included.";a.addButton(withTitle:"Export");a.addButton(withTitle:"Cancel")
        if a.runModal() != .alertFirstButtonReturn{return}
        let panel=NSSavePanel();panel.nameFieldStringValue="TigerBuildRelay-settings.plist";panel.allowedContentTypes=[.propertyList]
        if panel.runModal() != .OK{return};guard let url=panel.url else{return}
        message.stringValue="Exporting…"
        DispatchQueue.global().async {
            let result=command("settings-export")
            do {
                guard let str=result["data"] as? String,let data=Data(base64Encoded:str) else {throw NSError(domain:"Backup",code:1,userInfo:[NSLocalizedDescriptionKey:result["error"] as? String ?? "No backup returned"])}
                try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                DispatchQueue.main.async {self.message.stringValue="Settings exported. Keep the plaintext backup private."}
            }catch{DispatchQueue.main.async {self.message.stringValue=error.localizedDescription}}
        }
    }
    @objc func importSettings(_ sender:Any?) {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.propertyList];panel.allowsMultipleSelection=false
        if panel.runModal() != .OK{return};guard let url=panel.url else{return}
        let a=NSAlert();a.messageText="Replace all relay configuration?";a.informativeText="This restores credentials, tool settings, connection paths/token/port and login autostart. Enabled custom MCP servers are restored disabled for safety. Back up current settings first. The running relay will restart; update the client connection if needed.";a.addButton(withTitle:"Import");a.addButton(withTitle:"Cancel")
        if a.runModal() != .alertFirstButtonReturn{return}
        do {let data=try Data(contentsOf:url);if data.count>2*1024*1024{message.stringValue="Backup exceeds 2 MB.";return};perform("settings-import",["data":data.base64EncodedString()])}
        catch{message.stringValue=error.localizedDescription}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Controller()
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()

// Custom servers always run on the relay host. Editing this list is a user
// operation, never a model tool. Imported servers must be explicitly enabled.
final class IntegrationPanel: NSObject {
    var window: NSWindow!
    var config: [String:Any] = [:]
    var toggles: [String:NSButton] = [:]
    var rows: [[String:Any]] = []
    var list = NSStackView()
    var id = NSTextField(string: "")
    var executable = NSTextField(string: "")
    var arguments = NSTextField(string: "")
    var environment = NSTextField(string: "")
    var key = NSSecureTextField(string: "")
    var tavily = NSSecureTextField(string: "")
    var searchProvider = NSPopUpButton(frame:.zero,pullsDown:false)
    var clearTavily = NSButton(checkboxWithTitle:"Delete saved Tavily key",target:nil,action:nil)
    var clearKey = NSButton(checkboxWithTitle:"Delete saved search API key",target:nil,action:nil)
    var status = NSTextField(labelWithString: "Loading…")
    override init() {
        super.init()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:870),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "MCP Servers & Agent Tools"; window.center(); window.isReleasedWhenClosed = false
        func add(_ v:NSView,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat){v.frame=NSRect(x:x,y:y,width:w,height:h);window.contentView!.addSubview(v)}
        let y:CGFloat=825
        var index=0
        for (title,name) in [("Commander (built in)","ppc_enabled"),("Ask first before Commander runs a tool","ppc_approval"),("Let models ask other models for advice","consult_enabled"),("Agent toolbox (UTC time, scratch notes)","toolbox_enabled"),("Web search for other providers","search_enabled"),("Grok native web search","grok_native_search"),("Show model thinking","claude_thinking")] {
            let b=NSButton(checkboxWithTitle:title,target:nil,action:nil)
            add(b,index<4 ? 20 : 390,y-CGFloat(index<4 ? index : index-4)*30,350,24);toggles[name]=b
            index+=1
        }
        add(NSTextField(labelWithString:"Brave API key (blank keeps saved):"),20,665,265,24);add(key,290,665,435,24)
        add(clearKey,290,638,425,24)
        add(NSTextField(labelWithString:"Tavily API key (blank keeps saved):"),20,607,265,24);add(tavily,290,607,435,24)
        add(clearTavily,290,578,425,24)
        searchProvider.addItems(withTitles:["Brave Search","Tavily"])
        add(NSTextField(labelWithString:"Search service:"),20,540,265,24);add(searchProvider,290,540,220,26)
        add(NSTextField(labelWithString:"Custom stdio MCP servers (on the relay Mac; enable only trusted executables):"),20,442,720,24)
        let scroll=NSScrollView(frame:NSRect(x:20,y:270,width:710,height:167));scroll.hasVerticalScroller=true
        list.orientation = .vertical; list.alignment = .leading; list.spacing=7
        scroll.documentView=list;window.contentView!.addSubview(scroll)
        id.placeholderString="Unique ID (letters/digits/underscore)";add(id,20,235,250,24)
        executable.placeholderString="Absolute executable path, e.g. /opt/homebrew/bin/node";add(executable,280,235,450,24)
        arguments.placeholderString="Arguments as JSON array, e.g. [\"/path/server.js\"]";add(arguments,20,200,710,24)
        environment.placeholderString="Optional environment JSON, e.g. {\"API_KEY\":\"…\"}";add(environment,20,165,710,24)
        let addButton=NSButton(title:"Add Server (disabled initially)",target:self,action:#selector(addServer(_:)));addButton.bezelStyle = .rounded;add(addButton,20,125,270,30)
        let save=NSButton(title:"Save",target:self,action:#selector(save(_:)));save.bezelStyle = .rounded;add(save,610,125,120,30)
        status.maximumNumberOfLines=3;add(status,20,25,710,85)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.global().async {
            let data=command("integrations")
            DispatchQueue.main.async {
                if let error=data["error"] as? String {self.status.stringValue=error;return}
                self.config=data;self.rows=data["servers"] as? [[String:Any]] ?? []
                self.searchProvider.selectItem(at:(data["search_provider"] as? String)=="tavily" ? 1:0)
                for (name,b) in self.toggles {b.state=(data[name] as? Bool ?? false) ? .on : .off}
                self.status.stringValue="Saved keys: Brave \((data["search_key_saved"] as? Bool ?? false) ? "yes":"no"), Tavily \((data["tavily_key_saved"] as? Bool ?? false) ? "yes":"no"). Thinking text is separated from answers; signatures are kept opaque."
                self.render()
            }
        }
    }
    func render() {
        for v in list.arrangedSubviews {list.removeArrangedSubview(v);v.removeFromSuperview()}
        for (index,row) in rows.enumerated() {
            let view=NSView(frame:NSRect(x:0,y:0,width:690,height:28))
            let b=NSButton(checkboxWithTitle:"\(row["id"] as? String ?? "") — \(row["command"] as? String ?? "")",target:self,action:#selector(toggle(_:)))
            b.frame=NSRect(x:0,y:0,width:570,height:26);b.state=(row["enabled"] as? Bool ?? false) ? .on : .off;b.tag=index
            let remove=NSButton(title:"Remove",target:self,action:#selector(remove(_:)));remove.tag=index;remove.frame=NSRect(x:585,y:0,width:90,height:26);remove.bezelStyle = .rounded
            view.addSubview(b);view.addSubview(remove);list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant:690).isActive=true;view.heightAnchor.constraint(equalToConstant:28).isActive=true
        }
        list.frame=NSRect(x:0,y:0,width:695,height:max(160,rows.count*35))
    }
    @objc func toggle(_ sender:NSButton){rows[sender.tag]["enabled"]=sender.state == .on}
    @objc func remove(_ sender:NSButton){rows.remove(at:sender.tag);render()}
    @objc func addServer(_ sender:Any?) {
        do {
            let args=try JSONSerialization.jsonObject(with:Data((arguments.stringValue.isEmpty ? "[]" : arguments.stringValue).utf8))
            let env=try JSONSerialization.jsonObject(with:Data((environment.stringValue.isEmpty ? "{}" : environment.stringValue).utf8))
            guard let a=args as? [String],let e=env as? [String:String],executable.stringValue.hasPrefix("/"),!id.stringValue.isEmpty else {throw NSError(domain:"MCP",code:1,userInfo:[NSLocalizedDescriptionKey:"Specify ID, absolute executable, JSON argument array and environment object."])}
            rows.append(["id":id.stringValue,"command":executable.stringValue,"args":a,"env":e,"enabled":false]);render()
            id.stringValue="";executable.stringValue="";arguments.stringValue="";environment.stringValue=""
            status.stringValue="Added disabled. Check its box only if you trust it, then Save."
        }catch{status.stringValue=error.localizedDescription}
    }
    @objc func save(_ sender:Any?) {
        var out:[String:Any]=["servers":rows,"search_api_key":key.stringValue,"clear_search_key":clearKey.state == .on,"tavily_api_key":tavily.stringValue,
            "clear_tavily_key":clearTavily.state == .on,"search_provider":searchProvider.indexOfSelectedItem==1 ? "tavily":"brave"]
        for (k,v) in toggles {out[k]=v.state == .on}
        let a=NSAlert();a.messageText="Save tool configuration?";a.informativeText="Enabled custom executables run with your relay account's permissions when chats use tools. Do not enable untrusted servers.";a.addButton(withTitle:"Save");a.addButton(withTitle:"Cancel")
        if a.runModal() != .alertFirstButtonReturn{return}
        status.stringValue="Saving…"
        DispatchQueue.global().async {
            let result=command("integrations-save",out)
            DispatchQueue.main.async {self.status.stringValue=result["error"] as? String ?? "Saved. New chats/turns use the new tool configuration.";self.key.stringValue="";self.tavily.stringValue="";self.clearKey.state = .off;self.clearTavily.state = .off}
        }
    }
}
