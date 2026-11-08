import CryptoKit
import XCTest
@testable import OasesCPA

final class GatewayBundleTests: XCTestCase {
    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    func testBundledTarballExistsAndMatchesPinnedSHA256() throws {
        let bundled = GatewayBundle.bundled
        XCTAssertEqual(bundled.version, "0.1.0")
        XCTAssertEqual(bundled.fileName, "oases-gateway_0.1.0.tar.gz")
        XCTAssertFalse(bundled.isPlaceholder)
        XCTAssertFalse(bundled.version.contains("-dev"), "a shipped build carries a released gateway")
        let url = try XCTUnwrap(bundled.resourceURL(in: resourceBundle), "the gateway package must be an app resource")
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, bundled.sha256)
        XCTAssertEqual(digest, "6a6e1a8566a3fd9107b935da18b31a6dec847095fdc10cbc05ee11c8d363d22b")
        XCTAssertEqual(try bundled.verifiedPayload(in: resourceBundle), data)
    }

    func testPlaceholderGatewayRefusesDeployment() throws {
        let placeholder = GatewayBundle(
            version: GatewayBundle.placeholderVersion,
            fileName: "oases-gateway_0.0.0-dev.tar.gz",
            sha256: String(repeating: "a", count: 64)
        )
        XCTAssertTrue(placeholder.isPlaceholder)
        let pins = DeploymentPinSet.current.with(gateway: placeholder)
        XCTAssertThrowsError(try pins.deployable()) { error in
            guard case DeploymentExecutionError.placeholderGateway = error else {
                return XCTFail("expected .placeholderGateway, got \(error)")
            }
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                OasesLocalization.localized("此构建只含占位网关，不能部署；请先放入正式网关包")
            )
        }
        XCTAssertEqual(
            OasesLocalization.localized("此构建只含占位网关，不能部署；请先放入正式网关包", language: .simplifiedChinese),
            "此构建只含占位网关，不能部署；请先放入正式网关包"
        )
        XCTAssertNoThrow(try DeploymentPinSet.current.deployable())
    }

    func testPayloadWithAWrongDigestIsRefused() throws {
        let wrong = GatewayBundle(version: "0.1.0", fileName: "oases-gateway_0.1.0.tar.gz", sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try wrong.verifiedPayload(in: resourceBundle))
        let missing = GatewayBundle(version: "9.9.9", fileName: "oases-gateway_9.9.9.tar.gz", sha256: String(repeating: "0", count: 64))
        XCTAssertNil(missing.resourceURL(in: resourceBundle))
        XCTAssertThrowsError(try missing.verifiedPayload(in: resourceBundle))
    }

    func testResolveUsesTheEndToEndOverrideOnlyWhenComplete() throws {
        XCTAssertEqual(GatewayBundle.resolve(environment: [:]), .bundled)
        XCTAssertEqual(GatewayBundle.resolve(environment: ["OASES_E2E_GATEWAY_TARBALL": "/x/oases-gateway_0.2.0-dev.tar.gz"]), .bundled)
        let sha = String(repeating: "b", count: 64)
        let resolved = GatewayBundle.resolve(environment: [
            "OASES_E2E_GATEWAY_TARBALL": "/scratch/oases-gateway_0.2.0-dev.tar.gz",
            "OASES_E2E_GATEWAY_SHA256": sha,
            "OASES_E2E_GATEWAY_VERSION": "0.2.0-dev",
        ])
        #if DEBUG
        XCTAssertEqual(resolved.version, "0.2.0-dev")
        XCTAssertEqual(resolved.fileName, "oases-gateway_0.2.0-dev.tar.gz")
        XCTAssertEqual(resolved.sha256, sha)
        XCTAssertEqual(resolved.resourceURL(in: resourceBundle)?.path, "/scratch/oases-gateway_0.2.0-dev.tar.gz")
        #else
        XCTAssertEqual(resolved, .bundled)
        #endif
        // A malformed digest or a name that is not a gateway package keeps the bundled one.
        XCTAssertEqual(GatewayBundle.resolve(environment: [
            "OASES_E2E_GATEWAY_TARBALL": "/scratch/oases-gateway_0.2.0-dev.tar.gz",
            "OASES_E2E_GATEWAY_SHA256": "xyz",
            "OASES_E2E_GATEWAY_VERSION": "0.2.0-dev",
        ]), .bundled)
        XCTAssertEqual(GatewayBundle.resolve(environment: [
            "OASES_E2E_GATEWAY_TARBALL": "/scratch/other.tar.gz",
            "OASES_E2E_GATEWAY_SHA256": sha,
            "OASES_E2E_GATEWAY_VERSION": "0.2.0-dev",
        ]), .bundled)
    }
}
