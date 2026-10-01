# Validation — Room Remote 0.1.0

Completed on September 21, 2026.

- Android debug APK assembled successfully with Android SDK 35 and Gradle 8.11.1.
- Seven automated tests passed; none failed or were skipped.
- Tests cover private-address validation, malformed/public address rejection, discovery response filtering, device identity parsing, XML entity/doctype rejection, empty-body HTTP button commands, and handling refused control requests using a local mock TV server.
- Android lint completed with no errors. Seven warnings concern translation-ready strings, an attribute unused on older versions, and backup extraction-rule metadata. Backup is disabled.
- APK signature verification passed using APK Signature Scheme v2, compatible with the minimum Android 8.0 requirement.
- The manifest declares a connected-device foreground service, its permissions, notification permission, and stop-on-task-removal behavior. The code starts it from a visible user action and provides explicit Disconnect actions.

## Build environment notes

This Windows sandbox caused Java ZIP-library cleanup access errors and prevented automatic creation of the default debug signing key. The successful build used a separately generated debug key and Gradle's supported external compiler option. Compiler cleanup diagnostics remained in the log, but compilation, tests, lint, dex generation, packaging, and signature verification completed successfully. These environment workarounds do not change the app's runtime behavior.

## Not verified

No Android phone, emulator, or real Roku TV was available for runtime testing. UI rendering, TV discovery on your router, real TV commands, lock-screen persistence, manufacturer battery policies, and lifecycle behavior on a physical phone remain unverified. The foreground-service implementation is best-effort and cannot override Android force-stop or guarantee indefinite execution.

Roku's documented third-party control restriction remains a compatibility limitation. This package is an experimental, debug-signed personal prototype.
