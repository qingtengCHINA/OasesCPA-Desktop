import Foundation

/// A target platform of a native deployment, as the install scripts spell it
/// (`PLATFORM="$RELEASE_OS/$ARCH"`, with `arm64|aarch64 → arm64` and `x86_64|amd64 → amd64`).
enum DeploymentPlatform: String, CaseIterable, Sendable {
    case darwinARM64 = "darwin/arm64"
    case darwinAMD64 = "darwin/amd64"
    case linuxARM64 = "linux/arm64"
    case linuxAMD64 = "linux/amd64"
}

/// One downloadable release file and its SHA-256.
struct PinnedAsset: Equatable, Sendable {
    let fileName: String
    let sha256: String
}

/// A release (tag) with one pinned file per platform. A platform without an entry is not
/// deployable natively (the selection script exits 14 for it).
struct PinnedArtifact: Equatable, Sendable {
    let tag: String
    let assets: [DeploymentPlatform: PinnedAsset]
}

/// Every pinned input of a deployment. The values, their sources and the checks each one passed
/// are recorded in `docs/acceptance/supply-chain-pins.md`; scripts never read a remote checksum
/// file and never ask for a "latest" release.
struct DeploymentPinSet: Equatable, Sendable {
    let engine: PinnedArtifact
    let cpamp: PinnedArtifact
    let node: PinnedArtifact
    let gateway: GatewayBundle
    let cliDockerImage: String
    let cpampDockerImage: String

    static let nativeArchiveMaxBytes = 536_870_912

    static let current = DeploymentPinSet(
        engine: PinnedArtifact(tag: "v8.0.51", assets: [
            .darwinARM64: PinnedAsset(fileName: "CLIProxyAPI_8.0.51_darwin_aarch64.tar.gz", sha256: "fb8e2568e98e3304a1b892c4f70a4c154c661078ad87007e63cf7ba71b4ce168"),
            .darwinAMD64: PinnedAsset(fileName: "CLIProxyAPI_8.0.51_darwin_amd64.tar.gz", sha256: "7f68be928979c3991d097255fd8fb732edc684e72fe10faf29a365e44246cedb"),
            .linuxARM64: PinnedAsset(fileName: "CLIProxyAPI_8.0.51_linux_aarch64.tar.gz", sha256: "411aa08783c572bdb72a6ba0ffcc0a75155be27e75a1c5aef3b49d8b96da4d52"),
            .linuxAMD64: PinnedAsset(fileName: "CLIProxyAPI_8.0.51_linux_amd64.tar.gz", sha256: "15de160e1fd97a0f9f7e0577582c765b14e040ab6a8314f514af9fae8a2c4700"),
        ]),
        cpamp: PinnedArtifact(tag: "v1.14.10", assets: [
            .darwinARM64: PinnedAsset(fileName: "cpa-manager-plus_v1.14.10_darwin_arm64.tar.gz", sha256: "3a8df00dc1ffad46438e932536c6dab32aa547dba39d9ae50dd63ddec4fe4872"),
            .darwinAMD64: PinnedAsset(fileName: "cpa-manager-plus_v1.14.10_darwin_amd64.tar.gz", sha256: "4a10f1c0ea015072e2af0e09fdd67a7f5ce1d801c27741d7aead92fec240b009"),
            .linuxARM64: PinnedAsset(fileName: "cpa-manager-plus_v1.14.10_linux_arm64.tar.gz", sha256: "450bca4846e5ea916aa10480e05a524c0e1f55d591ce0c8ece5bb22ba3084c03"),
            .linuxAMD64: PinnedAsset(fileName: "cpa-manager-plus_v1.14.10_linux_amd64.tar.gz", sha256: "113a651af78f4dd8c5279e03348729411d964043d74bbd338147dafa2bcb8d86"),
        ]),
        node: PinnedArtifact(tag: "v24.22.2", assets: [
            .darwinARM64: PinnedAsset(fileName: "node-v24.22.2-darwin-arm64.tar.gz", sha256: "aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a"),
            .darwinAMD64: PinnedAsset(fileName: "node-v24.22.2-darwin-x64.tar.gz", sha256: "d5e336d588c45be0c37dbd52cc29895593009ca4997a77a1fd02815131ed0e52"),
            .linuxARM64: PinnedAsset(fileName: "node-v24.22.2-linux-arm64.tar.gz", sha256: "95c264150aceb7f3437a29fd6984924f5f8d1511ea3cbd6c508b83f6c555dae2"),
            .linuxAMD64: PinnedAsset(fileName: "node-v24.22.2-linux-x64.tar.gz", sha256: "361718c444e49af2ca5a110c83ba6a8901143f23ab285ebbef0341f391f482a9"),
        ]),
        gateway: .bundled,
        cliDockerImage: "eceasy/cli-proxy-api@sha256:15d13889e1a39a688be306dfbf2f6cf9003e99cd913b5070fa463f8ab2aa0031",
        cpampDockerImage: "seakee/cpa-manager-plus@sha256:0e803f21d51aceea7b752686417bf57f40678d8068fe102ba23cb2a3afb414e1"
    )

    /// The same pins with another gateway package (tests, and the DEBUG end-to-end override).
    func with(gateway: GatewayBundle) -> DeploymentPinSet {
        DeploymentPinSet(
            engine: engine,
            cpamp: cpamp,
            node: node,
            gateway: gateway,
            cliDockerImage: cliDockerImage,
            cpampDockerImage: cpampDockerImage
        )
    }

    /// Refuses a build that only carries the placeholder gateway. Install and upgrade call this
    /// before they generate a script.
    func deployable() throws -> DeploymentPinSet {
        guard !gateway.isPlaceholder else { throw DeploymentExecutionError.placeholderGateway }
        return self
    }

    /// Bash that selects the pinned files for `PLATFORM="$RELEASE_OS/$ARCH"` (the caller sets
    /// `RELEASE_OS` to darwin|linux and `ARCH` to arm64|amd64). It sets `CLI_ASSET`,
    /// `CLI_EXPECTED_SHA256`, `CLI_PACKAGE` (the asset name without `.tar.gz`, kept as the
    /// `runtime/<package>` directory name), the same for `CPAMP_*` and `NODE_*`, the tags
    /// `CLI_VERSION_TAG`, `CPAMP_VERSION_TAG`, `NODE_VERSION_TAG`, and `GATEWAY_VERSION`,
    /// `GATEWAY_FILE`, `GATEWAY_EXPECTED_SHA256`. An unknown platform exits 14.
    func nativeSelectionScript() -> String {
        var branches: [String] = []
        for platform in DeploymentPlatform.allCases {
            guard let cli = engine.assets[platform],
                  let panel = cpamp.assets[platform],
                  let runtime = node.assets[platform] else { continue }
            branches.append("""
              \(platform.rawValue))
                CLI_ASSET="\(cli.fileName)"
                CLI_EXPECTED_SHA256="\(cli.sha256)"
                CPAMP_ASSET="\(panel.fileName)"
                CPAMP_EXPECTED_SHA256="\(panel.sha256)"
                NODE_ASSET="\(runtime.fileName)"
                NODE_EXPECTED_SHA256="\(runtime.sha256)"
                ;;
            """)
        }
        return """
        CLI_VERSION_TAG="\(engine.tag)"
        CPAMP_VERSION_TAG="\(cpamp.tag)"
        NODE_VERSION_TAG="\(node.tag)"
        GATEWAY_VERSION="\(gateway.version)"
        GATEWAY_FILE="\(gateway.fileName)"
        GATEWAY_EXPECTED_SHA256="\(gateway.sha256)"
        PLATFORM="$RELEASE_OS/$ARCH"
        case "$PLATFORM" in
        \(branches.joined(separator: "\n"))
          *)
            printf '%s\\n' '目标平台没有固定的官方发布摘要。' >&2
            exit 14
            ;;
        esac
        CLI_PACKAGE="${CLI_ASSET%.tar.gz}"
        CPAMP_PACKAGE="${CPAMP_ASSET%.tar.gz}"
        NODE_PACKAGE="${NODE_ASSET%.tar.gz}"
        """
    }

    func dockerImageEnvironmentScript() -> String {
        """
        CLI_DOCKER_IMAGE="\(cliDockerImage)"
        CPAMP_DOCKER_IMAGE="\(cpampDockerImage)"
        """
    }
}
