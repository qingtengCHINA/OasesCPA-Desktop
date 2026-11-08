import CryptoKit
import Foundation
import XCTest
@testable import OasesCPA

/// Fake release packages and fake tools for running the real install scripts with real bash,
/// without network, real binaries or listening sockets. Everything lives in a case directory
/// under `$OASES_SCRATCH` (default `${TMPDIR}/oases-b-scratch`), mode 0700, which is left in
/// place for inspection.
///
/// - Engine and CPA Manager Plus: `#!/bin/bash` scripts that wait on a `sleep 300` child, so
///   `ps` shows their path under the install root (how the lifecycle scripts recognise their
///   own processes). SIGTERM ends them (and the child) and appends `<name> TERM` to
///   `$OASES_FAKE_TERM_LOG` when that is set.
/// - Node: `--version` prints the pinned tag; with `bootstrap.mjs` it applies the gateway
///   bootstrap's rules (interfaces §4 and the Server's `bootstrap.mjs`): a secrets or data
///   directory that is a symlink or writable by group/other, or a data directory to be created
///   inside such a parent, exits 3 (`insecure_directory`); a missing or empty management key
///   exits 2; otherwise it creates `permissions.json` (0600), `pack-engine-key` and
///   `pack-store-key` (0600) and prints one JSON line. With `server.mjs` it behaves like the
///   engine fake (named `gateway`; `FAKE_GATEWAY_TERM_DELAY` seconds pass between SIGTERM and
///   the exit, like the real gateway's shutdown grace; `FAKE_GATEWAY_EXIT` exits at once).
/// - The gateway package: one top directory `oases-gateway_<ver>/` (optionally a second one).
/// - `curl` (first on PATH): copies the matching fake package for `/releases/download/` and
///   `nodejs.org/dist/` URLs to `-o`, answers health URLs with success (`/healthz` with the
///   gateway's JSON), and reads and discards the config that `-K -` passes on stdin.
/// - Fake `curl` and fake `node` append their complete argv to `argv.log`.
struct FakeArtifacts {
    let caseDirectory: URL
    let artifactsDirectory: URL
    let binDirectory: URL
    let homeDirectory: URL
    let argvLog: URL
    let pins: DeploymentPinSet
    let gatewayPayloadBase64: String
    let gatewayVersion: String

    static let engineTag = "v8.0.51"
    static let cpampTag = "v1.14.10"
    static let nodeTag = "v24.99.0"

    static var scratchRoot: URL {
        if let configured = ProcessInfo.processInfo.environment["OASES_SCRATCH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("oases-b-scratch", isDirectory: true)
    }

    /// - Parameters:
    ///   - gatewayExtraTopDirectory: a second top directory in the gateway package (must be refused).
    ///   - gatewaySHA256Override: the SHA-256 the pins claim for the gateway (a wrong one must be refused).
    static func make(
        caseName: String,
        gatewayVersion: String = "0.9.0-test",
        gatewayExtraTopDirectory: String? = nil,
        gatewaySHA256Override: String? = nil,
        gatewayCraftedEntry: String? = nil,
        nodeCraftedEntry: String? = nil
    ) throws -> FakeArtifacts {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let caseDirectory = scratchRoot.appendingPathComponent("native-install-\(caseName)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: caseDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let artifacts = caseDirectory.appendingPathComponent("artifacts", isDirectory: true)
        let bin = caseDirectory.appendingPathComponent("bin", isDirectory: true)
        let home = caseDirectory.appendingPathComponent("home", isDirectory: true)
        let staging = caseDirectory.appendingPathComponent("staging", isDirectory: true)
        for directory in [artifacts, bin, home, staging] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let argvLog = caseDirectory.appendingPathComponent("argv.log")
        fileManager.createFile(atPath: argvLog.path, contents: Data())

        var engineAssets: [DeploymentPlatform: PinnedAsset] = [:]
        var cpampAssets: [DeploymentPlatform: PinnedAsset] = [:]
        var nodeAssets: [DeploymentPlatform: PinnedAsset] = [:]
        for platform in DeploymentPlatform.allCases {
            let parts = platform.rawValue.split(separator: "/").map(String.init)
            let (os, arch) = (parts[0], parts[1])

            // Engine: the binary at the top of the package, like the real one.
            let enginePackage = "CLIProxyAPI_8.0.51_\(os)_\(arch == "arm64" ? "aarch64" : arch)"
            let engineStage = staging.appendingPathComponent(enginePackage, isDirectory: true)
            try fileManager.createDirectory(at: engineStage, withIntermediateDirectories: true)
            try writeExecutable(fakeService(name: "cli-proxy-api"), to: engineStage.appendingPathComponent("cli-proxy-api"))
            let engineFile = "\(enginePackage).tar.gz"
            try tar(create: artifacts.appendingPathComponent(engineFile), from: engineStage, entries: ["cli-proxy-api"])
            engineAssets[platform] = PinnedAsset(fileName: engineFile, sha256: try sha256(of: artifacts.appendingPathComponent(engineFile)))

            // CPA Manager Plus: one top directory named like the package.
            let cpampPackage = "cpa-manager-plus_\(cpampTag)_\(os)_\(arch)"
            let cpampStage = staging.appendingPathComponent("cpamp-\(os)-\(arch)", isDirectory: true)
            try fileManager.createDirectory(at: cpampStage.appendingPathComponent(cpampPackage), withIntermediateDirectories: true)
            try writeExecutable(fakeService(name: "cpa-manager-plus"), to: cpampStage.appendingPathComponent(cpampPackage).appendingPathComponent("cpa-manager-plus"))
            let cpampFile = "\(cpampPackage).tar.gz"
            try tar(create: artifacts.appendingPathComponent(cpampFile), from: cpampStage, entries: [cpampPackage])
            cpampAssets[platform] = PinnedAsset(fileName: cpampFile, sha256: try sha256(of: artifacts.appendingPathComponent(cpampFile)))

            // Node: one top directory node-<tag>-<os>-<x64|arm64>/ with bin/node.
            let nodePackage = "node-\(nodeTag)-\(os)-\(arch == "amd64" ? "x64" : arch)"
            let nodeStage = staging.appendingPathComponent("node-\(os)-\(arch)", isDirectory: true)
            try fileManager.createDirectory(at: nodeStage.appendingPathComponent(nodePackage).appendingPathComponent("bin"), withIntermediateDirectories: true)
            try writeExecutable(fakeNode, to: nodeStage.appendingPathComponent(nodePackage).appendingPathComponent("bin/node"))
            let nodeFile = "\(nodePackage).tar.gz"
            try tar(create: artifacts.appendingPathComponent(nodeFile), from: nodeStage, entries: [nodePackage], craftedEntry: nodeCraftedEntry)
            nodeAssets[platform] = PinnedAsset(fileName: nodeFile, sha256: try sha256(of: artifacts.appendingPathComponent(nodeFile)))
        }

        let gatewayData = try makeGatewayPackage(
            version: gatewayVersion,
            artifacts: artifacts,
            staging: staging,
            extraTopDirectory: gatewayExtraTopDirectory,
            craftedEntry: gatewayCraftedEntry
        )
        let gatewayFile = "oases-gateway_\(gatewayVersion).tar.gz"

        try writeExecutable(fakeCurl, to: bin.appendingPathComponent("curl"))

        let pins = DeploymentPinSet(
            engine: PinnedArtifact(tag: engineTag, assets: engineAssets),
            cpamp: PinnedArtifact(tag: cpampTag, assets: cpampAssets),
            node: PinnedArtifact(tag: nodeTag, assets: nodeAssets),
            gateway: GatewayBundle(
                version: gatewayVersion,
                fileName: gatewayFile,
                sha256: gatewaySHA256Override ?? sha256(of: gatewayData)
            ),
            cliDockerImage: DeploymentPinSet.current.cliDockerImage,
            cpampDockerImage: DeploymentPinSet.current.cpampDockerImage
        )
        return FakeArtifacts(
            caseDirectory: caseDirectory,
            artifactsDirectory: artifacts,
            binDirectory: bin,
            homeDirectory: home,
            argvLog: argvLog,
            pins: pins,
            gatewayPayloadBase64: gatewayData.base64EncodedString(),
            gatewayVersion: gatewayVersion
        )
    }

    /// The same case directory, fake tools and engine/CPA Manager Plus/Node packages, with a
    /// second gateway package of `version` (an upgrade target).
    func withGateway(version: String) throws -> FakeArtifacts {
        let staging = caseDirectory.appendingPathComponent("staging-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let data = try Self.makeGatewayPackage(version: version, artifacts: artifactsDirectory, staging: staging, extraTopDirectory: nil, craftedEntry: nil)
        let pins = DeploymentPinSet(
            engine: self.pins.engine,
            cpamp: self.pins.cpamp,
            node: self.pins.node,
            gateway: GatewayBundle(version: version, fileName: "oases-gateway_\(version).tar.gz", sha256: Self.sha256(of: data)),
            cliDockerImage: self.pins.cliDockerImage,
            cpampDockerImage: self.pins.cpampDockerImage
        )
        return FakeArtifacts(
            caseDirectory: caseDirectory,
            artifactsDirectory: artifactsDirectory,
            binDirectory: binDirectory,
            homeDirectory: homeDirectory,
            argvLog: argvLog,
            pins: pins,
            gatewayPayloadBase64: data.base64EncodedString(),
            gatewayVersion: version
        )
    }

    private static func makeGatewayPackage(
        version gatewayVersion: String,
        artifacts: URL,
        staging: URL,
        extraTopDirectory gatewayExtraTopDirectory: String?,
        craftedEntry: String?
    ) throws -> Data {
        let fileManager = FileManager.default
        let gatewayTop = "oases-gateway_\(gatewayVersion)"
        let gatewayStage = staging.appendingPathComponent("gateway", isDirectory: true)
        try fileManager.createDirectory(at: gatewayStage.appendingPathComponent(gatewayTop), withIntermediateDirectories: true)
        try Data("\(gatewayVersion)\n".utf8).write(to: gatewayStage.appendingPathComponent(gatewayTop).appendingPathComponent("VERSION"))
        try Data("// fake gateway\n".utf8).write(to: gatewayStage.appendingPathComponent(gatewayTop).appendingPathComponent("server.mjs"))
        try Data("// fake bootstrap\n".utf8).write(to: gatewayStage.appendingPathComponent(gatewayTop).appendingPathComponent("bootstrap.mjs"))
        var gatewayEntries = [gatewayTop]
        if let extra = gatewayExtraTopDirectory {
            try fileManager.createDirectory(at: gatewayStage.appendingPathComponent(extra), withIntermediateDirectories: true)
            try Data("stray\n".utf8).write(to: gatewayStage.appendingPathComponent(extra).appendingPathComponent("file.txt"))
            gatewayEntries.append(extra)
        }
        let gatewayFile = "\(gatewayTop).tar.gz"
        let gatewayURL = artifacts.appendingPathComponent(gatewayFile)
        try tar(create: gatewayURL, from: gatewayStage, entries: gatewayEntries, craftedEntry: craftedEntry)
        return try Data(contentsOf: gatewayURL)
    }

    /// The environment of a script run: nothing of the caller's environment but a scratch HOME,
    /// a PATH with the fake tools first, and the fakes' settings.
    func environment(extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "PATH": "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": homeDirectory.path,
            "TMPDIR": caseDirectory.path,
            "LC_ALL": "C",
            "OASES_FAKE_ARGV_LOG": argvLog.path,
            "FAKE_ARTIFACTS_DIR": artifactsDirectory.path,
            "FAKE_HEALTHZ_BODY": "{\"ok\":true,\"version\":\"\(gatewayVersion)\"}",
        ]
        extra.forEach { environment[$0.key] = $0.value }
        return environment
    }

    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `script` with `/bin/bash` from a file in the case directory (stdout and stderr go to
    /// files, so background processes can never block the read); `prelude` runs first in the
    /// same shell (for `umask`).
    func run(_ script: String, prelude: String = "", extraEnvironment: [String: String] = [:]) throws -> RunResult {
        let name = UUID().uuidString.prefix(8)
        let scriptURL = caseDirectory.appendingPathComponent("script-\(name).sh")
        let stdoutURL = caseDirectory.appendingPathComponent("stdout-\(name).txt")
        let stderrURL = caseDirectory.appendingPathComponent("stderr-\(name).txt")
        try Data((prelude + "\n" + script).utf8).write(to: scriptURL)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = environment(extra: extraEnvironment)
        process.currentDirectoryURL = caseDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }

    /// Stops every fake long-running process a run under `root` started (pid files).
    func stopProcesses(under root: URL) {
        for name in DeploymentScriptFragments.managedProcesses(topology: .gateway).reversed().map(\.pidFile) {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { continue }
            kill(pid, SIGTERM)
        }
    }

    func argv() -> String {
        (try? String(contentsOf: argvLog, encoding: .utf8)) ?? ""
    }

    // MARK: - Helpers

    static func sha256(of url: URL) throws -> String {
        sha256(of: try Data(contentsOf: url))
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `craftedEntry` adds one extra file under that exact archive path (absolute or with `..`,
    /// which a well-formed package never has), written with bsdtar's `-s` substitution.
    private static func tar(create archive: URL, from directory: URL, entries: [String], craftedEntry: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        var arguments = ["-czf", archive.path, "-C", directory.path]
        var allEntries = entries
        if let craftedEntry {
            let source = "crafted-entry-\(UUID().uuidString.prefix(8))"
            try Data("crafted\n".utf8).write(to: directory.appendingPathComponent(source))
            arguments += ["-P", "-s", "|^\(source)$|\(craftedEntry)|"]
            allEntries.append(source)
        }
        process.arguments = arguments + allEntries
        process.environment = ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FakeArtifacts", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "tar failed for \(archive.lastPathComponent)"])
        }
    }

    /// A long-running fake service: `ps` shows the script's own path; SIGTERM ends it and its
    /// child and logs `<name> TERM`.
    private static func fakeService(name: String) -> String {
        """
        #!/bin/bash
        child=""
        trap 'printf "%s\\n" "\(name) TERM" >> "${OASES_FAKE_TERM_LOG:-/dev/null}"; kill "$child" 2>/dev/null; exit 0' TERM
        sleep 300 &
        child=$!
        wait "$child"

        """
    }

    private static let fakeCurl = #"""
    #!/bin/bash
    { printf 'curl'; for arg in "$@"; do printf ' %s' "$arg"; done; printf '\n'; } >> "$OASES_FAKE_ARGV_LOG"
    out=""
    url=""
    read_stdin=0
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-o" ]; then out="$arg"; fi
      if [ "$prev" = "-K" ] && [ "$arg" = "-" ]; then read_stdin=1; fi
      case "$arg" in http://*|https://*) url="$arg" ;; esac
      prev="$arg"
    done
    if [ "$read_stdin" -eq 1 ]; then cat > /dev/null; fi
    case "$url" in
      */releases/download/*|https://nodejs.org/dist/*)
        cp "$FAKE_ARTIFACTS_DIR/$(basename "$url")" "$out" || exit 22
        ;;
      */healthz)
        if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then printf '%s' "$FAKE_HEALTHZ_BODY" > "$out"; else printf '%s' "$FAKE_HEALTHZ_BODY"; fi
        ;;
      *)
        if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then : > "$out"; fi
        ;;
    esac
    exit 0
    """#

    private static let fakeNode = #"""
    #!/bin/bash
    { printf 'node'; for arg in "$@"; do printf ' %s' "$arg"; done; printf '\n'; } >> "$OASES_FAKE_ARGV_LOG"
    if [ "${1:-}" = "--version" ]; then
      printf '%s\n' "${FAKE_NODE_VERSION:-v24.99.0}"
      exit 0
    fi
    mode=""
    for arg in "$@"; do
      case "$arg" in
        */bootstrap.mjs) mode=bootstrap ;;
        */server.mjs) mode=server ;;
      esac
    done
    if [ "$mode" = server ]; then
      if [ -n "${FAKE_GATEWAY_EXIT:-}" ]; then exit "$FAKE_GATEWAY_EXIT"; fi
      child=""
      trap 'printf "%s\n" "gateway TERM" >> "${OASES_FAKE_TERM_LOG:-/dev/null}"; sleep "${FAKE_GATEWAY_TERM_DELAY:-0}"; printf "%s\n" "gateway exited" >> "${OASES_FAKE_TERM_LOG:-/dev/null}"; kill "$child" 2>/dev/null; exit 0' TERM
      sleep 300 &
      child=$!
      wait "$child"
      exit 0
    fi
    [ "$mode" = bootstrap ] || exit 0

    data=""
    secrets=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --data-dir) data="$2"; shift 2 ;;
        --secrets-dir) secrets="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    refuse() { printf '{"ok":false,"exit_code":%s,"error":"%s","path":"%s"}\n' "$1" "$2" "$3"; printf 'bootstrap: %s: %s\n' "$2" "$3" >&2; exit "$1"; }
    mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
    not_private() { local m; m="$(mode_of "$1")"; [ $(( 8#$m & 8#022 )) -ne 0 ]; }
    if [ -n "${FAKE_BOOTSTRAP_EXIT:-}" ]; then refuse "$FAKE_BOOTSTRAP_EXIT" forced "$secrets"; fi
    [ -n "$data" ] && [ -n "$secrets" ] || refuse 3 usage ""
    if [ -L "$secrets" ]; then refuse 3 insecure_directory "$secrets"; fi
    [ -d "$secrets" ] || refuse 2 management_key_missing "$secrets/cpa-management-key"
    if not_private "$secrets"; then refuse 3 insecure_directory "$secrets"; fi
    [ -f "$secrets/cpa-management-key" ] || refuse 2 management_key_missing "$secrets/cpa-management-key"
    if [ -z "$(tr -d '[:space:]' < "$secrets/cpa-management-key")" ]; then refuse 2 management_key_empty "$secrets/cpa-management-key"; fi
    if [ -L "$data" ]; then refuse 3 insecure_directory "$data"; fi
    if [ -d "$data" ]; then
      if not_private "$data"; then refuse 3 insecure_directory "$data"; fi
    else
      parent="$(dirname "$data")"
      if [ -L "$parent" ] || not_private "$parent"; then refuse 3 insecure_directory "$parent"; fi
      mkdir -m 700 "$data" || refuse 3 path_error "$data"
    fi
    created=""
    if [ ! -e "$data/permissions.json" ]; then
      (umask 077; printf '{"schema_version":2,"keys":{}}\n' > "$data/permissions.json"); created="$created\"permissions.json\","
    fi
    mkdir -p "$data/backups/permissions" && chmod 700 "$data/backups" "$data/backups/permissions"
    if [ ! -s "$secrets/pack-engine-key" ]; then
      (umask 077; printf 'oases-int-%s\n' "$(openssl rand -hex 21)" > "$secrets/pack-engine-key"); created="$created\"pack-engine-key\","
    fi
    if [ ! -s "$secrets/pack-store-key" ]; then
      (umask 077; openssl rand -base64 32 > "$secrets/pack-store-key"); created="$created\"pack-store-key\","
    fi
    printf '{"ok":true,"exit_code":0,"data_dir":"%s","secrets_dir":"%s","created":[%s],"kept":[],"warnings":[]}\n' "$data" "$secrets" "${created%,}"
    exit 0
    """#
}
