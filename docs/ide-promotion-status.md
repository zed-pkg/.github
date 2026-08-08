# IDE repository promotion status

Tracking: Linear `DEN-2508` and `zed-pkg/.github#28`.

The five formerly incubated IDE integrations now have dedicated repositories:

- `zed-pkg/zed-vscode`
- `zed-pkg/zed-qtcreator`
- `zed-pkg/zed-xcode`
- `zed-pkg/zed-eclipse`
- `zed-pkg/zed-visual-studio`

The old `publish-zed-vscode` bootstrap workflow and its split Git bundle were a one-time repository-provisioning mechanism. They are retired because the repository exists, the stored bundle was not a valid long-term source artifact, and the dedicated repository now carries ordinary source plus its own review/CI history.

Current dedicated-repository review candidates are recorded in `zed-pkg/zed-docs#56` and independently certified by `zed-pkg-test/zed-pkg-e2e#112`.

GitHub Projects v2 synchronization remains a separate operational gate: the connected GitHub app can write repository contents, issues, workflows, and pull requests, but its exposed action surface does not currently provide organization Project item mutation. No plaintext personal token belongs in a workflow input, branch, commit, remote, or log to bypass that boundary.
