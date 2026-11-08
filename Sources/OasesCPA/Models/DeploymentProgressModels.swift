import Foundation

// The welcome gate and 连接与部署 share one honest progress model: the rows follow the real
// order of the install and upgrade scripts, the active row comes from the stage the install
// script records in its attempt marker (`.oases-cpa-installing`, `stage=<name>`), and nothing
// is ever shown as a percentage. Failures are classified from the script's own messages and
// exit codes into one sentence that also states what the machine looks like now.

/// One line of the deployment checklist.
struct DeploymentChecklistRow: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pending
        case active
        case done
        case failed
    }

    let id: String
    let title: String
    var status: Status
    /// A short secondary text for the active row ("正在下载 · 12.4 MB") or the failed one.
    var detail: String?
}

/// What the install side of the checklist is doing.
enum InstallProgressPhase: Equatable, Sendable {
    /// Checking ports, probing the target and preparing the plan.
    case preparing
    /// The install script runs; `stage` is the last stage it recorded (nil: not reported,
    /// for example on an SSH target).
    case running(stage: String?)
    /// The script finished; the app waits for the services' health.
    case verifying
    case done
    /// The run stopped; `stage` is the stage it was in (nil: unknown, or before the script).
    case failed(stage: String?)
}

/// The rows of a fresh install, in the order the native install script runs them.
enum InstallChecklist {
    static let rowIDs = ["prepare", "engine", "cpamp", "node", "gateway", "start", "health"]

    /// The checklist row of an install-script stage (`set_stage` in `DeploymentExecutor`).
    static func rowID(forStage stage: String) -> String? {
        switch stage {
        case "prepare", "secure-directories": "prepare"
        case "resolve-cli-version", "download-cli", "verify-cli", "install-cli": "engine"
        case "resolve-cpamp-version", "download-cpamp", "verify-cpamp", "install-cpamp": "cpamp"
        case "install-node": "node"
        case "install-gateway", "bootstrap-gateway", "configure-cli": "gateway"
        case "start-cli", "wait-cli", "start-cpamp", "wait-cpamp", "start-gateway": "start"
        case "wait-gateway", "finalize": "health"
        default: nil
        }
    }

    /// What happens inside the active row, from the exact stage.
    static func activity(forStage stage: String, language: AppLanguage? = nil) -> String? {
        switch stage {
        case "download-cli", "download-cpamp":
            OasesLocalization.localized("正在下载", language: language)
        case "verify-cli", "verify-cpamp":
            OasesLocalization.localized("正在校验 SHA-256", language: language)
        case "install-cli", "install-cpamp":
            OasesLocalization.localized("正在解压", language: language)
        case "install-node":
            OasesLocalization.localized("正在下载并校验", language: language)
        case "bootstrap-gateway":
            OasesLocalization.localized("正在初始化网关数据", language: language)
        case "configure-cli":
            OasesLocalization.localized("正在写入私有配置", language: language)
        case "start-cli", "wait-cli":
            OasesLocalization.localized("正在启动 CLIProxyAPI", language: language)
        case "start-cpamp", "wait-cpamp":
            OasesLocalization.localized("正在启动 CPA Manager Plus", language: language)
        case "start-gateway":
            OasesLocalization.localized("正在启动 Oases 网关", language: language)
        default:
            nil
        }
    }

    static func titles(pins: DeploymentPinSet = .current, language: AppLanguage? = nil) -> [String: String] {
        [
            "prepare": OasesLocalization.localized("检查并准备这台 Mac", language: language),
            "engine": OasesLocalization.localizedFormat("下载并校验 %@", language: language, "CLIProxyAPI \(pins.engine.tag)"),
            "cpamp": OasesLocalization.localizedFormat("下载并校验 %@", language: language, "CPA Manager Plus \(pins.cpamp.tag)"),
            "node": OasesLocalization.localizedFormat("下载并校验 %@", language: language, "Node.js \(pins.node.tag)"),
            "gateway": OasesLocalization.localized("安装 Oases 网关", language: language),
            "start": OasesLocalization.localized("启动服务", language: language),
            "health": OasesLocalization.localized("检查网关", language: language),
        ]
    }

    /// The rows for `phase`. `receivedBytes` is the size of the file being downloaded right now
    /// (only known on this Mac); it is shown next to "正在下载", never as a share of a total.
    static func rows(
        phase: InstallProgressPhase,
        receivedBytes: Int64? = nil,
        pins: DeploymentPinSet = .current,
        language: AppLanguage? = nil
    ) -> [DeploymentChecklistRow] {
        let titles = titles(pins: pins, language: language)
        func make(activeIndex: Int?, status: DeploymentChecklistRow.Status, detail: String?) -> [DeploymentChecklistRow] {
            rowIDs.enumerated().map { index, id in
                var row = DeploymentChecklistRow(id: id, title: titles[id] ?? id, status: .pending, detail: nil)
                guard let activeIndex else { return row }
                if index < activeIndex {
                    row.status = .done
                } else if index == activeIndex {
                    row.status = status
                    row.detail = detail
                }
                return row
            }
        }

        switch phase {
        case .preparing:
            return make(activeIndex: 0, status: .active, detail: nil)
        case .running(let stage):
            guard let stage, let id = rowID(forStage: stage), let index = rowIDs.firstIndex(of: id) else {
                // No stage reported: say nothing about individual rows.
                return make(activeIndex: nil, status: .pending, detail: nil)
            }
            var detail = activity(forStage: stage, language: language)
            if let receivedBytes, receivedBytes > 0, stage.hasPrefix("download-") || stage == "install-node" {
                let size = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
                detail = OasesLocalization.localizedFormat("正在下载 · %@", language: language, size)
            }
            return make(activeIndex: index, status: .active, detail: detail)
        case .verifying:
            return make(activeIndex: rowIDs.count - 1, status: .active, detail: OasesLocalization.localized("正在确认服务连接", language: language))
        case .done:
            return make(activeIndex: rowIDs.count, status: .done, detail: nil)
        case .failed(let stage):
            let index = stage.flatMap(rowID(forStage:)).flatMap { rowIDs.firstIndex(of: $0) } ?? 0
            return make(activeIndex: index, status: .failed, detail: nil)
        }
    }
}

/// The rows of the legacy (0.1.x) upgrade, in the order the upgrade script runs them. The
/// upgrade reports no live stage, so while it runs no row is marked; a failure names its stage
/// (`OASES_UPGRADE_FAILURE stage=…`), which marks the rows before it as done.
enum UpgradeChecklist {
    static let rowIDs = ["stop", "backup", "download", "migrate", "start", "health"]

    static func rowID(forStage stage: String) -> String? {
        switch stage {
        case "prepare", "stop", "ports": "stop"
        case "backup": "backup"
        case "engine", "cpamp", "node", "gateway": "download"
        case "cpamp-config", "bootstrap", "migration-config", "migration-engine", "migration-keys": "migrate"
        case "start": "start"
        case "health", "finalize": "health"
        default: nil
        }
    }

    static func titles(language: AppLanguage? = nil) -> [String: String] {
        [
            "stop": OasesLocalization.localized("停止旧服务", language: language),
            "backup": OasesLocalization.localized("备份数据", language: language),
            "download": OasesLocalization.localized("下载并校验新版本", language: language),
            "migrate": OasesLocalization.localized("迁移配置", language: language),
            "start": OasesLocalization.localized("启动服务", language: language),
            "health": OasesLocalization.localized("检查网关", language: language),
        ]
    }

    enum Phase: Equatable, Sendable {
        case running
        case done
        case failed(stage: String?)
    }

    static func rows(phase: Phase, language: AppLanguage? = nil) -> [DeploymentChecklistRow] {
        let titles = titles(language: language)
        return rowIDs.enumerated().map { index, id in
            var row = DeploymentChecklistRow(id: id, title: titles[id] ?? id, status: .pending, detail: nil)
            switch phase {
            case .running:
                break
            case .done:
                row.status = .done
            case .failed(let stage):
                if let failedIndex = stage.flatMap(rowID(forStage:)).flatMap({ rowIDs.firstIndex(of: $0) }) {
                    if index < failedIndex { row.status = .done }
                    if index == failedIndex { row.status = .failed }
                }
            }
            return row
        }
    }
}

// MARK: - Failures

/// A failed install, classified for the one-sentence copy and its actions (design 6.7).
struct DeploymentFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case offline
        case downloadInterrupted
        case checksumMismatch
        case portBusy(port: Int?, process: String?)
        case permissionDenied
        case diskFull
        case healthTimeout
        case connectionCheckFailed
        case alreadyInstalled
        case directoryNotEmpty
        case anotherInstallRunning
        case missingTools
        case unsupportedPlatform
        case unsafeDirectory
        case gatewayPackage
        case cancelled
        case timedOut
        case other
    }

    enum Action: String, Equatable, Sendable {
        case retry
        case showLog
        case revealInFinder
    }

    /// What the machine looks like after the failure.
    enum MachineState: Equatable, Sendable {
        /// The script stopped before it changed anything.
        case unchanged
        /// The attempt left files but started nothing; a retry backs them up first.
        case partialFilesNothingRunning
        /// The attempt may have started some services; a retry stops them and backs up first.
        case partialFilesMaybeRunning
        /// The services were installed; the app could not confirm the connection.
        case installed
    }

    let kind: Kind
    /// The install script's stage when it stopped (nil: before the script or unknown).
    let stage: String?
    /// The script's exit status when it was reported.
    let exitStatus: Int?
    let machineState: MachineState

    var actions: [Action] {
        switch kind {
        case .offline, .checksumMismatch, .healthTimeout, .connectionCheckFailed, .other, .timedOut, .unsafeDirectory, .missingTools:
            [.retry, .showLog]
        case .downloadInterrupted, .portBusy, .diskFull, .anotherInstallRunning, .cancelled, .unsupportedPlatform, .gatewayPackage:
            [.retry]
        case .permissionDenied, .directoryNotEmpty, .alreadyInstalled:
            [.revealInFinder, .retry]
        }
    }

    /// What went wrong and what to do, in one or two short sentences.
    func reason(installDirectory: String = "~/.oases-cpa", language: AppLanguage? = nil) -> String {
        switch kind {
        case .offline:
            OasesLocalization.localized("无法连接下载服务器。检查网络后重试。", language: language)
        case .downloadInterrupted:
            OasesLocalization.localized("下载中断。重试会从头下载并重新校验。", language: language)
        case .checksumMismatch:
            OasesLocalization.localized("下载的文件与固定版本不一致，已删除，没有使用。", language: language)
        case .portBusy(let port, let process):
            switch (port, process) {
            case let (port?, process?):
                OasesLocalization.localizedFormat("端口 %@ 已被其他程序占用（%@）。退出该程序后重试。", language: language, String(port), process)
            case let (port?, nil):
                OasesLocalization.localizedFormat("端口 %@ 已被其他程序占用。退出该程序后重试。", language: language, String(port))
            default:
                OasesLocalization.localized("网关需要的端口已被其他程序占用。退出该程序后重试。", language: language)
            }
        case .permissionDenied:
            OasesLocalization.localizedFormat("无法写入 %@。检查这个文件夹的权限后重试。", language: language, installDirectory)
        case .diskFull:
            OasesLocalization.localized("磁盘空间不足。腾出空间后重试。", language: language)
        case .healthTimeout:
            OasesLocalization.localized("服务启动后没有响应。", language: language)
        case .connectionCheckFailed:
            OasesLocalization.localized("安装已完成，但 App 没能确认服务连接。", language: language)
        case .alreadyInstalled:
            OasesLocalization.localizedFormat("%@ 里已经有一个部署。可以在「连接与部署」中接入它。", language: language, installDirectory)
        case .directoryNotEmpty:
            OasesLocalization.localizedFormat("%@ 里已有其他文件。为保护这些文件，安装没有开始。", language: language, installDirectory)
        case .anotherInstallRunning:
            OasesLocalization.localized("另一个安装正在进行。等它结束后重试。", language: language)
        case .missingTools:
            OasesLocalization.localized("这台 Mac 缺少安装需要的命令行工具（curl、tar、openssl 或 shasum）。", language: language)
        case .unsupportedPlatform:
            OasesLocalization.localized("这台机器的系统或架构不在支持范围内（支持 macOS 和 Linux 的 arm64、x86_64）。", language: language)
        case .unsafeDirectory:
            OasesLocalization.localizedFormat("%@ 的权限不安全或是符号链接，网关拒绝使用它。", language: language, installDirectory)
        case .gatewayPackage:
            OasesLocalization.localized("应用内的网关包缺失或校验失败。请重新安装应用。", language: language)
        case .cancelled:
            OasesLocalization.localized("安装已取消。", language: language)
        case .timedOut:
            OasesLocalization.localized("安装超过 45 分钟没有完成，已停止。", language: language)
        case .other:
            OasesLocalization.localized("安装没有完成。", language: language)
        }
    }

    /// The sentence that always follows: what is on the machine now.
    func machineStateSentence(language: AppLanguage? = nil) -> String {
        switch machineState {
        case .unchanged:
            OasesLocalization.localized("没有做任何改动。", language: language)
        case .partialFilesNothingRunning:
            OasesLocalization.localized("没有服务在运行；重试时会先把这次未完成的文件移到 backups 文件夹。", language: language)
        case .partialFilesMaybeRunning:
            OasesLocalization.localized("部分服务可能仍在运行；重试时会先停止它们，并把这次未完成的文件移到 backups 文件夹。", language: language)
        case .installed:
            OasesLocalization.localized("服务已安装；App 会继续尝试连接，也可以重试。", language: language)
        }
    }

    func message(installDirectory: String = "~/.oases-cpa", language: AppLanguage? = nil) -> String {
        reason(installDirectory: installDirectory, language: language) + " " + machineStateSentence(language: language)
    }
}

/// Turns the text the store keeps for a failed install (the script's stderr: its own messages,
/// curl's errors and the tail of `logs/deployment.log`, which ends with
/// "部署在阶段 <stage> 失败（退出码 <n>）。") into a `DeploymentFailure`.
enum DeploymentFailureClassifier {
    /// The stages after which services may already run.
    static let servicesStartedStages: Set<String> = [
        "start-cli", "wait-cli", "start-cpamp", "wait-cpamp", "start-gateway", "wait-gateway", "finalize",
    ]

    /// - Parameters:
    ///   - message: the error text (`DeploymentStore.deploymentError`).
    ///   - installed: the script succeeded and the app failed afterwards (connection check).
    static func classify(message: String, installed: Bool = false) -> DeploymentFailure {
        if installed {
            return DeploymentFailure(kind: .connectionCheckFailed, stage: nil, exitStatus: nil, machineState: .installed)
        }
        let (stage, status) = stageAndStatus(in: message)
        let lowered = message.lowercased()
        let machineState: DeploymentFailure.MachineState = {
            guard let stage else {
                // Exit statuses of the checks before the script writes its attempt marker.
                if let status, [11, 12].contains(status) { return .unchanged }
                return message.contains("部署阶段") ? .partialFilesNothingRunning : .unchanged
            }
            return servicesStartedStages.contains(stage) ? .partialFilesMaybeRunning : .partialFilesNothingRunning
        }()
        func failure(_ kind: DeploymentFailure.Kind, state: DeploymentFailure.MachineState? = nil) -> DeploymentFailure {
            DeploymentFailure(kind: kind, stage: stage, exitStatus: status, machineState: state ?? machineState)
        }

        if lowered.contains("no space left on device") || message.contains("ENOSPC") || lowered.contains("curl: (23)") {
            return failure(.diskFull)
        }
        if message.contains("EADDRINUSE") || lowered.contains("address already in use") {
            return failure(.portBusy(port: busyPort(in: message), process: nil))
        }
        if (lowered.contains("permission denied") && !lowered.contains("permission denied (publickey"))
            || lowered.contains("operation not permitted") || lowered.contains("read-only file system") {
            return failure(.permissionDenied)
        }
        if message.contains("命令已取消") || status == 130 || stage == "cancelled" {
            return failure(.cancelled)
        }
        if message.contains("命令执行超时") {
            return failure(.timedOut)
        }
        if message.contains("SHA-256 校验失败") || message.contains("不完整或不是有效的 tar.gz") || status == 17
            || (status == 23 && message.contains("SHA-256")) {
            return failure(.checksumMismatch)
        }
        if status == 18 || message.contains("curl: (") {
            return failure(curlFailureIsInterruption(lowered) ? .downloadInterrupted : .offline)
        }
        if message.contains("已阻止重复安装") || message.contains("已有成功部署") {
            return failure(.alreadyInstalled, state: .unchanged)
        }
        if message.contains("并非空目录") {
            return failure(.directoryNotEmpty, state: .unchanged)
        }
        if message.contains("另一个 Oases CPA 部署正在进行") || message.contains("部署锁") || status == 11 {
            return failure(.anotherInstallRunning, state: .unchanged)
        }
        if message.contains("目标环境缺少") || message.contains("当前部署方式无法继续") || status == 13 {
            return failure(.missingTools)
        }
        if message.contains("原生部署目前支持") || message.contains("不在官方原生包支持范围") || status == 14 {
            return failure(.unsupportedPlatform)
        }
        if message.contains("网关包") || status == 24 {
            return failure(.gatewayPackage)
        }
        if message.contains("符号链接") || message.contains("insecure") || status == 25 {
            return failure(.unsafeDirectory)
        }
        if status == 26 || message.contains("没有通过健康检查") || ["wait-gateway", "wait-cli", "wait-cpamp"].contains(stage ?? "") {
            return failure(.healthTimeout)
        }
        return failure(.other)
    }

    /// The last "部署在阶段 <stage> 失败（退出码 <n>）" of the log tail.
    static func stageAndStatus(in message: String) -> (stage: String?, status: Int?) {
        guard let regex = try? NSRegularExpression(pattern: #"部署在阶段 ([A-Za-z0-9-]+) 失败（退出码 ([0-9]+)）"#) else { return (nil, nil) }
        let range = NSRange(message.startIndex..., in: message)
        guard let match = regex.matches(in: message, range: range).last,
              let stageRange = Range(match.range(at: 1), in: message),
              let statusRange = Range(match.range(at: 2), in: message) else { return (nil, nil) }
        return (String(message[stageRange]), Int(message[statusRange]))
    }

    /// curl codes for a transfer that started and stopped (partial file, receive failure,
    /// too slow), as opposed to one that never connected.
    private static func curlFailureIsInterruption(_ lowered: String) -> Bool {
        for code in ["(18)", "(56)", "(92)"] where lowered.contains("curl: \(code)") { return true }
        if lowered.contains("curl: (28)"), lowered.contains("bytes received"), !lowered.contains("with 0 bytes received"), !lowered.contains("with 0 out of") {
            return true
        }
        return lowered.contains("operation too slow")
    }

    private static func busyPort(in message: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:address already in use|EADDRINUSE)[^\n]*?:([0-9]{2,5})"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let portRange = Range(match.range(at: 1), in: message),
              let port = Int(message[portRange]), (1...65_535).contains(port) else { return nil }
        return port
    }
}

// MARK: - Install attempt marker

/// What the install script records in `<root>/.oases-cpa-installing` (`set_stage`).
struct InstallAttemptMarker: Equatable, Sendable {
    let stage: String
    let controlToken: String?

    init?(contents: String) {
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let stage = values["stage"], stage.range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) != nil else { return nil }
        self.stage = stage
        controlToken = values["control_token"]
    }
}

/// A live reading of an install on this Mac.
struct InstallProgressSnapshot: Equatable, Sendable {
    let stage: String
    /// Bytes of the file being downloaded now, when the stage downloads one.
    let receivedBytes: Int64?
}

/// What a failed upgrade (or rollback) left for the wizard to say.
enum MaintenanceFailure: Equatable, Sendable {
    /// The script reported its stage and what it restored.
    case upgrade(UpgradeFailure)
    /// A localized refusal before anything changed (newer components on the target).
    case refused(String)
    /// Anything else (SSH, the app's own checks after the script); details are in the log.
    case other
}
