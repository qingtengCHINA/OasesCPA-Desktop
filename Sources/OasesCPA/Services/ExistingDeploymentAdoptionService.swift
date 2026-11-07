import Foundation

enum ExistingDeploymentAdoptionError: LocalizedError {
    case invalidTarget
    case incompleteDeployment(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            OasesLocalization.localized("现有部署的目标信息无效，请重新检查主机、端口和安装目录。")
        case .incompleteDeployment(let detail):
            detail
        case .commandFailed(let detail):
            detail
        }
    }
}

/// Restores the two management credentials from a deployment created by Oases CPA.
/// The shell transport emits only Base64-encoded values and never logs secret contents.
struct ExistingDeploymentAdoptionService {
    func readCredentials(request: DeploymentExecutionRequest) async throws -> DeploymentExecutionResult {
        try validate(request)
        let script = credentialScript(installDirectory: request.installDirectory)
        let output: String

        do {
            switch request.target {
            case .local:
                output = try await BoundedProcessRunner.run(
                    executable: "/bin/bash",
                    arguments: ["-s"],
                    standardInput: script,
                    timeout: 5 * 60
                ).standardOutput
            case .ssh:
                let sshArguments = try SSHConnectionService.connectionArguments(
                    port: request.port,
                    privateKeyPath: request.privateKeyPath
                )
                output = try await BoundedProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: sshArguments + [
                        "\(request.user.isEmpty ? "root" : request.user)@\(request.host)",
                        "bash -s"
                    ],
                    standardInput: script,
                    timeout: 5 * 60
                ).standardOutput
            }
        } catch let error as BoundedProcessError {
            throw ExistingDeploymentAdoptionError.commandFailed(
                BoundedProcessRunner.userFacingMessage(
                    for: error,
                    fallback: OasesLocalization.localized("无法读取现有 Oases CPA 部署凭据。")
                )
            )
        }

        return try parse(output)
    }

    func scriptForVerification(installDirectory: String) -> String {
        credentialScript(installDirectory: installDirectory)
    }

    private func validate(_ request: DeploymentExecutionRequest) throws {
        let directory = request.installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty,
              directory != "/",
              !directory.contains("\n"),
              !directory.contains("\r") else {
            throw ExistingDeploymentAdoptionError.invalidTarget
        }
        if request.target == .ssh {
            guard !request.host.isEmpty,
                  !request.host.contains(where: { $0.isWhitespace }),
                  Int(request.port).map({ (1...65_535).contains($0) }) == true,
                  !request.privateKeyPath.isEmpty else {
                throw ExistingDeploymentAdoptionError.invalidTarget
            }
        }
    }

    private func parse(_ output: String) throws -> DeploymentExecutionResult {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let managementEncoded = values["OASES_CPA_MANAGEMENT_KEY_B64"],
              let managementData = Data(base64Encoded: managementEncoded),
              let managementKey = String(data: managementData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !managementKey.isEmpty,
              let adminEncoded = values["OASES_CPAMP_ADMIN_KEY_B64"],
              let adminData = Data(base64Encoded: adminEncoded),
              let adminKey = String(data: adminData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !adminKey.isEmpty else {
            throw ExistingDeploymentAdoptionError.incompleteDeployment(
                OasesLocalization.localized("检测到现有部署，但管理凭据不完整；请查看部署日志或使用修复功能。")
            )
        }

        return DeploymentExecutionResult(
            cpaManagementKey: managementKey,
            cpampAdminKey: adminKey
        )
    }

    private func credentialScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        return """
        set -euo pipefail
        ROOT=\(root)
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
        esac
        [ -f "$ROOT/.oases-cpa-installed" ] && [ ! -L "$ROOT/.oases-cpa-installed" ] || {
          printf '%s\n' '没有找到可信的 Oases CPA 成功部署标记。' >&2
          exit 20
        }

        emit_secret() {
          local variable_name="$1"
          local file="$2"
          [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || {
            printf '%s\n' '现有部署缺少可信的管理凭据文件。' >&2
            exit 21
          }
          local size
          size="$(wc -c < "$file" | tr -d '[:space:]')"
          case "$size" in
            ''|*[!0-9]*) exit 21 ;;
          esac
          [ "$size" -le 4096 ] || {
            printf '%s\n' '现有部署的管理凭据文件大小异常。' >&2
            exit 21
          }
          local encoded
          encoded="$(base64 < "$file" | tr -d '\r\n')"
          [ -n "$encoded" ] || exit 21
          printf '%s=%s\n' "$variable_name" "$encoded"
        }

        emit_secret 'OASES_CPA_MANAGEMENT_KEY_B64' "$ROOT/secrets/cpa-management-key"
        emit_secret 'OASES_CPAMP_ADMIN_KEY_B64' "$ROOT/secrets/cpamp-admin-key"
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
