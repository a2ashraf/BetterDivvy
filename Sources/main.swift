import Cocoa
import Carbon
import ApplicationServices

// MARK: - Window mover (Accessibility API)

struct TargetWindow {
    let element: AXUIElement
    let screen: NSScreen
}

func focusedWindow() -> TargetWindow? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
          let win = ref else { return nil }
    let element = win as! AXUIElement
    // Determine which screen the window is mostly on
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    var pos = CGPoint.zero, size = CGSize.zero
    if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success {
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
    }
    if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success {
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    }
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let center = CGPoint(x: pos.x + size.width / 2, y: primaryH - (pos.y + size.height / 2))
    let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    return TargetWindow(element: element, screen: screen)
}

func move(_ target: TargetWindow, toCocoaRect r: CGRect) {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    var pos = CGPoint(x: r.minX, y: primaryH - r.maxY)
    var size = r.size
    // Set size, position, size again: some apps clamp size based on current position.
    if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(target.element, kAXSizeAttribute as CFString, s) }
    if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(target.element, kAXPositionAttribute as CFString, p) }
    if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(target.element, kAXSizeAttribute as CFString, s) }
}

// MARK: - Grid UI

final class PassEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PanelDrawView: NSView {
    unowned let root: RootView
    init(root: RootView) { self.root = root; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { root.drawPanel(in: bounds) }
}

/// Full-screen dimmed canvas: shows a live preview of where the window will land,
/// and a centered panel with the grid to pick cells from.
final class RootView: NSView {
    var divisions = 4 { didSet { anchor = nil; hover = nil; layoutPanel(); needsDisplay = true; panelView.needsDisplay = true } }
    var anchor: (Int, Int)?
    var hover: (Int, Int)?
    var onCommit: ((Int, Int, Int, Int) -> Void)?
    var onCancel: (() -> Void)?
    var onSelectSize: ((Int) -> Void)?
    var onCycle: (() -> Void)?

    let sizes = [2, 4, 8]
    let visible: NSRect      // screen's usable area, in this view's (flipped) coordinates
    let effect = PassEffectView()
    var panelView: PanelDrawView!
    var panelRect = NSRect.zero, gridRect = NSRect.zero
    var pillRects: [NSRect] = []
    let headerH: CGFloat = 52, footerH: CGFloat = 34, pad: CGFloat = 16

    init(frame: NSRect, visible: NSRect) {
        self.visible = visible
        super.init(frame: frame)
        panelView = PanelDrawView(root: self)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true; effect.layer?.cornerRadius = 18; effect.layer?.masksToBounds = true
        addSubview(effect); addSubview(panelView)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        layoutPanel()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func layoutPanel() {
        let gw = min(visible.width * 0.45, 560)
        let gh = gw * visible.height / visible.width
        let w = gw + pad * 2, h = gh + headerH + footerH + pad
        panelRect = NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h).integral
        gridRect = NSRect(x: panelRect.minX + pad, y: panelRect.minY + headerH, width: gw, height: gh)
        effect.frame = panelRect
        panelView.frame = panelRect
        // size pills (right side of header)
        pillRects = []
        let pw: CGFloat = 58, ph: CGFloat = 26, gap: CGFloat = 6
        var x = panelRect.maxX - pad - (pw * 3 + gap * 2)
        for _ in sizes { pillRects.append(NSRect(x: x, y: panelRect.minY + 13, width: pw, height: ph)); x += pw + gap }
    }

    // MARK: geometry
    private func cell(at p: NSPoint) -> (Int, Int)? {
        guard gridRect.insetBy(dx: -1, dy: -1).contains(p) else { return nil }
        let cw = gridRect.width / CGFloat(divisions), ch = gridRect.height / CGFloat(divisions)
        return (min(max(Int((p.x - gridRect.minX) / cw), 0), divisions - 1),
                min(max(Int((p.y - gridRect.minY) / ch), 0), divisions - 1))
    }
    private func clampedCell(at p: NSPoint) -> (Int, Int) {
        let cw = gridRect.width / CGFloat(divisions), ch = gridRect.height / CGFloat(divisions)
        return (min(max(Int((p.x - gridRect.minX) / cw), 0), divisions - 1),
                min(max(Int((p.y - gridRect.minY) / ch), 0), divisions - 1))
    }
    private var selection: (c0: Int, r0: Int, c1: Int, r1: Int)? {
        guard let h = hover else { return nil }
        let a = anchor ?? h
        return (min(a.0, h.0), min(a.1, h.1), max(a.0, h.0), max(a.1, h.1))
    }
    private func rect(of s: (c0: Int, r0: Int, c1: Int, r1: Int), in area: NSRect) -> NSRect {
        let cw = area.width / CGFloat(divisions), ch = area.height / CGFloat(divisions)
        return NSRect(x: area.minX + CGFloat(s.c0) * cw, y: area.minY + CGFloat(s.r0) * ch,
                      width: CGFloat(s.c1 - s.c0 + 1) * cw, height: CGFloat(s.r1 - s.r0 + 1) * ch)
    }

    // MARK: events
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hover = cell(at: p); redraw()
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = pillRects.firstIndex(where: { $0.contains(p) }) { onSelectSize?(sizes[i]); return }
        if let c = cell(at: p) { anchor = c; hover = c; redraw(); return }
        if !panelRect.contains(p) { onCancel?() }
    }
    override func mouseDragged(with e: NSEvent) {
        guard anchor != nil else { return }
        hover = clampedCell(at: convert(e.locationInWindow, from: nil)); redraw()
    }
    override func mouseUp(with e: NSEvent) {
        guard anchor != nil, let s = selection else { return }
        onCommit?(s.c0, s.r0, s.c1, s.r1)
    }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: onCancel?()                       // esc
        case 48: onCycle?()                        // tab
        default: break
        }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    func redraw() { needsDisplay = true; panelView.needsDisplay = true }

    // MARK: drawing
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.35).setFill(); bounds.fill()

        // Live preview of where the window will land, on the real screen
        guard let s = selection else { return }
        let r = rect(of: s, in: visible).insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        NSColor.systemBlue.withAlphaComponent(0.22).setFill(); path.fill()
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke(); path.lineWidth = 3; path.stroke()
    }

    func drawPanel(in b: NSRect) {
        let title = "BetterDivvy" as NSString
        title.draw(at: NSPoint(x: pad, y: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])

        // size pills
        for (i, n) in sizes.enumerated() {
            let r = pillRects[i].offsetBy(dx: -panelRect.minX, dy: -panelRect.minY)
            let active = n == divisions
            let p = NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13)
            (active ? NSColor.systemBlue : NSColor(white: 1, alpha: 0.10)).setFill(); p.fill()
            let t = "\(n)×\(n)" as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: active ? NSColor.white : NSColor(white: 1, alpha: 0.65)]
            let sz = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
        }

        // grid cells
        let g = gridRect.offsetBy(dx: -panelRect.minX, dy: -panelRect.minY)
        let cw = g.width / CGFloat(divisions), ch = g.height / CGFloat(divisions)
        let gap: CGFloat = divisions >= 8 ? 1 : (divisions == 4 ? 1.5 : 2.5)
        let radius: CGFloat = divisions >= 8 ? 3 : (divisions == 4 ? 6 : 10)
        NSColor(white: 1, alpha: 0.10).setFill()
        for r in 0..<divisions {
            for c in 0..<divisions {
                let cellR = NSRect(x: g.minX + CGFloat(c) * cw, y: g.minY + CGFloat(r) * ch, width: cw, height: ch).insetBy(dx: gap, dy: gap)
                NSBezierPath(roundedRect: cellR, xRadius: radius, yRadius: radius).fill()
            }
        }
        // selection
        if let s = selection {
            let sr = rect(of: s, in: g).insetBy(dx: gap, dy: gap)
            let p = NSBezierPath(roundedRect: sr, xRadius: radius + 1, yRadius: radius + 1)
            NSColor.systemBlue.withAlphaComponent(0.85).setFill(); p.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke(); p.lineWidth = 1.5; p.stroke()
        }

        // footer
        var text = "Drag to select  ·  ⌥` or Tab: change grid  ·  Esc: cancel"
        if let s = selection { text = "\(s.c1 - s.c0 + 1) × \(s.r1 - s.r0 + 1) cells  ·  release to resize" }
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                .foregroundColor: NSColor(white: 1, alpha: 0.6)]
        let str = text as NSString
        let sz = str.size(withAttributes: a)
        str.draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.maxY - footerH / 2 - sz.height / 2 + 2), withAttributes: a)
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: OverlayWindow?
    var grid: RootView?
    var previousApp: NSRunningApplication?
    var target: TargetWindow?
    let sizes = [2, 4, 8]
    var sizeIndex = 1
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "BetterDivvy")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Grid (⌥`)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            NSLog("Accessibility permission needed")
        }
        registerHotKey()
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
            let d = Unmanaged<AppDelegate>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { d.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x44495659), id: 1)
        // keyCode 50 = ` / ~ key
        RegisterEventHotKey(50, UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    @objc func toggle() {
        if let p = panel, p.isVisible {
            // Pressing the hotkey again cycles the grid: 4 → 8 → 16 → 4
            cycle()
            return
        }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            return
        }
        guard let t = focusedWindow() else { NSSound.beep(); return }
        target = t
        sizeIndex = 1
        show(on: t.screen)
    }

    func show(on screen: NSScreen) {
        previousApp = NSWorkspace.shared.frontmostApplication
        let sf = screen.frame, vis = screen.visibleFrame
        let visInView = NSRect(x: vis.minX - sf.minX, y: sf.maxY - vis.maxY, width: vis.width, height: vis.height)
        let w = OverlayWindow(contentRect: sf, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .popUpMenu
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.acceptsMouseMovedEvents = true
        let g = RootView(frame: NSRect(origin: .zero, size: sf.size), visible: visInView)
        g.divisions = sizes[sizeIndex]
        g.onCancel = { [weak self] in self?.hide(restoreFocus: true) }
        g.onCycle = { [weak self] in self?.cycle() }
        g.onSelectSize = { [weak self] n in
            guard let self = self, let i = self.sizes.firstIndex(of: n) else { return }
            self.sizeIndex = i; self.grid?.divisions = n
        }
        g.onCommit = { [weak self] c0, r0, c1, r1 in self?.apply(c0, r0, c1, r1) }
        w.contentView = g
        // Activate so the window receives keyboard events (Esc).
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(g)
        panel = w; grid = g
    }

    func cycle() {
        sizeIndex = (sizeIndex + 1) % sizes.count
        grid?.divisions = sizes[sizeIndex]
    }

    func hide(restoreFocus: Bool) {
        panel?.orderOut(nil); panel = nil; grid = nil
        if restoreFocus { previousApp?.activate() }
    }

    func apply(_ c0: Int, _ r0: Int, _ c1: Int, _ r1: Int) {
        guard let t = target else { hide(restoreFocus: true); return }
        let n = CGFloat(sizes[sizeIndex])
        let v = t.screen.visibleFrame
        let cw = v.width / n, ch = v.height / n
        let rect = CGRect(x: v.minX + CGFloat(c0) * cw,
                          y: v.maxY - CGFloat(r1 + 1) * ch,
                          width: CGFloat(c1 - c0 + 1) * cw,
                          height: CGFloat(r1 - r0 + 1) * ch).integral
        hide(restoreFocus: true)
        move(t, toCocoaRect: rect)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
