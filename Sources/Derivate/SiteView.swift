import DerivateKit
import SwiftUI

/// A site's details: its type, password number, stored password, login
/// name, website and security answers.
struct SiteView: View {
    @Environment(AppModel.self) private var model
    let site: Site

    @State private var login = ""   // the login name the user set for the site
    @State private var stored = ""  // a password to store, as typed
    @State private var url = ""
    @State private var deleting = false
    @FocusState private var focus: Field?

    private enum Field { case stored, login, website }

    var body: some View {
        VStack(spacing: 0) {
            Header(title: site.name, back: model.back)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    password
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 18) {
                        fields
                    }
                    if !site.questions.isEmpty {
                        answers
                    }
                    HStack {
                        Text("Used \(Int(site.uses).counted("time")) · algorithm v\(site.algorithm.rawValue)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete Site…", role: .destructive) { deleting = true }
                            .buttonStyle(.destructive)
                    }
                }
                .font(.system(size: 13.5))
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 24, trailing: 20))
            }
        }
        .overlay {
            if deleting {
                Confirmation(
                    title: "Delete \(site.name)?",
                    message: "Derivate forgets its counter, type and login name. Typing its name again gives the first password of the default type.",
                    action: "Delete", cancel: { deleting = false }, confirm: { model.delete(site.name) })
            }
        }
        .onAppear {
            login = model.login(of: site) ?? ""
            url = site.url ?? ""
        }
    }

    private var password: some View {
        Group {
            if let password = model.password(of: site) {
                SecretRow(symbol: "key", value: password, size: 17, help: "Copy password") {
                    model.copyPassword(of: site)
                }
            } else {
                Label("No password stored yet", systemImage: "key")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
    }

    @ViewBuilder private var fields: some View {
        FieldRow(label: "Type") {
            Choices(options: ResultType.passwordTypes.map { ($0, $0.title) }, selection: binding(\.type))
        }
        if site.type.isTemplate {
            FieldRow(label: "Password", description: "Go to the next number when a site asks for a new password.") {
                NumberStepper(value: binding(\.counter), range: 1...ResultType.maxCounter, what: "password")
            }
        }
        if site.type.isStateful {
            FieldRow(label: "Stored", description: "Kept encrypted with your key, as Spectre keeps it.") {
                HStack {
                    SecureField("Stored", text: $stored, prompt: placeholder("The password to keep"))
                        .labelsHidden()
                        .focused($focus, equals: .stored)
                        .inputStyle(focused: focus == .stored)
                        .onSubmit(keepStored)
                    Button("Keep", action: keepStored)
                        .buttonStyle(.soft)
                        .disabled(stored.isEmpty)
                }
            }
        }
        FieldRow(label: "Login", description: "Shift+Enter copies it.") {
            TextField("Login", text: $login, prompt: placeholder("Your username or email"))
                .labelsHidden()
                .focused($focus, equals: .login)
                .inputStyle(focused: focus == .login)
                .onChange(of: login) { model.setLogin(login.trimmingCharacters(in: .whitespaces), for: site.name) }
        }
        FieldRow(label: "Website") {
            TextField("Website", text: $url, prompt: placeholder("https://"))
                .labelsHidden()
                .focused($focus, equals: .website)
                .inputStyle(focused: focus == .website)
                .onChange(of: url) {
                    let trimmed = url.trimmingCharacters(in: .whitespaces)
                    model.update(site.name) { $0.url = trimmed.isEmpty ? nil : trimmed }
                }
        }
    }

    /// The security answers Spectre gives the site.
    private var answers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Security answers")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(site.questions, id: \.keyword) { question in
                if let answer = try? model.key?.answer(to: question, for: site) {
                    HStack(spacing: 10) {
                        Text(question.keyword.isEmpty ? "Any question" : question.keyword)
                            .frame(width: 100, alignment: .leading)
                            .lineLimit(1)
                        Text(answer)
                            .font(.secret(13))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        IconButton("doc.on.doc", help: "Copy answer") { model.copy(answer) }
                    }
                }
            }
        }
    }

    /// A binding to a field of the site, which saves as it changes.
    private func binding<Value>(_ field: WritableKeyPath<Site, Value>) -> Binding<Value> {
        Binding(
            get: { site[keyPath: field] },
            set: { value in model.update(site.name) { $0[keyPath: field] = value } }
        )
    }

    /// Keeps a password the user typed for the site, encrypted.
    private func keepStored() {
        guard !stored.isEmpty, let state = model.encrypt(stored, algorithm: site.algorithm) else { return }
        model.update(site.name) { $0.state = state }
        stored = ""
    }
}
