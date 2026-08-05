# zed-visual-studio

Native Visual Studio extension for Zed package state, diagnostics, and recommended actions.

## Stack

- C#
- Visual Studio 2022 VSIX
- VSIX Community Toolkit
- WPF tool window
- `zed inspect --json` process adapter

## MVP

1. Detect the solution root and nearest `.zpkg.toml`.
2. Render package identity, direct/transitive dependencies, lock state, and CLI version.
3. Show issues in a dedicated **Zed Packages** tool window and mirror file-specific findings into the Error List.
4. Offer explicit, confirm-before-run actions such as `zed install`, `zed install --frozen`, `zed add`, `zed remove`, and `zed self-update --check`.
5. Refresh on solution open, manifest/lock change, and manual refresh.
6. Never mutate package state without showing the exact command and obtaining confirmation.

## Repository layout

- `src/Zed.VisualStudio.Core`: process adapter and shared report model; portable and testable without Visual Studio.
- `src/Zed.VisualStudio`: VSIX package, tool window, commands, Error List integration, and settings.
- `tests`: parser, process, and Visual Studio integration tests.

The incubated core below intentionally has no dependency on Visual Studio APIs. Generate the VSIX shell from the current official Visual Studio extensibility template, then reference the core project.
