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

    func newSurface(in view: NSView, context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW) -> ghostty_surface_t? {
        guard let app else { return nil }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // Use config default
        cfg.context = context
        let surface = ghostty_surface_new(app, &cfg)
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
        DispatchQueue.main.async {
            KytosGhosttyApp.shared.handleAction(action)
        }
        return true
    }

    @MainActor
    private func handleAction(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB:
            NotificationCenter.default.post(
                name: NSNotification.Name("KytosGhosttyNewTab"),
                object: nil
            )
        case GHOSTTY_ACTION_NEW_WINDOW:
            NotificationCenter.default.post(
                name: NSNotification.Name("KytosGhosttyNewWindow"),
                object: nil
            )
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title
            if let ptr = title.title {
                let str = String(cString: ptr)
                NotificationCenter.default.post(
                    name: NSNotification.Name("KytosGhosttySetTitle"),
                    object: str
                )
            }
        case GHOSTTY_ACTION_COLOR_CHANGE:
            kLog("[Ghostty] Color change action")
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            NotificationCenter.default.post(
                name: NSNotification.Name("KytosGhosttyChildExited"),
                object: nil
            )
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
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
        guard let str = NSPasteboard.general.string(forType: .string) else {
            ghostty_surface_complete_clipboard_request(nil, nil, state, false)
            return true
        }
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(nil, ptr, state, true)
        }
        return true
    }

    private static func writeClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0, let data = content.pointee.data else { return }
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
            NotificationCenter.default.post(
                name: NSNotification.Name("KytosGhosttyCloseSurface"),
                object: nil,
                userInfo: ["processAlive": processAlive]
            )
        }
    }
}
