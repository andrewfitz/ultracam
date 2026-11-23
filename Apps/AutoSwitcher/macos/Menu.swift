import AppKit
import UniformTypeIdentifiers

@main
final class SwitcherMenu: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = SwitcherMenu()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var service: Process?
    private var panel: NSPanel?
    private var observer: Process?
    private var routes: [String] = []
    private var current: String?
    private var profile: URL?
    private var keys: URL?
    private var hostClock = false
    private var status = "Stopped"
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Auto Switcher/Sessions")

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: "rectangle.2.swap", accessibilityDescription: "Auto Switcher")
        if item.button?.image == nil { item.button?.title = "Switcher" }
        refresh()
        showPanel()
    }

    private func refresh() {
        let menu = NSMenu()
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        func action(_ name: String, _ selector: Selector, enabled: Bool = true) {
            let row = menu.addItem(withTitle: name, action: enabled ? selector : nil, keyEquivalent: "")
            row.target = self
        }
        let idle = service == nil
        action("Open controls…", #selector(showPanel))
        action("Profile: " + (profile?.lastPathComponent ?? "Talking head") + "…", #selector(selectProfile), enabled: idle)
        action("Hotkeys: " + (keys?.lastPathComponent ?? "Off") + "…", #selector(selectKeys), enabled: idle)
        if keys != nil { action("Disable hotkeys", #selector(clearKeys), enabled: idle) }
        action("Clock: " + (hostClock ? "Host" : "Server"), #selector(toggleClock), enabled: idle)
        if let current, !idle {
            menu.addItem(.separator())
            menu.addItem(withTitle: "On air: " + current, action: nil, keyEquivalent: "")
            for route in routes where route != current {
                let row = menu.addItem(withTitle: "Take " + route, action: #selector(takeRoute(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = route
            }
        }
        menu.addItem(.separator())
        action(idle ? "Start server" : "Stop server", #selector(toggle))
        action("Show session journals", #selector(reveal))
        action("Quit Auto Switcher", #selector(quit))
        item.menu = menu
        updatePanel()
    }

    @objc private func showPanel() {
        if panel == nil {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel?.title = "Auto Switcher"
            panel?.isReleasedWhenClosed = false
            panel?.center()
        }
        updatePanel()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func updatePanel() {
        guard let panel else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        let state = NSTextField(labelWithString: current.map { "On air · " + $0 } ?? status)
        state.font = .systemFont(ofSize: 19, weight: .semibold)
        stack.addArrangedSubview(state)
        let idle = service == nil
        func button(_ label: String, _ action: Selector, enabled: Bool = true) -> NSButton {
            let button = NSButton(title: label, target: self, action: action)
            button.isEnabled = enabled
            return button
        }
        stack.addArrangedSubview(button("Profile · " + (profile?.lastPathComponent ?? "Talking head"), #selector(selectProfile), enabled: idle))
        stack.addArrangedSubview(button("Clock · " + (hostClock ? "Host" : "Server"), #selector(toggleClock), enabled: idle))
        stack.addArrangedSubview(button("Hotkeys · " + (keys?.lastPathComponent ?? "Off"), #selector(selectKeys), enabled: idle))
        stack.addArrangedSubview(button(idle ? "Start server" : "Stop server", #selector(toggle)))
        if !idle && !routes.isEmpty {
            let targets = NSPopUpButton(frame: .zero, pullsDown: true)
            targets.addItem(withTitle: "Take route")
            for route in routes where route != current {
                let row = NSMenuItem(title: route, action: #selector(takeRoute(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = route
                targets.menu?.addItem(row)
            }
            stack.addArrangedSubview(targets)
        }
        stack.addArrangedSubview(button("Show session journals", #selector(reveal)))
        panel.contentView = stack
    }

    private func choose(_ title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Bundle.main.resourceURL?.appendingPathComponent("profiles")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
    @objc private func selectProfile() { if let url = choose("Choose switching profile") { profile = url }; refresh() }
    @objc private func selectKeys() { if let url = choose("Choose hotkey mapping") { keys = url }; refresh() }
    @objc private func clearKeys() { keys = nil; refresh() }
    @objc private func toggleClock() { hostClock.toggle(); refresh() }
    @objc private func reveal() { NSWorkspace.shared.open(folder) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { if service?.isRunning == true { service?.terminate() } }

    @objc private func takeRoute(_ row: NSMenuItem) {
        guard let route = row.representedObject as? String else { return }
        let take = Process()
        take.executableURL = Bundle.main.url(forAuxiliaryExecutable: "auto-switcher")
        take.arguments = ["take", "--", route]
        do { try take.run() } catch { status = error.localizedDescription; refresh() }
    }

    private func observe(_ owner: Process) {
        let process = Process()
        process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "auto-switcher")
        process.arguments = ["watch"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { status = error.localizedDescription; refresh(); return }
        observer = process
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            var last: String?
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let data = buffer[..<end]
                    buffer.removeSubrange(...end)
                    guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let status = event["status"] as? [String: Any],
                          let route = status["current_camera_id"] as? String, route != last else { continue }
                    last = route
                    let config = event["config"] as? [String: Any]
                    let ids = [config?["anchor_camera_id"], config?["emphasis_camera_id"]].compactMap { $0 as? String }
                        + (config?["additional_targets"] as? [String] ?? [])
                    DispatchQueue.main.async {
                        guard let self, self.service === owner else { return }
                        self.current = route
                        if !ids.isEmpty {
                            self.routes = ids
                            self.status = "Listening on 127.0.0.1:48765"
                        }
                        self.refresh()
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.service === owner, owner.isRunning else { return }
                self.observer = nil
                self.current = nil
                self.routes = []
                self.status = "Reconnecting to server…"
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard self.service === owner, owner.isRunning else { return }
                    self.observe(owner)
                }
            }
        }
    }

    @objc private func toggle() {
        if let service { if service.isRunning { service.terminate() }; return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "auto-switcher")
            process.currentDirectoryURL = folder
            var args = ["serve"]
            if !hostClock { args.append("--clock") }
            if let profile { args += ["--config", profile.path] }
            if let keys { args += ["--hotkeys", keys.path] }
            process.arguments = args
            let errors = Pipe()
            let ready = Pipe()
            process.standardOutput = ready
            ready.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                guard !data.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.service === process else { return }
                    self.status = "Listening on 127.0.0.1:48765"
                    self.observe(process)
                    self.refresh()
                }
            }
            process.standardError = errors
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard let self, self.service === process else { return }
                    self.status = message
                    self.refresh()
                }
            }
            process.terminationHandler = { [weak self] child in
                DispatchQueue.main.async {
                    guard let self, self.service === child else { return }
                    if self.observer?.isRunning == true { self.observer?.terminate() }
                    self.observer = nil
                    self.current = nil
                    self.routes = []
                    self.service = nil
                    if child.terminationStatus == 0 || child.terminationReason == .uncaughtSignal { self.status = "Stopped" }
                    else if ["Starting server…", "Listening on 127.0.0.1:48765", "Reconnecting to server…"].contains(self.status) {
                        self.status = "Server exited (\(child.terminationStatus))"
                    }
                    self.refresh()
                }
            }
            try process.run()
            service = process
            status = "Starting server…"
        } catch { status = error.localizedDescription }
        refresh()
    }
}
