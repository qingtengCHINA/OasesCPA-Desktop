import Foundation

enum DeploymentTargetKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case local
    case ssh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: OasesLocalization.localized("本机 Mac")
        case .ssh: OasesLocalization.localized("远程 SSH / VPS")
        }
    }

    var subtitle: String {
        switch self {
        case .local: OasesLocalization.localized("在当前 Mac 的终端内部署")
        case .ssh: OasesLocalization.localized("通过 SSH 连接 Linux / macOS 服务器")
        }
    }

    var systemImage: String {
        switch self {
        case .local: "laptopcomputer"
        case .ssh: "server.rack"
        }
    }
}

enum DeploymentMethod: String, CaseIterable, Identifiable, Sendable, Codable {
    case native
    case docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: OasesLocalization.localized("原生二进制")
        case .docker: "Docker Compose"
        }
    }

    var subtitle: String {
        switch self {
        case .native: OasesLocalization.localized("更轻量，适合本机和有权限的 VPS")
        case .docker: OasesLocalization.localized("隔离更强，适合已有 Docker 的完整栈")
        }
    }
}

enum DeploymentStage: String {
    case idle
    case ready
    case connecting
    case installing
    case attached
    case cancelled
    case failed

    var title: String {
        switch self {
        case .idle: OasesLocalization.localized("未开始")
        case .ready: OasesLocalization.localized("计划已生成")
        case .connecting: OasesLocalization.localized("连接中")
        case .installing: OasesLocalization.localized("部署中")
        case .attached: OasesLocalization.localized("已接入")
        case .cancelled: OasesLocalization.localized("已取消")
        case .failed: OasesLocalization.localized("需要处理")
        }
    }
}

enum DeploymentHealthState: String, Equatable {
    case unknown
    case healthy
    case checking
    case degraded
    case recovering

    var title: String {
        switch self {
        case .unknown: OasesLocalization.localized("未检测")
        case .healthy: OasesLocalization.localized("服务健康")
        case .checking: OasesLocalization.localized("检测中")
        case .degraded: OasesLocalization.localized("服务不可用")
        case .recovering: OasesLocalization.localized("自动恢复中")
        }
    }
}

enum DeploymentStepStatus: String {
    case pending
    case current
    case complete
    case note
}

struct DeploymentStep: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    var status: DeploymentStepStatus
}

struct DeploymentTargetSummary {
    let operatingSystem: String
    let architecture: String
    let shell: String
    let access: String
}

enum DeploymentPlanFactory {
    static func makeSteps(target: DeploymentTargetKind, method: DeploymentMethod) -> [DeploymentStep] {
        let connectionDetail: String
        if target == .local {
            connectionDetail = OasesLocalization.localized("确认当前用户可以在本机执行安装命令")
        } else {
            connectionDetail = OasesLocalization.localized("建立 SSH 会话，并优先创建本地端口转发")
        }

        let runtimeDetail = method == .native
            ? OasesLocalization.localized("下载官方 CLIProxyAPI 与 CPAMP 原生包，并校验 SHA-256")
            : OasesLocalization.localized("生成 Compose 文件，准备 CLIProxyAPI 与 CPAMP 两个服务")

        return [
            .init(title: OasesLocalization.localized("连接目标环境"), detail: connectionDetail, systemImage: "point.3.connected.trianglepath.dotted", status: .current),
            .init(title: OasesLocalization.localized("检测系统与依赖"), detail: OasesLocalization.localized("识别 OS、架构、curl、SSH、Docker 与可写目录"), systemImage: "checkmark.shield", status: .pending),
            .init(title: OasesLocalization.localized("部署 CLIProxyAPI"), detail: runtimeDetail, systemImage: "arrow.down.app", status: .pending),
            .init(title: OasesLocalization.localized("生成私有配置"), detail: OasesLocalization.localized("创建 config.yaml、认证目录与管理密钥，不覆盖已有配置"), systemImage: "lock.doc", status: .pending),
            .init(title: OasesLocalization.localized("启动并验证网关"), detail: OasesLocalization.localized("验证 8317 管理 API 与本机回环访问"), systemImage: "bolt.horizontal.circle", status: .pending),
            .init(title: OasesLocalization.localized("接入 CPA Manager Plus"), detail: OasesLocalization.localized("Full Mode 提供请求监控、成本、配额与账号健康"), systemImage: "rectangle.3.group", status: .pending)
        ]
    }
}
