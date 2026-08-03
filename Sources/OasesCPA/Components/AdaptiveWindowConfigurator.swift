import AppKit
import SwiftUI

/// A deliberately narrow SwiftUI → AppKit bridge. SwiftUI owns the scene;
/// AppKit only supplies the current screen's Dock/menu-bar-aware visible frame.
struct AdaptiveWindowConfigurator: NSViewRepresentable {
    let minimumContentSize: NSSize

    init(minimumContentSize: NSSize = WindowLayoutPolicy.preferredMinimumContentSize) {
        self.minimumContentSize = minimumContentSize
    }

    func makeNSView(context: Context) -> AdaptiveWindowConfigurationView {
        AdaptiveWindowConfigurationView(minimumContentSize: minimumContentSize)
    }

    func updateNSView(_ nsView: AdaptiveWindowConfigurationView, context: Context) {
        nsView.minimumContentSize = minimumContentSize
    }
}

final class AdaptiveWindowConfigurationView: NSView {
    private weak var configuredWindow: NSWindow?
    var minimumContentSize: NSSize

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
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeScreen(_:)),
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
            }
        }

        scheduleWindowConfiguration()
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
