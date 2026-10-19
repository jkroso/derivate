import AppKit
import Observation
import ServiceManagement
import DerivateKit
import UniformTypeIdentifiers

enum Screen: Equatable {
    case sites
    case site(name: String)
    case secrets
    case secret(name: String)
    case settings
}

/// The lock screen's form.
struct LockForm {
    static let newUser = "New user…"

    var who = LockForm.newUser // the user chosen, by name, or newUser
    var name = ""              // a new user's full name
    var masterPassword = ""
    var confirm = ""           // a new user's master password, again
    var busy = false           // scrypt runs
    var error: String?

    /// A Spectre export waiting for its user's master password, and the name of its
    /// file.
    var pending: User?
    var pendingFile = ""

    var isCreating: Bool { pending == nil && who == LockForm.newUser }
}

/// The state of the app and its panel. Locking is up to the user: the key
/// stays until they lock, or quit, which logging out does.
@MainActor @Observable
final class AppModel {
    private(set) var users: [User]
    /// The user unlocked, with their changes.
    var user: User?
    private(set) var key: Key?
    /// The unlocked user's secrets, decrypted.
    var secrets: [Secret] = []
    /// Why the user's secrets do not read: Derivate then leaves their file
    /// as it is.
    var secretsError: String?

    var screen = Screen.sites
    var query = ""
    var selection = 0
    var lockForm = LockForm()
    var settings: Settings {
        didSet {
            store.save(settings)
            if settings.agents != oldValue.agents || settings.agentKey != oldValue.agentKey
                || settings.agentPort != oldValue.agentPort {
                if settings.agents == .off {
                    answerAll(.off)
                }
                allowedAgents = []
                serveAgents(settings)
            }
        }
    }
    /// A message the panel shows for a moment.
    var toast: String?
    /// Changes when the panel opens, to put the keyboard in its first field.
    var opened = 0
    @ObservationIgnored private var quietUnlock: Task<Void, Never>?

    @ObservationIgnored let store: Store
    /// Opens and closes the panel.
    @ObservationIgnored var showPanel: (_ centered: Bool) -> Void = { _ in }
    @ObservationIgnored var closePanel: () -> Void = {}
    /// Puts the keyboard in the panel's top text field.
    @ObservationIgnored var focusTopField: () -> Void = {}
    /// Shows "Copied" in the menu bar.
    @ObservationIgnored var didCopy: () -> Void = {}
    /// Writes the clipboard in place of Clipboard, for tests.
    @ObservationIgnored var clipboard: ((String) -> Void)?
    /// Choose a file to open, and where to save one, in place of the
    /// dialogs, for tests.
    @ObservationIgnored var openDialog: (() -> URL?)?
    @ObservationIgnored var saveDialog: ((_ name: String) -> URL?)?
    /// Registers the shortcut with the system, and reports why it failed.
    @ObservationIgnored var registerShortcut: (Shortcut?) -> String? = { _ in nil }
    /// Starts, changes or stops the server for agents, as the settings say.
    @ObservationIgnored var serveAgents: (Settings) -> Void = { _ in }

    /// What agents wait for the user to allow. The panel shows the first.
    var agentRequests: [AgentRequest] = []
    /// Whether Enter allows the request that shows yet.
    var agentRequestReady = false
    /// Why the server for agents does not run.
    var agentServerError: String?
    @ObservationIgnored var agentAnswers: [UUID: CheckedContinuation<AgentAnswer, Never>] = [:]
    @ObservationIgnored var agentPrompt = 0
    /// The agent sessions the user allowed, until they lock.
    @ObservationIgnored var allowedAgents: Set<PeerProcess.ID> = []
    /// How long a request waits for the user.
    @ObservationIgnored var agentTimeout = Duration.seconds(120)
    /// When Derivate unlocked last. For a moment after it, Enter does not
    /// copy: the user can press it for the master password just after
    /// Derivate unlocked without it.
    @ObservationIgnored var unlockedAt: ContinuousClock.Instant?
    @ObservationIgnored var enterPause = Duration.seconds(1)

    /// The settings record the next keys pressed as the shortcut.
    private(set) var recording = false
    var shortcutError: String?

    init(store: Store) {
        self.store = store
        users = store.loadUsers()
        settings = store.loadSettings()
        if settings.agentKey == nil {
            settings.agentKey = Self.newAgentKey()
            store.save(settings)
        }
        resetLockForm()
    }

    var isUnlocked: Bool { user != nil && key != nil }

    /// Starts the panel on the sites, or the lock screen, as it opens.
    func prepare() {
        screen = .sites
        stopRecording()
        query = ""
        selection = 0
        if !lockForm.busy {
            lockForm.error = nil
        }
        opened += 1
    }

    // MARK: Locking

    func resetLockForm() {
        let pending = lockForm.pending, file = lockForm.pendingFile
        lockForm = LockForm(pending: pending, pendingFile: file)
        if let last = settings.lastUser, users.contains(where: { $0.name == last }) {
            lockForm.who = last
        } else if let first = users.first {
            lockForm.who = first.name
        }
    }

    /// Forgets the key: the panel asks for the master password again.
    func lock() {
        key?.wipe()
        key = nil
        user = nil
        secrets = []
        secretsError = nil
        allowedAgents = []
        answerAll(.locked)
        screen = .sites
        query = ""
        selection = 0
        resetLockForm()
        focusTopField()
    }

    /// Derives the key of the user the form names, off the main thread,
    /// and opens their sites if the master password is theirs.
    func unlock() {
        var form = lockForm
        guard !form.busy else { return }
        var target: User
        var creating = false
        if let pending = form.pending {
            target = pending
        } else if form.who != LockForm.newUser, let existing = users.first(where: { $0.name == form.who }) {
            target = existing
        } else {
            let name = form.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !name.isEmpty else {
                lockForm.error = "Type your full name."
                return
            }
            if let existing = users.first(where: { $0.name == name }) {
                target = existing
            } else {
                guard form.masterPassword == form.confirm else {
                    lockForm.error = "The two master passwords are different. Type them again."
                    lockForm.masterPassword = ""
                    lockForm.confirm = ""
                    return
                }
                target = User(name: name)
                creating = true
            }
        }
        guard !form.masterPassword.isEmpty else {
            lockForm.error = "Type your master password."
            return
        }
        form.busy = true
        form.error = nil
        lockForm = form
        let masterPassword = form.masterPassword, name = target.name
        Task {
            let result = await Self.derive(target, masterPassword: masterPassword)
            // The form changed meanwhile: an import came, or it was reset.
            guard lockForm.busy, lockForm.pending?.name == form.pending?.name else {
                if case .success(let (_, key)) = result { key.wipe() }
                return
            }
            lockForm.busy = false
            switch result {
            case .success(let (user, key)):
                unlocked(user, key: key, creating: creating)
            case .failure(let error as SpectreError) where error == .wrongSecret:
                lockForm.error = "That is not the master password of \(name)."
                lockForm.masterPassword = ""
            case .failure(let error):
                lockForm.error = error.localizedDescription
                lockForm.masterPassword = ""
            }
        }
    }

    /// Unlocks as soon as the master password typed is the user's, without
    /// Enter: a pause in the typing checks it against the user's key ID. A
    /// master password that is not theirs, or not yet, shows nothing. A new
    /// user, and an export without a key ID, wait for Enter: nothing checks
    /// their master password.
    func masterPasswordChanged() {
        quietUnlock?.cancel()
        let form = lockForm
        guard !form.busy, !form.masterPassword.isEmpty, !isUnlocked else { return }
        let target = form.pending ?? (form.isCreating ? nil : users.first { $0.name == form.who })
        guard let target, target.keyID != nil else { return }
        quietUnlock = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = await Self.derive(target, masterPassword: form.masterPassword)
            guard case .success(let (user, key)) = result else { return }
            // Unlock only for what the form still holds.
            guard !isUnlocked, !lockForm.busy, lockForm.masterPassword == form.masterPassword,
                  lockForm.who == form.who, lockForm.pending?.name == form.pending?.name
            else {
                key.wipe()
                return
            }
            unlocked(user, key: key, creating: false)
        }
    }

    /// Derives the user's key from the master password, off the main thread:
    /// scrypt takes a moment. It fails if the master password does not match
    /// their key ID.
    private static func derive(_ user: User, masterPassword: String) async -> Result<(User, Key), any Error> {
        await Task.detached(priority: .userInitiated) {
            Result { () throws -> (User, Key) in
                var user = user
                let key = try user.unlock(secret: masterPassword)
                return (user, key)
            }
        }.value
    }

    /// Opens the sites of a user whose master password matched, keeping a new user
    /// or an import first.
    private func unlocked(_ unlocked: User, key: Key, creating: Bool) {
        var user = unlocked
        if lockForm.pending != nil {
            let count = user.sites.count
            if let i = users.firstIndex(where: { $0.name == user.name }) {
                users[i].merge(user)
                user = users[i]
            } else {
                users.append(user)
            }
            toast = "Imported \(count.counted("site"))."
        } else if creating {
            users.append(user)
        }
        users.sort { $0.name < $1.name }
        self.user = user
        self.key = key
        save()
        loadSecrets()
        settings.lastUser = user.name
        lockForm.pending = nil
        lockForm.pendingFile = ""
        resetLockForm()
        screen = .sites
        query = ""
        selection = 0
        opened += 1
        unlockedAt = .now
        focusTopField()
        agentsUnlocked()
    }

    // MARK: Sites

    /// The sites the search finds.
    var results: [Site] {
        guard let user else { return [] }
        return sites(matching: query, of: user)
    }

    /// The user's sites that a query finds.
    func sites(matching query: String, of user: User) -> [Site] {
        Self.search(user.sites, for: query, name: \.name, lastUsed: \.lastUsed)
    }

    /// What a query finds of named things: those whose names start with
    /// it, then those holding it, then those holding its letters in order,
    /// each the most recently used first.
    static func search<Item>(_ items: [Item], for query: String, name: (Item) -> String,
                             lastUsed: (Item) -> Date?) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items
            .compactMap { item -> (Item, Int)? in
                let name = name(item).lowercased()
                if q.isEmpty || name.hasPrefix(q) || name.trimmingPrefix("www.").hasPrefix(q) { return (item, 0) }
                if name.contains(q) { return (item, 1) }
                if name.containsInOrder(q) { return (item, 2) }
                return nil
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                let (x, y) = (lastUsed(a.0) ?? .distantPast, lastUsed(b.0) ?? .distantPast)
                if x != y { return x > y }
                return name(a.0) < name(b.0)
            }
            .map(\.0)
    }

    /// A site of the name typed, which the user has none of yet: Enter
    /// saves it with the user's default type, as in Spectre.
    var draft: Site? {
        let name = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let user, !name.isEmpty, user.site(named: name) == nil else { return nil }
        return user.newSite(named: name)
    }

    func password(of site: Site) -> String? { try? key?.password(for: site) }

    /// The login name the user set for the site, or for all their sites.
    /// Spectre also makes one for each site, as it makes passwords: that
    /// one does not show, as few sites use it.
    func login(of site: Site) -> String? {
        guard let key, let user, (site.loginType ?? user.loginType)?.isStateful == true,
              let login = try? key.login(for: site, of: user), !login.isEmpty
        else { return nil }
        return login
    }

    /// Keeps a login name of the site's own, encrypted, or none when it is
    /// empty.
    func setLogin(_ login: String, for siteName: String) {
        guard let site = site(named: siteName), login != self.login(of: site) ?? "" else { return }
        if login.isEmpty {
            update(siteName) {
                $0.loginType = nil
                $0.loginState = nil
            }
        } else if let state = encrypt(login, algorithm: site.algorithm) {
            update(siteName) {
                $0.loginType = .personal
                $0.loginState = state
            }
        }
    }

    func copyPassword(of site: Site) {
        guard let password = password(of: site) else { return }
        copy(password, for: site)
    }

    func copyLogin(of site: Site) {
        guard let login = login(of: site) else { return }
        copy(login, for: site)
    }

    func copy(_ text: String, for site: Site? = nil) {
        if let site { used(site) }
        if let clipboard {
            clipboard(text)
        } else {
            Clipboard.copySecret(text, clearAfter: settings.clearAfter > 0 ? .seconds(settings.clearAfter) : nil)
        }
        didCopy()
        closePanel()
    }

    /// Counts a use of a site, as Spectre does, and keeps a new one.
    func used(_ site: Site) {
        let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        update(site.name, adding: site) {
            $0.uses += 1
            $0.lastUsed = now
        }
        user?.lastUsed = now
        save()
    }

    func site(named name: String) -> Site? { user?.site(named: name) }

    /// Changes the user's site of that name, or adds the site given first,
    /// and saves.
    func update(_ name: String, adding new: Site? = nil, _ change: (inout Site) -> Void) {
        guard var user else { return }
        if user.siteIndex(named: name) == nil, let new {
            user.sites.append(new)
        }
        guard let i = user.siteIndex(named: name) else { return }
        change(&user.sites[i])
        self.user = user
        save()
    }

    func delete(_ name: String) {
        user?.sites.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        save()
        screen = .sites
    }

    /// Encrypts a value to store with the user's key.
    func encrypt(_ plain: String, algorithm: Algorithm) -> String? {
        do {
            return try key?.encrypt(plain, algorithm: algorithm)
        } catch {
            toast = error.localizedDescription
            return nil
        }
    }

    /// Keeps the unlocked user's changes, in memory and on disk.
    func save() {
        guard let user else { return }
        if let i = users.firstIndex(where: { $0.name == user.name }) {
            users[i] = user
        }
        do {
            try store.save(user)
        } catch {
            toast = "Derivate could not save: \(error.localizedDescription)"
        }
    }

    /// Deletes a user's file, and locks.
    func forget(_ name: String) {
        guard let user = users.first(where: { $0.name == name }) else { return }
        do {
            try store.delete(user)
        } catch {
            toast = "Derivate could not delete \(name): \(error.localizedDescription)"
            return
        }
        users.removeAll { $0.name == name }
        if settings.lastUser == name {
            settings.lastUser = nil
        }
        lock()
    }

    // MARK: Import and export

    /// Asks for a Spectre export to import.
    func chooseImport() {
        closePanel()
        let dialog = NSOpenPanel()
        dialog.title = "Import a Spectre Export"
        dialog.message = "Choose the file Spectre exported: an .mpjson or an .mpsites file."
        dialog.allowedContentTypes = ["mpjson", "mpsites", "json"].compactMap { UTType(filenameExtension: $0) }
        NSApp.activate()
        guard dialog.runModal() == .OK, let file = dialog.url else { return }
        importFile(at: file)
    }

    /// Reads a Spectre export, then opens the panel to ask for its user's
    /// master password, which checks the file and encrypts any password it holds in
    /// the clear.
    func importFile(at file: URL) {
        do {
            let user = try User(importing: Data(contentsOf: file))
            lock()
            lockForm.pending = user
            lockForm.pendingFile = file.lastPathComponent
            resetLockForm()
            showPanel(true)
        } catch {
            alert("Derivate could not import \(file.lastPathComponent)", error.localizedDescription)
        }
    }

    /// The user an export writes: the user unlocked, else the one who
    /// unlocked last.
    var exportUser: User? {
        user ?? users.first { $0.name == settings.lastUser } ?? (users.count == 1 ? users.first : nil)
    }

    /// Writes the user's sites to a file Spectre imports.
    func chooseExport() {
        guard let user = exportUser else { return }
        closePanel()
        let dialog = NSSavePanel()
        dialog.title = "Export for Spectre"
        dialog.nameFieldStringValue = store.file(of: user).lastPathComponent
        NSApp.activate()
        guard dialog.runModal() == .OK, let file = dialog.url else { return }
        do {
            try user.exportData().write(to: file, options: .atomic)
        } catch {
            alert("Derivate could not export \(user.name)", error.localizedDescription)
        }
    }

    func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Settings

    func recordShortcut() {
        recording = true
        shortcutError = nil
        _ = registerShortcut(nil) // so that the old one records too
    }

    func stopRecording() {
        guard recording else { return }
        recording = false
        _ = registerShortcut(settings.shortcut)
    }

    /// Takes a key pressed while recording as the shortcut.
    func record(_ event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            stopRecording() // Escape
        } else if let shortcut = Shortcut(event: event) {
            recording = false
            setShortcut(shortcut)
        } else {
            shortcutError = "Use ⌘, ⌃ or ⌥ with the key."
        }
    }

    /// Makes the shortcut open the panel, keeping the old one if macOS
    /// refuses it.
    func setShortcut(_ shortcut: Shortcut?) {
        if let error = registerShortcut(shortcut) {
            shortcutError = error
            _ = registerShortcut(settings.shortcut)
        } else {
            shortcutError = nil
            settings.shortcut = shortcut
        }
    }

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                toast = "Derivate could not change Open at Login: \(error.localizedDescription)"
            }
        }
    }
}

extension Int {
    /// "1 site", "2 sites".
    func counted(_ noun: String) -> String { self == 1 ? "1 \(noun)" : "\(self) \(noun)s" }
}

private extension String {
    /// Whether the letters of other appear in this string, in order.
    func containsInOrder(_ other: String) -> Bool {
        var rest = other[...]
        for c in self where c == rest.first {
            rest = rest.dropFirst()
        }
        return rest.isEmpty
    }
}
