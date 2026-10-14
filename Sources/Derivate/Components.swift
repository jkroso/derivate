import AppKit
import DerivateKit
import SwiftUI

extension Color {
    /// The panel's color, over the blurred desktop: faint, so the colors
    /// of the desktop show through. The blur keeps the text behind from
    /// showing, as it would compete with the panel's.
    static let panelTint = Color(light: 0xF4F4F5, dark: 0x27272A).opacity(0.1)
    /// The face of the boxes that hold passwords.
    static let fieldBackground = Color(light: 0xFFFFFF, dark: 0x18181B).opacity(0.7)
    static let hairline = Color.primary.opacity(0.1)

    init(light: UInt32, dark: UInt32) {
        func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}

extension Font {
    /// Passwords and login names, whose letters must not be mistaken.
    static func secret(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

/// A button that shows an SF Symbol, named for VoiceOver by its tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovered ? 0.1 : 0.05))
                )
                .onHover { hovered = $0 }
        }
    }
}

/// The key that does what is next to it.
struct Keycap: View {
    let key: String
    /// Whether it is on the accent color, as in a chosen row.
    var onAccent = false

    var body: some View {
        Text(key)
            .font(.system(size: 11.5))
            .foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(onAccent ? Color.white.opacity(0.45) : Color.hairline)
            }
    }
}

/// The top of a screen below the sites, with a button back to them,
/// which Escape presses too.
struct Header: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconButton("chevron.left", help: "Back  ⎋", action: back)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A row of a form: a label on the left, the control and a description
/// below it on the right. Use it in a Grid.
struct FieldRow<Content: View>: View {
    let label: String
    var description: String?
    var error: String?
    @ViewBuilder let content: Content

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 6) {
                content
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                }
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// What went wrong, in red.
struct ErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(.red)
        }
    }
}

/// Asks before something that cannot be undone, over the screen.
struct Confirmation: View {
    let title: String
    let message: String
    let action: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel)
                        .buttonStyle(.soft)
                    Button(action, role: .destructive, action: confirm)
                        .buttonStyle(SoftButtonStyle(prominent: true, fill: .red))
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 20)
        }
    }
}

extension ResultType {
    /// "Long · password 1".
    func detail(counter: UInt32) -> String {
        isTemplate ? "\(title) · password \(counter)" : title
    }
}

// MARK: Form controls

/// The text a field shows while it is empty, grey, as no value is.
func placeholder(_ text: String) -> Text {
    Text(text).foregroundStyle(.secondary)
}

extension View {
    /// The look of the panel's text fields: roomy, on the face of the
    /// password boxes, outlined in the accent color while focused.
    func inputStyle(focused: Bool) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color.hairline, lineWidth: focused ? 1.5 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A choice of one of a few values, each a button: what a pop-up menu
/// hides, they show, and a click chooses.
struct Choices<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
                    .buttonStyle(ChoiceStyle(selected: option.value == selection))
                    .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
    }
}

private struct ChoiceStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, selected: selected)
    }

    private struct Face: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor
                              : Color.primary.opacity(configuration.isPressed ? 0.16 : hovered ? 0.1 : 0.06))
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// A number with buttons that step it down and up.
struct NumberStepper: View {
    @Binding var value: UInt32
    let range: ClosedRange<UInt32>
    let what: String

    var body: some View {
        HStack(spacing: 10) {
            IconButton("minus", help: "Previous \(what)") { value -= 1 }
                .disabled(value <= range.lowerBound)
            Text(value, format: .number.grouping(.never))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 28)
            IconButton("plus", help: "Next \(what)") { value += 1 }
                .disabled(value >= range.upperBound)
        }
    }
}

/// The look of the panel's buttons: text on a soft face, or on the
/// accent color for the screen's main action.
struct SoftButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .primary
    var fill: Color = .accentColor // of a prominent button

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, prominent: prominent, tint: tint, fill: fill)
    }

    private struct Face: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        let fill: Color
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? fill : tint.opacity(0.08))
                        .brightness(prominent && (hovered || configuration.isPressed) ? (configuration.isPressed ? -0.08 : 0.05) : 0)
                        .overlay {
                            if !prominent {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(tint.opacity(configuration.isPressed ? 0.1 : hovered ? 0.05 : 0))
                            }
                        }
                }
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static var prominent: SoftButtonStyle { SoftButtonStyle(prominent: true) }
    static var destructive: SoftButtonStyle { SoftButtonStyle(tint: .red) }
}

/// Lays its views out in rows, as words: a view that does not fit goes to
/// the next row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    /// The sizes of the views, row by row.
    private func rows(of subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        return rows
    }
}
