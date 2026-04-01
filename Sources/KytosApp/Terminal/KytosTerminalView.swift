// KytosTerminalView.swift — SwiftTerm-based terminal view for kytos panes

import AppKit
@preconcurrency import SwiftTerm

/// NSView subclass wrapping SwiftTerm's `LocalProcessTerminalView`.
/// Handles key interception, focus management, drag-and-drop, and
/// scrollbar overlay. Each instance corresponds to one terminal pane.
class KytosTerminalView: LocalProcessTerminalView {

    // MARK: - View Registry

    /// Maps pane UUIDs to their live views. Used for focus, view reuse, and search.
    static var viewRegistry: [UUID: KytosTerminalView] = [:]

    /// Maps pane UUIDs to the direct child PID spawned by the terminal.
    static var childPids: [UUID: pid_t] = [:]

    static func view(for paneID: UUID) -> KytosTerminalView? {
        viewRegistry[paneID]
    }

    // MARK: - Properties

    /// The pane UUID this view belongs to. Set by KytosTerminalRepresentable.
    var paneID: UUID?
    /// Initial working directory for PWD restoration on launch.
    var initialPwd: String?
    /// Published surface title — updated via delegate callback.
    var title: String = ""
    /// Published working directory — updated via delegate callback.
    var pwd: String = ""

    /// Current font size for font scaling support.
    private var currentFontSize: CGFloat = KytosSettings.shared.fontSize

    /// Dragged file/URL types this view accepts.
    private static let dropTypes: [NSPasteboard.PasteboardType] = [.string, .fileURL, .URL]

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes(Self.dropTypes)
        configureDefaults()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureDefaults() {
        applySettingsFont()
        applyCursorShape()
        optionAsMetaKey = true
        configureOscHandlers()
        configureWindowFocusObserver()
    }

    /// Apply cursor shape from settings.
    func applyCursorShape() {
        let shape = KytosCursorShape(rawValue: KytosSettings.shared.cursorShape) ?? .bar
        terminal.setCursorStyle(shape.cursorStyle)
    }

    /// Force caret redraw when the window regains key status.
    /// SwiftTerm's built-in observer uses didBecomeMain, which may not
    /// fire when the app is reactivated into a non-main window.
    private func configureWindowFocusObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
    }

    @objc private func windowDidBecomeKey(_ notif: Notification) {
        guard let window = notif.object as? NSWindow,
              window === self.window,
              window.firstResponder === self else { return }
        hasFocus = true
    }

    /// Apply font from settings.
    func applySettingsFont() {
        let settings = KytosSettings.shared
        currentFontSize = settings.fontSize
        if let customFont = NSFont(name: settings.fontFamily, size: currentFontSize) {
            font = customFont
        } else {
            font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)
        }
    }

    /// Register custom OSC handlers for features kytos consumes.
    /// OSC 9;4 — progress reporting (ConEmu/Windows Terminal convention).
    private func configureOscHandlers() {
        let terminal = getTerminal()
        let view: KytosTerminalView = self
        terminal.parser.oscHandlers[9] = { data in
            guard let text = String(bytes: data, encoding: .ascii) else { return }
            let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "4" else { return }
            guard parts[1].count == 1, let stateValue = Int(parts[1]) else { return }

            let kytosState: UInt32
            var progress: Int8 = -1

            switch stateValue {
            case 0:
                kytosState = KytosProgressState.none.rawValue
            case 1:
                kytosState = KytosProgressState.running.rawValue
                if parts.count >= 3, let pct = Int(parts[2]) {
                    progress = Int8(clamping: max(0, min(100, pct)))
                }
            case 2:
                kytosState = KytosProgressState.error.rawValue
                if parts.count >= 3, let pct = Int(parts[2]) {
                    progress = Int8(clamping: max(0, min(100, pct)))
                }
            case 3:
                kytosState = KytosProgressState.running.rawValue
            case 4:
                kytosState = KytosProgressState.pause.rawValue
                if parts.count >= 3, let pct = Int(parts[2]) {
                    progress = Int8(clamping: max(0, min(100, pct)))
                }
            default:
                return
            }

            NotificationCenter.default.post(
                name: .kytosTerminalProgressReport,
                object: view,
                userInfo: ["state": kytosState, "progress": progress]
            )
        }
    }

    // MARK: - Process Lifecycle

    /// Start a login shell process with the appropriate environment.
    func startTerminalProcess(workingDirectory: String? = nil) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if let resourcePath = Bundle.main.resourcePath {
            let integrationDir = resourcePath + "/kytos/shell-integration"
            env["KYTOS_SHELL_INTEGRATION_DIR"] = integrationDir
            // Auto-inject for zsh via ZDOTDIR (points to our .zshenv bootstrap).
            if shell.hasSuffix("/zsh") || shell.hasSuffix("/zsh-") {
                if let existingZdotdir = env["ZDOTDIR"] {
                    env["KYTOS_ORIG_ZDOTDIR"] = existingZdotdir
                }
                env["ZDOTDIR"] = integrationDir + "/zsh"
            }
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        let wd = workingDirectory ?? initialPwd ?? NSHomeDirectory()

        let ourPid = ProcessInfo.processInfo.processIdentifier
        let childrenBefore = Self.directChildPids(of: ourPid)

        startProcess(
            executable: shell,
            args: ["-l", "-i"],
            environment: envArray,
            currentDirectory: wd
        )

        if let paneID {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                let childrenAfter = Self.directChildPids(of: ourPid)
                let newChildren = childrenAfter.subtracting(childrenBefore)
                if let childPid = newChildren.first {
                    Self.childPids[paneID] = childPid
                    kLog("[Terminal] pane \(paneID.uuidString.prefix(8)) → child pid \(childPid)")
                }
            }
        }
    }

    /// Close the terminal session and clean up the registry.
    func closeSurface() {
        if let paneID {
            KytosTerminalView.viewRegistry.removeValue(forKey: paneID)
            KytosTerminalView.childPids.removeValue(forKey: paneID)
        }
    }

    /// Clear both screen and scrollback buffer.
    func clearScreenAndScrollback() {
        feed(text: "\u{001b}c")
        feed(text: "\u{001b}[2J\u{001b}[H")
    }

    // MARK: - Delegate Overrides

    /// Override open method: restart shell on process termination.
    override public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        clearScreenAndScrollback()
        startTerminalProcess()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Key Interception

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            if let chars = event.charactersIgnoringModifiers, chars == "c" {
                if selectionActive {
                    copy(self)
                    return true
                }
            }
            if let chars = event.charactersIgnoringModifiers, chars == "v" {
                paste(self)
                return true
            }
            if let chars = event.charactersIgnoringModifiers, chars == "a",
               flags.contains(.shift) {
                selectAll()
                return true
            }
            if let chars = event.charactersIgnoringModifiers, chars == "=" || chars == "+" {
                adjustFontSize(delta: 1)
                return true
            }
            if let chars = event.charactersIgnoringModifiers, chars == "-" {
                adjustFontSize(delta: -1)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        if flags.contains(.control) && !flags.contains(.command) {
            self.keyDown(with: event)
            return true
        }

        if let chars = event.charactersIgnoringModifiers,
           let scalar = chars.unicodeScalars.first {
            let v = Int(scalar.value)
            let isFunctionKey = (v >= NSUpArrowFunctionKey && v <= NSRightArrowFunctionKey)
                || (v >= NSF1FunctionKey && v <= NSF35FunctionKey)
                || v == NSDeleteFunctionKey
                || v == NSHomeFunctionKey || v == NSEndFunctionKey
                || v == NSPageUpFunctionKey || v == NSPageDownFunctionKey
            if isFunctionKey {
                self.keyDown(with: event)
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Font Scaling

    private func adjustFontSize(delta: CGFloat) {
        let newSize = max(8, min(72, currentFontSize + delta))
        setKytosFontSize(newSize)
    }

    func resetKytosFontSize() {
        setKytosFontSize(KytosSettings.shared.fontSize)
    }

    private func setKytosFontSize(_ size: CGFloat) {
        currentFontSize = size
        let family = KytosSettings.shared.fontFamily
        if let customFont = NSFont(name: family, size: size) {
            font = customFont
        } else {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    // MARK: - Focus Management

    override var canBecomeKeyView: Bool { true }

    private func postFocusNotificationIfNeeded() {
        guard window?.firstResponder === self, let paneID else { return }
        NotificationCenter.default.post(
            name: .kytosTerminalFocusChanged,
            object: self,
            userInfo: ["paneID": paneID]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if KytosSettings.shared.focusFollowsMouse {
            window?.makeFirstResponder(self)
            postFocusNotificationIfNeeded()
        }
    }

    // MARK: - Search

    @discardableResult
    func searchForward(_ query: String) -> Bool {
        guard !query.isEmpty else {
            clearSearch()
            return false
        }
        return findNext(query)
    }

    @discardableResult
    func searchBackward(_ query: String) -> Bool {
        guard !query.isEmpty else {
            clearSearch()
            return false
        }
        return findPrevious(query)
    }

    func endSearch() {
        clearSearch()
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if pb.types?.contains(.fileURL) == true || pb.types?.contains(.string) == true {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let files = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let paths = files.map { Self.shellEscape($0.path) }
            send(txt: paths.joined(separator: " "))
            return true
        }
        if let text = pb.string(forType: .string) {
            send(txt: text)
            return true
        }
        return false
    }

    // MARK: - Helpers

    static func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func directChildPids(of parentPid: pid_t) -> Set<pid_t> {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        sysctl(&name, UInt32(name.count), nil, &size, nil, 0)
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        sysctl(&name, UInt32(name.count), &procs, &size, nil, 0)
        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var result = Set<pid_t>()
        for i in 0..<actualCount {
            if procs[i].kp_eproc.e_ppid == parentPid {
                result.insert(procs[i].kp_proc.p_pid)
            }
        }
        return result
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let kytosTerminalSetTitle = Notification.Name("KytosTerminalSetTitle")
    static let kytosTerminalPwd = Notification.Name("KytosTerminalPwd")
    static let kytosTerminalNewSplit = Notification.Name("KytosTerminalNewSplit")
    static let kytosTerminalGotoSplit = Notification.Name("KytosTerminalGotoSplit")
    static let kytosTerminalEqualizeSplits = Notification.Name("KytosTerminalEqualizeSplits")
    static let kytosTerminalCloseSurface = Notification.Name("KytosTerminalCloseSurface")
    static let kytosTerminalFocusChanged = Notification.Name("KytosTerminalFocusChanged")
    static let kytosTerminalStartSearch = Notification.Name("KytosTerminalStartSearch")
    static let kytosTerminalProgressReport = Notification.Name("KytosTerminalProgressReport")
    static let kytosTerminalNewTab = Notification.Name("KytosTerminalNewTab")
    static let kytosTerminalNewWindow = Notification.Name("KytosTerminalNewWindow")
    static let kytosSearchNext = Notification.Name("KytosSearchNext")
    static let kytosSearchPrevious = Notification.Name("KytosSearchPrevious")
    static let kytosResetFontSize = Notification.Name("KytosResetFontSize")
}

// MARK: - Goto Split Direction

enum KytosGotoSplitDirection: UInt32 {
    case left = 0
    case right = 1
    case up = 2
    case down = 3
    case next = 4
    case previous = 5
}

// MARK: - Progress Report State

enum KytosProgressState: UInt32 {
    case none = 0
    case running = 1
    case error = 2
    case pause = 3
}

// MARK: - Defaults

enum KytosTerminalDefaults {
    static let fontFamily: String = "SF Mono"
    static let fontSize: CGFloat = 11
}

enum KytosCursorShape: String, CaseIterable {
    case bar = "Bar"
    case block = "Block"
    case underline = "Underline"

    var cursorStyle: CursorStyle {
        switch self {
        case .bar: return .steadyBar
        case .block: return .steadyBlock
        case .underline: return .steadyUnderline
        }
    }
}
