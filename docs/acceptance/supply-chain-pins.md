# Supply-chain pins (Task 7)

Recorded 2026-11-08. Every SHA-256 in `Sources/OasesCPA/Services/DeploymentPins.swift` and
`GatewayBundle.swift` was obtained from the sources below and cross-checked; none was typed in
from memory. Scripts never read a remote checksum file at run time and never ask GitHub for a
"latest" release: the values are compiled into the app. `<scratch>` stands for the session's
scratch directory.

Rule for every value: it is pinned only when all of its sources agree. No source disagreed, so
every platform of every artifact is pinned.

Checks:

- **D** GitHub asset `digest` (`gh api repos/<owner>/<repo>/releases/tags/<tag>`).
- **C** the release's own checksum manifest, downloaded (a small text file) and read; for the
  engine and CPA Manager Plus its own SHA-256 also equals the GitHub digest of that manifest.
- **S** Node's `SHASUMS256.txt`, verified with `gpg --verify SHASUMS256.txt.sig` in a separate
  scratch keyring against the release key named below.
- **P** the Server repository's `test/e2e/engine-pin.json` (engine only).
- **H** the handover record of the production engine upgrade (engine linux/amd64 only).
- **L** local `shasum -a 256` of the downloaded package (darwin/arm64 only; no other platform's
  package was downloaded).

## Engine: CLIProxyAPI v8.0.51

Release `router-for-me/CLIProxyAPI` `v8.0.51`, `prerelease=false`, `draft=false`, published
2026-11-01T17:08:04Z. Asset names use `aarch64` for arm64 (R13). The package has no top
directory; the binary at its root is still named `cli-proxy-api` (checked in the darwin/arm64
package).

| Platform | File | SHA-256 | Checks |
|---|---|---|---|
| darwin/arm64 | `CLIProxyAPI_8.0.51_darwin_aarch64.tar.gz` | `fb8e2568e98e3304a1b892c4f70a4c154c661078ad87007e63cf7ba71b4ce168` | D, C, P, L |
| darwin/amd64 | `CLIProxyAPI_8.0.51_darwin_amd64.tar.gz` | `7f68be928979c3991d097255fd8fb732edc684e72fe10faf29a365e44246cedb` | D, C, P |
| linux/arm64 | `CLIProxyAPI_8.0.51_linux_aarch64.tar.gz` | `411aa08783c572bdb72a6ba0ffcc0a75155be27e75a1c5aef3b49d8b96da4d52` | D, C, P |
| linux/amd64 | `CLIProxyAPI_8.0.51_linux_amd64.tar.gz` | `15de160e1fd97a0f9f7e0577582c765b14e040ab6a8314f514af9fae8a2c4700` | D, C, P, H |

The release manifest (`checksums.txt`, 1084 bytes) has SHA-256
`658605a22aaaecca6c513338bacd7531adb455fc444e3b64db3aa51bd094a9b5`, equal to its GitHub digest
and to the copy downloaded earlier in the session. The darwin/arm64 package is the copy already
in `<scratch>/engine-v8.0.51-darwin/` (22,708,873 bytes); it was not downloaded again.

## Panel backend: CPA Manager Plus v1.14.10

Release `seakee/CPA-Manager-Plus` `v1.14.10`, `prerelease=false`, `draft=false`, published
2026-10-29T04:45:36Z (the `qualification-*` pre-releases are not used). Each package has one
top directory `cpa-manager-plus_v1.14.10_<os>_<arch>/` with the binary `cpa-manager-plus`.

| Platform | File | SHA-256 | Checks |
|---|---|---|---|
| darwin/arm64 | `cpa-manager-plus_v1.14.10_darwin_arm64.tar.gz` | `3a8df00dc1ffad46438e932536c6dab32aa547dba39d9ae50dd63ddec4fe4872` | D, C, L |
| darwin/amd64 | `cpa-manager-plus_v1.14.10_darwin_amd64.tar.gz` | `4a10f1c0ea015072e2af0e09fdd67a7f5ce1d801c27741d7aead92fec240b009` | D, C |
| linux/arm64 | `cpa-manager-plus_v1.14.10_linux_arm64.tar.gz` | `450bca4846e5ea916aa10480e05a524c0e1f55d591ce0c8ece5bb22ba3084c03` | D, C |
| linux/amd64 | `cpa-manager-plus_v1.14.10_linux_amd64.tar.gz` | `113a651af78f4dd8c5279e03348729411d964043d74bbd338147dafa2bcb8d86` | D, C |

The release manifest (`checksums.txt`, 678 bytes) has SHA-256
`7c509e591e53cc1153db28c3b082b1f8d364f85461800aafe72886bd6bfcacbf`, equal to its GitHub digest.
The darwin/arm64 package (8,492,494 bytes) was downloaded once into its own new directory
`<scratch>/cpamp-v1.14.10-darwin-arm64/` and only read (listed, hashed), never run from there.

## Node.js runtime: v24.22.2 (24 LTS "Krypton")

`https://nodejs.org/dist/index.json` read on 2026-11-08: the newest entry whose `lts` is not
false and whose version starts with `v24.` is `v24.22.2` (2026-10-27). GitHub has no assets for
Node, so check D does not exist for it; the signed manifest is the source.

`SHASUMS256.txt` (3171 bytes) and `SHASUMS256.txt.sig` were downloaded from
`https://nodejs.org/dist/v24.22.2/`. `gpg --verify` reports a good EdDSA signature by key
`5BE8A3F6C8A5C01D106C0AD820B1A390B168D356`; the public key was taken from
`nodejs/release-keys` (`keys/5BE8A3F6C8A5C01D106C0AD820B1A390B168D356.asc`), the fingerprint is
listed in that repository's `keys.list` and among the releasers in the README of `nodejs/node`.
The key is not certified in the scratch keyring (gpg's "not certified with a trusted
signature" warning); the trust decision rests on those two listings.

| Platform | File | SHA-256 | Checks |
|---|---|---|---|
| darwin/arm64 | `node-v24.22.2-darwin-arm64.tar.gz` | `aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a` | S, L |
| darwin/amd64 | `node-v24.22.2-darwin-x64.tar.gz` | `d5e336d588c45be0c37dbd52cc29895593009ca4997a77a1fd02815131ed0e52` | S |
| linux/arm64 | `node-v24.22.2-linux-arm64.tar.gz` | `95c264150aceb7f3437a29fd6984924f5f8d1511ea3cbd6c508b83f6c555dae2` | S |
| linux/amd64 | `node-v24.22.2-linux-x64.tar.gz` | `361718c444e49af2ca5a110c83ba6a8901143f23ab285ebbef0341f391f482a9` | S |

The darwin/arm64 package (53,068,959 bytes) was downloaded once into its own new directory
`<scratch>/node-v24.22.2-darwin-arm64/`; it has one top directory
`node-v24.22.2-darwin-arm64/` with `bin/node`.

## Docker images (legacy Docker topology)

`docker buildx imagetools inspect` on 2026-11-08; the pin is the digest of the multi-platform
image index (OCI index, linux/amd64 and linux/arm64 manifests plus attestations). One source
(the registry) per image.

| Image | Pin |
|---|---|
| `eceasy/cli-proxy-api:v8.0.51` | `eceasy/cli-proxy-api@sha256:15d13889e1a39a688be306dfbf2f6cf9003e99cd913b5070fa463f8ab2aa0031` |
| `seakee/cpa-manager-plus:v1.14.10` | `seakee/cpa-manager-plus@sha256:0e803f21d51aceea7b752686417bf57f40678d8068fe102ba23cb2a3afb414e1` |

## Bundled gateway: oases-gateway 0.1.0

The app carries the released Server package (R17/H1) as
`Sources/OasesCPA/Resources/Gateway/oases-gateway_0.1.0.tar.gz` (116,327 bytes), vendored with
`script/vendor_gateway.sh --tarball <scratch>/release-out/oases-gateway_0.1.0.tar.gz --checksums
<scratch>/release-out/checksums.txt`:

- SHA-256 `6a6e1a8566a3fd9107b935da18b31a6dec847095fdc10cbc05ee11c8d363d22b`, equal to the
  package's line in the release `checksums.txt`.
- One top directory `oases-gateway_0.1.0/` with `VERSION` = `0.1.0`, `server.mjs`,
  `bootstrap.mjs` and the gateway modules, `LICENSE`, `NOTICE`.
- The shared scanner (`check-no-private.sh --dir … --require-private-terms`) found nothing in
  the unpacked package.
- Provenance: the Server repository at commit `b6774df1d8c63c447aea1fb874f26188bc610409`
  (branch `feat/server-bundle`, clean work tree), exported with `git archive` and built with its
  own `script/build-release.sh`, gives a byte-identical package (same SHA-256): the build is
  reproducible and the bundled package is that commit's release.
- `script/vendor_gateway.sh --server` was exercised once against the same commit into a scratch
  directory (not used for the resource): it produced `oases-gateway_0.1.0-dev.tar.gz`, which
  `script/package_release.sh` would refuse to ship.
