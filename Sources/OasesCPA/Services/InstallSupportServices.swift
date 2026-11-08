import Darwin
import Foundation

/// Read-only progress of an install running on this Mac: the stage of the attempt marker the
/// install script writes, and the size of the `.part` file it is downloading. Nothing here
/// writes to the install directory. SSH targets report nothing (no extra round trips).
enum InstallProgressReader {
    static func expandedRoot(_ installDirectory: String) -> URL {
        URL(fileURLWithPath: (installDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The marker's stage, only when it belongs to the run with `controlToken` (a marker left by
    /// an earlier attempt is ignored), plus the bytes of the current download.
    static func read(
        installDirectory: String,
        controlToken: String,
        platform: DeploymentPlatform = .local,
        pins: DeploymentPinSet = .current
    ) -> InstallProgressSnapshot? {
        let root = expandedRoot(installDirectory)
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".oases-cpa-installing"), options: .uncached),
              data.count < 4_096,
              let marker = InstallAttemptMarker(contents: String(decoding: data, as: UTF8.self)),
              marker.controlToken == controlToken else { return nil }
        let part = partialDownloadPath(stage: marker.stage, root: root, platform: platform, pins: pins)
        let bytes = part.flatMap { url -> Int64? in
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
            return size.int64Value
        }
        return InstallProgressSnapshot(stage: marker.stage, receivedBytes: bytes)
    }

    /// The `.part` file the install script downloads to in `stage` (`DeploymentExecutor`,
    /// `DeploymentScriptFragments.installNode`).
    static func partialDownloadPath(stage: String, root: URL, platform: DeploymentPlatform, pins: DeploymentPinSet) -> URL? {
        func package(_ fileName: String) -> String {
            fileName.hasSuffix(".tar.gz") ? String(fileName.dropLast(".tar.gz".count)) : fileName
        }
        switch stage {
        case "download-cli":
            guard let asset = pins.engine.assets[platform] else { return nil }
            return root.appendingPathComponent("cli-proxy-api/downloads/\(package(asset.fileName)).tar.gz.part")
        case "download-cpamp":
            guard let asset = pins.cpamp.assets[platform] else { return nil }
            return root.appendingPathComponent("cpamp/downloads/\(package(asset.fileName)).tar.gz.part")
        case "install-node":
            guard let asset = pins.node.assets[platform] else { return nil }
            return root.appendingPathComponent("node/downloads/\(asset.fileName).part")
        default:
            return nil
        }
    }
}

extension DeploymentPlatform {
    /// This Mac.
    static var local: DeploymentPlatform {
        #if arch(arm64)
        .darwinARM64
        #else
        .darwinAMD64
        #endif
    }
}

/// After a cancelled fresh install on this Mac: moves what the attempt created to the Trash
/// (never deletes). Refuses a root that holds a finished deployment or is a symlink; keeps
/// `backups/` and anything it does not know; removes the root itself only when nothing else is
/// left in it.
enum InstallAttemptTrash {
    /// The entries a native install creates at the top of its root.
    static let attemptEntries = [
        "cli-proxy-api", "cpamp", "node", "gateway", "gateway-data", "logs", "secrets",
        "cli-proxy-api.pid", "cpa-manager-plus.pid", "gateway.pid",
        ".oases-cpa-installing", ".oases-cpa-failed", ".oases-cpa-paused",
        ".oases-cpa-managed", ".oases-cpa-versions", ".oases-cpa-deployment-lock",
    ]

    enum TrashError: Error, Equatable {
        case notADirectory
        case finishedDeployment
    }

    /// - Parameter trash: moves one item to the Trash (`FileManager.trashItem` in the app).
    /// - Returns: the number of entries moved.
    @discardableResult
    static func moveAttemptToTrash(root: URL, trash: (URL) throws -> Void) throws -> Int {
        let manager = FileManager.default
        let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink != true, values?.isDirectory == true else { throw TrashError.notADirectory }
        guard !manager.fileExists(atPath: root.appendingPathComponent(".oases-cpa-installed").path) else {
            throw TrashError.finishedDeployment
        }
        var moved = 0
        for entry in attemptEntries {
            let url = root.appendingPathComponent(entry)
            // `fileExists` follows symlinks; a dangling link still has attributes.
            guard (try? manager.attributesOfItem(atPath: url.path)) != nil else { continue }
            try trash(url)
            moved += 1
        }
        let remaining = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != ".DS_Store" }
        if remaining.isEmpty {
            try trash(root)
        }
        return moved
    }

    static func liveTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Before a fresh install on this Mac: are the fixed loopback ports free? A port is busy when a
/// TCP connection to 127.0.0.1 succeeds. The owner of a busy port is read with `lsof` when it
/// answers within two seconds; otherwise the copy names only the port.
enum LocalPortCheck {
    static func isListening(port: Int, host: String = "127.0.0.1") -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// The first busy port of `ports`, in order.
    static func firstBusyPort(_ ports: [Int], isListening: (Int) -> Bool = { isListening(port: $0) }) -> Int? {
        ports.first(where: isListening)
    }

    /// The command name `lsof -Fc` reports for the listener of `port` (`c<name>` lines).
    static func processName(fromLsofOutput output: String) -> String? {
        output.split(separator: "\n")
            .first(where: { $0.hasPrefix("c") && $0.count > 1 })
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty || $0.count > 64 ? nil : $0 }
    }

    static func processName(listeningOn port: Int) async -> String? {
        guard let result = try? await BoundedProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"],
            timeout: 2,
            maximumOutputBytes: 16_384
        ) else { return nil }
        return processName(fromLsofOutput: result.standardOutput)
    }

    /// The process ids `lsof -Fp` reports (`p<pid>` lines), in order, without duplicates.
    static func processIDs(fromLsofOutput output: String) -> [Int32] {
        var seen = Set<Int32>()
        return output.split(separator: "\n").compactMap { line -> Int32? in
            guard line.hasPrefix("p"), let pid = Int32(line.dropFirst()), pid > 1, seen.insert(pid).inserted else { return nil }
            return pid
        }
    }

    /// Every busy port of `ports`, in order, with the command name of its listener and the
    /// command lines of the listening processes. When `lsof` or `ps` do not answer, the command
    /// lines stay empty, which no ownership rule accepts (fails closed).
    static func busyListeners(_ ports: [Int]) async -> [LocalPortListener] {
        var listeners: [LocalPortListener] = []
        for port in ports where isListening(port: port) {
            let lsof = try? await BoundedProcessRunner.run(
                executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"],
                timeout: 2,
                maximumOutputBytes: 16_384
            )
            let output = lsof?.standardOutput ?? ""
            var commands: [String] = []
            for pid in processIDs(fromLsofOutput: output) {
                guard let ps = try? await BoundedProcessRunner.run(
                    executable: "/bin/ps",
                    arguments: ["-ww", "-p", String(pid), "-o", "command="],
                    timeout: 2,
                    maximumOutputBytes: 65_536
                ) else {
                    commands = []
                    break
                }
                let command = ps.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else {
                    commands = []
                    break
                }
                commands.append(command)
            }
            listeners.append(LocalPortListener(port: port, process: processName(fromLsofOutput: output), commands: commands))
        }
        return listeners
    }
}

/// A fixed loopback port that is already taken: the port, the command name `lsof` reports and
/// the full command lines of the processes listening on it (empty when they could not be read).
struct LocalPortListener: Equatable, Sendable {
    let port: Int
    let process: String?
    var commands: [String] = []
}

/// Which busy ports may stop a retry of a fresh install. A port counts as ours only when an
/// earlier attempt in the same install root did not finish (`.oases-cpa-failed` or
/// `.oases-cpa-installing` is there) and every process listening on it runs from a managed
/// directory of that root — the rule the install script uses for its managed processes
/// (`oases_managed_process_alive_under`: the `ps` command line contains `<root>/<dir>/`). The
/// script stops those processes itself before it moves the attempt to `backups`. Anything else
/// (another program, an unreadable owner, no unfinished attempt) still stops the retry.
enum InstallAttemptPortOwnership {
    static let attemptMarkers = [".oases-cpa-failed", ".oases-cpa-installing"]

    /// Whether `root` holds the marker of an attempt that did not finish. Read only.
    static func hasUnfinishedAttempt(root: URL) -> Bool {
        attemptMarkers.contains { marker in
            let path = root.appendingPathComponent(marker).path
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    /// Whether a `ps` command line runs from one of the managed directories of `root`. The
    /// trailing slash keeps `<root>/gateway/` from matching `<root>/gateway-data/…`.
    static func isOwned(command: String, root: String) -> Bool {
        let base = root == "/" ? "" : (root.hasSuffix("/") ? String(root.dropLast()) : root)
        guard !base.isEmpty else { return false }
        return DeploymentScriptFragments.managedProcesses(topology: .gateway).contains { process in
            command.contains("\(base)/\(process.ownedPath)/")
        }
    }

    /// The first listener that stops the retry; nil when every busy port belongs to the
    /// unfinished attempt under `attemptRoot`. Without an unfinished attempt every busy port
    /// stops it.
    static func blockingListener(_ listeners: [LocalPortListener], attemptRoot: String?) -> LocalPortListener? {
        guard let attemptRoot else { return listeners.first }
        return listeners.first { listener in
            listener.commands.isEmpty || !listener.commands.allSatisfy { isOwned(command: $0, root: attemptRoot) }
        }
    }
}
