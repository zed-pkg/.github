# zed-eclipse

Native Eclipse plug-in for Zed package state, diagnostics, and recommended actions.

## Stack

- Java 21
- Eclipse PDE / OSGi bundle
- Maven Tycho build
- Eclipse view, workspace markers, commands, and quick fixes
- `zed inspect --json` process adapter

## MVP

1. Add a **Zed Packages** view for the selected project.
2. Watch `.zpkg.toml` and `.zpkg.lock` through Eclipse resource listeners.
3. Convert file-specific Zed issues into workspace markers so they appear in Problems.
4. Expose quick fixes, but require confirmation before every mutating command.
5. Support projects nested inside larger workspaces and multi-project workspaces.
6. Package a signed p2 update site and downloadable feature archive.

The incubated Java class is the process boundary. The PDE project should keep JSON parsing and command execution behind this API so UI and marker tests can inject deterministic reports.
