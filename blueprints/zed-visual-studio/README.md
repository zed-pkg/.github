# zed-visual-studio

Buildable .NET core candidate for a Visual Studio VSIX.

The core uses `ProcessStartInfo.ArgumentList`, timeout/cancellation, injected process tests, schema validation, credential redaction, and unsafe command-action rejection.

A dedicated repository still needs the VS SDK AsyncPackage, tool window, solution/workspace listeners, Error List integration, VSIX manifest/signing, and experimental-instance UI tests.
