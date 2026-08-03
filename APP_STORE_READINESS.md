# App Store Readiness

The generated OasesCPA.xcodeproj includes an AppStore build configuration. It
uses OasesCPA-AppStore.entitlements, which enables App Sandbox, user-selected
read/write files, outgoing network access, and incoming network access for the
loopback OAuth callback. The project also bundles a privacy manifest declaring
the app's own UserDefaults use.

This configuration is an archive and signing foundation, not an assertion that
the current product is ready for Mac App Store review.

## Current review blocker

The app's core deployment flow downloads, installs, and executes CLIProxyAPI
and CPA Manager Plus on a local target. Mac App Store Review Guideline 2.4.5
does not permit an app to download or install standalone apps, code, or
resources that add functionality, and requires the submission to be a
self-contained app bundle. The current direct-distribution product therefore
needs an App Store-specific product change before submission.

## Recommended App Store variant

1. Remove local binary and Docker deployment from the App Store target.
2. Keep remote SSH control only for a user-owned, already provisioned target,
   or provide read-only monitoring/configuration for a target the user
   connects to.
3. Replace text-entered local installation directories with an NSOpenPanel
   selection and persisted security-scoped bookmark where file access is
   required.
4. Test every retained workflow under the AppStore configuration with a real
   Apple Development or Apple Distribution signing identity, then archive from
   the Oases CPA scheme.
5. Complete App Store Connect privacy nutrition labels, the privacy policy,
   screenshots, and review notes before upload.

Until that variant is implemented and reviewed, use the existing Developer ID
or direct distribution workflow for the full local deployment feature set.
