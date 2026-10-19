import DerivateKit
import SwiftUI

/// The panel: the lock screen until the user unlocks, then their sites, a
/// site's details, their secrets, a secret's details or the settings.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false
    /// Sizes the panel to the height of the screen it shows.
    var fit: (CGFloat) -> Void = { _ in }

    /// The lock screen is as tall as what it holds. The other screens take
    /// the panel's full height, for their lists.
    private var fitsContent: Bool { !model.isUnlocked && model.screen != .settings }

    var body: some View {
        ZStack(alignment: .bottom) {
            screen
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thickMaterial, in: Capsule())
                    .padding(.bottom, 70)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: PanelMetrics.size.width, height: fitsContent ? nil : PanelMetrics.size.height)
        .fixedSize(horizontal: false, vertical: fitsContent)
        .background(Color.panelTint)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PanelMetrics.radius, style: .continuous)
                .strokeBorder(dropping ? Color.accentColor : Color.hairline, lineWidth: dropping ? 2 : 1)
        }
        // A Spectre export dropped on the panel imports, as the menu's
        // Import does. On the secrets, a file dropped is a secret's.
        .dropDestination(for: URL.self) { files, _ in
            guard let file = files.first else { return false }
            model.dropped(file)
            return true
        } isTargeted: { dropping = $0 }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .task(id: model.toast) {
            guard model.toast != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                model.toast = nil
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height, action: fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var screen: some View {
        if model.isUnlocked, let request = model.agentRequests.first {
            ApprovalView(request: request)
        } else if model.screen == .settings {
            SettingsView()
        } else if !model.isUnlocked {
            LockView()
        } else if case .site(let name) = model.screen, let site = model.site(named: name) {
            SiteView(site: site)
        } else if model.screen == .secrets {
            SecretsView()
        } else if case .secret(let name) = model.screen {
            SecretView(secret: model.secret(named: name) ?? Secret(name: name))
        } else {
            SitesView()
        }
    }
}
