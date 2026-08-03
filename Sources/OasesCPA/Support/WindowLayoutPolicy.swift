import AppKit

enum WindowLayoutPolicy {
    static let screenMargin: CGFloat = 16
    static let preferredMinimumContentSize = NSSize(width: 720, height: 520)

    static func minimumContentSize(
        _ preferredSize: NSSize = preferredMinimumContentSize,
        for visibleFrame: NSRect
    ) -> NSSize {
        let availableWidth = max(1, visibleFrame.width - screenMargin * 2)
        let availableHeight = max(1, visibleFrame.height - screenMargin * 2)
        return NSSize(
            width: min(preferredSize.width, availableWidth),
            height: min(preferredSize.height, availableHeight)
        )
    }

    static func clampedWindowFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        let safeFrame = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        guard safeFrame.width > 0, safeFrame.height > 0 else { return visibleFrame }

        var result = frame
        result.size.width = min(result.width, safeFrame.width)
        result.size.height = min(result.height, safeFrame.height)
        result.origin.x = min(max(result.minX, safeFrame.minX), safeFrame.maxX - result.width)
        result.origin.y = min(max(result.minY, safeFrame.minY), safeFrame.maxY - result.height)
        return result
    }
}
