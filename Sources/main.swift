import AppKit
import SwiftUI
import PDFKit
import Carbon.HIToolbox

/// The modifier keys that open Dial, saved in user defaults. fn + control unless changed in Settings.
enum Shortcut {
    static let standard: NSEvent.ModifierFlags = [.control, .function]
    static let keys: [(flag: NSEvent.ModifierFlags, label: String, name: String)] = [
        (.function, "fn", "fn"), (.control, "⌃ Control", "control"), (.option, "⌥ Option", "option"),
        (.command, "⌘ Command", "command"), (.shift, "⇧ Shift", "shift"),
    ]
    static var current: NSEvent.ModifierFlags {
        valid(NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "shortcut"))))
    }
    /// Two keys at least, so a plain Shift-click or Command-click never opens the ring.
    static func valid(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags { count(flags) >= 2 ? flags : standard }
    static func count(_ flags: NSEvent.ModifierFlags) -> Int { keys.filter { flags.contains($0.flag) }.count }
    static func name(_ flags: NSEvent.ModifierFlags) -> String {
        keys.filter { flags.contains($0.flag) }.map(\.name).joined(separator: " + ")
    }
}

/// Paths from an AppleScript list, one item each, so a file name containing a line break stays one file.
func paths(in list: NSAppleEventDescriptor?) -> [String] {
    guard let list, list.numberOfItems > 0 else { return [] }
    return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }.filter { $0.hasPrefix("/") }
}

/// The shortcut keys pressed together and released with no other key in between.
/// Firing on release keeps fn + control + arrow (window tiling) and control + F-keys working as before.
struct ChordDetector {
    var keys = Shortcut.standard
    private var armedAt: TimeInterval?

    mutating func keyDown() { armedAt = nil }

    /// True when the chord was just tapped.
    mutating func flagsChanged(_ raw: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        let flags = raw.intersection([.command, .option, .control, .shift, .function])
        if flags == keys {
            if armedAt == nil { armedAt = time }
        } else if flags.isEmpty, let start = armedAt {
            armedAt = nil
            return time - start < 1.0
        } else if !flags.isSubset(of: keys) {
            armedAt = nil
        }
        return false
    }
}

struct SettingsView: View {
    @AppStorage("shortcut") private var raw = Int(Shortcut.standard.rawValue)
    private var flags: NSEvent.ModifierFlags { Shortcut.valid(NSEvent.ModifierFlags(rawValue: UInt(raw))) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    ForEach(Shortcut.keys, id: \.name) { key in
                        let on = flags.contains(key.flag)
                        let tap = {
                            let next = on ? flags.subtracting(key.flag) : flags.union(key.flag)
                            if Shortcut.count(next) >= 2 { raw = Int(next.rawValue) }
                        }
                        Button(action: tap) {
                            Text(key.label)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            } header: {
                Text("Open Dial with")
            } footer: {
                Text("Select files in Finder, then tap and release \(Shortcut.name(flags)) together. Pick at least two keys.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Use fn + control") { raw = Int(Shortcut.standard.rawValue) }
                    .disabled(flags == Shortcut.standard)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = MenuModel()
    var panel: MenuPanel!
    var status: NSStatusItem!
    var hintItem: NSMenuItem!
    var accessItem: NSMenuItem!
    var settings: NSWindow?
    var busy = false
    var chord = ChordDetector()
    var monitors: [Any] = []
    var keyMonitor: Any?
    var backdrop: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setBusy(false)
        let menu = NSMenu()
        menu.delegate = self
        hintItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        accessItem = menu.addItem(withTitle: "Allow Accessibility access…", action: #selector(openAccessibility), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu

        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 372),  // wide enough for the caption
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let host = NSHostingView(rootView: RadialMenuView(m: model))
        host.sizingOptions = []
        panel.contentView = host

        model.close = { [weak self] in self?.hide() }
        model.run = { [weak self] action, files in self?.perform(action, files) }

        if CommandLine.arguments.contains("--demo") { return demo() }
        startTrigger()
    }

    // MARK: Trigger

    func startTrigger() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        installMonitors()
        accessItem.isHidden = trusted
        guard !trusted else { return }
        // Global key monitors only start delivering once access is granted: reinstall then.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted(), let self else { return }
            timer.invalidate()
            self.installMonitors()
            self.accessItem.isHidden = true
        }
    }

    func installMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        let onFlags: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            self.chord.keys = Shortcut.current  // picks up Settings changes right away
            guard self.chord.flagsChanged(e.modifierFlags, at: e.timestamp) else { return }
            self.trigger()
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: onFlags),
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in self?.chord.keyDown() },
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in onFlags(e); return e },
        ].compactMap { $0 }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func menuWillOpen(_ menu: NSMenu) {
        hintItem.title = "Select files in Finder, then tap \(Shortcut.name(Shortcut.current))"
    }

    @objc func openSettings() {
        if settings == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Dial Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }

    func trigger() {
        if panel.isVisible { return hide() }
        guard !busy else { return NSSound.beep() }  // one action at a time, so two runs never pick the same output name
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return NSSound.beep() }
        let files = finderSelection()
        guard !files.isEmpty else { return NSSound.beep() }
        show(files, at: NSEvent.mouseLocation)
    }

    func finderSelection() -> [URL] {
        let source = """
        tell application "Finder"
            set out to {}
            repeat with f in (get selection)
                set end of out to POSIX path of (f as alias)
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        let list = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Dial: couldn't read the Finder selection: \(error)") }
        return paths(in: list).map { URL(fileURLWithPath: $0) }
    }

    // MARK: Panel

    func show(_ files: [URL], at point: NSPoint) {
        model.selection = files
        model.category = nil
        model.hot = nil
        model.pressed = nil
        model.appeared = false

        let size = panel.frame.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - (size.height - 160))  // ring centre on the point
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX), v.maxX - size.width)
            origin.y = min(max(origin.y, v.minY), v.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        withAnimation(.smooth(duration: 0.25)) { model.appeared = true }

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if backdrop == nil { hide() }
    }

    func handle(_ e: NSEvent) -> NSEvent? {
        chord.keyDown()
        switch Int(e.keyCode) {
        case kVK_Escape: model.back()
        case kVK_RightArrow, kVK_DownArrow: model.step(1)
        case kVK_LeftArrow, kVK_UpArrow: model.step(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter: if let h = model.hot { model.choose(h) }
        default:
            guard let c = e.charactersIgnoringModifiers, let n = Int(c), n >= 1 else { return e }
            model.choose(n - 1)
        }
        return nil
    }

    // MARK: Run

    func perform(_ action: Action, _ files: [URL]) {
        hide()
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try action.run(files) }
            DispatchQueue.main.async { [self] in
                setBusy(false)
                switch result {
                case .success(let outputs):
                    NSSound(named: "Pop")?.play()
                    if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                case .failure(let error):
                    NSApp.activate()
                    let alert = NSAlert()
                    alert.messageText = "\(action.title) didn't work"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        status.button?.image = NSImage(systemSymbolName: busy ? "hourglass" : "circle.circle", accessibilityDescription: "Dial")
    }

    // MARK: Demo

    /// Dial --demo [--dark] [--backdrop img] [--level PDF] [--hot N] [--press N] file…
    /// Opens the menu in a fixed state over a known backdrop, and prints the area to capture.
    func demo() {
        var args = Array(CommandLine.arguments.drop { $0 != "--demo" }.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            defer { args.removeSubrange(i...(i + 1)) }
            return args[i + 1]
        }
        let dark = args.firstIndex(of: "--dark").map { args.remove(at: $0) } != nil
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let image = take("--backdrop"), level = take("--level")
        let hot = take("--hot").flatMap(Int.init), press = take("--press").flatMap(Int.init)

        let screen = NSScreen.main!.frame
        let frame = NSRect(x: screen.midX - 260, y: screen.midY - 240, width: 520, height: 480)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.contentView = NSHostingView(rootView: DemoBackdrop(image: image))
        window.orderFrontRegardless()
        backdrop = window

        show(args.map { URL(fileURLWithPath: $0) }, at: NSPoint(x: frame.midX, y: frame.midY + 26))
        model.appeared = true
        model.category = catalog.first { $0.title == level }
        model.hot = hot ?? press
        model.pressed = press
        print("CAPTURE \(Int(frame.minX)),\(Int(screen.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)
    }
}

/// Busy content behind the menu: a photo plus dense text, the worst case for glass legibility.
struct DemoBackdrop: View {
    let image: String?
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image, let ns = NSImage(contentsOfFile: image) {
                Image(nsImage: ns).resizable().scaledToFill()
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            Text(String(repeating: "Quarterly report draft — revenue grew in every region, with the strongest gains in services. ", count: 14))
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .padding(24)
                .frame(width: 520, alignment: .leading)
        }
        .frame(width: 520, height: 480)
        .clipped()
    }
}

// MARK: - Self-test: Dial --selftest <folder of sample files>

func valid(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
    if isDir.boolValue { return !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty }
    switch url.pathExtension.lowercased() {
    case "pdf": return (PDFDocument(url: url)?.pageCount ?? 0) > 0
    case "jpg", "png", "heic", "webp", "gif", "tiff":
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
    case "txt": return true  // an image-only PDF has no text
    default: return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }
}

func selfTest(_ samples: URL) -> Int32 {
    let fm = FileManager.default
    let all = ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? [])
        .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var failed = 0
    func check(_ ok: Bool, _ label: String) {
        print((ok ? "PASS  " : "FAIL  ") + label)
        if !ok { failed += 1 }
    }

    // fn + control tap opens; other keys or modifiers in between cancel it.
    func tapped(_ steps: [Any], keys: NSEvent.ModifierFlags = Shortcut.standard) -> Bool {
        var d = ChordDetector(), fired = false, t = 0.0
        d.keys = keys
        for s in steps {
            t += 0.05
            if let f = s as? NSEvent.ModifierFlags { fired = d.flagsChanged(f, at: t) || fired } else { d.keyDown() }
        }
        return fired
    }
    let ctrl: NSEvent.ModifierFlags = .control, fn: NSEvent.ModifierFlags = .function, both: NSEvent.ModifierFlags = [.control, .function]
    check(tapped([ctrl, both, ctrl, NSEvent.ModifierFlags()]), "fn + control tap opens")
    check(tapped([fn, both, fn, NSEvent.ModifierFlags()]), "control + fn tap (other order) opens")
    check(!tapped([ctrl, both, "arrow", NSEvent.ModifierFlags()]), "fn + control + arrow does not open")
    check(!tapped([ctrl, both, NSEvent.ModifierFlags([.control, .function, .shift]), NSEvent.ModifierFlags()]), "adding shift cancels")
    check(!tapped([ctrl, NSEvent.ModifierFlags()]), "control alone does not open")

    // Finder selection: a line break inside a name doesn't split it into two files.
    let sel = NSAppleScript(source: "return {\"/tmp/a\" & linefeed & \"/etc/passwd\", \"/tmp/b\"}")?.executeAndReturnError(nil)
    check(paths(in: sel) == ["/tmp/a\n/etc/passwd", "/tmp/b"], "a line break in a file name stays one file")
    check(paths(in: NSAppleScript(source: "return {}")?.executeAndReturnError(nil)).isEmpty, "empty selection reads as no files")

    // A shortcut picked in Settings replaces fn + control.
    let optCmd: NSEvent.ModifierFlags = [.option, .command]
    check(tapped([NSEvent.ModifierFlags.option, optCmd, NSEvent.ModifierFlags()], keys: optCmd), "option + command opens when chosen")
    check(!tapped([ctrl, both, NSEvent.ModifierFlags()], keys: optCmd), "fn + control no longer opens then")
    check(Shortcut.valid(.shift) == Shortcut.standard, "a one-key shortcut falls back to fn + control")
    check(Shortcut.name(optCmd) == "option + command", "shortcut name reads option + command")

    // A mixed selection only offers what can run on it.
    if let pdf = all.first(where: { kind(of: $0) == .pdf }), let mp4 = all.first(where: { kind(of: $0) == .video }),
       let img = all.first(where: { kind(of: $0) == .image }) {
        check(usableCategories(for: [pdf, mp4]).map(\.title) == ["PDF", "Video", "General"], "PDF + MP4 shows PDF, Video, General")
        check(!usableActions(catalog[0], for: [pdf, mp4]).contains { $0.title == "Merge" }, "PDF + MP4 hides Merge")
        check(usableActions(catalog[0], for: [pdf, img]).contains { $0.title == "Merge" }, "PDF + image offers Merge")
        check(usableActions(catalog[0], for: [pdf]).allSatisfy { $0.title != "Merge" }, "one PDF hides Merge")
    }

    for c in catalog {
        for a in c.actions where a.title != "Copy path" {
            let work = fm.temporaryDirectory.appendingPathComponent("dial-test-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let copies = all.map { src -> URL in
                // A leading "-" proves no tool reads a file name as an option.
                let dst = work.appendingPathComponent("-" + src.lastPathComponent)
                try? fm.copyItem(at: src, to: dst)
                return dst
            }
            var files = inputs(a, in: c, from: copies)
            if c.kind == .general { files = Array(files.prefix(2)) }
            let label = "\(c.title) › \(a.title)"
            guard files.count >= a.minFiles else { check(false, "\(label): no sample input"); continue }
            do {
                let out = try a.run(files)
                check(!out.isEmpty && out.allSatisfy(valid), "\(label) → \(out.map(\.lastPathComponent).joined(separator: ", "))")
            } catch {
                check(false, "\(label): \(error.localizedDescription)")
            }
        }
    }
    print(failed == 0 ? "\nAll passed" : "\n\(failed) failed")
    return failed == 0 ? 0 : 1
}

// MARK: - Entry

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
    exit(selfTest(URL(fileURLWithPath: args[i + 1])))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
