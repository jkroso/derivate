import DerivateKit
import SwiftUI

/// The search, the list of sites and the card of the chosen one.
struct SitesView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                TextField("Site name", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searching)
                    .onChange(of: model.query) { model.selection = 0 }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Divider() }

            list
            if let site = model.chosen {
                SiteCard(site: site)
            }
            footer
        }
        .onAppear { searching = true }
        .onChange(of: model.opened) { searching = true }
    }

    /// The sites found, then a new site of the name typed, last.
    private var list: some View {
        let results = model.results
        let draft = model.draft
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if results.isEmpty && draft == nil {
                        VStack(spacing: 8) {
                            Text("No sites yet").font(.system(size: 15, weight: .semibold))
                            Text("Type a site's name, as you would in Spectre, or import your Spectre export.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 36)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, site in
                        SiteRow(site: site, index: i, isNew: false)
                    }
                    if let draft {
                        SiteRow(site: draft, index: results.count, isNew: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: model.selection) {
                if let id = model.chosen?.id {
                    scroller.scrollTo(id)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "person")
                .foregroundStyle(.secondary)
            Text(model.user?.name ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            IconButton("slider.horizontal.3", help: "Settings  ⌘,") { model.screen = .settings }
            IconButton("lock", help: "Lock  ⌘L", action: model.lock)
        }
        .font(.system(size: 13))
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A site of the list, which a click chooses and a double click copies
/// the password of.
private struct SiteRow: View {
    @Environment(AppModel.self) private var model
    let site: Site
    let index: Int
    let isNew: Bool
    @State private var hovered = false

    var body: some View {
        let selected = index == model.selection
        HStack(spacing: 12) {
            if isNew {
                Image(systemName: "plus")
                    .frame(width: 18)
                Text("New site")
                Text(site.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Keycap(key: "⌘↩", onAccent: selected)
            } else {
                Image(systemName: "globe")
                    .frame(width: 18)
                    .opacity(selected ? 0.85 : 0.55)
                Text(site.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Group {
                    if let user = model.user, site.type != user.defaultType {
                        Text(site.type.title)
                    }
                    if site.counter > 1 {
                        Text("#\(site.counter)")
                    }
                }
                .font(.system(size: 12))
                .opacity(selected ? 0.8 : 0.55)
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
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.copyPassword(of: site) })
        .id(site.id)
    }
}

/// The chosen site's password and login name, with the keys and buttons
/// that copy them.
private struct SiteCard: View {
    @Environment(AppModel.self) private var model
    let site: Site

    var body: some View {
        let isNew = model.isDraft(site)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(site.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text((isNew ? "New · " : "") + site.type.detail(counter: site.counter))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                if !isNew {
                    IconButton("ellipsis", help: "Details  ⌘E") { model.edit(site) }
                }
            }
            VStack(spacing: 0) {
                if let password = model.password(of: site) {
                    SecretRow(symbol: "key", value: password, size: 17, key: "↩", help: "Copy password  ↩") {
                        model.copyPassword(of: site)
                    }
                } else {
                    Text("No password stored")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                if let login = model.login(of: site), !login.isEmpty {
                    Divider()
                    SecretRow(symbol: "at", value: login, size: 14.5, key: "⇧↩", help: "Copy login name  ⇧↩") {
                        model.copyLogin(of: site)
                    }
                }
            }
            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
        .overlay(alignment: .top) { Divider() }
    }
}

/// A row of the card: an icon, the value, the key that copies it and a
/// button that does too.
struct SecretRow: View {
    let symbol: String
    let value: String
    let size: CGFloat
    var key: String?
    let help: String
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(value)
                .font(.secret(size))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let key {
                Keycap(key: key)
            }
            IconButton("doc.on.doc", help: help, action: copy)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }
}
