import AppKit
import GhosttyKit

/// Wraps `ghostty_app_t` — one per process. Owns config, runtime callbacks, and
/// the app tick loop. Surfaces are created/destroyed via this object.
@Observable
@MainActor
final class KytosGhosttyApp {
    static let shared = KytosGhosttyApp()

    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    nonisolated(unsafe) private var config: ghostty_config_t?
    private var appearanceObserver: NSKeyValueObservation?

    // MARK: - Init

    private init() {
        // 0. Initialize ghostty global state (must be called before any other API)
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            kLog("[Ghostty] ghostty_init failed")
            return
        }

        // 1. Config
        guard let cfg = ghostty_config_new() else {
            kLog("[Ghostty] ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        config = cfg

        // 2. Runtime config with C callbacks
        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { ud in KytosGhosttyApp.wakeupCallback(ud) }
        rt.action_cb = { app, target, action in KytosGhosttyApp.actionCallback(app, target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state in KytosGhosttyApp.readClipboardCallback(ud, location: loc, state: state) }
        rt.confirm_read_clipboard_cb = nil
        rt.write_clipboard_cb = { ud, loc, content, len, confirm in KytosGhosttyApp.writeClipboardCallback(ud, location: loc, content: content, len: len, confirm: confirm) }
        rt.close_surface_cb = { ud, processAlive in KytosGhosttyApp.closeSurfaceCallback(ud, processAlive: processAlive) }

        // 3. Create app
        guard let ghosttyApp = ghostty_app_new(&rt, cfg) else {
            kLog("[Ghostty] ghostty_app_new failed")
            return
        }
        app = ghosttyApp
        kLog("[Ghostty] App initialized")

        // 4. Observe system appearance for color scheme
        let appHandle = ghosttyApp
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance, options: [.new, .initial]
        ) { _, change in
            guard let appearance = change.newValue else { return }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark
                ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(appHandle, scheme)
            // Also refresh all surfaces so theme changes apply immediately
            DispatchQueue.main.async {
                KytosGhosttyApp.shared.refreshAllSurfaces(scheme: scheme)
            }
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    // MARK: - Tick

    func appTick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Surface lifecycle

    func newSurface(in view: NSView, context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW, workingDirectory: String? = nil) -> ghostty_surface_t? {
        guard let app else { return nil }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // Use config default
        cfg.context = context

        // Set working directory for PWD restoration
        var wdPtr: UnsafeMutablePointer<CChar>?
        if let wd = workingDirectory, !wd.isEmpty {
            wdPtr = strdup(wd)
            cfg.working_directory = UnsafePointer(wdPtr!)
        }

        // Set shell environment variables
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let features = "ghostty,splits"
        let envKey1 = strdup("KYTOS_SHELL_VERSION")!
        let envVal1 = strdup(version)!
        let envKey2 = strdup("KYTOS_SHELL_FEATURES")!
        let envVal2 = strdup(features)!
        var envVars: [ghostty_env_var_s] = [
            ghostty_env_var_s(key: envKey1, value: envVal1),
            ghostty_env_var_s(key: envKey2, value: envVal2),
        ]
        cfg.env_vars = UnsafeMutablePointer(mutating: &envVars)
        cfg.env_var_count = envVars.count

        let surface = ghostty_surface_new(app, &cfg)

        // Free strdup'd strings after libghostty has copied them
        free(envKey1); free(envVal1)
        free(envKey2); free(envVal2)
        if let wdPtr { free(wdPtr) }

        if surface == nil {
            kLog("[Ghostty] ghostty_surface_new failed")
        }
        return surface
    }

    // MARK: - Config

    func reloadConfig() {
        guard let app else { return }
        guard let cfg = ghostty_config_new() else { return }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
        kLog("[Ghostty] Config reloaded")
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, scheme)
        refreshAllSurfaces(scheme: scheme)
    }

    /// Refresh all live surfaces after a color scheme or config change.
    func refreshAllSurfaces(scheme: ghostty_color_scheme_e? = nil) {
        for (_, view) in KytosGhosttyView.viewRegistry {
            guard let surface = view.surface else { continue }
            if let scheme {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
            ghostty_surface_refresh(surface)
        }
    }

    // MARK: - Callbacks (static, C-compatible)

    private static func wakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
        guard let ud = userdata else { return }
        let app = Unmanaged<KytosGhosttyApp>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async { app.appTick() }
    }

    private static func actionCallback(
        _ ghosttyApp: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        // Extract the source view if target is a specific surface
        var sourceView: KytosGhosttyView?
        if target.tag == GHOSTTY_TARGET_SURFACE {
            let surface = target.target.surface
            if let ud = ghostty_surface_userdata(surface) {
                sourceView = Unmanaged<KytosGhosttyView>.fromOpaque(ud).takeUnretainedValue()
            }
        }

        // IMPORTANT: Copy all C string data synchronously before dispatching,
        // because the C pointers in `action` may be freed after this callback returns.
        let safeAction = SafeAction(from: action)

        DispatchQueue.main.async {
            KytosGhosttyApp.shared.handleAction(action, sourceView: sourceView, safe: safeAction)
        }
        return true
    }

    /// Pre-extracted string data from ghostty_action_s, safe to use across threads.
    private struct SafeAction {
        var title: String?
        var pwd: String?
        var searchNeedle: String?

        init(from action: ghostty_action_s) {
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                if let ptr = action.action.set_title.title {
                    self.title = String(cString: ptr)
                }
            case GHOSTTY_ACTION_PWD:
                if let ptr = action.action.pwd.pwd {
                    self.pwd = String(cString: ptr)
                }
            case GHOSTTY_ACTION_START_SEARCH:
                if let ptr = action.action.start_search.needle {
                    self.searchNeedle = String(cString: ptr)
                }
            default:
                break
            }
        }
    }

    @MainActor
    private func handleAction(_ action: ghostty_action_s, sourceView: KytosGhosttyView?, safe: SafeAction = SafeAction(from: ghostty_action_s())) {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB:
            Self.postWindowScopedNotification(name: NSNotification.Name("KytosGhosttyNewTab"), sourceView: sourceView)
        case GHOSTTY_ACTION_NEW_WINDOW:
            Self.postWindowScopedNotification(name: NSNotification.Name("KytosGhosttyNewWindow"), sourceView: sourceView)
        case GHOSTTY_ACTION_NEW_SPLIT:
            let splitDir = action.action.new_split
            let direction: KytosSplitDirection = (splitDir == GHOSTTY_SPLIT_DIRECTION_DOWN || splitDir == GHOSTTY_SPLIT_DIRECTION_UP)
                ? .vertical : .horizontal
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttyNewSplit"),
                sourceView: sourceView,
                userInfo: ["direction": direction]
            )
        case GHOSTTY_ACTION_GOTO_SPLIT:
            let gotoDir = action.action.goto_split
            kLog("[Ghostty] GOTO_SPLIT action: rawValue=\(gotoDir.rawValue)")
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttyGotoSplit"),
                sourceView: sourceView,
                userInfo: ["direction": gotoDir.rawValue]
            )
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = action.action.resize_split
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttyResizeSplit"),
                sourceView: sourceView,
                userInfo: ["amount": resize.amount, "direction": resize.direction]
            )
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            Self.postWindowScopedNotification(name: NSNotification.Name("KytosGhosttyEqualizeSplits"), sourceView: sourceView)
        case GHOSTTY_ACTION_SET_TITLE:
            if let str = safe.title {
                sourceView?.title = str
                kLog("[Ghostty] SET_TITLE: '\(str)' for view \(sourceView?.paneID?.uuidString.prefix(8) ?? "nil")")
                Self.postWindowScopedNotification(
                    name: NSNotification.Name("KytosGhosttySetTitle"),
                    sourceView: sourceView,
                    userInfo: ["title": str]
                )
            }
        case GHOSTTY_ACTION_COLOR_CHANGE:
            kLog("[Ghostty] Color change action")
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            Self.postWindowScopedNotification(name: NSNotification.Name("KytosGhosttyChildExited"), sourceView: sourceView)
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
        case GHOSTTY_ACTION_PWD:
            if let pwd = safe.pwd {
                sourceView?.pwd = pwd
                kLog("[Ghostty] PWD: '\(pwd)' for view \(sourceView?.paneID?.uuidString.prefix(8) ?? "nil")")
                Self.postWindowScopedNotification(
                    name: NSNotification.Name("KytosGhosttyPwd"),
                    sourceView: sourceView,
                    userInfo: ["pwd": pwd]
                )
            }
        case GHOSTTY_ACTION_SCROLLBAR:
            let sb = action.action.scrollbar
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttyScrollbar"),
                sourceView: sourceView,
                userInfo: ["total": sb.total, "offset": sb.offset, "len": sb.len]
            )
        case GHOSTTY_ACTION_CELL_SIZE:
            let cs = action.action.cell_size
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhottyCellSize"),
                sourceView: sourceView,
                userInfo: ["width": cs.width, "height": cs.height]
            )
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let pr = action.action.progress_report
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttyProgressReport"),
                sourceView: sourceView,
                userInfo: ["state": pr.state.rawValue, "progress": pr.progress]
            )
        case GHOSTTY_ACTION_START_SEARCH:
            var info: [String: Any] = [:]
            if let needle = safe.searchNeedle { info["needle"] = needle }
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttyStartSearch"),
                sourceView: sourceView,
                userInfo: info
            )
        case GHOSTTY_ACTION_END_SEARCH:
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttyEndSearch"),
                sourceView: sourceView
            )
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttySearchTotal"),
                sourceView: sourceView,
                userInfo: ["total": total]
            )
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            Self.postWindowScopedNotification(
                name: NSNotification.Name("KytosGhosttySearchSelected"),
                sourceView: sourceView,
                userInfo: ["selected": selected]
            )
        default:
            kLog("[Ghostty] Unhandled action: \(action.tag.rawValue)")
        }
    }

    private static func readClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let state else { return false }
        let sourceView = userdata.map { Unmanaged<KytosGhosttyView>.fromOpaque($0).takeUnretainedValue() }
        guard let surface = sourceView?.surface else {
            kLog("[Ghostty] Clipboard read ignored: missing surface")
            return false
        }
        let str = if Thread.isMainThread {
            NSPasteboard.general.string(forType: .string)
        } else {
            DispatchQueue.main.sync {
                NSPasteboard.general.string(forType: .string)
            }
        }
        guard let str else {
            ghostty_surface_complete_clipboard_request(surface, nil, state, false)
            return true
        }
        guard let duplicated = strdup(str) else {
            ghostty_surface_complete_clipboard_request(surface, nil, state, false)
            return true
        }
        ghostty_surface_complete_clipboard_request(surface, duplicated, state, true)
        free(duplicated)
        return true
    }

    private static func writeClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }

        let entries = UnsafeBufferPointer(start: content, count: len)
        let preferredEntry = entries.first {
            guard let mime = $0.mime else { return false }
            let mimeString = String(cString: mime)
            return mimeString == "text/plain;charset=utf-8" || mimeString == "text/plain" || mimeString == "public.utf8-plain-text"
        } ?? entries.first

        guard let selectedEntry = preferredEntry,
              let data = selectedEntry.data else {
            kLog("[Ghostty] Clipboard write ignored: no usable clipboard entry count=\(len)")
            return
        }

        let str = String(cString: data)
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    private static func closeSurfaceCallback(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        DispatchQueue.main.async {
            var userInfo: [String: Any] = ["processAlive": processAlive]
            if let windowID = KytosAppModel.shared.windowID(for: NSApp.keyWindow) {
                userInfo["windowID"] = windowID
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("KytosGhosttyCloseSurface"),
                object: nil,
                userInfo: userInfo
            )
        }
    }

    @MainActor
    private static func postWindowScopedNotification(
        name: NSNotification.Name,
        sourceView: KytosGhosttyView?,
        userInfo: [String: Any] = [:]
    ) {
        var info = userInfo
        if let windowID = KytosAppModel.shared.windowID(for: sourceView?.window) {
            info["windowID"] = windowID
        }
        NotificationCenter.default.post(name: name, object: sourceView, userInfo: info.isEmpty ? nil : info)
    }
}
