import Foundation

enum DeploymentRemovalError: LocalizedError {
    case invalidInstallDirectory
    case invalidRemoteTarget
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInstallDirectory:
            OasesLocalization.localized("为保护系统文件，只能删除明确受管的部署目录，不能删除空路径、根目录或用户主目录。")
        case .invalidRemoteTarget:
            OasesLocalization.localized("远程目标信息不完整，无法卸载部署。")
        case .commandFailed(let message):
            message
        }
    }
}

struct DeploymentRemovalService {
    func uninstall(request: DeploymentExecutionRequest) async throws {
        try validate(request: request)
        _ = try await execute(
            request: request,
            script: scriptForVerification(method: request.method, installDirectory: request.installDirectory)
        )
    }

    func scriptForVerification(method: DeploymentMethod, installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        let methodValue = shellQuote(method.rawValue)
        return """
        set -euo pipefail

        ROOT=\(root)
        METHOD=\(methodValue)
        fail() {
          printf '%s\\n' "$1" >&2
          exit "${2:-26}"
        }
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
          '$HOME') ROOT="$HOME" ;;
        esac
        [ -n "$ROOT" ] || fail '安装目录不能为空。'
        case "$ROOT" in *'\\n'*|*'\\r'*) fail '安装目录不能包含换行。' ;; esac
        if [ "$ROOT" != "/" ]; then ROOT="${ROOT%/}"; fi
        [ "$ROOT" != "/" ] || fail '为保护系统文件，不能卸载文件系统根目录。'
        [ "$ROOT" != "$HOME" ] || fail '为保护用户文件，不能卸载用户主目录。'
        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || fail '目标目录不存在，或目标目录是符号链接。'
        ROOT="$(cd "$ROOT" && pwd -P)"
        HOME_PHYSICAL="$(cd "$HOME" && pwd -P)"
        [ -n "$ROOT" ] && [ "$ROOT" != "/" ] || fail '为保护系统文件，不能卸载文件系统根目录。'
        [ "$ROOT" != "$HOME_PHYSICAL" ] || fail '为保护用户文件，不能卸载用户主目录。'

        MANAGED_MARKER="$ROOT/.oases-cpa-managed"
        LOCK_DIR="$ROOT/.oases-cpa-deployment-lock"
        LOCK_PID_FILE="$LOCK_DIR/pid"
        [ -f "$MANAGED_MARKER" ] && [ ! -L "$MANAGED_MARKER" ] || fail '目标目录没有可信的 Oases CPA 受管标记。'
        grep -Fqx 'owned-by=oases-cpa' "$MANAGED_MARKER" || fail '目标目录受管标记不属于 Oases CPA，已拒绝删除。'

        if [ -e "$LOCK_DIR" ]; then
          [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || fail '部署锁目录无效，已拒绝删除。'
          [ -f "$LOCK_PID_FILE" ] && [ ! -L "$LOCK_PID_FILE" ] || fail '部署锁 PID 文件无效，已拒绝删除。'
          LOCK_PID="$(cat "$LOCK_PID_FILE")"
          case "$LOCK_PID" in ''|*[!0-9]*) fail '部署锁 PID 不是纯数字，已拒绝删除。' ;; esac
          if kill -0 "$LOCK_PID" >/dev/null 2>&1; then
            fail '部署仍在进行中，请先取消部署，再删除整个部署目录。'
          fi
        fi

        process_matches_path() {
          PID_TO_CHECK="$1"
          EXPECTED_PATH="$2"
          case "$PID_TO_CHECK" in ''|*[!0-9]*) return 1 ;; esac
          kill -0 "$PID_TO_CHECK" >/dev/null 2>&1 || return 1
          COMMAND_LINE="$(ps -p "$PID_TO_CHECK" -o command= 2>/dev/null || true)"
          case "$COMMAND_LINE" in *"$EXPECTED_PATH"*) return 0 ;; *) return 1 ;; esac
        }

        stop_native_pid() {
          PID_TO_STOP="$1"
          EXPECTED_PATH="$2"
          process_matches_path "$PID_TO_STOP" "$EXPECTED_PATH" || return 0
          kill -TERM "$PID_TO_STOP" >/dev/null 2>&1 || true
          for _ in $(seq 1 25); do
            process_matches_path "$PID_TO_STOP" "$EXPECTED_PATH" || return 0
            sleep 0.2
          done
          if process_matches_path "$PID_TO_STOP" "$EXPECTED_PATH"; then
            kill -KILL "$PID_TO_STOP" >/dev/null 2>&1 || true
          fi
        }

        stop_native_processes() {
          for PID_FILE in "$ROOT/cli-proxy-api.pid" "$ROOT/cpa-manager-plus.pid"; do
            [ -e "$PID_FILE" ] || continue
            [ -f "$PID_FILE" ] && [ ! -L "$PID_FILE" ] || fail '受管进程 PID 文件无效，已拒绝删除。'
            PID_TO_STOP="$(cat "$PID_FILE")"
            case "$PID_TO_STOP" in ''|*[!0-9]*) fail '受管进程 PID 不是纯数字，已拒绝删除。' ;; esac
            case "$PID_FILE" in
              *'/cli-proxy-api.pid') EXPECTED_PATH="$ROOT/cli-proxy-api" ;;
              *'/cpa-manager-plus.pid') EXPECTED_PATH="$ROOT/cpamp" ;;
              *) fail '发现未知受管 PID 文件，已拒绝删除。' ;;
            esac
            stop_native_pid "$PID_TO_STOP" "$EXPECTED_PATH"
          done
        }

        if [ "$METHOD" = 'native' ]; then
          stop_native_processes
        elif [ "$METHOD" = 'docker' ]; then
          if [ -f "$ROOT/compose.yaml" ] || [ -f "$ROOT/compose.yml" ]; then
            [ ! -L "$ROOT/compose.yaml" ] 2>/dev/null || fail 'Compose 配置是符号链接，已拒绝删除。'
            [ ! -L "$ROOT/compose.yml" ] 2>/dev/null || fail 'Compose 配置是符号链接，已拒绝删除。'
            command -v docker >/dev/null 2>&1 || fail 'Docker CLI 不可用，无法停止 Compose 服务。'
            (cd "$ROOT" && docker compose down --volumes --remove-orphans)
          fi
        else
          fail '部署方式无效。'
        fi

        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || fail '删除前目标目录状态已改变，已停止操作。'
        [ -f "$MANAGED_MARKER" ] && [ ! -L "$MANAGED_MARKER" ] || fail '删除前受管标记已改变，已停止操作。'
        grep -Fqx 'owned-by=oases-cpa' "$MANAGED_MARKER" || fail '删除前受管标记已改变，已停止操作。'
        if [ -e "$LOCK_PID_FILE" ]; then
          LOCK_PID="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
          case "$LOCK_PID" in ''|*[!0-9]*) fail '删除前部署锁已改变，已停止操作。' ;; esac
          kill -0 "$LOCK_PID" >/dev/null 2>&1 && fail '部署仍在进行中，请先取消部署，再删除整个部署目录。'
        fi
        rm -rf -- "$ROOT"
        printf '%s\\n' 'OASES_CPA_REMOVED=1'
        """
    }

    private func validate(request: DeploymentExecutionRequest) throws {
        let directory = request.installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty, directory != "/", !directory.contains("\n"), !directory.contains("\r") else {
            throw DeploymentRemovalError.invalidInstallDirectory
        }
        if request.target == .local {
            let expanded = (directory as NSString).expandingTildeInPath
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            guard URL(fileURLWithPath: expanded).standardizedFileURL.path != home else {
                throw DeploymentRemovalError.invalidInstallDirectory
            }
        } else {
            guard !request.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !request.host.contains(where: { $0.isWhitespace || $0 == "\n" || $0 == "\r" }),
                  !request.user.contains(where: { $0.isWhitespace || $0 == "\n" || $0 == "\r" }),
                  !request.privateKeyPath.isEmpty,
                  Int(request.port).map({ (1...65_535).contains($0) }) == true else {
                throw DeploymentRemovalError.invalidRemoteTarget
            }
        }
    }

    private func execute(request: DeploymentExecutionRequest, script: String) async throws -> String {
        do {
            switch request.target {
            case .local:
                return try await BoundedProcessRunner.run(
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
                return try await BoundedProcessRunner.run(
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
            throw DeploymentRemovalError.commandFailed(
                BoundedProcessRunner.userFacingMessage(
                    for: error,
                    fallback: OasesLocalization.localized("卸载部署失败。")
                )
            )
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
