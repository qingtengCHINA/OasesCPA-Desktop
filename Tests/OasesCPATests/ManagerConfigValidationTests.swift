import XCTest
@testable import OasesCPA

/// The address CPA Manager Plus uses to reach the engine (`config.cpaConnection.cpaBaseUrl`).
/// In the gateway topology it must be the engine on IPv4 loopback (`127.0.0.1:18316`); the
/// gateway's own ports and CPA Manager Plus itself are classic mistakes, and every listener
/// binds IPv4 loopback only (`localhost` may resolve to `::1`, where nothing listens).
final class ManagerConfigValidationTests: XCTestCase {
    func testRejectsGatewayPortsAndNonLoopbackUpstream() {
        XCTAssertNotNil(ManagerUpstreamValidation.error(for: "http://127.0.0.1:8317", topology: .gateway))
        XCTAssertNotNil(ManagerUpstreamValidation.error(for: "http://127.0.0.1:18320", topology: .gateway))
        XCTAssertNotNil(ManagerUpstreamValidation.error(for: "http://203.0.113.5:18316", topology: .gateway))
        XCTAssertNil(ManagerUpstreamValidation.error(for: "http://127.0.0.1:18316", topology: .gateway))
        XCTAssertNil(ManagerUpstreamValidation.error(for: "http://127.0.0.1:8317", topology: .legacy))
    }

    /// Legacy topology: any http(s) engine address (a Docker stack uses the container name), but
    /// never CPA Manager Plus's own loopback address 18317.
    func testLegacyTopologyRefusesCPAMPsOwnAddress() throws {
        for address in ["http://127.0.0.1:18317", "http://localhost:18317", "http://[::1]:18317", "https://127.0.0.1:18317/"] {
            let message = try XCTUnwrap(ManagerUpstreamValidation.error(for: address, topology: .legacy), address)
            XCTAssertTrue(message.contains("18317"), message)
            XCTAssertTrue(message.contains("http://127.0.0.1:8317"), "names the legacy engine: \(message)")
        }
        for address in ["http://127.0.0.1:8317", "http://cli-proxy-api:8317", "https://203.0.113.5:18317"] {
            XCTAssertNil(ManagerUpstreamValidation.error(for: address, topology: .legacy), address)
        }
    }

    func testGatewayTopologyIsIPv4LoopbackOnly() {
        for address in [
            "http://localhost:18316",
            "http://[::1]:18316",
            "http://0.0.0.0:18316",
            "http://127.0.0.2:18316",
            "http://127.0.0.1:18317",
            "https://127.0.0.1:18316",
            "http://127.0.0.1",
            "127.0.0.1:18316",
            "",
            "not a url"
        ] {
            XCTAssertNotNil(ManagerUpstreamValidation.error(for: address, topology: .gateway), address)
        }
        // Surrounding whitespace and a trailing slash are harmless.
        XCTAssertNil(ManagerUpstreamValidation.error(for: " http://127.0.0.1:18316/ ", topology: .gateway))
    }

    func testMessagesAreLocalizedAndNameTheEngine() throws {
        let gatewayPort = try XCTUnwrap(ManagerUpstreamValidation.error(for: "http://127.0.0.1:8317", topology: .gateway))
        let remote = try XCTUnwrap(ManagerUpstreamValidation.error(for: "http://localhost:18316", topology: .gateway))
        XCTAssertNotEqual(gatewayPort, remote, "a gateway port and a non-loopback host get their own explanation")
        for message in [gatewayPort, remote] {
            XCTAssertTrue(message.contains("http://127.0.0.1:18316"), message)
        }
        for source in ManagerUpstreamValidation.messageSources {
            XCTAssertNotEqual(OasesLocalization.localized(source, language: .english), source, source)
        }
    }

    func testLegacyTopologyOnlyNeedsAnHTTPAddress() {
        // A legacy Docker stack reaches the engine by its container name.
        XCTAssertNil(ManagerUpstreamValidation.error(for: "http://cli-proxy-api:8317", topology: .legacy))
        XCTAssertNotNil(ManagerUpstreamValidation.error(for: "", topology: .legacy))
        XCTAssertNotNil(ManagerUpstreamValidation.error(for: "ftp://127.0.0.1:8317", topology: .legacy))
    }
}
