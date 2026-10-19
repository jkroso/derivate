import AppKit
import DerivateKit

/// What the user keeps in Derivate besides their sites: a file, such as a
/// certificate exported as .p12, a password, such as the file's, and
/// notes. Spectre's files have no place for these, so Derivate keeps them
/// in a file of its own, encrypted with the user's key.
struct Secret: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    /// The name the file had, such as "Developer ID.p12", which saving it
    /// suggests.
    var fileName: String?
    var file: Data?
    var password = ""
    var notes = ""
    var added = Date.nowToTheSecond
    var lastUsed: Date?

    /// The largest file Derivate keeps: each change writes all of the
    /// user's secrets again.
    static let maxFileSize = 5 << 20

    private enum CodingKeys: String, CodingKey {
        case name, fileName = "file_name", file, password, notes, added, lastUsed = "last_used"
    }

    init(name: String, fileName: String? = nil, file: Data? = nil) {
        self.name = name
        self.fileName = fileName
        self.file = file
    }

    /// Derivate does not keep a secret that holds nothing.
    var isEmpty: Bool { file == nil && password.isEmpty && notes.isEmpty }
}

extension Date {
    /// Now, without the fraction of a second that files do not keep.
    static var nowToTheSecond: Date { Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down)) }
}

extension AppModel {
    // MARK: The list

    /// The secrets the search finds.
    var secretResults: [Secret] {
        Self.search(secrets, for: query, name: \.name, lastUsed: \.lastUsed)
    }

    /// A secret of the name typed, which the user has none of yet: Enter
    /// opens it, to add its file or password.
    var secretDraft: Secret? {
        let name = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard isUnlocked, secretsError == nil, !name.isEmpty, secret(named: name) == nil else { return nil }
        return Secret(name: name)
    }

    /// The secret the list has chosen: one of the results, or the draft
    /// after them.
    var chosenSecret: Secret? {
        let results = secretResults
        if results.indices.contains(selection) {
            return results[selection]
        }
        return secretDraft ?? results.last
    }

    var secretChoices: Int { secretResults.count + (secretDraft == nil ? 0 : 1) }

    func secret(named name: String) -> Secret? {
        secrets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func isDraft(_ secret: Secret) -> Bool { self.secret(named: secret.name) == nil }

    /// Opens the secrets, or goes back from them to the sites, with an
    /// empty search.
    func showSecrets(_ show: Bool = true) {
        screen = show ? .secrets : .sites
        query = ""
        selection = 0
        opened += 1
        focusTopField()
    }

    /// What Enter does to a secret: saves its file, else copies its
    /// password, else opens it, as it opens a new one.
    func use(_ secret: Secret) {
        if isDraft(secret) {
            screen = .secret(name: secret.name)
        } else if secret.file != nil {
            saveFile(of: secret)
        } else if !secret.password.isEmpty {
            copyPassword(of: secret)
        } else {
            screen = .secret(name: secret.name)
        }
    }

    // MARK: Changes

    /// Reads the unlocked user's secrets. If their file does not decrypt,
    /// Derivate shows why and does not change it.
    func loadSecrets() {
        guard let user, let key else { return }
        do {
            secrets = try store.loadSecrets(of: user, key: key)
            secretsError = nil
        } catch {
            secrets = []
            let file = (store.secretsFile(of: user).path as NSString).abbreviatingWithTildeInPath
            secretsError = "Derivate could not read your secrets in \(file). It does not change that file."
                + (error is SpectreError ? "" : " \(error.localizedDescription)")
        }
    }

    /// Changes the secret of that name, or adds it, and saves. A secret
    /// left with nothing in it goes. Returns whether it saved.
    @discardableResult
    func updateSecret(_ name: String, _ change: (inout Secret) -> Void) -> Bool {
        changeSecrets { secrets in
            if !secrets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                secrets.append(Secret(name: name))
            }
            if let i = secrets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                change(&secrets[i])
            }
        }
    }

    func deleteSecret(_ name: String) {
        changeSecrets { $0.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        screen = .secrets
    }

    /// Saves the secrets as changed, encrypted. It changes nothing while
    /// their file does not read, so that it stays as it was.
    @discardableResult
    private func changeSecrets(_ change: (inout [Secret]) -> Void) -> Bool {
        guard let user, let key else { return false }
        if let secretsError {
            toast = secretsError
            return false
        }
        var changed = secrets
        change(&changed)
        changed.removeAll(where: \.isEmpty)
        guard changed != secrets else { return true }
        do {
            try store.save(changed, of: user, key: key)
            secrets = changed
            return true
        } catch {
            toast = "Derivate could not save your secrets: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Files

    /// A file dropped on the panel: on the secrets, it is a secret's file.
    /// Elsewhere, it is a Spectre export to import.
    func dropped(_ file: URL) {
        switch screen {
        case .secrets where isUnlocked: addSecret(from: file)
        case .secret(let name) where isUnlocked: setFile(of: name, from: file)
        default: importFile(at: file)
        }
    }

    /// Adds a secret of a file, named as the file is, and opens it.
    func addSecret(from file: URL) {
        guard let data = read(file) else { return }
        let base = file.deletingPathExtension().lastPathComponent
        var name = base, number = 2
        while secret(named: name) != nil {
            name = "\(base) \(number)"
            number += 1
        }
        if updateSecret(name, { $0 = Secret(name: name, fileName: file.lastPathComponent, file: data) }) {
            screen = .secret(name: name)
        }
    }

    /// Keeps a copy of the file as the secret's file, encrypted.
    func setFile(of name: String, from file: URL) {
        guard let data = read(file) else { return }
        updateSecret(name) {
            $0.file = data
            $0.fileName = file.lastPathComponent
        }
    }

    /// Asks for a file to keep as the secret's, then opens the secret again.
    func chooseFile(for name: String) {
        closePanel()
        let file: URL?
        if let openDialog {
            file = openDialog()
        } else {
            let dialog = NSOpenPanel()
            dialog.title = "Choose the File of \(name)"
            dialog.message = "Derivate keeps a copy, encrypted with your key."
            NSApp.activate()
            file = dialog.runModal() == .OK ? dialog.url : nil
        }
        showPanel(true)
        screen = .secret(name: name)
        if let file {
            setFile(of: name, from: file)
        }
    }

    /// Asks where to save the secret's file, and saves it there, decrypted
    /// and readable by the user alone.
    func saveFile(of secret: Secret) {
        guard let data = secret.file else { return }
        let fileName = secret.fileName ?? secret.name
        closePanel()
        let destination: URL?
        if let saveDialog {
            destination = saveDialog(fileName)
        } else {
            let dialog = NSSavePanel()
            dialog.title = "Save \(secret.name)"
            dialog.message = "Derivate saves the file decrypted. Only your Mac user can read it."
            dialog.nameFieldStringValue = fileName
            NSApp.activate()
            destination = dialog.runModal() == .OK ? dialog.url : nil
        }
        guard let destination else { return }
        do {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            alert("Derivate could not save \(fileName)", error.localizedDescription)
            return
        }
        updateSecret(secret.name) { $0.lastUsed = .nowToTheSecond }
    }

    func copyPassword(of secret: Secret) {
        guard !secret.password.isEmpty else { return }
        updateSecret(secret.name) { $0.lastUsed = .nowToTheSecond }
        copy(secret.password)
    }

    /// A file to keep, or nil and a message why not.
    private func read(_ file: URL) -> Data? {
        let name = file.lastPathComponent
        do {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                toast = "\(name) is a folder. Derivate keeps files only."
                return nil
            }
            if let size = values.fileSize, size > Secret.maxFileSize {
                toast = "\(name) is larger than 5 MB, which Derivate keeps at most."
                return nil
            }
            return try Data(contentsOf: file)
        } catch {
            toast = "Derivate could not read \(name): \(error.localizedDescription)"
            return nil
        }
    }
}
