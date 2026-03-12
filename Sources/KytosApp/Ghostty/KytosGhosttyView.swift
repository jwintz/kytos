import AppKit
import GhosttyKit

/// NSView subclass wrapping a `ghostty_surface_t`. Handles Metal layer setup,
/// keyboard/mouse forwarding, and IME via NSTextInputClient.
@MainActor
final class KytosGhosttyView: NSView, @preconcurrency NSTextInputClient {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    /// Cached content size in logical points for re-use on backing changes.
    private var contentSize: CGSize = .zero

    /// Published surface title — updated via SET_TITLE action.
    var title: String = ""
    /// Published working directory — updated via PWD action.
    var pwd: String = ""

    /// The pane UUID this view belongs to. Set by KytosTerminalRepresentable.
    var paneID: UUID?
    /// Initial working directory for PWD restoration on launch.
    var initialPwd: String?
    
    // Native scrollbar via NSScrollView overlay
    private var scrollView: KytosPassthroughScrollView?
    private var scrollDocumentView: NSView?
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    private var scrollbarState: (total: UInt64, offset: UInt64, len: UInt64)?
    private var cellHeight: CGFloat = 0
    private var scrollObservers: [NSObjectProtocol] = []

    // MARK: - View Registry

    /// Static registry mapping pane UUIDs to their live views.
    /// Used for keyboard focus management, view reuse, and appearance refresh.
    static var viewRegistry: [UUID: KytosGhosttyView] = [:]

    static func view(for paneID: UUID) -> KytosGhosttyView? {
        viewRegistry[paneID]
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupScroller()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        let savedPaneID = self.paneID
        if let surface { ghostty_surface_free(surface) }
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor in
            if let savedPaneID { KytosGhosttyView.viewRegistry.removeValue(forKey: savedPaneID) }
        }
    }
    
    override func removeFromSuperview() {
        for obs in scrollObservers { NotificationCenter.default.removeObserver(obs) }
        scrollObservers.removeAll()
        super.removeFromSuperview()
    }

    // MARK: - Scroller (NSScrollView overlay, like ghostty's SurfaceScrollView)
    
    private func setupScroller() {
        let sv = KytosPassthroughScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = false
        sv.scrollerStyle = .overlay
        sv.drawsBackground = false
        sv.contentView.clipsToBounds = false
        
        let doc = NSView(frame: NSRect(origin: .zero, size: bounds.size))
        sv.documentView = doc
        self.scrollDocumentView = doc
        
        sv.frame = bounds
        sv.autoresizingMask = [.width, .height]
        addSubview(sv)
        self.scrollView = sv
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleScrollbarAction(_:)),
                                               name: NSNotification.Name("KytosGhosttyScrollbar"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleCellSizeAction(_:)),
                                               name: NSNotification.Name("KytosGhottyCellSize"), object: nil)
        
        // Force overlay style back on system preference change
        scrollObservers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.scrollView?.scrollerStyle = .overlay
        })
        
        // Listen for live scroll (user dragging scrollbar)
        sv.contentView.postsBoundsChangedNotifications = true
        scrollObservers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: sv, queue: .main
        ) { [weak self] _ in self?.isLiveScrolling = true })
        
        scrollObservers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: sv, queue: .main
        ) { [weak self] _ in self?.isLiveScrolling = false })
        
        scrollObservers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: sv, queue: .main
        ) { [weak self] _ in self?.handleLiveScroll() })
    }
    
    /// Calculate document height from scrollbar state
    private func scrollDocumentHeight() -> CGFloat {
        let contentHeight = scrollView?.contentSize.height ?? bounds.height
        guard cellHeight > 0, let sb = scrollbarState else { return contentHeight }
        let docGridHeight = CGFloat(sb.total) * cellHeight
        let padding = contentHeight - (CGFloat(sb.len) * cellHeight)
        return docGridHeight + padding
    }
    
    /// Synchronize the scroll view's document size and position with ghostty's scrollbar state
    private func synchronizeScrollView() {
        guard let sv = scrollView, let doc = scrollDocumentView else { return }
        doc.frame.size.height = scrollDocumentHeight()
        doc.frame.size.width = sv.bounds.width
        
        if !isLiveScrolling, cellHeight > 0, let sb = scrollbarState {
            // Invert: terminal offset is from top, AppKit position from bottom
            let offsetY = CGFloat(sb.total - sb.offset - sb.len) * cellHeight
            sv.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            lastSentRow = Int(sb.offset)
        }
        
        sv.reflectScrolledClipView(sv.contentView)
    }
    
    /// Handle user dragging the scrollbar — convert pixel position to row number
    private func handleLiveScroll() {
        guard cellHeight > 0, let sv = scrollView, let doc = scrollDocumentView else { return }
        let visibleRect = sv.contentView.documentVisibleRect
        let documentHeight = doc.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)
        
        guard row != lastSentRow else { return }
        lastSentRow = row
        
        guard let surface else { return }
        let cmd = "scroll_to_row:\(row)"
        cmd.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(cmd.utf8.count))
        }
    }
    
    @objc private func handleCellSizeAction(_ notif: Notification) {
        guard let view = notif.object as? KytosGhosttyView, view === self else { return }
        if let width = notif.userInfo?["width"] as? UInt32,
           let height = notif.userInfo?["height"] as? UInt32 {
            let scale = window?.backingScaleFactor ?? 2.0
            cellHeight = CGFloat(height) / scale
        }
    }
    
    @objc private func handleScrollbarAction(_ notif: Notification) {
        guard let view = notif.object as? KytosGhosttyView, view === self else { return }
        guard let total = notif.userInfo?["total"] as? UInt64,
              let offset = notif.userInfo?["offset"] as? UInt64,
              let len = notif.userInfo?["len"] as? UInt64 else { return }
        
        scrollbarState = (total: total, offset: offset, len: len)
        synchronizeScrollView()
    }

    // MARK: - Surface lifecycle

    func createSurface(context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW) {
        guard surface == nil else { return }
        surface = KytosGhosttyApp.shared.newSurface(in: self, context: context, workingDirectory: initialPwd)
        if let surface {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            ghostty_surface_set_content_scale(surface, scale, scale)
            contentSize = bounds.size
            let fb = convertToBacking(NSRect(origin: .zero, size: contentSize)).size
            ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
            kLog("[Surface] created scale=\(scale) logical=\(contentSize) fb=\(fb)")
        } else {
            kLog("[Surface] createSurface FAILED")
        }
    }

    // MARK: - Layout

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface, newSize.width > 0, newSize.height > 0 else { return }
        contentSize = newSize
        let fb = convertToBacking(NSRect(origin: .zero, size: newSize)).size
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
    }
    
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // NSScrollView handles its own resizing via autoresizingMask
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Update layer contentsScale to prevent compositor scaling
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface else { return }

        // Detect X/Y scale factor
        let fbFrame = convertToBacking(frame)
        let xScale = fbFrame.size.width / frame.size.width
        let yScale = fbFrame.size.height / frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        // When scale factor changes, fb size changes too
        let scaledSize = convertToBacking(NSRect(origin: .zero, size: contentSize)).size
        if scaledSize.width > 0, scaledSize.height > 0 {
            ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && surface == nil {
            createSurface()
        }
        // Register/unregister from view registry
        if window != nil, let paneID {
            KytosGhosttyView.viewRegistry[paneID] = self
        } else if let paneID, window == nil {
            KytosGhosttyView.viewRegistry.removeValue(forKey: paneID)
        }
        if let surface {
            ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
            if let displayID = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self
        ))
    }

    override func becomeFirstResponder() -> Bool {
        guard let surface else { return false }
        ghostty_surface_set_focus(surface, true)
        if let paneID {
            NotificationCenter.default.post(
                name: NSNotification.Name("KytosGhosttyFocusChanged"),
                object: self,
                userInfo: ["paneID": paneID]
            )
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Track marked text state before this event
        let markedTextBefore = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        // Sync preedit state
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let acc = keyTextAccumulator, !acc.isEmpty {
            // Composed text from IME or regular typing
            for text in acc {
                _ = keyAction(action, event: event, text: text)
            }
        } else {
            // No accumulated text — send key event with characters from the event.
            // This handles Enter, Backspace, arrows, etc.
            _ = keyAction(
                action,
                event: event,
                text: Self.filteredCharacters(event),
                composing: markedText.length > 0 || markedTextBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // Don't process mods during preedit
        if hasMarkedText() { return }

        let mods = Self.ghosttyMods(event.modifierFlags)

        // If the modifier is active in flags, it's a press; otherwise release
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Check correct side for right-hand modifiers
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: // Right Shift
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: // Right Control
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: // Right Option
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: // Right Command
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }
            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        // Let Kytos-owned shortcuts propagate to menu bar / SwiftUI responder chain
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.keyCode {
            case 12: return false  // Cmd+Q → app quit
            case 29: return false  // Cmd+0 → reset zoom
            case 18: return false  // Cmd+1 → first tab
            case 43: return false  // Cmd+, → settings
            default: break
            }
        }

        guard let surface else { return false }

        // Must pass text to ghostty for binding matching (same as reference impl)
        var keyEvent = Self.ghosttyKeyEvent(from: event, action: GHOSTTY_ACTION_PRESS)
        let chars = event.characters ?? ""
        let isBinding = chars.withCString { ptr -> Bool in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, nil)
        }

        if isBinding {
            self.keyDown(with: event)
            return true
        }
        return false
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.composing = composing

        // consumed_mods: modifiers that contributed to text translation.
        // Control and command never contribute.
        keyEvent.consumed_mods = Self.ghosttyMods(
            event.modifierFlags.subtracting([.control, .command])
        )

        // unshifted_codepoint: the character this key produces with no modifiers
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }

        // Only send text if it's not a control character (>= 0x20).
        // Control characters are encoded by Ghostty itself.
        if let text, !text.isEmpty,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Filter event characters for use as key text.
    /// Returns nil for function keys (PUA range) and strips control modifiers from control chars.
    private static func filteredCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            // Control characters: return chars without control pressed
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // Function keys in PUA range: don't send
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    private func syncPreedit(clearIfNeeded: Bool = false) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8.count
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(len))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            x *= 10
            y *= 10
        }
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 }
        let mods = Self.ghosttyMods(event.modifierFlags)
        scrollMods |= Int32(mods.rawValue) << 4
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let str = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: str)
        } else if let str = string as? String {
            markedText = NSMutableAttributedString(string: str)
        }
        // Don't sync preedit here; keyDown handles it after interpretKeyEvents
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func insertText(_ string: Any, replacementRange: NSRange) {
        unmarkText()
        let chars: String
        if let str = string as? NSAttributedString {
            chars = str.string
        } else if let str = string as? String {
            chars = str
        } else { return }

        if keyTextAccumulator != nil {
            keyTextAccumulator!.append(chars)
            return
        }
        // Fallback for direct insertText calls (not via keyDown)
        guard let surface else { return }
        let len = chars.utf8.count
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len))
        }
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewPoint = NSPoint(x: x, y: bounds.height - y - h)
        let screenRect = window?.convertToScreen(
            NSRect(origin: convert(viewPoint, to: nil), size: NSSize(width: w, height: h))
        )
        return screenRect ?? NSRect(x: x, y: y, width: w, height: h)
    }

    override func doCommand(by selector: Selector) {
        // Do NOT call perform(selector) — that would trigger NSResponder actions
        // (insertNewline:, deleteBackward:, etc.) that interfere with key event processing.
        // Key events are handled entirely through keyAction/ghostty_surface_key.
    }

    // MARK: - Helpers

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    static func ghosttyKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = ghosttyMods(event.modifierFlags)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.consumed_mods = ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }
        return keyEvent
    }
}

// MARK: - Passthrough NSScrollView

/// An NSScrollView that only handles scrollbar interactions.
/// All other events (scroll wheel, mouse, keyboard) pass through to the
/// KytosGhosttyView underneath, so ghostty handles scrolling internally.
private class KytosPassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Forward scroll wheel events to superview (KytosGhosttyView)
        superview?.scrollWheel(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept hits on the scroller knob/track area
        if let scroller = verticalScroller {
            let scrollerPoint = convert(point, to: scroller)
            if scroller.bounds.contains(scrollerPoint) && scroller.testPart(scrollerPoint) != .noPart {
                return super.hitTest(point)
            }
        }
        // Pass everything else through to superview
        return nil
    }
}
