import AppKit
import Carbon.HIToolbox
import DerivateKit

extension AppModel {
    /// The site the list has chosen: one of the results, or the draft
    /// after them.
    var chosen: Site? {
        let sites = results
        if sites.indices.contains(selection) {
            return sites[selection]
        }
        return draft ?? sites.last
    }

    var choices: Int { results.count + (draft == nil ? 0 : 1) }

    func isDraft(_ site: Site) -> Bool { self.site(named: site.name) == nil }

    func edit(_ site: Site) {
        if !isDraft(site) {
            screen = .site(name: site.name)
        }
    }

    /// Goes back to the sites, or from a secret to the secrets, with the
    /// keyboard in the search field.
    func back() {
        if case .secret = screen {
            screen = .secrets
        } else {
            screen = .sites
        }
        opened += 1
        focusTopField()
    }

    /// Handles a key pressed in the panel, and reports whether it did:
    ///
    ///   - ↑ and ↓ choose a site. Enter copies its password, Shift+Enter
    ///     the login name the user set for it. For a moment after Derivate
    ///     unlocks, Enter does nothing.
    ///   - ⌘Enter saves the name typed as a new site and copies its
    ///     password, even when other sites match it.
    ///   - ⌘E opens its details, ⌘S the secrets, ⌘L locks, ⌘, opens the
    ///     settings.
    ///   - Escape clears the search, then closes the panel. On the other
    ///     screens, it goes back to the sites.
    ///   - On the secrets, Enter saves the chosen secret's file, else
    ///     copies its password. Shift+Enter copies its password. Escape
    ///     and ⌘S go back to the sites.
    ///   - While an agent's request shows, Enter allows it, and Escape
    ///     and ⌘L refuse it. ⌘L also locks.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = Int(event.keyCode)
        let enter = key == kVK_Return || key == kVK_ANSI_KeypadEnter
        if isUnlocked, let request = agentRequests.first {
            switch (key, modifiers) {
            case (_, []) where enter:
                if agentRequestReady { answer(request.id, .allowed) }
            case (kVK_Escape, []):
                answer(request.id, .refused)
            case (kVK_ANSI_L, .command):
                lock()
            default:
                return false
            }
            return true
        }
        if recording {
            record(event)
            return true
        }
        if screen == .secrets, isUnlocked {
            return handleSecretsKey(key, modifiers, enter: enter)
        }
        if screen != .sites {
            guard key == kVK_Escape, modifiers.isEmpty else { return false }
            back()
            return true
        }
        guard isUnlocked else {
            switch (key, modifiers) {
            case (kVK_Escape, []): closePanel()
            case (kVK_ANSI_Comma, .command): screen = .settings
            default: return false
            }
            return true
        }
        switch (key, modifiers) {
        case _ where enter && justUnlocked:
            break // meant for the master password
        case (kVK_DownArrow, []):
            selection = min(selection + 1, max(choices - 1, 0))
        case (kVK_UpArrow, []):
            selection = max(selection - 1, 0)
        case (_, []) where enter:
            if let chosen { copyPassword(of: chosen) }
        case (_, .shift) where enter:
            if let chosen { copyLogin(of: chosen) }
        case (_, .command) where enter:
            if let draft { copyPassword(of: draft) }
        case (kVK_Escape, []):
            if query.isEmpty {
                closePanel()
            } else {
                query = ""
                selection = 0
            }
        case (kVK_ANSI_E, .command), (kVK_ANSI_I, .command):
            if let chosen { edit(chosen) }
        case (kVK_ANSI_S, .command):
            showSecrets()
        case (kVK_ANSI_L, .command):
            lock()
        case (kVK_ANSI_Comma, .command):
            screen = .settings
        default:
            return false
        }
        return true
    }

    /// Whether Derivate unlocked a moment ago.
    private var justUnlocked: Bool {
        unlockedAt.map { ContinuousClock.now - $0 < enterPause } ?? false
    }

    private func handleSecretsKey(_ key: Int, _ modifiers: NSEvent.ModifierFlags, enter: Bool) -> Bool {
        switch (key, modifiers) {
        case (kVK_DownArrow, []):
            selection = min(selection + 1, max(secretChoices - 1, 0))
        case (kVK_UpArrow, []):
            selection = max(selection - 1, 0)
        case (_, []) where enter:
            if let chosenSecret { use(chosenSecret) }
        case (_, .shift) where enter:
            if let chosenSecret { copyPassword(of: chosenSecret) }
        case (_, .command) where enter:
            if let secretDraft { use(secretDraft) }
        case (kVK_Escape, []):
            if query.isEmpty {
                showSecrets(false)
            } else {
                query = ""
                selection = 0
            }
        case (kVK_ANSI_E, .command), (kVK_ANSI_I, .command):
            if let chosenSecret { screen = .secret(name: chosenSecret.name) }
        case (kVK_ANSI_S, .command):
            showSecrets(false)
        case (kVK_ANSI_L, .command):
            lock()
        case (kVK_ANSI_Comma, .command):
            screen = .settings
        default:
            return false
        }
        return true
    }
}
