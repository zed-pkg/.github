# zed-pkg Nix environment rollout status

Last verified: 2026-08-05

This document is the organization-level execution record for Linear issue
[`DEN-359`](https://linear.app/denman/issue/DEN-359/zed-pkg-repos-audit-and-roll-out-agent-first-nix-environments).
It complements `PROJECT_TRACKING.md`: Linear owns roadmap and dependency state;
GitHub pull requests own exact source changes, CI evidence, and merge commits.

## Completed: `zed-clients`

[`zed-pkg/zed-clients#29`](https://github.com/zed-pkg/zed-clients/pull/29)
merged into `main` on 2026-08-05 as
`e79723981b88f8b6fbb2f49e7d3d954e2832cdc6`.

The merged change supplies an agent-first, runtime-focused Nix environment for
the fourteen-client SDK matrix. Its permanent product delta is limited to nine
environment, validation, cache-policy, and documentation files; it does not
modify SDK production source, SDK tests, package manifests, interface schemas,
or Zed lockfile product behavior.

Delivered guarantees:

- immutable `nixos-unstable` input and committed `flake.lock`;
- focused shells for toolchain, preflight, contract, and fourteen SDK stages;
- a complete default shell for human development;
- non-interactive `nix develop -c agent-check <stage>` entry points;
- read-only GitHub Actions with immutable action SHAs;
- isolated npm, Cargo, Go, Dart, Rebar3, Mix, Hex, and Maven caches;
- exact sibling `zed-interfaces` checkout for Rust and WASM validation;
- TypeScript validation across Node.js, Deno, Bun, and edge entry points;
- Swift compiler and SwiftPM supplied as one internally compatible Nixpkgs
  package set, with `SWIFT_EXEC` bound to that compiler; and
- no hand-repacked Swift archive or branch-mutating helper workflow in the
  merged tree.

The previous experimental Swift path was rejected after it demonstrated that a
repacked Ubuntu Swift toolchain could start `swiftc` while still failing SwiftPM
manifest compilation. The merged implementation uses the flake-locked Nixpkgs
Swift package set instead of mixing incompatible runtime libraries.

## Evidence policy

For every repository in the rollout:

1. Record the exact PR URL, reviewed head SHA, and merge SHA.
2. Distinguish source/test failures from runner allocation, workflow approval,
   billing, or credential failures.
3. Require the ordinary product head to pass; a temporary materializer or
   formatter workflow is not sufficient evidence.
4. Keep the final tree free of write-enabled helper workflows.
5. Preserve native package-manager and Docker/OCI behavior unless a reviewed
   product requirement explicitly changes it.
6. Update Linear only after GitHub reports the actual merge state.

## Remaining organization rollout

`DEN-359` remains an organization-wide issue rather than a single-repository
completion marker. Continue auditing active `zed-pkg` repositories and classify
each as CLI, interface, client/SDK, server, registry, integration-test,
package-fixture, monorepo, or infrastructure work.

For each applicable repository, add or verify:

- root `flake.nix` and committed `flake.lock`;
- small `.nix/` modules rather than duplicated workflow shell logic;
- a deterministic, non-interactive `agent-check` command;
- pinned read-only Nix CI;
- native package-manager interoperability tests;
- Docker/OCI parity for server and registry workloads; and
- links between the GitHub PR and the canonical Linear issue.

## GitHub Projects v2

[`zed-pkg-project`](https://github.com/orgs/zed-pkg/projects/1) is the verified
canonical organization board (project 1). The fleet reconciler maintains its
exact title, active state, durable governance issue, and links to the canonical
Linear project and organization documentation.

Use:

- the Linear project [`github.com/zed-pkg`](https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc) for portfolio planning and dependencies;
- `zed-pkg-project` for cross-repository execution visibility; and
- GitHub issues, pull requests, commits, checks, releases, and this organization
  policy repository for code and delivery evidence.
