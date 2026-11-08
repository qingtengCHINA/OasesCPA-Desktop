import AppKit
import SwiftUI

/// A deliberately narrow SwiftUI → AppKit bridge. SwiftUI owns the scene;
/// AppKit only supplies the current screen's Dock/menu-bar-aware visible frame.
///
/// `title`, when given, is kept on the window: scenes whose title SwiftUI resolves from the
/// macOS language (the `Settings` window, `Window("…")` scenes) show the in-app language
/// instead. Pass a string computed in a body (for example with `OasesLocalization`), so a
/// language switch updates it.
struct AdaptiveWindowConfigurator: NSViewRepresentable {
    let minimumContentSize: NSSize
    let title: String?

    init(minimumContentSize: NSSize = WindowLayoutPolicy.preferredMinimumContentSize, title: String? = nil) {
        self.minimumContentSize = minimumContentSize
        self.title = title
    }

    func makeNSView(context: Context) -> AdaptiveWindowConfigurationView {
        let view = AdaptiveWindowConfigurationView(minimumContentSize: minimumContentSize)
        view.windowTitle = title
        return view
    }

    func updateNSView(_ nsView: AdaptiveWindowConfigurationView, context: Context) {
        nsView.minimumContentSize = minimumContentSize
        nsView.windowTitle = title
    }
}

final class AdaptiveWindowConfigurationView: NSView {
    private weak var configuredWindow: NSWindow?
    private var titleObservation: NSKeyValueObservation?
    var minimumContentSize: NSSize
    /// The title this view keeps on its window; nil leaves the title to SwiftUI.
    var windowTitle: String? {
        didSet {
            guard windowTitle != oldValue else { return }
            applyWindowTitle()
        }
    }

    init(minimumContentSize: NSSize) {
        self.minimumContentSize = minimumContentSize
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if configuredWindow !== window {
            if let configuredWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didChangeScreenNotification,
                    object: configuredWindow
                )
            }
            configuredWindow = window
            titleObservation = nil
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeScreen(_:)),
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
                // SwiftUI (re)sets scene titles from the macOS language, e.g. when the Settings
                // window opens again; put the in-app title back whenever that happens.
                titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.applyWindowTitle() }
                }
            }
        }

        applyWindowTitle()
        scheduleWindowConfiguration()
    }

    private func applyWindowTitle() {
        guard let windowTitle, let window, window.title != windowTitle else { return }
        window.title = windowTitle
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {
        scheduleWindowConfiguration()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        scheduleWindowConfiguration()
    }

    private func scheduleWindowConfiguration() {
        DispatchQueue.main.async { [weak self] in
            self?.configureWindow()
        }
    }

    private func configureWindow() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        window.contentMinSize = WindowLayoutPolicy.minimumContentSize(
            minimumContentSize,
            for: visibleFrame
        )

        let clampedFrame = WindowLayoutPolicy.clampedWindowFrame(window.frame, to: visibleFrame)
        if !NSEqualRects(window.frame, clampedFrame) {
            window.setFrame(clampedFrame, display: true)
        }
    }
}
