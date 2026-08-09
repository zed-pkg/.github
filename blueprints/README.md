# IDE extension repository blueprints

These directories are incubation trees for three dedicated repositories:

- `zed-pkg/zed-visual-studio`
- `zed-pkg/zed-eclipse`
- `zed-pkg/zed-xcode`

They share the read-only diagnostic contract in `docs/ide-insight-contract.md`. Once the repositories are created, copy each directory to its own repository, preserve Git history where practical, and replace the bootstrap README with native build and release documentation.

The native technology choices are intentional:

- Visual Studio: C# and a VSIX tool window/commands.
- Eclipse: Java, OSGi/PDE, and an Eclipse view with markers and quick fixes.
- Xcode: Swift, a macOS companion dashboard, and an Xcode Source Editor Extension. XcodeKit does not provide a general-purpose persistent IDE sidebar, so package-state UI belongs in the companion app while editor commands expose safe contextual actions.
