import AppKit
import SwiftUI

enum PanelMetrics {
    static let size = NSSize(width: 440, height: 580)
    static let radius: CGFloat = 14
}

/// A panel that takes the keyboard without bringing the app to the
/// front, as Spotlight's does: the app the user was in stays in front, and
/// gets the keyboard back as the panel closes.
final class Panel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: PanelMetrics.size),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Makes the panel as tall as the screen it shows, keeping its top
    /// edge where it is.
    func fit(height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var frame = frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        setFrame(frame, display: true, animate: isVisible)
        invalidateShadow()
    }

    /// Puts the keyboard in the topmost text field, so that typing goes
    /// there as the panel opens: the search, or the secret.
    func focusTopTextField() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fields = content.descendants.compactMap { $0 as? NSTextField }.filter { $0.isEditable && !$0.isHidden }
        let top = fields.max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }
        if let top, top.currentEditor() == nil {
            makeFirstResponder(top)
        }
    }
}

private extension NSView {
    var descendants: [NSView] { subviews.flatMap { [$0] + $0.descendants } }
}

/// Shows the panel below the menu bar icon, or in the middle of the screen
/// for the shortcut, and closes it when the user clicks elsewhere.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var panel: Panel?
    private var keys: Any?
    private var closedAt = Date.distantPast

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens the panel, or closes it if it is open. A click on the menu
    /// bar icon closes the panel before it gets here: that click must
    /// not open it again.
    func toggle(below anchor: NSRect?) {
        if isOpen {
            close()
        } else if Date.now.timeIntervalSince(closedAt) > 0.3 {
            show(below: anchor)
        }
    }

    /// Opens the panel below the anchor, a rectangle on the screen, or in
    /// the upper middle of the screen with the pointer when it is nil.
    func show(below anchor: NSRect?) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        model.prepare()
        let panel = Panel()
        panel.delegate = self
        self.panel = panel
        panel.contentView = PanelContent(model: model) { [weak panel] height in panel?.fit(height: height) }
        panel.setFrameOrigin(origin(below: anchor))
        panel.contentView?.layoutSubtreeIfNeeded() // fits it before it shows
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        watchKeys()
        focusTopField()
    }

    /// Puts the keyboard in the top text field, now and once SwiftUI has
    /// drawn what changed.
    func focusTopField() {
        panel?.focusTopTextField()
        DispatchQueue.main.async { [weak self] in self?.panel?.focusTopTextField() }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        closedAt = .now
        if let keys {
            NSEvent.removeMonitor(keys)
        }
        keys = nil
        model.panelClosed()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func origin(below anchor: NSRect?) -> NSPoint {
        let size = PanelMetrics.size
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let area = screen.visibleFrame
            let x = min(max(anchor.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
            return NSPoint(x: x, y: anchor.minY - 6 - size.height)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        return NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height / 5 - size.height)
    }

    /// The panel's keys, before its fields see them: the arrows choose a
    /// site while the search field keeps the keyboard.
    private func watchKeys() {
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }
}

/// The panel's content: a blurred material with the app's view over it.
final class PanelContent: NSVisualEffectView {
    init(model: AppModel, fit: @escaping (CGFloat) -> Void = { _ in }) {
        super.init(frame: NSRect(origin: .zero, size: PanelMetrics.size))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        maskImage = .roundedRect(radius: PanelMetrics.radius)
        let host = NSHostingView(rootView: RootView(fit: fit).environment(model))
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private extension NSImage {
    /// A mask of a rounded rectangle, which stretches to any size.
    static func roundedRect(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
