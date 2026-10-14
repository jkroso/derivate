import AppKit
import DerivateKit
import SwiftUI

/// The settings: the shortcut, the clipboard, import and export.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var forgetting = false

    /// How long a copied password stays, in seconds.
    private static let clearChoices = [(30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (0, "Never")]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Header(title: "Settings", back: model.back)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 18) {
                        FieldRow(label: "Shortcut", description: "Opens Derivate from any app.", error: model.shortcutError) {
                            ShortcutRecorder()
                        }
                        FieldRow(label: "Clear clipboard", description: "After you copy a password, unless you copy something else first.") {
                            Choices(options: Self.clearChoices, selection: $model.settings.clearAfter)
                        }
                        FieldRow(label: "Locking", description: "Derivate stays unlocked until you lock it (⌘L) or quit it. Logging out quits it.") {
                            Text("Only when you lock it")
                        }
                        FieldRow(label: "Open at login") {
                            Toggle("Open at login", isOn: $model.opensAtLogin)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        FieldRow(label: "AI agents", description: model.settings.agents.explanation, error: model.agentServerError) {
                            Choices(options: AgentAccess.allCases.map { ($0, $0.title) }, selection: $model.settings.agents)
                        }
                        if model.settings.agents != .off {
                            FieldRow(label: "Command",
                                     description: "Add this command to each agent's MCP settings. Agents need no key: the command gets it from Derivate. If you move Derivate, change the command too.") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppModel.agentCommand)
                                        .font(.secret(12))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Copy Command", action: model.copyAgentCommand)
                                        .buttonStyle(.soft)
                                }
                            }
                        }
                        if model.isUnlocked {
                            FieldRow(label: "New sites", description: "The type of password a new site gets.") {
                                Choices(options: ResultType.passwordTypes.filter { !$0.isStateful }.map { ($0, $0.title) },
                                        selection: defaultType)
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button(action: model.chooseImport) {
                                Label("Import…", systemImage: "square.and.arrow.down")
                            }
                            Button(action: model.chooseExport) {
                                Label("Export…", systemImage: "square.and.arrow.up")
                            }
                            .disabled(model.exportUser == nil)
                        }
                        .buttonStyle(.soft)
                        Text("Exports are Spectre's .mpjson files, with stored passwords encrypted. Spectre imports them.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let user = model.user {
                        Divider()
                        HStack {
                            Text(user.name).lineLimit(1)
                            Spacer()
                            Button("Forget User…", role: .destructive) { forgetting = true }
                                .buttonStyle(.destructive)
                        }
                    }
                    HStack {
                        Text("Derivate \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Quit") { NSApp.terminate(nil) }
                            .buttonStyle(.soft)
                    }
                }
                .font(.system(size: 13.5))
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 24, trailing: 20))
            }
        }
        .overlay {
            if forgetting, let user = model.user {
                Confirmation(
                    title: "Forget \(user.name)?",
                    message: "Derivate deletes their sites from this Mac. Their passwords come back with their name and secret, but counters, types, login names and stored passwords do not, unless you export them first.",
                    action: "Forget", cancel: { forgetting = false }, confirm: { model.forget(user.name) })
            }
        }
    }

    private var defaultType: Binding<ResultType> {
        Binding(
            get: { model.user?.defaultType ?? .long },
            set: { type in
                model.user?.defaultType = type
                model.save()
            }
        )
    }
}

/// Shows the shortcut, and records a new one: a click, then the keys.
private struct ShortcutRecorder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.recordShortcut()
            } label: {
                Text(model.recording ? "Type the shortcut…" : model.settings.shortcut?.symbols ?? "None")
                    .frame(minWidth: 140)
            }
            .buttonStyle(SoftButtonStyle(prominent: model.recording))
            if model.recording {
                Button("Cancel", action: model.stopRecording)
                    .buttonStyle(.soft)
            } else if model.settings.shortcut != nil {
                IconButton("xmark", help: "Remove the shortcut") { model.setShortcut(nil) }
            }
        }
    }
}
