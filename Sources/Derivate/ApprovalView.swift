import DerivateKit
import SwiftUI

/// Asks the user to allow an agent's request: a site's password, or a new
/// site. Enter allows it, Escape refuses it.
struct ApprovalView: View {
    @Environment(AppModel.self) private var model
    let request: AgentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.system(size: 17, weight: .bold))
                    if let folder = request.agent.folder {
                        Text("In \(folder)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            card
            if let note {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.agentRequests.count > 1 {
                Text(model.agentRequests.count == 2 ? "1 more request waits." : "\(model.agentRequests.count - 1) more requests wait.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer()
                Button { model.answer(request.id, .refused) } label: {
                    HStack(spacing: 8) {
                        Text("Refuse")
                        Text("esc").font(.system(size: 11.5)).opacity(0.6)
                    }
                }
                .buttonStyle(.soft)
                Button { model.answer(request.id, .allowed) } label: {
                    HStack(spacing: 8) {
                        Text("Allow")
                        Text("↩").font(.system(size: 11.5)).opacity(0.75)
                    }
                }
                .buttonStyle(.prominent)
                .disabled(!model.agentRequestReady)
            }
        }
        .font(.system(size: 13.5))
        .padding(24)
    }

    /// The site, as the agent will get or make it.
    private var card: some View {
        VStack(spacing: 0) {
            row("globe", site, detail: detail, size: 15, weight: .semibold)
            if let login {
                Divider()
                row("at", login, size: 14)
            }
            if let url {
                Divider()
                row("link", url, size: 13)
            }
        }
        .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
    }

    private func row(_ symbol: String, _ text: String, detail: String? = nil, size: CGFloat,
                     weight: Font.Weight = .regular) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: size, weight: weight))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var site: String { model.site(named: request.action.site)?.name ?? request.action.site }

    private var login: String? {
        switch request.action {
        case .password(let name): model.site(named: name).flatMap(model.login(of:))
        case .create(_, let login, _, _, _): login
        }
    }

    private var url: String? {
        switch request.action {
        case .password(let name): model.site(named: name)?.url
        case .create(_, _, let url, _, _): url
        }
    }

    private var detail: String? {
        switch request.action {
        case .password(let name):
            return model.site(named: name).map { $0.type.detail(counter: $0.counter) }
        case .create(_, _, _, let type, let givesPassword):
            if givesPassword { return "Stored password" }
            return "New · " + (type ?? model.user?.defaultType ?? .long).title
        }
    }

    private var note: String? {
        let agent = request.agent.name
        switch request.action {
        case .create(_, _, _, _, let givesPassword):
            return givesPassword
                ? "Derivate keeps the password that \(agent) gives, encrypted with your key."
                : "Derivate adds the site and gives its new password to \(agent)."
        case .password:
            guard model.settings.agents == .askOnce, request.agent.process != nil else {
                return "Derivate gives \(agent) the password and the login name."
            }
            return "If you allow it, this \(agent) session gets other passwords without asking until you lock Derivate."
        }
    }
}

extension AgentRequest {
    /// "Claude Code wants a password".
    var title: String {
        switch action {
        case .password: "\(agent.name) wants a password"
        case .create: "\(agent.name) wants to add a site"
        }
    }
}

/// On the lock screen: an agent waits for the user to unlock.
struct AgentWaitingNote: View {
    let request: AgentRequest
    let count: Int

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var text: String {
        let what = switch request.action {
        case .password(let site): "the password of \(site)"
        case .create(let site, _, _, _, _): "to add \(site)"
        }
        let more = count > 1 ? " \(count - 1) more \(count == 2 ? "request waits" : "requests wait")." : ""
        return "\(request.agent.name) wants \(what). Unlock to answer, or press Esc to refuse.\(more)"
    }
}
