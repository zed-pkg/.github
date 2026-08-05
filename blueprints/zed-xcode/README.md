# zed-xcode

Native Apple integration for Zed package state, diagnostics, and recommended actions.

## Stack

- Swift
- macOS companion app with a package dashboard
- Xcode Source Editor Extension using XcodeKit
- shared App Group storage between the app and extension
- `zed inspect --json` process adapter in the companion app

## Why a companion app

Xcode Source Editor Extensions add editor commands; they are not a general-purpose persistent tool-window API. The companion app therefore owns workspace selection, filesystem watching, process execution, package graphs, issue lists, settings, and confirmation dialogs. The Xcode extension reads the latest cached report and exposes contextual commands such as **Show Zed package issue**, **Insert diagnostic summary**, and safe source edits derived from a confirmed recommendation.

## MVP

1. Let the user select and remember one or more project roots.
2. Watch `.zpkg.toml` and `.zpkg.lock`, invoke `zed inspect --json`, and cache reports in the App Group.
3. Render dependency state and recommended actions in a native SwiftUI dashboard.
4. Require confirmation in the companion app before any mutating command.
5. Add an Xcode Source Editor Extension target for contextual commands.
6. Sign and notarize releases; evaluate Mac App Store distribution for the companion/extension bundle.

`Sources/ZedCore` is a Swift Package core that can be tested independently before the Xcode app and extension targets are generated.
