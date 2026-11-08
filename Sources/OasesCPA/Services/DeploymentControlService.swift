import Foundation

enum DeploymentControlAction: String, Sendable, Equatable {
    case pause
    case resume
    case cancel
}

enum DeploymentControlError: LocalizedError {
    case invalidControlToken
    case invalidInstallDirectory
    case invalidRemoteTarget
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidControlToken:
            OasesLocalization.localized("部署控制令牌无效，已拒绝操作。")
        case .invalidInstallDirectory:
            OasesLocalization.localized("安装目录不能为空，也不能直接使用文件系统根目录。")
        case .invalidRemoteTarget:
            OasesLocalization.localized("远程目标信息不完整，无法执行部署控制操作。")
        case .commandFailed(let message):
            message
        }
    }
}

struct DeploymentControlService {
    func perform(
        action: DeploymentControlAction,
        request: DeploymentExecutionRequest,
        controlToken: String
    ) async throws {
        try validate(request: request, controlToken: controlToken)
        let script = scriptForVerification(
            action: action,
            method: request.method,
            installDirectory: request.installDirectory,
            controlToken: controlToken
        )
        _ = try await execute(request: request, script: script)
    }

    func scriptForVerification(
        action: DeploymentControlAction,
        method: DeploymentMethod,
        installDirectory: String,
        controlToken: String
    ) -> String {
        let root = shellQuote(installDirectory)
        let token = shellQuote(controlToken)
        let methodValue = shellQuote(method.rawValue)
        let actionValue = shellQuote(action.rawValue)

        return """
        set -euo pipefail

        ROOT=\(root)
        CONTROL_TOKEN=\(token)
        METHOD=\(methodValue)
        ACTION=\(actionValue)
        fail() {
          printf '%s\\n' "$1" >&2
          exit "${2:-24}"
        }
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
        esac
        [ -n "$ROOT" ] || fail '安装目录不能为空。'
        case "$ROOT" in
          */*'\\n'*|*'\\r'*) fail '安装目录不能包含换行。' ;;
        esac
        if [ "$ROOT" != "/" ]; then ROOT="${ROOT%/}"; fi
        [ -n "$CONTROL_TOKEN" ] || fail '部署控制令牌不能为空。'
        case "$CONTROL_TOKEN" in *'\\n'*|*'\\r'*) fail '部署控制令牌不能包含换行。' ;; esac

        # A click can race the first few milliseconds of the installer. Wait
        # briefly for this exact deployment to create its managed root and
        # control markers, without ever falling back to an unverified PID.
        for _ in $(seq 1 50); do
          if [ -d "$ROOT" ] && [ ! -L "$ROOT" ] &&
             [ -f "$ROOT/.oases-cpa-installing" ] &&
             [ -f "$ROOT/.oases-cpa-deployment-lock/pid" ]; then
            break
          fi
          sleep 0.1
        done
        [ "$ROOT" != "/" ] || fail '为保护系统文件，不能控制根目录部署。'
        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || fail '目标目录不存在，或目标目录是符号链接。'

        MANAGED_MARKER="$ROOT/.oases-cpa-managed"
        ATTEMPT_MARKER="$ROOT/.oases-cpa-installing"
        PAUSED_MARKER="$ROOT/.oases-cpa-paused"
        LOCK_DIR="$ROOT/.oases-cpa-deployment-lock"
        LOCK_PID_FILE="$LOCK_DIR/pid"
        FAILED_MARKER="$ROOT/.oases-cpa-failed"

        [ -f "$MANAGED_MARKER" ] && [ ! -L "$MANAGED_MARKER" ] || fail '目标目录没有可信的 Oases CPA 受管标记。'
        grep -Fqx 'owned-by=oases-cpa' "$MANAGED_MARKER" || fail '目标目录受管标记不属于 Oases CPA。'
        [ -f "$ATTEMPT_MARKER" ] && [ ! -L "$ATTEMPT_MARKER" ] || fail '没有找到正在进行中的 Oases CPA 部署。'
        [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || fail '没有找到可信的部署锁。'
        [ -f "$LOCK_PID_FILE" ] && [ ! -L "$LOCK_PID_FILE" ] || fail '部署锁 PID 文件无效。'

        token_count="$(grep -c '^control_token=' "$ATTEMPT_MARKER" || true)"
        [ "$token_count" = 1 ] || fail '部署标记缺少唯一控制令牌。'
        grep -Fqx "control_token=$CONTROL_TOKEN" "$ATTEMPT_MARKER" || fail '部署控制令牌不匹配，未发送任何信号。'

        pid_count="$(grep -c '^pid=' "$ATTEMPT_MARKER" || true)"
        [ "$pid_count" = 1 ] || fail '部署标记缺少唯一 PID。'
        MARKER_PID="$(awk -F= '$1 == "pid" { print $2; exit }' "$ATTEMPT_MARKER")"
        case "$MARKER_PID" in ''|*[!0-9]*) fail '部署标记 PID 不是纯数字。' ;; esac
        [ "$MARKER_PID" -gt 0 ] || fail '部署标记 PID 无效。'
        LOCK_PID="$(cat "$LOCK_PID_FILE")"
        case "$LOCK_PID" in ''|*[!0-9]*) fail '部署锁 PID 不是纯数字。' ;; esac
        [ "$LOCK_PID" = "$MARKER_PID" ] || fail '部署锁 PID 与部署标记 PID 不一致，未发送任何信号。'
        kill -0 "$MARKER_PID" >/dev/null 2>&1 || fail '部署进程已经结束，未发送任何信号。'
        MARKER_COMMAND="$(ps -p "$MARKER_PID" -o command= 2>/dev/null || true)"
        case "$MARKER_COMMAND" in
          *bash*) ;;
          *) fail '部署锁 PID 已不再属于 Oases CPA 安装进程，未发送任何信号。' ;;
        esac

        if [ -e "$PAUSED_MARKER" ] && [ ! -f "$PAUSED_MARKER" -o -L "$PAUSED_MARKER" ]; then
          fail '暂停状态标记无效。'
        fi
        if [ -e "$FAILED_MARKER" ] && [ -L "$FAILED_MARKER" ]; then
          fail '失败状态标记是符号链接，已停止操作。'
        fi

        collect_process_tree() {
          TREE_PIDS="$MARKER_PID"
          FRONTIER="$MARKER_PID"
          while [ -n "$FRONTIER" ]; do
            NEXT_FRONTIER=""
            while read -r CANDIDATE_PID CANDIDATE_PPID; do
              case "$CANDIDATE_PID" in ''|*[!0-9]*) continue ;; esac
              case "$CANDIDATE_PPID" in ''|*[!0-9]*) continue ;; esac
              case " $TREE_PIDS " in *" $CANDIDATE_PID "*) continue ;; esac
              for PARENT_PID in $FRONTIER; do
                if [ "$CANDIDATE_PPID" = "$PARENT_PID" ]; then
                  TREE_PIDS="$TREE_PIDS $CANDIDATE_PID"
                  NEXT_FRONTIER="$NEXT_FRONTIER $CANDIDATE_PID"
                  break
                fi
              done
            done <<EOF_PS
        $(ps -axo pid=,ppid= 2>/dev/null || true)
        EOF_PS
            FRONTIER="$NEXT_FRONTIER"
          done
        }

        signal_process_tree() {
          SIGNAL="$1"
          collect_process_tree
          kill -s "$SIGNAL" "$MARKER_PID" >/dev/null 2>&1 || return 1
          for PID in $TREE_PIDS; do
            case "$PID" in ''|*[!0-9]*) continue ;; esac
            [ "$PID" = "$MARKER_PID" ] && continue
            kill -s "$SIGNAL" "$PID" >/dev/null 2>&1 || true
          done
        }

        wait_for_process_tree() {
          for _ in $(seq 1 50); do
            alive=no
            for PID in $TREE_PIDS; do
              case "$PID" in ''|*[!0-9]*) continue ;; esac
              if kill -0 "$PID" >/dev/null 2>&1; then alive=yes; fi
            done
            [ "$alive" = no ] && return 0
            sleep 0.2
          done
          return 1
        }

        \(DeploymentScriptFragments.managedProcessList(topology: .gateway))
        \(DeploymentScriptFragments.managedProcessStop())

        # Gateway first (up to 30 s grace), then CPA Manager Plus and the engine.
        stop_native_processes() {
          for PID_NAME in $OASES_MANAGED_STOP_ORDER; do
            PID_FILE="$ROOT/$PID_NAME"
            [ -e "$PID_FILE" ] || continue
            [ -f "$PID_FILE" ] && [ ! -L "$PID_FILE" ] || fail '受管进程 PID 文件无效，未停止任何未经验证的进程。'
            PID_TO_STOP="$(cat "$PID_FILE")"
            EXPECTED_PATH="$ROOT/$(oases_managed_owned_path "$PID_NAME")"
            oases_stop_owned_pid "$PID_TO_STOP" "$EXPECTED_PATH" "$PID_NAME"
          done
        }

        preflight_cancel_targets() {
          case "$METHOD" in
            native)
              for PID_NAME in $OASES_MANAGED_PID_FILES; do
                PID_FILE="$ROOT/$PID_NAME"
                [ -e "$PID_FILE" ] || continue
                [ -f "$PID_FILE" ] && [ ! -L "$PID_FILE" ] || fail '受管进程 PID 文件无效，未发送任何信号。'
                PID_TO_VALIDATE="$(cat "$PID_FILE")"
                case "$PID_TO_VALIDATE" in ''|*[!0-9]*) fail '受管进程 PID 不是纯数字，未发送任何信号。' ;; esac
              done
              ;;
            docker)
              if [ -f "$ROOT/compose.yaml" ] || [ -f "$ROOT/compose.yml" ]; then
                [ ! -L "$ROOT/compose.yaml" ] 2>/dev/null || fail 'Compose 配置是符号链接，未发送任何信号。'
                [ ! -L "$ROOT/compose.yml" ] 2>/dev/null || fail 'Compose 配置是符号链接，未发送任何信号。'
                command -v docker >/dev/null 2>&1 || fail 'Docker CLI 不可用，未发送任何信号。'
              fi
              ;;
            *) fail '部署方式无效，未发送任何信号。' ;;
          esac
        }

        write_paused_marker() {
          [ ! -e "$PAUSED_MARKER" ] || { [ -f "$PAUSED_MARKER" ] && [ ! -L "$PAUSED_MARKER" ]; } || fail '暂停状态标记无效。'
          PAUSED_PART="$PAUSED_MARKER.part.$$"
          printf 'control_token=%s\\npid=%s\\n' "$CONTROL_TOKEN" "$MARKER_PID" > "$PAUSED_PART"
          chmod 600 "$PAUSED_PART"
          mv -f "$PAUSED_PART" "$PAUSED_MARKER"
        }

        case "$ACTION" in
          pause)
            write_paused_marker
            signal_process_tree STOP || {
              rm -f "$PAUSED_MARKER"
              fail '部署进程已经结束，无法暂停。'
            }
            printf '%s\\n' 'OASES_CPA_CONTROL=paused'
            ;;
          resume)
            [ -f "$PAUSED_MARKER" ] && [ ! -L "$PAUSED_MARKER" ] || fail '当前部署没有处于暂停状态。'
            grep -Fqx "control_token=$CONTROL_TOKEN" "$PAUSED_MARKER" || fail '暂停状态令牌不匹配，未发送任何信号。'
            grep -Fqx "pid=$MARKER_PID" "$PAUSED_MARKER" || fail '暂停状态 PID 不匹配，未发送任何信号。'
            kill -0 "$MARKER_PID" >/dev/null 2>&1 || fail '部署进程已经结束，无法恢复。'
            signal_process_tree CONT || fail '部署进程已经结束，无法恢复。'
            rm -f "$PAUSED_MARKER"
            printf '%s\\n' 'OASES_CPA_CONTROL=resumed'
          ;;
          cancel)
            preflight_cancel_targets
            if kill -0 "$MARKER_PID" >/dev/null 2>&1; then
              signal_process_tree CONT || true
              signal_process_tree TERM || true
              wait_for_process_tree || {
                signal_process_tree KILL
                wait_for_process_tree || true
              }
            fi
            if [ "$METHOD" = 'native' ]; then
              stop_native_processes
            elif [ "$METHOD" = 'docker' ]; then
              if [ -f "$ROOT/compose.yaml" ] || [ -f "$ROOT/compose.yml" ]; then
                (cd "$ROOT" && docker compose down --volumes --remove-orphans)
              fi
            else
              fail '部署方式无效。'
            fi
            rm -f "$PAUSED_MARKER" "$ATTEMPT_MARKER" "$LOCK_PID_FILE"
            rmdir "$LOCK_DIR" 2>/dev/null || true
            FAILED_PART="$FAILED_MARKER.part.$$"
            printf 'timestamp=%s\\nmethod=%s\\nreason=cancelled\\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$METHOD" > "$FAILED_PART"
            chmod 600 "$FAILED_PART"
            mv -f "$FAILED_PART" "$FAILED_MARKER"
            printf '%s\\n' 'OASES_CPA_CONTROL=cancelled'
            ;;
          *) fail '不支持的部署控制操作。' ;;
        esac
        """
    }

    private func validate(request: DeploymentExecutionRequest, controlToken: String) throws {
        let directory = request.installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty, directory != "/", !directory.contains("\n"), !directory.contains("\r") else {
            throw DeploymentControlError.invalidInstallDirectory
        }
        guard !controlToken.isEmpty, !controlToken.contains("\n"), !controlToken.contains("\r") else {
            throw DeploymentControlError.invalidControlToken
        }
        if request.target == .ssh {
            guard !request.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !request.host.contains(where: { $0.isWhitespace || $0 == "\n" || $0 == "\r" }),
                  !request.user.contains(where: { $0.isWhitespace || $0 == "\n" || $0 == "\r" }),
                  !request.privateKeyPath.isEmpty,
                  Int(request.port).map({ (1...65_535).contains($0) }) == true else {
                throw DeploymentControlError.invalidRemoteTarget
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
            throw DeploymentControlError.commandFailed(
                BoundedProcessRunner.userFacingMessage(
                    for: error,
                    fallback: OasesLocalization.localized("部署控制命令失败。")
                )
            )
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
