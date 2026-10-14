import AppKit
import DerivateKit
import ServiceManagement

/// Derivate makes your passwords from your name and secret, in the menu
/// bar. Its icon, or its shortcut from any app (⌃⌘P at first), opens a
/// panel where typing a site's name finds its password, and Enter copies
/// it. It makes them as Spectre does, so they are the same in both apps.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(store: .standard())
    private lazy var panel = PanelController(model: model)
    private lazy var hotKey = HotKey { [unowned self] in self.panel.toggle(below: nil) }
    private var statusItem: NSStatusItem?
    private var copiedTitle: Task<Void, Never>?
    private var agentServer: AgentServer?
    private var agentPort = 0

    static func main() {
        // `Derivate mcp` is the MCP server that agents run.
        if CommandLine.arguments.dropFirst().first == "mcp" {
            StdioBridge.run()
        }
        // SpectreBar was this app's name: take over its data, and open at
        // login as SpectreBar did.
        if ProcessInfo.processInfo.environment["DERIVATE_DIR"] == nil, Store.moveFromSpectreBar() {
            try? SMAppService.mainApp.register()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: "Derivate")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        model.showPanel = { [unowned self] centered in
            panel.show(below: centered ? nil : statusItemFrame)
        }
        model.closePanel = { [unowned self] in panel.close() }
        model.focusTopField = { [unowned self] in panel.focusTopField() }
        model.didCopy = { [unowned self] in showCopied() }
        model.registerShortcut = { [unowned self] shortcut in
            do {
                try hotKey.register(shortcut)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let error = model.registerShortcut(model.settings.shortcut) {
            NSLog("Derivate: shortcut %@: %@", model.settings.shortcut?.text ?? "none", error)
            model.shortcutError = error
        }
        model.serveAgents = { [unowned self] settings in serveAgents(settings) }
        serveAgents(model.settings)
        if model.users.isEmpty {
            panel.show(below: nil) // the first run shows what the app is
        }
    }

    /// Opening the app again, from Finder or `open`, opens its panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show(below: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.lock()
    }

    /// Runs the server for agents while the settings allow agents, on the
    /// port they name, with their key.
    private func serveAgents(_ settings: Settings) {
        guard settings.agents != .off else {
            agentServer?.stop()
            agentServer = nil
            model.agentServerError = nil
            return
        }
        if let agentServer, agentPort == settings.agentPort {
            agentServer.key = settings.agentKey ?? ""
            return
        }
        agentServer?.stop()
        let server = model.makeAgentServer()
        agentServer = server
        agentPort = settings.agentPort
        model.agentServerError = nil
        Task {
            do {
                _ = try await server.start(port: UInt16(clamping: settings.agentPort))
            } catch {
                guard agentServer === server else { return }
                agentServer = nil
                model.agentServerError = "Derivate could not start its server for agents. \(error.localizedDescription)"
            }
        }
    }

    private var statusItemFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.close()
            statusItem?.menu = statusMenu()
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil // clicks toggle the panel again
        } else {
            panel.toggle(below: statusItemFrame)
        }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
        }
        add("Open Derivate", #selector(openPanel))
        add("Lock", #selector(lock), enabled: model.isUnlocked)
        menu.addItem(.separator())
        add("Import Spectre Export…", #selector(importExport))
        add("Export for Spectre…", #selector(exportUser), enabled: model.exportUser != nil)
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings))
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = model.opensAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Derivate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openPanel() { panel.show(below: statusItemFrame) }
    @objc private func lock() { model.lock() }
    @objc private func importExport() { model.chooseImport() }
    @objc private func exportUser() { model.chooseExport() }
    @objc private func toggleOpenAtLogin() { model.opensAtLogin.toggle() }

    @objc private func openSettings() {
        panel.show(below: statusItemFrame)
        model.screen = .settings
    }

    /// Shows "Copied" next to the menu bar icon for a moment.
    private func showCopied() {
        statusItem?.length = NSStatusItem.variableLength
        statusItem?.button?.title = " Copied"
        copiedTitle?.cancel()
        copiedTitle = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            statusItem?.button?.title = ""
            statusItem?.length = NSStatusItem.squareLength
        }
    }

    /// An app without a menu bar still needs an Edit menu: its key
    /// equivalents make ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z work in text fields.
    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }
}
