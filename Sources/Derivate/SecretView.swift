import DerivateKit
import SwiftUI

/// A secret's details: its file, password and notes. A new secret shows
/// here before it holds anything, and Derivate keeps it once it does.
struct SecretView: View {
    @Environment(AppModel.self) private var model
    let secret: Secret

    @State private var password = ""
    @State private var notes = ""
    @State private var deleting = false
    @FocusState private var focus: Field?

    private enum Field { case password, notes }

    var body: some View {
        VStack(spacing: 0) {
            Header(title: secret.name, back: model.back)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    file
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 18) {
                        FieldRow(label: "Password", description: "Such as the file's password. Shift+Enter copies it from the list.") {
                            TextField("Password", text: $password, prompt: placeholder("The password to keep").font(.system(size: 14)))
                                .labelsHidden()
                                .font(.secret(14))
                                .focused($focus, equals: .password)
                                .inputStyle(focused: focus == .password)
                                .onChange(of: password) { model.updateSecret(secret.name) { $0.password = password } }
                        }
                        FieldRow(label: "Notes") {
                            TextEditor(text: $notes)
                                .font(.system(size: 13.5))
                                .scrollContentBackground(.hidden)
                                .focused($focus, equals: .notes)
                                .frame(height: 96)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 8)
                                .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(focus == .notes ? Color.accentColor : Color.hairline,
                                                      lineWidth: focus == .notes ? 1.5 : 1)
                                }
                                .onChange(of: notes) { model.updateSecret(secret.name) { $0.notes = notes } }
                        }
                    }
                    if !model.isDraft(secret) {
                        HStack {
                            Text("Added \(secret.added.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Delete Secret…", role: .destructive) { deleting = true }
                                .buttonStyle(.destructive)
                        }
                    }
                }
                .font(.system(size: 13.5))
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 24, trailing: 20))
            }
        }
        .overlay {
            if deleting {
                Confirmation(
                    title: "Delete \(secret.name)?",
                    message: "You cannot undo this. Derivate deletes the secret's file, password and notes from this Mac.",
                    action: "Delete", cancel: { deleting = false }, confirm: { model.deleteSecret(secret.name) })
            }
        }
        .onAppear {
            password = secret.password
            notes = secret.notes
        }
    }

    /// The file, with the buttons that save it and choose another.
    private var file: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if secret.file != nil {
                    FileRow(secret: secret) { model.saveFile(of: secret) }
                } else {
                    Label("No file yet", systemImage: "doc")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button(secret.file == nil ? "Choose File…" : "Replace File…") { model.chooseFile(for: secret.name) }
                    .buttonStyle(.soft)
                Text("Or drop a file on the panel. Derivate keeps a copy, encrypted with your key, so you can delete the original.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
