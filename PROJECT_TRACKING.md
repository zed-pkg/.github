# zed-pkg project tracking

Last verified: 2026-08-05

This document records only identifiers read from canonical systems. Do not
infer a project number, channel name, release state, or integration state from
repository naming.

## Canonical organization

- GitHub organization: [`zed-pkg`](https://github.com/zed-pkg)
- Organization policy repository: [`zed-pkg/.github`](https://github.com/zed-pkg/.github)
- Primary CLI repository: [`zed-pkg/zed-cli`](https://github.com/zed-pkg/zed-cli)
- Independent locking library: [`zed-pkg/zed-lock`](https://github.com/zed-pkg/zed-lock)

`zed-pkg` is an independent multi-language package-management framework. It is
not part of, sponsored by, or integrated with the Zed editor product.

## Linear

The verified Linear project is:

- Name: `github.com/zed-pkg`
- Project ID: `9107ce62-1112-43ff-89bc-f442613c4156`
- URL: [`github.com/zed-pkg`](https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc)
- Team: `Denman` (`DEN`)
- State: `In Progress`
- Priority: `Urgent`
- Connected Slack channel ID: `C0BL0K0HABB`

Linear owns the cross-repository roadmap, issue dependencies, architectural
policy, rollout status, and certification evidence. GitHub pull requests own the
reviewable source diff, exact commits, CI evidence, merge state, and release
artifacts.

When updating Linear from GitHub work:

1. Link the exact pull request and immutable head SHA.
2. Distinguish code/test failures from workflow approval, billing, or runner
   allocation failures.
3. Record the merge commit only after GitHub reports the PR merged.
4. Do not mark a feature complete merely because a materializer or helper
   workflow succeeded; validate the ordinary product-source head.
5. Keep superseded PRs and branches explicitly identified so stale stacks are
   not merged accidentally.

## GitHub Projects v2

The intended organization board title is `zed-pkg-project`.

No GitHub Projects v2 node ID or project number was verified during this update.
The connected GitHub API surface exposed repository, pull-request, issue, and
Actions operations but not Projects v2 GraphQL mutations. Requests to the
legacy organization-project endpoint and an assumed `/projects/1` URL returned
`404`, so this repository must not claim that project number 1 exists.

Creation or verification is tracked in
[`zed-pkg/.github#13`](https://github.com/zed-pkg/.github/issues/13).

Until the board is verified or created through an authorized GraphQL or
`gh project` session:

- use the Linear project above as the portfolio roadmap;
- use GitHub issues and pull requests as the repository execution ledger;
- do not fabricate a project URL in issue templates, automation, or reports;
- once created, record the verified project number, node ID, URL, owner, and
  field schema here in a reviewed PR.

Recommended Projects v2 fields:

| Field | Purpose |
| --- | --- |
| `Status` | Backlog, Ready, In progress, In review, Blocked, Done |
| `Repository` | Owning `zed-pkg/*` repository |
| `Linear` | DEN issue identifier or project link |
| `Package layer` | Interfaces, clients, library, CLI, server, test, infra |
| `Release gate` | Source review, CI, artifact, publish, certification |
| `Target branch` | `main`, `dev`, or another explicitly reviewed branch |
| `Blocked by` | Upstream PR, package, credential, or runner dependency |

## Current CLI and package merge train

Completed foundations:

1. [`zed-pkg/zed-cli#162`](https://github.com/zed-pkg/zed-cli/pull/162)
   merged explicit global executable profiles and controlled PATH ownership.
2. [`zed-pkg/zed-cli#198`](https://github.com/zed-pkg/zed-cli/pull/198)
   moved Cargo to the standalone lock repository, regenerated `Cargo.lock`,
   removed the duplicate `crates/zed-lock` copy, and split crate-owned from
   CLI-owned CI.
3. [`zed-pkg/zed-lock#2`](https://github.com/zed-pkg/zed-lock/pull/2)
   merged as immutable commit
   `a0dc78d385bc3ab553d3027b427f5f1428239c9c`. It versions the hardened package
   as 0.1.1, declares Rust 1.88 as the actual MSRV, corrects Zed package
   metadata, adds fail-closed provenance/metadata tests, passes Linux/macOS/
   Windows conformance, and emits a reviewed `.crate` plus SHA-256 artifact.
4. [`zed-pkg/zed-cli#199`](https://github.com/zed-pkg/zed-cli/pull/199)
   merged the supported `macos-15-intel` runner for the unchanged
   `x86_64-apple-darwin` release target.

Active ordered work:

1. The `zed-lock` branch `release/v0.1.1` runs a one-shot publisher that checks
   out exact merge commit `a0dc78d385bc3ab553d3027b427f5f1428239c9c`,
   revalidates the package, creates immutable tag/release `v0.1.1`, and uploads
   a newly generated crate and checksum. It does not alter `v0.1.0`.
2. [`zed-pkg/zed-cli#204`](https://github.com/zed-pkg/zed-cli/pull/204)
   updates the exact Cargo revision and generated lock entry to the hardened
   merge commit and adds `zed-pkg/zed-lock = "^0.1.1"` to the Zed package
   graph. Its carrier proves no non-lock package changes, removes itself, and
   leaves ordinary source for the full matrix.
3. [`zed-pkg/zed-cli#203`](https://github.com/zed-pkg/zed-cli/pull/203)
   certifies the real compiled global install, frozen restore, lock graph,
   PATH copy, transitive package, and uninstall lifecycle against a hermetic
   `file://` registry.
4. [`zed-pkg/zed-cli#200`](https://github.com/zed-pkg/zed-cli/pull/200)
   cleanly rematerializes deterministic, conflict-safe `zed env export mise`
   on the latest mainline, preserving the typed write boundary and real-CLI
   reserved-path regressions.
5. The release-candidate branch `release/v0.1.0-rc.3` rebuilds all seven CLI
   target archives and checksums using the corrected Intel macOS runner. It is
   a retained review-artifact lane, not a public `v*` release.

Superseded work:

- [`zed-pkg/zed-cli#195`](https://github.com/zed-pkg/zed-cli/pull/195) is closed
  because it assumed the now-removed internal lock crate.
- [`zed-pkg/zed-cli#131`](https://github.com/zed-pkg/zed-cli/pull/131) is closed
  in favor of the current-main semantic carrier #200.
- [`zed-pkg/zed-cli#202`](https://github.com/zed-pkg/zed-cli/pull/202) is closed
  because merged PR #199 already contains its exact one-line runner change.

Merge rules:

- never merge a dependent PR before its canonical dependency is green and
  merged;
- never weaken the package graph to make an invented coordinate pass;
- use a semantic merge or current-main carrier when branches overlap, preserving
  compatible behavior and tests rather than choosing one side wholesale;
- merge only the exact ordinary-source head whose required checks passed;
- publish only after immutable source, checksum, provenance, and
  repository-specific CI evidence are available.

## Releases and review artifacts

[`zed-lock v0.1.0`](https://github.com/zed-pkg/zed-lock/releases/tag/v0.1.0)
is already published from the original extraction commit
`0fc100afc3cd60b5ce091b4207f910bf08f2cfb7`. It remains immutable.

The hardened package is a distinct **v0.1.1** release from merge commit
`a0dc78d385bc3ab553d3027b427f5f1428239c9c`. Its release is considered
published only after GitHub reports the tag/release and both crate/checksum
assets at that exact commit.

CI artifacts are review evidence, not automatic public releases. CLI
`release/**` branches retain candidate archives; only `v*` tags invoke the
public GitHub Release job.