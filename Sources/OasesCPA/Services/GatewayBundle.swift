import CryptoKit
import Foundation

/// The gateway release package the app carries as a resource (`Resources/Gateway/<fileName>`)
/// and deploys: the install script embeds it, checks this SHA-256 and unpacks it.
///
/// `script/vendor_gateway.sh` puts a package into the resources and prints the three values for
/// `bundled`; `script/package_release.sh` reads them from this file and refuses to ship a
/// "-dev" gateway (the placeholder included) or a package whose SHA-256 differs.
struct GatewayBundle: Equatable, Sendable {
    let version: String
    let fileName: String
    let sha256: String
    /// DEBUG end-to-end runs only: an absolute path of a package outside the app resources.
    let overridePath: String?

    init(version: String, fileName: String, sha256: String, overridePath: String? = nil) {
        self.version = version
        self.fileName = fileName
        self.sha256 = sha256
        self.overridePath = overridePath
    }

    static let placeholderVersion = "0.0.0-dev"
    var isPlaceholder: Bool { version == Self.placeholderVersion }

    /// The released Server package 0.1.0 (provenance in docs/acceptance/supply-chain-pins.md).
    static let bundled = GatewayBundle(
        version: "0.1.0",
        fileName: "oases-gateway_0.1.0.tar.gz",
        sha256: "6a6e1a8566a3fd9107b935da18b31a6dec847095fdc10cbc05ee11c8d363d22b"
    )

    /// The bundle that holds the app's resources.
    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    /// Where the package is: the override path, else the resource (in `Gateway/` or, when the
    /// build flattened the resources, at the top of the bundle). Nil when it is missing.
    func resourceURL(in bundle: Bundle) -> URL? {
        if let overridePath { return URL(fileURLWithPath: overridePath) }
        guard fileName.hasSuffix(".tar.gz") else { return nil }
        let name = String(fileName.dropLast(".tar.gz".count))
        return bundle.url(forResource: name, withExtension: "tar.gz", subdirectory: "Gateway")
            ?? bundle.url(forResource: name, withExtension: "tar.gz")
    }

    /// The package's bytes after its SHA-256 matched `sha256`.
    func verifiedPayload(in bundle: Bundle) throws -> Data {
        guard let url = resourceURL(in: bundle), let data = try? Data(contentsOf: url) else {
            throw DeploymentExecutionError.gatewayPackageUnavailable
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw DeploymentExecutionError.gatewayPackageUnavailable }
        return data
    }

    /// The bundled package, or in DEBUG builds the end-to-end override given by all three of
    /// `OASES_E2E_GATEWAY_TARBALL` (an absolute path of `oases-gateway_<version>.tar.gz`),
    /// `OASES_E2E_GATEWAY_SHA256` (64 lowercase hex) and `OASES_E2E_GATEWAY_VERSION`.
    /// Anything incomplete or malformed keeps the bundled package; release builds ignore them.
    static func resolve(environment: [String: String]) -> GatewayBundle {
        #if DEBUG
        guard let path = environment["OASES_E2E_GATEWAY_TARBALL"], path.hasPrefix("/"),
              let sha = environment["OASES_E2E_GATEWAY_SHA256"],
              sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let version = environment["OASES_E2E_GATEWAY_VERSION"],
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$", options: .regularExpression) != nil
        else { return bundled }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        guard fileName == "oases-gateway_\(version).tar.gz" else { return bundled }
        return GatewayBundle(version: version, fileName: fileName, sha256: sha, overridePath: path)
        #else
        return bundled
        #endif
    }
}
