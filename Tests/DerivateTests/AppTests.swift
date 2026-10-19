import AppKit
import Carbon.HIToolbox
import Foundation
import DerivateKit
import SwiftUI
import Testing
@testable import Derivate

private let robert = "Robert Lee Mitchell"
private let banana = "banana colored duckling"

/// The app's state with its files in a new folder, and a clipboard of its
/// own: the tests leave the Mac's alone.
@MainActor
private final class Harness {
    let folder: URL
    let model: AppModel
    var copied: [String] = []
    var closed = 0

    init(folder: URL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) {
        self.folder = folder
        model = AppModel(store: Store(folder: folder))
        model.clipboard = { [unowned self] in copied.append($0) }
        model.closePanel = { [unowned self] in closed += 1 }
        model.prepare()
    }

    /// Waits for scrypt, which runs off the main thread.
    func settle() async {
        while model.lockForm.busy {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @discardableResult
    func press(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false,
                                     keyCode: UInt16(keyCode))!
        return model.handleKey(event)
    }

    func createRobert() async {
        model.lockForm.name = robert
        model.lockForm.masterPassword = banana
        model.lockForm.confirm = banana
        model.unlock()
        await settle()
    }
}

@MainActor
struct AppTests {
    @Test func newUserAndSites() async throws {
        let h = Harness()
        let model = h.model
        #expect(model.lockForm.isCreating)

        model.lockForm.name = robert
        model.lockForm.masterPassword = banana
        model.lockForm.confirm = "banana colored ducklin"
        model.unlock()
        #expect(model.lockForm.error == "The two master passwords are different. Type them again.")

        await h.createRobert()
        #expect(model.isUnlocked)
        #expect(model.user?.name == robert)
        #expect(FileManager.default.fileExists(atPath: h.folder.appending(path: "users/\(robert).mpjson").path))

        // A name the user has no site of is a new site, whose password
        // Enter copies and keeps.
        model.query = "masterpasswordapp.com"
        let draft = try #require(model.chosen)
        #expect(model.isDraft(draft))
        #expect(model.password(of: draft) == "Jejr5[RepuSosp")
        #expect(h.press(kVK_Return))
        #expect(h.copied.last == "Jejr5[RepuSosp")
        #expect(h.closed == 1)
        #expect(model.site(named: "masterpasswordapp.com")?.uses == 1)

        // The login name Spectre makes for a site does not show, nor copy:
        // only one the user sets.
        let site = try #require(model.site(named: "masterpasswordapp.com"))
        #expect(try model.key?.login(for: site, of: #require(model.user)) == "wohzaqage")
        #expect(model.login(of: site) == nil)
        h.press(kVK_Return, .shift)
        #expect(h.copied.count == 1)
        model.setLogin("robert@example.com", for: site.name)
        #expect(model.login(of: try #require(model.site(named: site.name))) == "robert@example.com")
        h.press(kVK_Return, .shift)
        #expect(h.copied.last == "robert@example.com")
        let saved = try User(importing: Data(contentsOf: h.folder.appending(path: "users/\(robert).mpjson")))
        #expect(saved.site(named: site.name)?.loginType == .personal)
        model.setLogin("", for: site.name)
        #expect(model.login(of: try #require(model.site(named: site.name))) == nil)

        // Another site, then the arrows choose between them.
        model.prepare()
        model.query = "example.com"
        h.press(kVK_Return)
        model.prepare()
        #expect(model.results.map(\.name) == ["example.com", "masterpasswordapp.com"])
        h.press(kVK_DownArrow)
        h.press(kVK_Return)
        #expect(h.copied.last == "Jejr5[RepuSosp")

        // Typing filters, the letters in order too; ⌘E opens the details.
        model.prepare()
        model.query = "mpw"
        #expect(model.results.map(\.name) == ["masterpasswordapp.com"])
        h.press(kVK_ANSI_E, .command)
        #expect(model.screen == .site(name: "masterpasswordapp.com"))
        h.press(kVK_Escape)
        #expect(model.screen == .sites)

        // Escape clears the search, then closes the panel.
        h.press(kVK_Escape)
        #expect(model.query.isEmpty)
        h.press(kVK_Escape)
        #expect(h.closed == 5)

        // Only the user locks it. A wrong secret does not unlock.
        h.press(kVK_ANSI_L, .command)
        #expect(!model.isUnlocked)
        model.lockForm.masterPassword = "wrong secret"
        model.unlock()
        await h.settle()
        #expect(model.lockForm.error == "That is not the master password of \(robert).")
        model.lockForm.masterPassword = banana
        model.unlock()
        await h.settle()
        #expect(model.isUnlocked)

        // The sites outlive the app.
        let again = Harness(folder: h.folder)
        #expect(again.model.users.count == 1)
        #expect(again.model.users.first?.sites.count == 2)
        #expect(again.model.lockForm.who == robert)
    }

    @Test func importExport() async throws {
        var user = User(name: robert)
        let key = try user.unlock(secret: banana)
        let stored = try key.encrypt("hunter2", algorithm: .v3)
        var bank = user.newSite(named: "bank.example")
        bank.type = .personal
        bank.state = stored
        var spectre = user.newSite(named: "spectre.app")
        spectre.counter = 3
        user.sites = [spectre, bank]
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mpjson")
        try user.exportData().write(to: file)

        let h = Harness()
        let model = h.model
        model.importFile(at: file)
        #expect(model.lockForm.pending?.sites.count == 2)
        model.lockForm.masterPassword = "not the secret"
        model.unlock()
        await h.settle()
        #expect(model.lockForm.error == "That is not the master password of \(robert).")
        #expect(model.users.isEmpty)

        model.lockForm.masterPassword = banana
        model.unlock()
        await h.settle()
        #expect(model.user?.sites.count == 2)
        #expect(model.toast == "Imported 2 sites.")
        model.query = "bank"
        h.press(kVK_Return)
        #expect(h.copied.last == "hunter2")
    }

    /// The keyboard goes to the panel's top text field as it opens: the
    /// search, or the lock screen's first field.
    @Test func panelFocusesTheTopField() async throws {
        let h = Harness()
        let panel = Panel()
        panel.contentView = PanelContent(model: h.model)
        func focused() -> NSTextField? { (panel.firstResponder as? NSText)?.delegate as? NSTextField }
        func placeholder() -> String? {
            focused().flatMap { $0.placeholderString ?? $0.placeholderAttributedString?.string }
        }

        panel.focusTopTextField()
        #expect(placeholder() == "As Spectre has it")

        await h.createRobert()
        h.model.lock()
        panel.focusTopTextField()
        #expect(focused() is NSSecureTextField)

        h.model.lockForm.masterPassword = banana
        h.model.unlock()
        await h.settle()
        panel.focusTopTextField()
        #expect(placeholder() == "Site name")
        panel.close()
    }

    /// The secret unlocks as soon as it is typed, without Enter: a pause
    /// checks it. A secret that is not the user's, or not yet, shows
    /// nothing.
    @Test func unlocksWithoutEnter() async throws {
        let h = Harness()
        let model = h.model
        await h.createRobert()
        model.lock()

        model.lockForm.masterPassword = String(banana.dropLast())
        model.masterPasswordChanged()
        try await Task.sleep(for: .seconds(4)) // scrypt is slow in debug builds
        #expect(!model.isUnlocked)
        #expect(model.lockForm.error == nil)
        #expect(model.lockForm.masterPassword == String(banana.dropLast()))

        model.lockForm.masterPassword = banana
        model.masterPasswordChanged()
        for _ in 0..<200 where !model.isUnlocked {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.isUnlocked)
        #expect(model.lockForm.masterPassword.isEmpty)

        // A new user waits for Enter: nothing checks their secret.
        model.lock()
        model.lockForm.who = LockForm.newUser
        model.lockForm.name = "Someone New"
        model.lockForm.masterPassword = banana
        model.masterPasswordChanged()
        try await Task.sleep(for: .seconds(1))
        #expect(!model.isUnlocked)
        #expect(model.users.count == 1)
    }

    /// The panel is as tall as the lock screen's fields, and takes its full
    /// height for the sites, with its top edge where it was.
    @Test func panelFitsTheLockScreen() async throws {
        let h = Harness()
        await h.createRobert()
        h.model.lock()
        let panel = Panel()
        panel.contentView = PanelContent(model: h.model) { [weak panel] in panel?.fit(height: $0) }
        panel.setFrameOrigin(NSPoint(x: 100, y: 100))
        let top = panel.frame.maxY
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.frame.height < 360)
        #expect(panel.frame.maxY == top)

        h.model.lockForm.masterPassword = banana
        h.model.unlock()
        await h.settle()
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.frame.height == PanelMetrics.size.height)
        #expect(panel.frame.maxY == top)
        panel.close()
    }

    /// A new site of the name typed stays in reach when other sites match
    /// it: ⌘Enter saves it and copies its password, and ↓ gets to it.
    @Test func newSiteAmongMatches() async throws {
        let h = Harness()
        let model = h.model
        await h.createRobert()
        for name in ["trademe.co.nz", "transferwise.com", "tradezone.com.au"] {
            model.query = name
            h.press(kVK_Return)
        }
        model.prepare()
        model.query = "tr"
        #expect(model.results.count == 3)
        #expect(model.draft?.name == "tr")

        h.press(kVK_Return, .command)
        #expect(model.site(named: "tr") != nil)
        #expect(h.copied.last == model.password(of: try #require(model.site(named: "tr"))))

        // Enter still copies the first match.
        model.prepare()
        model.query = "tra"
        h.press(kVK_Return)
        #expect(h.copied.last == model.password(of: try #require(model.results.first)))
        #expect(model.site(named: "tra") == nil)

        // ↓ past the matches chooses the new site.
        model.prepare()
        model.query = "tra"
        for _ in 0..<5 { h.press(kVK_DownArrow) }
        #expect(model.chosen?.name == "tra")
        #expect(model.isDraft(try #require(model.chosen)))
    }

    /// Secrets have their own screen: files and passwords that Derivate
    /// keeps encrypted with the user's key.
    @Test func secrets() async throws {
        let h = Harness()
        let model = h.model
        await h.createRobert()
        #expect(h.press(kVK_ANSI_S, .command))
        #expect(model.screen == .secrets)
        #expect(model.secretResults.isEmpty)

        // A name typed is a new secret, which Enter opens. Derivate keeps
        // it only once it holds something.
        model.query = "Developer ID"
        h.press(kVK_Return)
        #expect(model.screen == .secret(name: "Developer ID"))
        h.press(kVK_Escape)
        #expect(model.screen == .secrets)
        #expect(model.secrets.isEmpty)

        // A file chosen for it, and its password.
        try FileManager.default.createDirectory(at: h.folder, withIntermediateDirectories: true)
        let certificate = Data((0..<3000).map { UInt8($0 % 251) })
        let original = h.folder.appending(path: "Developer ID Application.p12")
        try certificate.write(to: original)
        model.openDialog = { original }
        h.press(kVK_Return)
        model.chooseFile(for: "Developer ID")
        #expect(model.screen == .secret(name: "Developer ID"))
        #expect(model.secret(named: "Developer ID")?.file == certificate)
        #expect(model.secret(named: "Developer ID")?.fileName == "Developer ID Application.p12")
        model.updateSecret("Developer ID") { $0.password = "p12 password" }

        // Their file holds neither in the clear, and only the user reads it.
        let file = h.folder.appending(path: "secrets/\(robert).secrets")
        let stored = try Data(contentsOf: file)
        #expect(stored.starts(with: Data("Derivate secrets 1\n".utf8)))
        #expect(stored.range(of: Data("p12 password".utf8)) == nil)
        #expect(stored.range(of: certificate.prefix(32)) == nil)
        #expect(stored.range(of: Data("Developer ID".utf8)) == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // Enter saves the file, Shift+Enter copies its password.
        model.back()
        #expect(model.screen == .secrets)
        model.query = "dev"
        let saved = h.folder.appending(path: "saved.p12")
        var suggested: String?
        model.saveDialog = { name in
            suggested = name
            return saved
        }
        h.press(kVK_Return)
        #expect(suggested == "Developer ID Application.p12")
        #expect(try Data(contentsOf: saved) == certificate)
        h.press(kVK_Return, .shift)
        #expect(h.copied.last == "p12 password")

        // A file dropped on the secrets is a new secret, named as the file.
        let apiKey = h.folder.appending(path: "AuthKey_ABC123.p8")
        try Data("-----BEGIN PRIVATE KEY-----".utf8).write(to: apiKey)
        model.dropped(apiKey)
        #expect(model.screen == .secret(name: "AuthKey_ABC123"))
        model.back()
        model.dropped(apiKey)
        #expect(model.screen == .secret(name: "AuthKey_ABC123 2"))
        model.deleteSecret("AuthKey_ABC123 2")
        #expect(model.screen == .secrets)
        model.dropped(h.folder)
        #expect(model.toast?.hasSuffix("is a folder. Derivate keeps files only.") == true)

        // Enter copies the password of a secret without a file.
        model.query = "npm token"
        h.press(kVK_Return, .command)
        model.updateSecret("npm token") { $0.password = "npm_abc" }
        model.back()
        model.query = "npm"
        h.press(kVK_Return)
        #expect(h.copied.last == "npm_abc")

        // Escape clears the search, then goes back to the sites.
        h.press(kVK_Escape)
        #expect(model.query.isEmpty)
        h.press(kVK_Escape)
        #expect(model.screen == .sites)

        // Locking forgets them, and unlocking reads them again.
        model.lock()
        #expect(model.secrets.isEmpty)
        model.lockForm.masterPassword = banana
        model.unlock()
        await h.settle()
        #expect(model.secrets.map(\.name).sorted() == ["AuthKey_ABC123", "Developer ID", "npm token"])
        #expect(model.secret(named: "developer id")?.file == certificate)

        // A file that does not decrypt stays as it was.
        var broken = stored
        broken[broken.count - 1] ^= 1
        try broken.write(to: file)
        model.lock()
        model.lockForm.masterPassword = banana
        model.unlock()
        await h.settle()
        #expect(model.secrets.isEmpty)
        #expect(model.secretsError?.hasPrefix("Derivate could not read your secrets") == true)
        model.showSecrets()
        #expect(model.secretDraft == nil)
        let changed = model.updateSecret("new") { $0.password = "x" }
        #expect(!changed)
        #expect(try Data(contentsOf: file) == broken)

        // Forgetting the user deletes their secrets.
        model.forget(robert)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func shortcuts() {
        #expect(Shortcut("Ctrl+Cmd+P") == .standard)
        #expect(Shortcut.standard.text == "Ctrl+Cmd+P")
        #expect(Shortcut.standard.symbols == "⌃⌘P")
        #expect(Shortcut("Alt+Shift+Space")?.symbols == "⌥⇧Space")
        #expect(Shortcut("Cmd+F5")?.text == "Cmd+F5")
        #expect(Shortcut("P") == nil)
        #expect(Shortcut("") == nil)
    }

    /// Draws the panel's screens to PNG files in the folder that
    /// DERIVATE_SNAPSHOT names, to look at the design without a window
    /// on the screen.
    @Test func snapshot() async throws {
        guard let out = ProcessInfo.processInfo.environment["DERIVATE_SNAPSHOT"] else { return }
        for dark in [false, true] {
            let h = Harness()
            let model = h.model
            let mode = dark ? "dark" : "light"
            func shot(_ name: String) throws {
                let view = RootView().environment(model)
                    .background(Color(nsColor: dark ? .darkGray : .lightGray))
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: PanelMetrics.size)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(filePath: out).appending(path: "\(name)-\(mode).png"))
            }
            try shot("first-run")
            await h.createRobert()
            for (i, name) in ["google", "discord", "apple-centient", "pickles.com.au", "easysigns.com.au", "paypal",
                              "fairworkcommission", "demo.airwallex.com", "github.com"].enumerated() {
                var site = model.user!.newSite(named: name)
                site.lastUsed = Date.now.addingTimeInterval(-Double(i) * 3600)
                if name == "easysigns.com.au" { site.type = .maximum }
                model.user?.sites.append(site)
            }
            model.prepare()
            try shot("sites")
            model.query = "pay"
            try shot("search")
            h.press(kVK_ANSI_E, .command)
            try shot("site")
            model.screen = .settings
            try shot("settings")
            model.updateSecret("Developer ID Application") {
                $0.fileName = "Developer ID Application.p12"
                $0.file = Data(count: 3_213)
                $0.password = "correct horse battery"
            }
            model.updateSecret("App Store Connect API") {
                $0.fileName = "AuthKey_ABC123.p8"
                $0.file = Data(count: 257)
            }
            model.updateSecret("npm token") { $0.password = "npm_3f9Kq2Lr8XvTb1" }
            model.updateSecret("Recovery codes") { $0.notes = "GitHub: 1a2b-3c4d" }
            model.showSecrets()
            try shot("secrets")
            model.query = "dev"
            try shot("secrets-search")
            h.press(kVK_ANSI_E, .command)
            try shot("secret")
            model.lock()
            try shot("lock")
        }
    }
}

/// Shows the panel for a few seconds, over stripes of its own, without the
/// keyboard or the mouse, to photograph its material. DERIVATE_LIVE
/// names where: "x,y" in points from the bottom left of the main screen.
@MainActor
@Test func livePreview() async throws {
    guard let place = ProcessInfo.processInfo.environment["DERIVATE_LIVE"] else { return }
    let xy = place.split(separator: ",").compactMap { Double($0) }
    let origin = NSPoint(x: xy[0], y: xy[1])
    NSApplication.shared.setActivationPolicy(.accessory)
    if ProcessInfo.processInfo.environment["DERIVATE_LIGHT"] == "1" {
        NSApp.appearance = NSAppearance(named: .aqua)
    }
    let h = Harness()
    await h.createRobert()
    for name in ["google", "discord", "apple-centient", "pickles.com.au", "paypal", "github.com"] {
        let site = try #require(h.model.user).newSite(named: name)
        h.model.user?.sites.append(site)
    }
    h.model.prepare()
    switch ProcessInfo.processInfo.environment["DERIVATE_LIVE_SCREEN"] {
    case "site": h.model.screen = .site(name: "google")
    case "settings": h.model.screen = .settings
    case "lock": h.model.lock()
    default: break
    }

    let size = PanelMetrics.size
    let backdrop = NSWindow(contentRect: NSRect(x: origin.x - 60, y: origin.y - 60, width: size.width + 120, height: size.height + 120),
                            styleMask: .borderless, backing: .buffered, defer: false)
    backdrop.contentView = NSHostingView(rootView: VStack(spacing: 0) {
        ForEach(0..<28, id: \.self) { i in
            let colors: [Color] = [.red, .orange, .green, .blue, .purple, .white, .black]
            Text("The quick brown fox jumps over the lazy dog 0123456789")
                .font(.system(size: 15))
                .foregroundStyle(colors[(i + 3) % colors.count])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(colors[i % colors.count])
        }
    })
    backdrop.ignoresMouseEvents = true
    backdrop.orderFrontRegardless()

    let panel = Panel()
    panel.contentView = PanelContent(model: h.model) { [weak panel] in panel?.fit(height: $0) }
    panel.setFrameOrigin(origin)
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.ignoresMouseEvents = true
    panel.orderFrontRegardless()
    panel.invalidateShadow()
    try await Task.sleep(for: .seconds(0.5))
    if let mark = ProcessInfo.processInfo.environment["DERIVATE_LIVE_MARK"] {
        FileManager.default.createFile(atPath: mark, contents: nil) // the photo can be taken
    }
    try await Task.sleep(for: .seconds(3))
    panel.close()
    backdrop.close()
}
