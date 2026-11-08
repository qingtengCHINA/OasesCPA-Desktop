import XCTest
@testable import OasesCPA

final class DeploymentTopologyTests: XCTestCase {
    func testGatewayEndpointsUseFourLoopbackPorts() {
        let e = DeploymentEndpoints(topology: .gateway)
        XCTAssertEqual(e.topology, .gateway)
        XCTAssertEqual(e.clientAPIBaseURL.absoluteString, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(e.gatewayAdminBaseURL?.absoluteString, "http://127.0.0.1:18320")
        XCTAssertEqual(e.engineBaseURL.absoluteString, "http://127.0.0.1:18316")
        XCTAssertEqual(e.cpampBaseURL.absoluteString, "http://127.0.0.1:18317")
    }

    func testLegacyEndpointsKeepEngineOn8317AndNoGatewayAdmin() {
        let e = DeploymentEndpoints(topology: .legacy)
        XCTAssertEqual(e.topology, .legacy)
        XCTAssertEqual(e.clientAPIBaseURL.absoluteString, "http://127.0.0.1:8317/v1")
        XCTAssertNil(e.gatewayAdminBaseURL)
        XCTAssertEqual(e.engineBaseURL.absoluteString, "http://127.0.0.1:8317")
        XCTAssertEqual(e.cpampBaseURL.absoluteString, "http://127.0.0.1:18317")
    }

    func testPortConstantsAndTunnelPortsPerTopology() {
        XCTAssertEqual(DeploymentPorts.gatewayAPI, 8317)
        XCTAssertEqual(DeploymentPorts.gatewayAdmin, 18320)
        XCTAssertEqual(DeploymentPorts.engine, 18316)
        XCTAssertEqual(DeploymentPorts.cpamp, 18317)
        XCTAssertEqual(DeploymentPorts.legacyEngine, 8317)
        XCTAssertEqual(DeploymentPorts.tunnelPorts(for: .gateway), [8317, 18320, 18317, 18316])
        XCTAssertEqual(DeploymentPorts.tunnelPorts(for: .legacy), [8317, 18317])
    }

    func testProfileWithoutTopologyDecodesAsLegacy() throws {
        // The shape app 0.1.x saved in UserDefaults: no "topology" key.
        let legacyJSON = """
        {
          "id": "7D1E2C34-5B6A-4F8E-9C0D-1A2B3C4D5E6F",
          "targetKind": "local",
          "deploymentMethod": "native",
          "remoteHost": "",
          "remoteUser": "root",
          "remotePort": "22",
          "privateKeyPath": "",
          "installDirectory": "~/.oases-cpa",
          "isInstalled": true,
          "lastAttachedAt": 752000000
        }
        """
        let profile = try JSONDecoder().decode(DeploymentProfile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(profile.topology, .legacy)
        XCTAssertEqual(profile.installDirectory, "~/.oases-cpa")
        XCTAssertTrue(profile.isInstalled)
    }

    func testProfileRoundTripsGatewayTopology() throws {
        var profile = DeploymentProfile(
            targetKind: .ssh,
            deploymentMethod: .native,
            remoteHost: "vps.example.com",
            remoteUser: "root",
            remotePort: "22",
            privateKeyPath: "/tmp/key",
            installDirectory: "/srv/oases",
            isInstalled: true,
            lastAttachedAt: nil
        )
        XCTAssertEqual(profile.topology, .legacy, "a new profile starts as legacy until a probe says otherwise")
        profile.topology = .gateway
        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["topology"] as? String, "gateway")
        XCTAssertEqual(try JSONDecoder().decode(DeploymentProfile.self, from: data), profile)
    }

    func testUnknownTopologyValueFailsToDecode() {
        let json = """
        {"targetKind":"local","deploymentMethod":"native","remoteHost":"","remoteUser":"root","remotePort":"22",
         "privateKeyPath":"","installDirectory":"~/.oases-cpa","isInstalled":false,"topology":"mesh"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(DeploymentProfile.self, from: Data(json.utf8)))
    }

    /// A profile list with one entry this version cannot read (a `topology` from a newer
    /// version): the readable profiles still load, and saving never drops the unreadable one.
    @MainActor
    func testUnknownTopologyKeepsTheOtherProfilesAndIsNeverOverwritten() async throws {
        let suiteName = "oases-profile-lenient-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let readableID = UUID()
        let futureID = UUID()
        let stored = """
        [{"id":"\(readableID.uuidString)","targetKind":"local","deploymentMethod":"native","remoteHost":"","remoteUser":"root",
          "remotePort":"22","privateKeyPath":"","installDirectory":"/scratch/a","isInstalled":true,"topology":"gateway"},
         {"id":"\(futureID.uuidString)","targetKind":"local","deploymentMethod":"native","remoteHost":"","remoteUser":"root",
          "remotePort":"22","privateKeyPath":"","installDirectory":"/scratch/b","isInstalled":true,"topology":"mesh","futureField":[1,2]}]
        """
        let profilesKey = "oases.cpa.deployment.profiles"
        func storedFuture() throws -> [String: Any]? {
            let data = try XCTUnwrap(suite.data(forKey: profilesKey))
            let list = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            return list.first { $0["id"] as? String == futureID.uuidString }
        }
        try await DeploymentProfileStore.withDefaultsForTesting(suite) {
            suite.set(Data(stored.utf8), forKey: profilesKey)

            let loaded = DeploymentProfileStore.loadAll()
            XCTAssertEqual(loaded.map(\.id), [readableID], "the readable profile loads; the unknown one is not guessed at")
            XCTAssertTrue(DeploymentProfileStore.hasUnreadableProfiles)

            // Saving another profile keeps the unreadable entry byte-for-byte in content.
            let added = DeploymentProfile(
                targetKind: .local, deploymentMethod: .native, remoteHost: "", remoteUser: "root", remotePort: "22",
                privateKeyPath: "", installDirectory: "/scratch/c", isInstalled: true, lastAttachedAt: nil, topology: .gateway
            )
            DeploymentProfileStore.save(added)
            XCTAssertEqual(Set(DeploymentProfileStore.loadAll().map(\.id)), [readableID, added.id])
            var future = try XCTUnwrap(try storedFuture(), "the unreadable profile is still stored")
            XCTAssertEqual(future["topology"] as? String, "mesh")
            XCTAssertEqual(future["futureField"] as? [Int], [1, 2], "its unknown fields are kept")

            // Removing every readable profile does not clear the list either.
            DeploymentProfileStore.remove(readableID)
            DeploymentProfileStore.remove(added.id)
            XCTAssertEqual(DeploymentProfileStore.loadAll(), [])
            future = try XCTUnwrap(try storedFuture(), "still stored after the readable ones are gone")
            XCTAssertEqual(future["installDirectory"] as? String, "/scratch/b")
        }
    }

    /// A stored value that is not a list at all is copied aside before the first save replaces it.
    @MainActor
    func testUndecodableProfileListIsSetAsideBeforeItIsReplaced() async throws {
        let suiteName = "oases-profile-garbage-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let garbage = Data(#"{"not":"a list"}"#.utf8)
        await DeploymentProfileStore.withDefaultsForTesting(suite) {
            suite.set(garbage, forKey: "oases.cpa.deployment.profiles")
            XCTAssertEqual(DeploymentProfileStore.loadAll(), [])
            DeploymentProfileStore.save(DeploymentProfile(
                targetKind: .local, deploymentMethod: .native, remoteHost: "", remoteUser: "root", remotePort: "22",
                privateKeyPath: "", installDirectory: "/scratch/d", isInstalled: true, lastAttachedAt: nil
            ))
            XCTAssertEqual(suite.data(forKey: DeploymentProfileStore.unreadableProfilesKey), garbage)
            XCTAssertEqual(DeploymentProfileStore.loadAll().count, 1)
        }
    }

    @MainActor
    func testStoreEndpointsFollowTopologyAndClientURLHasV1() {
        let store = DeploymentStore(autoProbe: false)
        store.attachForTesting(topology: .gateway, managementKey: "m", adminKey: "a")
        XCTAssertEqual(store.topology, .gateway)
        XCTAssertEqual(store.endpoints, DeploymentEndpoints(topology: .gateway))
        XCTAssertEqual(store.engineBaseURL.absoluteString, "http://127.0.0.1:18316")
        XCTAssertEqual(store.cpampBaseURL.absoluteString, "http://127.0.0.1:18317")
        XCTAssertEqual(store.cpaClientURLString, "http://127.0.0.1:8317/v1")

        store.attachForTesting(topology: .legacy, managementKey: "m", adminKey: "a")
        XCTAssertEqual(store.engineBaseURL.absoluteString, "http://127.0.0.1:8317")
        XCTAssertEqual(store.cpaClientURLString, "http://127.0.0.1:8317/v1")
    }

    func testLifecycleHealthCheckTargetsTheTopologyEngine() {
        XCTAssertEqual(
            RuntimeLifecycleService(endpoints: DeploymentEndpoints(topology: .gateway)).engineHealthURL.absoluteString,
            "http://127.0.0.1:18316/v0/management/config"
        )
        XCTAssertEqual(
            RuntimeLifecycleService().engineHealthURL.absoluteString,
            "http://127.0.0.1:8317/v0/management/config"
        )
        XCTAssertEqual(RuntimeLifecycleService().panelHealthURL.absoluteString, "http://127.0.0.1:18317/health")
    }

    /// The session and the endpoints both come from the initializer (one source of endpoints).
    func testLifecycleHealthChecksGoThroughTheInjectedSession() async {
        URLProtocolStub.install { request, _ in
            request.url?.path == "/healthz" ? .json(200, #"{"ok":true}"#, for: request) : .json(200, "{}", for: request)
        }
        defer { URLProtocolStub.reset() }
        let healthy = await RuntimeLifecycleService(
            session: URLProtocolStub.makeSession(),
            endpoints: DeploymentEndpoints(topology: .gateway)
        ).checkConnectionHealth(cpaManagementKey: "cpa_test")
        XCTAssertTrue(healthy)
        let urls = Set(URLProtocolStub.recordedRequests.compactMap { $0.0.url?.absoluteString })
        XCTAssertTrue(urls.contains("http://127.0.0.1:18316/v0/management/config"), "\(urls)")
        XCTAssertTrue(urls.contains("http://127.0.0.1:18317/health"), "\(urls)")
        XCTAssertTrue(urls.contains("http://127.0.0.1:18320/healthz"), "\(urls)")
    }

    func testWelcomeDiagramNamesThe8317RowByTopology() {
        // In the gateway topology 8317 /v1 is the Oases gateway, not CLIProxyAPI.
        XCTAssertEqual(WelcomeRuntimeLabels.apiRowName(topology: .gateway, language: .simplifiedChinese), "Oases 网关")
        XCTAssertEqual(WelcomeRuntimeLabels.apiRowName(topology: .gateway, language: .english), "Oases gateway")
        XCTAssertEqual(WelcomeRuntimeLabels.apiRowName(topology: .legacy, language: .english), "CLIProxyAPI")
        XCTAssertTrue(WelcomeRuntimeLabels.diagramAccessibilityLabel(topology: .gateway, language: .english).contains("Oases gateway"))
        XCTAssertTrue(WelcomeRuntimeLabels.diagramAccessibilityLabel(topology: .gateway, language: .simplifiedChinese).contains("Oases 网关"))
        XCTAssertFalse(WelcomeRuntimeLabels.diagramAccessibilityLabel(topology: .legacy, language: .english).contains("gateway"))
    }

    /// Nothing attached yet: a native install would deploy the gateway, so the diagram already
    /// names the 8317 row "Oases gateway" (zh-Hans and en); an attached target shows its own.
    func testWelcomeDiagramShowsTheGatewayWhenNothingIsAttached() {
        let unattached = WelcomeRuntimeLabels.displayedTopology(topology: .legacy, hasInstalledDeployment: false, method: .native)
        XCTAssertEqual(unattached, .gateway)
        XCTAssertEqual(WelcomeRuntimeLabels.apiRowName(topology: unattached, language: .simplifiedChinese), "Oases 网关")
        XCTAssertEqual(WelcomeRuntimeLabels.apiRowName(topology: unattached, language: .english), "Oases gateway")
        XCTAssertEqual(WelcomeRuntimeLabels.displayedTopology(topology: .legacy, hasInstalledDeployment: false, method: .docker), .legacy,
                       "a Docker install has no gateway")
        XCTAssertEqual(WelcomeRuntimeLabels.displayedTopology(topology: .legacy, hasInstalledDeployment: true, method: .native), .legacy,
                       "an attached legacy deployment keeps its own label")
        XCTAssertEqual(WelcomeRuntimeLabels.displayedTopology(topology: .gateway, hasInstalledDeployment: true, method: .native), .gateway)
    }
}
