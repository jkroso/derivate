import DerivateKit
import SwiftUI

/// The search, the list of secrets and the card of the chosen one.
struct SecretsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lock.doc")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                TextField("Secret name", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searching)
                    .onChange(of: model.query) { model.selection = 0 }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Divider() }

            list
            if let secret = model.chosenSecret {
                SecretCard(secret: secret)
            }
            Footer()
        }
        .onAppear { searching = true }
        .onChange(of: model.opened) { searching = true }
    }

    /// The secrets found, then a new secret of the name typed, last.
    private var list: some View {
        let results = model.secretResults
        let draft = model.secretDraft
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if let error = model.secretsError {
                        ErrorText(message: error)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 20)
                    } else if results.isEmpty && draft == nil {
                        VStack(spacing: 8) {
                            Text("No secrets yet").font(.system(size: 15, weight: .semibold))
                            Text("Keep files such as certificates here, with their passwords. Type a name for a new secret, or drop a file on the panel.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 36)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, secret in
                        SecretListRow(secret: secret, index: i, isNew: false)
                    }
                    if let draft {
                        SecretListRow(secret: draft, index: results.count, isNew: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: model.selection) {
                if let id = model.chosenSecret?.id {
                    scroller.scrollTo(id)
                }
            }
        }
    }
}

extension Secret {
    /// What the secret holds most: a file, a password or notes.
    var symbol: String { file != nil ? "doc" : !password.isEmpty ? "key" : "note.text" }
}

/// A secret of the list, which a click chooses and a double click uses.
private struct SecretListRow: View {
    @Environment(AppModel.self) private var model
    let secret: Secret
    let index: Int
    let isNew: Bool
    @State private var hovered = false

    var body: some View {
        let selected = index == model.selection
        HStack(spacing: 12) {
            if isNew {
                Image(systemName: "plus")
                    .frame(width: 18)
                Text("New secret")
                Text(secret.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Keycap(key: "⌘↩", onAccent: selected)
            } else {
                Image(systemName: secret.symbol)
                    .frame(width: 18)
                    .opacity(selected ? 0.85 : 0.55)
                Text(secret.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let fileName = secret.fileName, !(fileName as NSString).pathExtension.isEmpty {
                    Text("." + (fileName as NSString).pathExtension)
                        .font(.system(size: 12))
                        .opacity(selected ? 0.8 : 0.55)
                }
            }
        }
        .font(.system(size: 14.5))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor : Color.primary.opacity(hovered ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.selection = index }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.use(secret) })
        .id(secret.id)
    }
}

/// The chosen secret's file and password, with the keys and buttons that
/// save and copy them.
private struct SecretCard: View {
    @Environment(AppModel.self) private var model
    let secret: Secret

    var body: some View {
        let isNew = model.isDraft(secret)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(secret.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if isNew {
                    Text("New")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                } else {
                    IconButton("ellipsis", help: "Details  ⌘E") { model.screen = .secret(name: secret.name) }
                }
            }
            if isNew {
                Text("Enter opens it. Then choose its file, or type its password.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    if secret.file != nil {
                        FileRow(secret: secret, key: "↩") { model.saveFile(of: secret) }
                    }
                    if !secret.password.isEmpty {
                        if secret.file != nil {
                            Divider()
                        }
                        let key = secret.file == nil ? "↩" : "⇧↩"
                        SecretRow(symbol: "key", value: secret.password, size: 14.5, key: key, help: "Copy password  \(key)") {
                            model.copyPassword(of: secret)
                        }
                    }
                    if secret.file == nil && secret.password.isEmpty {
                        Text(secret.notes)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
            }
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
        .overlay(alignment: .top) { Divider() }
    }
}

/// A secret's file: its name and size, the key that saves it and a
/// button that does too.
struct FileRow: View {
    let secret: Secret
    var key: String?
    let save: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.fileName ?? secret.name)
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Int64(secret.file?.count ?? 0).formatted(.byteCount(style: .file)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let key {
                Keycap(key: key)
            }
            IconButton("square.and.arrow.down", help: "Save file…" + (key.map { "  \($0)" } ?? ""), action: save)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
}
