import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import OasesCPA

/// Offscreen PNG renders of SwiftUI views for design review, without showing a window.
///
/// Opt-in: `SnapshotSupport.outputDirectory()` throws `XCTSkip` unless `OASES_SNAPSHOT_DIR`
/// names a directory, so the default `swift test` run stays headless and fast.
///
/// A render hosts the view in an `NSHostingView` inside an `NSWindow` that is positioned far
/// off-screen and NEVER ordered front, lays it out, and draws it with `cacheDisplay(in:to:)`.
///
/// Localization: while a render runs, `Bundle.main` is redirected to the app's resource
/// bundle (the one holding `zh-Hans.lproj` / `en.lproj`), so plain `Text("…")` literals
/// resolve through the `\.locale` the render sets, exactly as in the app; text built through
/// `OasesLocalization` follows the persisted language, which the render sets too.
///
/// Typical use (one call):
///
///     try SnapshotSupport.render(MyView().snapshotEnvironment(fixture),
///                                size: CGSize(width: 900, height: 600),
///                                appearance: .dark, language: .english, name: "my-view")
@MainActor
enum SnapshotSupport {
    enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark

        var nsAppearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }

        var colorScheme: ColorScheme { self == .light ? .light : .dark }
    }

    /// The languages a gallery is rendered in.
    static let languages: [AppLanguage] = [.simplifiedChinese, .english]

    /// The directory named by `OASES_SNAPSHOT_DIR` (created if needed); skips the test otherwise.
    /// `subdirectory` keeps the files of one test class together.
    static func outputDirectory(_ subdirectory: String? = nil) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OASES_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set OASES_SNAPSHOT_DIR to render the offscreen snapshots.")
        }
        var url = URL(fileURLWithPath: path, isDirectory: true)
        if let subdirectory { url.appendPathComponent(subdirectory, isDirectory: true) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Optional filter: `OASES_SNAPSHOT_ONLY` lists names (comma separated, prefix match) to
    /// render; everything else is skipped quietly. `script/snapshot.sh` sets it.
    static func isSelected(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["OASES_SNAPSHOT_ONLY"], !only.isEmpty else {
            return true
        }
        return only.split(separator: ",").contains { name.hasPrefix($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Renders `view` at `size` in `appearance` and `language` and writes `<name>.png` into
    /// `directory` (default: `outputDirectory()`). Returns the file URL, or nil when the name is
    /// filtered out by `OASES_SNAPSHOT_ONLY`.
    @discardableResult
    static func render<V: View>(
        _ view: V,
        size: CGSize,
        appearance: Appearance = .light,
        language: AppLanguage = .simplifiedChinese,
        chrome: Bool = false,
        name: String,
        directory: URL? = nil
    ) throws -> URL? {
        guard isSelected(name) else { return nil }
        let directory = try directory ?? outputDirectory()
        let session = try begin(view, size: size, appearance: appearance, language: language, chrome: chrome)
        defer { session.close() }
        return try session.write(name: name, to: directory)
    }

    /// A live render: keep the host to change state (select another section, switch the
    /// language) and write several PNGs from the same view identity.
    static func begin<V: View>(
        _ view: V,
        size: CGSize,
        appearance: Appearance = .light,
        language: AppLanguage = .simplifiedChinese,
        chrome: Bool = false
    ) throws -> Session<V> {
        LocalizedMainBundle.install()
        setLanguage(language)
        return Session(view: view, size: size, appearance: appearance, chrome: chrome)
    }

    /// Persists the in-app language (what the Settings picker does) and lets SwiftUI settle.
    static func setLanguage(_ language: AppLanguage) {
        OasesLocalization.setPreferredLanguage(language)
        settle(0.05)
    }

    /// Runs the main run loop so SwiftUI can apply state changes, tasks and layout.
    static func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Restores `Bundle.main` and the persisted language; call from `tearDown`.
    static func reset(savedLanguage: String?) {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: AppLanguage.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        }
        OasesLanguageObserver.shared.synchronize()
        LocalizedMainBundle.uninstall()
    }

    /// One hosted view in a never-shown window.
    @MainActor
    final class Session<V: View> {
        let window: NSWindow
        let host: NSHostingView<SnapshotRoot<V>>
        /// Whether the PNG includes the window chrome (title bar and toolbar).
        let chrome: Bool

        init(view: V, size: CGSize, appearance: Appearance, chrome: Bool) {
            self.chrome = chrome
            host = NSHostingView(rootView: SnapshotRoot(content: view))
            // A fixed canvas: the window must not grow to the content's ideal size.
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            window = SnapshotWindow(
                contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                styleMask: chrome ? [.titled, .resizable, .fullSizeContentView, .closable, .miniaturizable] : [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance.nsAppearance
            window.contentView = host
            window.setContentSize(size)
            // Never ordered front: the window only gives the view a backing store and an
            // effective appearance.
            SnapshotSupport.settle()
        }

        /// Writes the current state of the view as `<name>.png`.
        @discardableResult
        func write(name: String, to directory: URL) throws -> URL? {
            guard SnapshotSupport.isSelected(name) else { return nil }
            let target: NSView = chrome ? (window.contentView?.superview ?? host) : host
            target.layoutSubtreeIfNeeded()
            SnapshotSupport.settle(0.1)
            Self.flattenMaterials(in: target)
            target.layoutSubtreeIfNeeded()
            target.displayIfNeeded()
            let bounds = target.bounds
            let representation = try XCTUnwrap(target.bitmapImageRepForCachingDisplay(in: bounds))
            target.cacheDisplay(in: bounds, to: representation)
            Self.composeGlassContent(of: target, into: representation)
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url)
            return url
        }

        /// Behind-window materials (the sidebar, the toolbar) are composited by the window
        /// server and come out blank in `cacheDisplay`; within-window blending draws them into
        /// the view hierarchy, so the capture shows the sidebar and its rows. The colours are
        /// close to, not identical with, the on-screen vibrancy.
        static func flattenMaterials(in view: NSView) {
            if let effect = view as? NSVisualEffectView {
                effect.blendingMode = .withinWindow
                effect.state = .active
            }
            for subview in view.subviews {
                flattenMaterials(in: subview)
            }
        }

        /// macOS 26+ draws the sidebar pane through `NSGlassEffectView`, which `cacheDisplay`
        /// leaves blank (white even in dark mode). The pane is painted with the window ground
        /// colour and whatever its content draws offscreen is laid over it; on macOS 27 the native
        /// source list itself does NOT draw this way, so window captures show an empty sidebar
        /// pane: use `SidebarView` rendered on its own (`DesignSnapshotTests.testSidebar`) to
        /// judge the sidebar. The title bar is drawn again on top.
        static func composeGlassContent(of target: NSView, into representation: NSBitmapImageRep) {
            var glassViews: [NSView] = []
            func collect(_ view: NSView) {
                if String(describing: type(of: view)) == "NSGlassEffectView" {
                    glassViews.append(view)
                    return
                }
                view.subviews.forEach(collect)
            }
            collect(target)
            guard !glassViews.isEmpty, let context = NSGraphicsContext(bitmapImageRep: representation) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            defer { NSGraphicsContext.restoreGraphicsState() }
            func firstHostingView(in view: NSView) -> NSView? {
                if String(describing: type(of: view)).hasPrefix("NSHostingView") { return view }
                for subview in view.subviews {
                    if let found = firstHostingView(in: subview) { return found }
                }
                return nil
            }
            func draw(_ view: NSView, fill: Bool) {
                guard let layerRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: layerRep)
                var rect = view.convert(view.bounds, to: target)
                if target.isFlipped {
                    rect.origin.y = target.bounds.height - rect.maxY
                }
                if fill {
                    target.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        rect.fill()
                    }
                }
                layerRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
            // Only panes (the sidebar); toolbar platters already render their buttons.
            var composed = false
            for glass in glassViews where glass.bounds.height > 120 {
                guard let content = firstHostingView(in: glass) else { continue }
                draw(content, fill: true)
                composed = true
            }
            // The title bar (traffic lights, title, toolbar) stays on top of the pane.
            if composed, let titlebar = target.subviews.first(where: { String(describing: type(of: $0)) == "NSTitlebarContainerView" }) {
                draw(titlebar, fill: false)
            }
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }
}

/// Reports itself as the key and main window so controls draw their active look (accent
/// colour on prominent buttons, switches and selections) although it is never shown.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// What the app's scenes do: the SwiftUI locale follows the stored language. The opaque window
/// ground is drawn here because `cacheDisplay` captures only the hosting view.
struct SnapshotRoot<Content: View>: View {
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue
    var content: Content

    var body: some View {
        content
            .environment(\.locale, (AppLanguage(rawValue: languageRaw) ?? .system).locale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Fixtures

/// The app's environment objects in an idle, offline state: no saved target (the test HOME is a
/// scratch directory), no automatic probe, no Keychain read, no network. Pages show their
/// not-connected / empty states.
@MainActor
struct SnapshotFixture {
    let store: AppStore
    let deploymentStore: DeploymentStore
    let runtimeDataStore: RuntimeDataStore
    let appUpdateService: AppUpdateService

    init(section: AppSection = .dashboard) {
        store = AppStore()
        store.selectSection(section)
        deploymentStore = DeploymentStore(autoProbe: false)
        runtimeDataStore = RuntimeDataStore()
        appUpdateService = AppUpdateService(configuration: nil)
    }
}

extension View {
    /// Injects the fixture's stores the way `OasesCPAApp` does.
    @MainActor
    func snapshotEnvironment(_ fixture: SnapshotFixture) -> some View {
        environmentObject(fixture.store)
            .environmentObject(fixture.deploymentStore)
            .environmentObject(fixture.runtimeDataStore)
            .environmentObject(fixture.appUpdateService)
    }
}

// MARK: - Bundle.main redirection

/// Under `swift test` the process's main bundle is the XCTest runner, which has no string
/// tables, so `Text("…")` literals would always show their Chinese source. While installed,
/// `+[NSBundle mainBundle]` returns the app's resource bundle instead (it contains
/// `zh-Hans.lproj` and `en.lproj`), so literals resolve through the `\.locale` environment as
/// they do in the app. Only snapshot tests install it; `reset` uninstalls it.
@MainActor
enum LocalizedMainBundle {
    private static var originalImplementation: IMP?

    static var resourceBundle: Bundle? {
        let lproj = OasesLocalization.bundle(for: .english)
        guard lproj.bundleURL.pathExtension == "lproj" else { return nil }
        return Bundle(url: lproj.bundleURL.deletingLastPathComponent())
    }

    static func install() {
        guard originalImplementation == nil,
              let replacement = resourceBundle,
              let method = class_getClassMethod(Bundle.self, NSSelectorFromString("mainBundle")) else { return }
        let block: @convention(block) (AnyObject) -> Bundle = { _ in replacement }
        originalImplementation = method_setImplementation(method, imp_implementationWithBlock(block))
    }

    static func uninstall() {
        guard let originalImplementation,
              let method = class_getClassMethod(Bundle.self, NSSelectorFromString("mainBundle")) else { return }
        method_setImplementation(method, originalImplementation)
        self.originalImplementation = nil
    }
}
