import Foundation
import Darwin

enum SSHHostKeyConfirmationReason: String, Equatable, Sendable {
    case firstUse
    case changed
}

struct SSHHostKeyRecord: Equatable, Sendable {
    let hostPattern: String
    let algorithm: String
    let publicKey: String
    let fingerprint: String
}

typealias SSHHostKeyScanner = @Sendable (_ host: String, _ port: Int) throws -> SSHHostKeyRecord

struct SSHProcessResult: Equatable, Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool
}

typealias SSHProcessRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ standardInput: String?,
    _ timeout: TimeInterval
) throws -> SSHProcessResult

private final class SSHBoundedOutputCollector: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var bytes = Data()
    private var wasTruncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard bytes.count < maximumBytes else {
            wasTruncated = true
            return
        }
        let remaining = maximumBytes - bytes.count
        if chunk.count > remaining {
            bytes.append(chunk.prefix(remaining))
            wasTruncated = true
        } else {
            bytes.append(chunk)
        }
    }

    var result: (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, wasTruncated)
    }
}

struct SSHHostKeyConfirmation: Equatable, Sendable, Identifiable {
    let host: String
    let port: Int
    let algorithm: String
    let fingerprint: String
    let knownHostsLine: String
    let reason: SSHHostKeyConfirmationReason
    let previousFingerprint: String?

    var id: String {
        "\(host):\(port):\(algorithm):\(fingerprint)"
    }
}

enum SSHHostKeyInspection: Equatable, Sendable {
    case trusted
    case needsConfirmation(SSHHostKeyConfirmation)
}

enum SSHConnectionError: LocalizedError, Equatable, Sendable {
    case cannotPrepareKnownHosts(String)
    case invalidPort
    case invalidHost
    case invalidUser
    case invalidPrivateKeyPath
    case hostKeyScanFailed(String)
    case hostKeyConfirmationRequired(SSHHostKeyConfirmation)
    case staleHostKeyConfirmation
    case invalidHostKeyConfirmation

    var errorDescription: String? {
        switch self {
        case .cannotPrepareKnownHosts(let message):
            return "无法准备 SSH 主机指纹文件：\(message)"
        case .invalidPort:
            return OasesLocalization.localized("SSH 端口必须是 1-65535 之间的数字。")
        case .invalidHost:
            return OasesLocalization.localized("SSH 主机名或 IP 地址包含无效字符。")
        case .invalidUser:
            return OasesLocalization.localized("SSH 用户名包含无效字符。")
        case .invalidPrivateKeyPath:
            return OasesLocalization.localized("SSH 私钥路径不能为空，也不能包含换行或控制字符。")
        case .hostKeyScanFailed(let message):
            return OasesLocalization.localizedFormat("无法读取 SSH 主机指纹：%@", message)
        case .hostKeyConfirmationRequired(let confirmation):
            let action = confirmation.reason == .changed ? "变更" : "首次"
            return "SSH 主机需要\(action)指纹确认：\(confirmation.host):\(confirmation.port)（\(confirmation.fingerprint)）"
        case .staleHostKeyConfirmation:
            return OasesLocalization.localized("SSH 主机指纹确认已过期；当前 known_hosts 未被覆盖，请重新核验。")
        case .invalidHostKeyConfirmation:
            return OasesLocalization.localized("SSH 主机指纹确认数据无效，已停止连接。")
        }
    }
}

enum SSHConnectionService {
    private static let knownHostsFileName = "known_hosts"
    private static let knownHostsLockFileName = ".known_hosts.lock"
    private static let maximumKnownHostsBytes = 4 * 1024 * 1024
    private static let maximumToolOutputBytes = 256 * 1024
    private static let maximumToolInputBytes = 64 * 1024
    private static let stateLock = NSLock()

#if DEBUG
    nonisolated(unsafe) private static var processRunnerOverride: SSHProcessRunner?

    static func runSSHToolForTesting(
        executable: String,
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval = 10
    ) throws -> SSHProcessResult {
        try runProcess(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    nonisolated(unsafe) private static var knownHostsURLOverride: URL?

    /// Runs `operation` with the app's known_hosts file replaced by `url` (tests must never
    /// create or change the real one under Application Support).
    static func withKnownHostsFileURLForTesting<T>(_ url: URL, operation: () throws -> T) rethrows -> T {
        let previous = knownHostsURLOverride
        knownHostsURLOverride = url
        defer { knownHostsURLOverride = previous }
        return try operation()
    }

    static func withSSHToolRunnerForTesting<T>(
        _ runner: @escaping SSHProcessRunner,
        operation: () throws -> T
    ) rethrows -> T {
        let previous = processRunnerOverride
        processRunnerOverride = runner
        defer { processRunnerOverride = previous }
        return try operation()
    }
#endif

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private struct KnownHostsRead {
        let document: KnownHostsDocument
        let identity: FileIdentity?
    }

    static func connectionArguments(port: String, privateKeyPath: String) throws -> [String] {
        _ = try validatedPort(port)
        try validatePrivateKeyPath(privateKeyPath)
        let knownHostsPath = try prepareKnownHostsFile()
        try verifyKnownHostsFileForConnection()
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-p", port,
            "-i", privateKeyPath
        ]
    }

    /// `ssh -N` arguments that forward exactly the topology's loopback ports. Both ends of every
    /// forward name `127.0.0.1` explicitly, so the local listener never binds another interface
    /// (whatever `GatewayPorts` says) and the remote side never reaches beyond its loopback.
    static func tunnelArguments(
        host: String,
        user: String,
        port: String,
        privateKeyPath: String,
        topology: DeploymentTopology
    ) throws -> [String] {
        let validatedHost = try validateHost(host)
        let validatedUser = try validateUser(user)
        _ = try validatedPort(port)
        try validatePrivateKeyPath(privateKeyPath)

        let forwards = DeploymentPorts.tunnelPorts(for: topology).flatMap { forwardedPort in
            ["-L", "127.0.0.1:\(forwardedPort):127.0.0.1:\(forwardedPort)"]
        }
        return [
            "-N",
            "-o", "ExitOnForwardFailure=yes"
        ] + (try connectionArguments(port: port, privateKeyPath: privateKeyPath)) + forwards + [
            "\(validatedUser)@\(validatedHost)"
        ]
    }

    static func inspectHostKey(
        host: String,
        port: String,
        knownHostsURL: URL? = nil,
        scanner: SSHHostKeyScanner? = nil
    ) throws -> SSHHostKeyInspection {
        let validatedHost = try validateHost(host)
        let validatedPort = try validatedPort(port)
        let hostPattern = knownHostsTarget(host: validatedHost, port: validatedPort)
        let scanned = try (scanner ?? liveHostKeyScanner)(validatedHost, validatedPort)
        let record = try validateScannedRecord(scanned, expectedHostPattern: hostPattern)
        let fileURL = try knownHostsURL ?? knownHostsFileURL()

        stateLock.lock()
        defer { stateLock.unlock() }
        return try withSecureKnownHostsParent(at: fileURL, create: true) { parentFD, fileName in
            try withKnownHostsLock(parentFD: parentFD) {
                let read = try readKnownHostsDocument(parentFD: parentFD, fileName: fileName)
                let entries = read.document.entries
                let matchingEntries = entries.filter { $0.hostPatterns.contains(hostPattern) }
                guard let existing = matchingEntries.first else {
                    return .needsConfirmation(
                        confirmation(
                            for: record,
                            host: validatedHost,
                            port: validatedPort,
                            reason: .firstUse,
                            previousFingerprint: nil
                        )
                    )
                }

                if matchingEntries.contains(where: {
                    $0.marker == nil &&
                    $0.algorithm == record.algorithm &&
                    $0.publicKey == record.publicKey
                }) {
                    return .trusted
                }

                let previousEntry = matchingEntries.first(where: { $0.algorithm == record.algorithm }) ?? existing
                let previousFingerprint = try fingerprint(for: previousEntry)
                return .needsConfirmation(
                    confirmation(
                        for: record,
                        host: validatedHost,
                        port: validatedPort,
                        reason: .changed,
                        previousFingerprint: previousFingerprint
                    )
                )
            }
        }
    }

    static func confirmHostKey(
        _ confirmation: SSHHostKeyConfirmation,
        knownHostsURL: URL? = nil
    ) throws {
        try validateConfirmation(confirmation)
        let fileURL = try knownHostsURL ?? knownHostsFileURL()
        let hostPattern = knownHostsTarget(host: confirmation.host, port: confirmation.port)

        stateLock.lock()
        defer { stateLock.unlock() }
        try withSecureKnownHostsParent(at: fileURL, create: true) { parentFD, fileName in
            try withKnownHostsLock(parentFD: parentFD) {
                let read = try readKnownHostsDocument(parentFD: parentFD, fileName: fileName)
                var document = read.document
                let entries = document.entries
                let matchingIndexes = entries.indices.filter { entries[$0].hostPatterns.contains(hostPattern) }
                let confirmationKey = publicKey(from: confirmation.knownHostsLine)

                if matchingIndexes.contains(where: {
                    entries[$0].marker == nil &&
                        entries[$0].algorithm == confirmation.algorithm &&
                        entries[$0].publicKey == confirmationKey
                }) {
                    return
                }

                switch confirmation.reason {
                case .firstUse:
                    guard matchingIndexes.isEmpty else {
                        throw SSHConnectionError.staleHostKeyConfirmation
                    }
                case .changed:
                    guard let index = matchingIndexes.first(where: {
                        (try? fingerprint(for: entries[$0])) == confirmation.previousFingerprint
                    }) else {
                        throw SSHConnectionError.staleHostKeyConfirmation
                    }

                    if entries[index].algorithm == confirmation.algorithm {
                        let lineIndex = entries[index].lineIndex
                        guard document.lines.indices.contains(lineIndex) else {
                            throw SSHConnectionError.staleHostKeyConfirmation
                        }
                        document.lines[lineIndex] = confirmation.knownHostsLine
                    } else {
                        document.lines.append(confirmation.knownHostsLine)
                    }
                    try writeKnownHostsAtomically(
                        document.lines,
                        parentFD: parentFD,
                        fileName: fileName,
                        expectedIdentity: read.identity
                    )
                    return
                }

                document.lines.append(confirmation.knownHostsLine)
                try writeKnownHostsAtomically(
                    document.lines,
                    parentFD: parentFD,
                    fileName: fileName,
                    expectedIdentity: read.identity
                )
            }
        }
    }

    static func userFacingError(_ rawMessage: String, fallback: String) -> String {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = message.lowercased()
        if message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || message.contains("Host key verification failed") {
            return OasesLocalization.localized("SSH 主机指纹与 App 已记录的值不一致；为避免连接到错误的服务器，本次连接已拒绝。确认 VPS 身份后，再更新 App 专属 known_hosts。")
        }
        if lowercased.contains("permission denied (publickey") {
            return OasesLocalization.localized("SSH 公钥认证失败；请确认远程用户、私钥和 VPS 的 authorized_keys 配置。")
        }
        if lowercased.contains("could not resolve hostname") {
            return OasesLocalization.localized("无法解析 SSH 主机名；请检查 VPS 主机名或 IP 地址。")
        }
        if lowercased.contains("connection timed out") || (lowercased.contains("connect to host") && lowercased.contains("timed out")) {
            return OasesLocalization.localized("SSH 连接超时；请检查 VPS 地址、防火墙和 SSH 端口。")
        }
        return message.isEmpty ? fallback : message
    }

    static func prepareKnownHostsFile() throws -> String {
        let fileURL = try knownHostsFileURL()
        stateLock.lock()
        defer { stateLock.unlock() }
        try withSecureKnownHostsParent(at: fileURL, create: true) { parentFD, fileName in
            try withKnownHostsLock(parentFD: parentFD) {
                let descriptor = try openAt(
                    parentFD,
                    fileName,
                    flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                    mode: mode_t(0o600)
                )
                defer { Darwin.close(descriptor) }
                _ = try regularFileIdentity(descriptor)
                guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw cannotPrepare("文件权限设置失败")
                }
                guard Darwin.fsync(descriptor) == 0 else {
                    throw cannotPrepare("文件同步失败")
                }
            }
        }
        return fileURL.path
    }

    static func verifyKnownHostsFileForConnection() throws {
        let fileURL = try knownHostsFileURL()
        stateLock.lock()
        defer { stateLock.unlock() }
        try withSecureKnownHostsParent(at: fileURL, create: false) { parentFD, fileName in
            try withKnownHostsLock(parentFD: parentFD) {
                _ = try readKnownHostsDocument(parentFD: parentFD, fileName: fileName)
            }
        }
    }

    private struct KnownHostsEntry: Equatable {
        let line: String
        let lineIndex: Int
        let marker: String?
        let hostPatterns: [String]
        let algorithm: String
        let publicKey: String
    }

    private struct KnownHostsDocument {
        var lines: [String]
        let entries: [KnownHostsEntry]
    }

    private static var liveHostKeyScanner: SSHHostKeyScanner {
        { host, port in
            let result = try runProcess(
                executable: "/usr/bin/ssh-keyscan",
                arguments: ["-T", "8", "-p", String(port), host]
            )
            let records = result.standardOutput
                .split(separator: "\n")
                .compactMap { parseScannedLine(String($0)) }
            guard let record = records.first(where: { $0.algorithm == "ssh-ed25519" }) ?? records.first else {
                throw SSHConnectionError.hostKeyScanFailed("ssh-keyscan 未返回主机 key")
            }
            return SSHHostKeyRecord(
                hostPattern: record.hostPattern,
                algorithm: record.algorithm,
                publicKey: record.publicKey,
                fingerprint: try fingerprint(algorithm: record.algorithm, publicKey: record.publicKey)
            )
        }
    }

    private static func validateHost(_ host: String) throws -> String {
        guard !host.isEmpty,
              !host.hasPrefix("-"),
              host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              host.count <= 253,
              host.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (value >= 48 && value <= 57) ||
                      (value >= 65 && value <= 90) ||
                      (value >= 97 && value <= 122) ||
                      ".-_:[%]".unicodeScalars.contains(scalar)
              })
        else {
            throw SSHConnectionError.invalidHost
        }
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else {
                throw SSHConnectionError.invalidHost
            }
            let unbracketed = String(host.dropFirst().dropLast())
            guard unbracketed.contains(":"), !unbracketed.contains("[") && !unbracketed.contains("]") else {
                throw SSHConnectionError.invalidHost
            }
            return unbracketed
        }
        return host
    }

    private static func validateUser(_ user: String) throws -> String {
        let value = user.isEmpty ? "root" : user
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("-"),
              value.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  let number = scalar.value
                  return (number >= 48 && number <= 57) ||
                      (number >= 65 && number <= 90) ||
                      (number >= 97 && number <= 122) ||
                      ".-_".unicodeScalars.contains(scalar)
              })
        else {
            throw SSHConnectionError.invalidUser
        }
        return value
    }

    private static func validatePrivateKeyPath(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == path,
              !path.hasPrefix("-"),
              !path.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0 || scalar.value == 10 || scalar.value == 13 || scalar.value < 32
              })
        else {
            throw SSHConnectionError.invalidPrivateKeyPath
        }
    }

    private static func validatedPort(_ value: String) throws -> Int {
        guard let port = Int(value), (1...65_535).contains(port), value == String(port) else {
            throw SSHConnectionError.invalidPort
        }
        return port
    }

    private static func knownHostsTarget(host: String, port: Int) -> String {
        let normalizedHost: String
        if host.hasPrefix("[") && host.hasSuffix("]") {
            normalizedHost = String(host.dropFirst().dropLast())
        } else {
            normalizedHost = host
        }
        if normalizedHost.contains(":") {
            return "[\(normalizedHost)]:\(port)"
        }
        return port == 22 ? normalizedHost : "[\(normalizedHost)]:\(port)"
    }

    private static func confirmation(
        for record: SSHHostKeyRecord,
        host: String,
        port: Int,
        reason: SSHHostKeyConfirmationReason,
        previousFingerprint: String?
    ) -> SSHHostKeyConfirmation {
        SSHHostKeyConfirmation(
            host: host,
            port: port,
            algorithm: record.algorithm,
            fingerprint: record.fingerprint,
            knownHostsLine: "\(record.hostPattern) \(record.algorithm) \(record.publicKey)",
            reason: reason,
            previousFingerprint: previousFingerprint
        )
    }

    private static func validateConfirmation(_ confirmation: SSHHostKeyConfirmation) throws {
        _ = try validateHost(confirmation.host)
        let fields = confirmation.knownHostsLine
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let confirmationKey = publicKey(from: confirmation.knownHostsLine)
        guard (1...65_535).contains(confirmation.port),
              fields.count == 3,
              isValidHostKeyAlgorithm(confirmation.algorithm),
              isValidPublicKey(confirmationKey),
              confirmation.fingerprint.hasPrefix("SHA256:")
        else {
            throw SSHConnectionError.invalidHostKeyConfirmation
        }
        switch confirmation.reason {
        case .firstUse where confirmation.previousFingerprint == nil:
            break
        case .changed where confirmation.previousFingerprint?.hasPrefix("SHA256:") == true:
            break
        default:
            throw SSHConnectionError.invalidHostKeyConfirmation
        }
        let target = knownHostsTarget(host: confirmation.host, port: confirmation.port)
        guard confirmation.knownHostsLine.hasPrefix("\(target) \(confirmation.algorithm) ") else {
            throw SSHConnectionError.invalidHostKeyConfirmation
        }
        guard (try? fingerprint(algorithm: confirmation.algorithm, publicKey: confirmationKey)) == confirmation.fingerprint else {
            throw SSHConnectionError.invalidHostKeyConfirmation
        }
    }

    private static func validateScannedRecord(
        _ record: SSHHostKeyRecord,
        expectedHostPattern: String
    ) throws -> SSHHostKeyRecord {
        guard record.hostPattern == expectedHostPattern,
              isValidHostKeyAlgorithm(record.algorithm),
              isValidPublicKey(record.publicKey),
              record.fingerprint.hasPrefix("SHA256:")
        else {
            throw SSHConnectionError.hostKeyScanFailed("ssh-keyscan 返回了无效的主机 key")
        }
        return try recordWithFingerprint(record)
    }

    private static func isValidHostKeyAlgorithm(_ algorithm: String) -> Bool {
        guard !algorithm.isEmpty,
              algorithm.count <= 128,
              algorithm.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (value >= 48 && value <= 57) ||
                      (value >= 65 && value <= 90) ||
                      (value >= 97 && value <= 122) ||
                      "-._@".unicodeScalars.contains(scalar)
              })
        else {
            return false
        }
        return algorithm.hasPrefix("ssh-") ||
            algorithm.hasPrefix("ecdsa-") ||
            algorithm.hasPrefix("sk-") ||
            algorithm.hasPrefix("rsa-")
    }

    private static func isValidPublicKey(_ key: String) -> Bool {
        guard !key.isEmpty,
              key.count <= 16_384,
              !key.contains(where: { $0.isWhitespace }) else {
            return false
        }
        return Data(base64Encoded: key) != nil
    }

    private static func recordWithFingerprint(_ record: SSHHostKeyRecord) throws -> SSHHostKeyRecord {
        let computed = try fingerprint(algorithm: record.algorithm, publicKey: record.publicKey)
        guard computed == record.fingerprint else {
            throw SSHConnectionError.hostKeyScanFailed("主机 key 指纹校验失败")
        }
        return record
    }

    private static func parseScannedLine(_ line: String) -> SSHHostKeyRecord? {
        let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 3 else { return nil }
        return SSHHostKeyRecord(hostPattern: fields[0], algorithm: fields[1], publicKey: fields[2], fingerprint: "")
    }

    private static func parseKnownHosts(_ text: String) -> KnownHostsDocument {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }

        let entries: [KnownHostsEntry] = lines.enumerated().compactMap { item -> KnownHostsEntry? in
            let lineIndex = item.offset
            let line = item.element
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let offset = fields.first?.hasPrefix("@") == true ? 1 : 0
            guard fields.count >= offset + 3 else { return nil }
            return KnownHostsEntry(
                line: line,
                lineIndex: lineIndex,
                marker: offset == 1 ? fields[0] : nil,
                hostPatterns: fields[offset].split(separator: ",").map(String.init),
                algorithm: fields[offset + 1],
                publicKey: fields[offset + 2]
            )
        }
        return KnownHostsDocument(lines: lines, entries: entries)
    }

    private static func readKnownHostsDocument(parentFD: Int32, fileName: String) throws -> KnownHostsRead {
        let descriptor = openAtRaw(
            parentFD,
            fileName,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return KnownHostsRead(
                    document: KnownHostsDocument(lines: [], entries: []),
                    identity: nil
                )
            }
            throw cannotPrepare("known_hosts 文件打开失败")
        }
        defer { Darwin.close(descriptor) }

        let identity = try regularFileIdentity(descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw cannotPrepare("文件权限设置失败")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            guard count >= 0 else { throw cannotPrepare("无法读取 known_hosts") }
            if count == 0 { break }
            guard data.count + count <= maximumKnownHostsBytes else {
                throw cannotPrepare("known_hosts 文件过大")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw cannotPrepare("known_hosts 不是有效的 UTF-8 文件")
        }
        return KnownHostsRead(document: parseKnownHosts(text), identity: identity)
    }

    private static func withSecureKnownHostsParent<T>(
        at fileURL: URL,
        create: Bool,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        guard fileURL.isFileURL else { throw cannotPrepare("known_hosts 路径无效") }
        let path = fileURL.path
        let components = fileURL.pathComponents
        guard path.hasPrefix("/"), components.count >= 2,
              components.first == "/",
              let fileName = components.last,
              !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/") else {
            throw cannotPrepare("known_hosts 路径无效")
        }

        let rootFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw cannotPrepare("known_hosts 根目录打开失败") }
        var parentFD = rootFD
        defer { Darwin.close(parentFD) }

        for component in components.dropFirst().dropLast() {
            guard component != ".", component != "..", !component.isEmpty else {
                throw cannotPrepare("known_hosts 父路径无效")
            }
            var nextFD = openAtRaw(
                parentFD,
                component,
                flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            var created = false
            if nextFD < 0, create, errno == ENOENT {
                let mkdirStatus = component.withCString { name in
                    Darwin.mkdirat(parentFD, name, mode_t(0o700))
                }
                guard mkdirStatus == 0 || errno == EEXIST else {
                    throw cannotPrepare("known_hosts 目录创建失败")
                }
                created = mkdirStatus == 0
                nextFD = openAtRaw(
                    parentFD,
                    component,
                    flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextFD >= 0 else {
                throw cannotPrepare("known_hosts 父路径不是安全目录")
            }
            let openedFD = nextFD
            if created {
                guard Darwin.fsync(parentFD) == 0 else {
                    Darwin.close(openedFD)
                    throw cannotPrepare("known_hosts 父目录同步失败")
                }
            }
            if component == components[components.count - 2] {
                guard Darwin.fchmod(openedFD, mode_t(0o700)) == 0,
                      Darwin.fsync(openedFD) == 0 else {
                    Darwin.close(openedFD)
                    throw cannotPrepare("known_hosts 目录权限或同步失败")
                }
            }
            Darwin.close(parentFD)
            parentFD = openedFD
        }
        return try body(parentFD, fileName)
    }

    private static func openAt(
        _ parentFD: Int32,
        _ name: String,
        flags: Int32,
        mode: mode_t = 0
    ) throws -> Int32 {
        let descriptor = openAtRaw(parentFD, name, flags: flags, mode: mode)
        guard descriptor >= 0 else {
            throw cannotPrepare("known_hosts 文件打开失败")
        }
        return descriptor
    }

    private static func openAtRaw(
        _ parentFD: Int32,
        _ name: String,
        flags: Int32,
        mode: mode_t = 0
    ) -> Int32 {
        name.withCString { childName in
            Darwin.openat(parentFD, childName, flags, mode)
        }
    }

    private static func regularFileIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw cannotPrepare("无法检查 known_hosts 文件")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw cannotPrepare("known_hosts 必须是普通文件")
        }
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private static func withKnownHostsLock<T>(
        parentFD: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let lockFD = try openAt(
            parentFD,
            knownHostsLockFileName,
            flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode: mode_t(0o600)
        )
        defer { Darwin.close(lockFD) }
        _ = try regularFileIdentity(lockFD)
        guard Darwin.fchmod(lockFD, mode_t(0o600)) == 0 else {
            throw cannotPrepare("known_hosts 锁权限设置失败")
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        var lockStatus: Int32 = -1
        repeat {
            lockStatus = Darwin.fcntl(lockFD, F_SETLKW, &lock)
        } while lockStatus == -1 && errno == EINTR
        guard lockStatus == 0 else {
            throw cannotPrepare("known_hosts 锁获取失败")
        }
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(lockFD, F_SETLK, &unlock)
        }
        return try body()
    }

#if DEBUG
    static func holdKnownHostsLockForTesting(
        at fileURL: URL,
        duration: TimeInterval,
        readyMarker: URL
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        try withSecureKnownHostsParent(at: fileURL, create: true) { parentFD, _ in
            try withKnownHostsLock(parentFD: parentFD) {
                guard FileManager.default.createFile(
                    atPath: readyMarker.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw cannotPrepare("测试锁 marker 创建失败")
                }
                usleep(UInt32(max(0, duration) * 1_000_000))
            }
        }
    }
#endif

    private static func verifyKnownHostsIdentity(
        parentFD: Int32,
        fileName: String,
        expected: FileIdentity?
    ) throws {
        let descriptor = openAtRaw(
            parentFD,
            fileName,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            guard expected == nil, errno == ENOENT else {
                throw cannotPrepare("known_hosts 文件打开失败")
            }
            return
        }
        defer { Darwin.close(descriptor) }
        let actual = try regularFileIdentity(descriptor)
        guard actual == expected else {
            throw cannotPrepare("known_hosts 在写入前发生变化")
        }
    }

    private static func writeKnownHostsAtomically(
        _ lines: [String],
        parentFD: Int32,
        fileName: String,
        expectedIdentity: FileIdentity?
    ) throws {
        try verifyKnownHostsIdentity(
            parentFD: parentFD,
            fileName: fileName,
            expected: expectedIdentity
        )

        let temporaryName = ".known_hosts.\(UUID().uuidString).tmp"
        let descriptor = try openAt(
            parentFD,
            temporaryName,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode: mode_t(0o600)
        )
        var committed = false
        var descriptorClosed = false
        defer {
            if !descriptorClosed {
                Darwin.close(descriptor)
            }
            if !committed {
                _ = temporaryName.withCString { name in
                    Darwin.unlinkat(parentFD, name, 0)
                }
            }
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw cannotPrepare("临时文件权限设置失败")
        }
        let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        let data = Data(content.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            guard written > 0 else { throw cannotPrepare("临时文件写入失败") }
            offset += written
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw cannotPrepare("临时文件同步失败")
        }
        guard Darwin.close(descriptor) == 0 else {
            throw cannotPrepare("临时文件关闭失败")
        }
        descriptorClosed = true

        try verifyKnownHostsIdentity(
            parentFD: parentFD,
            fileName: fileName,
            expected: expectedIdentity
        )
        let renameStatus = temporaryName.withCString { source in
            fileName.withCString { destination in
                Darwin.renameat(parentFD, source, parentFD, destination)
            }
        }
        guard renameStatus == 0 else { throw cannotPrepare("known_hosts 原子替换失败") }
        committed = true

        let finalDescriptor = try openAt(
            parentFD,
            fileName,
            flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        defer { Darwin.close(finalDescriptor) }
        _ = try regularFileIdentity(finalDescriptor)
        guard Darwin.fchmod(finalDescriptor, mode_t(0o600)) == 0,
              Darwin.fsync(finalDescriptor) == 0,
              Darwin.fsync(parentFD) == 0 else {
            throw cannotPrepare("known_hosts 提交后同步失败")
        }
    }

    private static func fingerprint(for entry: KnownHostsEntry) throws -> String {
        try fingerprint(algorithm: entry.algorithm, publicKey: entry.publicKey)
    }

    private static func fingerprint(algorithm: String, publicKey: String) throws -> String {
        let result = try runProcess(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-lf", "-", "-E", "sha256"],
            standardInput: "\(algorithm) \(publicKey)\n"
        )
        guard result.status == 0,
              let fingerprint = result.standardOutput
                  .split(whereSeparator: { $0.isWhitespace })
                  .dropFirst()
                  .first,
              fingerprint.hasPrefix("SHA256:")
        else {
            throw SSHConnectionError.hostKeyScanFailed("ssh-keygen 未返回 SHA-256 指纹")
        }
        return String(fingerprint)
    }

    private static func knownHostsFileURL() throws -> URL {
#if DEBUG
        if let knownHostsURLOverride {
            return knownHostsURLOverride
        }
        // A test process must never create or change the user's real known_hosts: tests use
        // `withKnownHostsFileURLForTesting`.
        if NSClassFromString("XCTestCase") != nil {
            throw cannotPrepare("测试进程不得使用真实的 known_hosts")
        }
#endif
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw cannotPrepare("无法找到 Application Support")
        }
        return defaultKnownHostsFileURL(applicationSupport: applicationSupport)
    }

    /// The app's known_hosts location under `applicationSupport`. Pure: creates nothing.
    static func defaultKnownHostsFileURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Oases CPA/SSH", isDirectory: true)
            .appendingPathComponent(knownHostsFileName)
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval = 10
    ) throws -> SSHProcessResult {
#if DEBUG
        if let processRunnerOverride {
            return try processRunnerOverride(executable, arguments, standardInput, timeout)
        }
#endif
        return try runBoundedProcess(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    private static func runBoundedProcess(
        executable: String,
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval
    ) throws -> SSHProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error

        let input: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe
        } else {
            input = nil
        }

        do {
            try process.run()
        } catch {
            throw SSHConnectionError.hostKeyScanFailed("SSH 工具执行失败")
        }

        let outputCollector = SSHBoundedOutputCollector(maximumBytes: maximumToolOutputBytes)
        let errorCollector = SSHBoundedOutputCollector(maximumBytes: maximumToolOutputBytes)
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drainGroup.leave() }
            while true {
                let data = output.fileHandleForReading.readData(ofLength: 16 * 1024)
                if data.isEmpty { break }
                outputCollector.append(data)
            }
            output.fileHandleForReading.closeFile()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drainGroup.leave() }
            while true {
                let data = error.fileHandleForReading.readData(ofLength: 16 * 1024)
                if data.isEmpty { break }
                errorCollector.append(data)
            }
            error.fileHandleForReading.closeFile()
        }

        let processID = process.processIdentifier
        let processGroupConfigured: Bool
        if processID > 0 {
            let setGroupStatus = Darwin.setpgid(processID, processID)
            processGroupConfigured = setGroupStatus == 0 || Darwin.getpgid(processID) == processID
        } else {
            processGroupConfigured = false
        }
        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        var wasCancelled = false
        var timedOut = false
        if let input {
            let inputData = Data(standardInput!.utf8)
            guard inputData.count <= maximumToolInputBytes else {
                terminateProcess(process, processGroupConfigured: processGroupConfigured)
                input.fileHandleForWriting.closeFile()
                drainGroup.wait()
                throw SSHConnectionError.hostKeyScanFailed("SSH 工具输入过大")
            }
            let descriptor = input.fileHandleForWriting.fileDescriptor
            let flags = Darwin.fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                terminateProcess(process, processGroupConfigured: processGroupConfigured)
                input.fileHandleForWriting.closeFile()
                drainGroup.wait()
                throw SSHConnectionError.hostKeyScanFailed("SSH 工具输入管道不可用")
            }
            var offset = 0
            while offset < inputData.count {
                let written = inputData.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        inputData.count - offset
                    )
                }
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    if Task.isCancelled {
                        wasCancelled = true
                        terminateProcess(process, processGroupConfigured: processGroupConfigured)
                        break
                    }
                    if Date() >= deadline {
                        timedOut = true
                        terminateProcess(process, processGroupConfigured: processGroupConfigured)
                        break
                    }
                    usleep(5_000)
                } else {
                    break
                }
            }
            input.fileHandleForWriting.closeFile()
        }

        while process.isRunning {
            if Task.isCancelled {
                wasCancelled = true
                terminateProcess(process, processGroupConfigured: processGroupConfigured)
                break
            }
            if Date() >= deadline {
                timedOut = true
                terminateProcess(process, processGroupConfigured: processGroupConfigured)
                break
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        drainGroup.wait()

        if timedOut || wasCancelled {
            throw SSHConnectionError.hostKeyScanFailed(
                timedOut ? "SSH 工具执行超时" : "SSH 工具执行已取消"
            )
        }

        let outputResult = outputCollector.result
        let errorResult = errorCollector.result

        return SSHProcessResult(
            status: process.terminationStatus,
            standardOutput: String(data: outputResult.data, encoding: .utf8) ?? "",
            standardError: String(data: errorResult.data, encoding: .utf8) ?? "",
            standardOutputTruncated: outputResult.truncated,
            standardErrorTruncated: errorResult.truncated
        )
    }

    private static func terminateProcess(_ process: Process, processGroupConfigured: Bool) {
        let processID = process.processIdentifier
        if processGroupConfigured {
            _ = Darwin.kill(-processID, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
        }
        let softDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < softDeadline {
            usleep(10_000)
        }
        if process.isRunning {
            if processID > 0 {
                if processGroupConfigured {
                    _ = Darwin.kill(-processID, SIGKILL)
                }
                _ = Darwin.kill(processID, SIGKILL)
            }
            process.terminate()
        }
        process.waitUntilExit()
    }

    private static func publicKey(from knownHostsLine: String) -> String {
        knownHostsLine
            .split(whereSeparator: { $0.isWhitespace })
            .dropFirst(2)
            .first
            .map(String.init) ?? ""
    }

    private static func cannotPrepare(_ message: String) -> SSHConnectionError {
        .cannotPrepareKnownHosts(message)
    }
}
