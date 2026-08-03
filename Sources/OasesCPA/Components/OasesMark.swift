import AppKit
import SwiftUI

struct OasesMark: View {
    var size: CGFloat = 31

    var body: some View {
        Image(nsImage: OasesBrandAsset.image)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Oases CPA")
    }
}

@MainActor
enum OasesBrandAsset {
    static var image: NSImage {
        load(named: "OasesBrandIcon")
    }

    static var menuBarImage: NSImage {
        load(named: "OasesMenuBarIcon")
    }

    private static func load(named name: String) -> NSImage {
        guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSApplication.shared.applicationIconImage
        }
        return image
    }

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
}
