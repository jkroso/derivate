import DerivateKit
import SwiftUI

/// The lock screen: unlock a user, make a new one, or finish an import.
struct LockView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focus: Field?

    private enum Field { case name, masterPassword, again }

    var body: some View {
        @Bindable var model = model
        let form = model.lockForm
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Derivate").font(.system(size: 17, weight: .bold))
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                if let request = model.agentRequests.first {
                    AgentWaitingNote(request: request, count: model.agentRequests.count)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                    if let pending = form.pending {
                        FieldRow(label: "Name") {
                            Text(pending.name).fontWeight(.semibold).lineLimit(1)
                        }
                    } else if !model.users.isEmpty {
                        FieldRow(label: "Name") {
                            Choices(options: model.users.map { ($0.name, $0.name) } + [(LockForm.newUser, LockForm.newUser)],
                                    selection: $model.lockForm.who)
                            .onChange(of: form.who) {
                                model.lockForm.error = nil
                                model.lockForm.masterPassword = ""
                                model.lockForm.confirm = ""
                                focus = model.lockForm.isCreating ? .name : .masterPassword
                            }
                        }
                    }
                    if form.isCreating {
                        FieldRow(label: "Full name") {
                            TextField("Full name", text: $model.lockForm.name, prompt: placeholder("As Spectre has it"))
                                .labelsHidden()
                                .focused($focus, equals: .name)
                                .inputStyle(focused: focus == .name)
                        }
                    }
                    FieldRow(label: "Master password", description: hint) {
                        SecureField("Master password", text: $model.lockForm.masterPassword, prompt: placeholder("Master password"))
                            .labelsHidden()
                            .focused($focus, equals: .masterPassword)
                            .inputStyle(focused: focus == .masterPassword)
                            .onChange(of: form.masterPassword) { model.masterPasswordChanged() }
                            .disabled(form.busy)
                            .onSubmit(model.unlock)
                    }
                    if form.isCreating {
                        FieldRow(label: "Again") {
                            SecureField("Again", text: $model.lockForm.confirm, prompt: placeholder("The same master password"))
                                .labelsHidden()
                                .focused($focus, equals: .again)
                                .inputStyle(focused: focus == .again)
                                .disabled(form.busy)
                                .onSubmit(model.unlock)
                        }
                    }
                }
                ErrorText(message: form.error)
                if form.pending != nil || form.busy || submitTitle != nil {
                    HStack(spacing: 10) {
                        if form.pending != nil {
                            Button("Cancel Import") {
                                model.lockForm.pending = nil
                                model.resetLockForm()
                            }
                            .buttonStyle(.soft)
                        }
                        Spacer()
                        if form.busy {
                            ProgressView().controlSize(.small)
                        }
                        if let submitTitle {
                            Button(submitTitle, action: model.unlock)
                                .buttonStyle(.prominent)
                                .disabled(form.busy)
                        }
                    }
                }
            }
            .font(.system(size: 13.5))
            .padding(24)

            HStack {
                Button(action: model.chooseImport) {
                    Label("Import Spectre Export…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.soft)
                Spacer()
                IconButton("slider.horizontal.3", help: "Settings  ⌘,") { model.screen = .settings }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Divider() }
        }
        .onAppear(perform: focusFirst)
        .onChange(of: model.opened, focusFirst)
        .onChange(of: form.error) {
            if form.error != nil && !form.isCreating {
                focus = .masterPassword
            }
        }
    }

    private func focusFirst() {
        focus = model.lockForm.isCreating ? .name : .masterPassword
    }

    /// The button that submits the form, where typing the master password
    /// does not unlock by itself: a new user, and an export with no key ID
    /// to check it against. Enter submits it too.
    private var submitTitle: String? {
        let form = model.lockForm
        if form.isCreating {
            return "Create"
        }
        if let pending = form.pending, pending.keyID == nil {
            return "Import"
        }
        return nil
    }

    private var subtitle: String {
        let form = model.lockForm
        if let pending = form.pending {
            return "Importing \(pending.sites.count.counted("site")) from \(form.pendingFile)."
        }
        if form.isCreating && model.users.isEmpty {
            return "Your name and master password make your passwords, as in Spectre."
        }
        return "Type your master password to see your passwords."
    }

    private var hint: String? {
        let form = model.lockForm
        if let pending = form.pending {
            return pending.keyID == nil
                ? "This export cannot check the master password: type it with care."
                : "The master password you use in Spectre, which Spectre calls your secret. Derivate checks it against the export."
        }
        return form.isCreating ? "Type it twice. The same name and master password give the same passwords on every device." : nil
    }
}
