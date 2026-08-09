# zed-xcode

Buildable Swift core candidate for a macOS companion app and Xcode Source Editor Extension.

The core has an injectable process runner, argv execution, timeout, schema validation, output redaction, and unsafe-action rejection. `swift test` covers the contract without launching a user's Xcode instance.

A dedicated repository still needs the companion dashboard, XcodeKit commands, signed app/appex packaging, entitlements, and clean Xcode-instance UI tests.
