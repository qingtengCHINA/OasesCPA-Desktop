import Foundation

enum SSHConnectionError: LocalizedError {
    case cannotPrepareKnownHosts(String)
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .cannotPrepareKnownHosts(let message):
            "无法准备 SSH 主机指纹文件：\(message)"
        case .invalidPort:
            OasesLocalization.localized("SSH 端口必须是 1-65535 之间的数字。")
        }
    }
}

enum SSHConnectionService {
    private static let knownHostsFileName = "known_hosts"

    static func connectionArguments(port: String, privateKeyPath: String) throws -> [String] {
        guard let portNumber = Int(port), (1...65_535).contains(portNumber) else {
            throw SSHConnectionError.invalidPort
        }
        let knownHostsPath = try prepareKnownHostsFile()
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-p", port,
            "-i", privateKeyPath
        ]
    }

    static func tunnelArguments(
        host: String,
        user: String,
        port: String,
        privateKeyPath: String
    ) throws -> [String] {
        [
            "-N",
            "-o", "ExitOnForwardFailure=yes"
        ] + (try connectionArguments(port: port, privateKeyPath: privateKeyPath)) + [
            "-L", "8317:127.0.0.1:8317",
            "-L", "18317:127.0.0.1:18317",
            "\(user.isEmpty ? "root" : user)@\(host)"
        ]
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
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = applicationSupport.appendingPathComponent("Oases CPA/SSH", isDirectory: true)
        let file = directory.appendingPathComponent(knownHostsFileName)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(
                    atPath: file.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw SSHConnectionError.cannotPrepareKnownHosts(OasesLocalization.localized("文件创建失败"))
                }
            } else {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
            }
            return file.path
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.cannotPrepareKnownHosts(error.localizedDescription)
        }
    }
}
