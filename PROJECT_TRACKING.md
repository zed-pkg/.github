# zed-pkg project tracking

Last verified: 2026-08-20 (GitHub Projects v2 section: 2026-08-08)

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

### Public registry reliability rollout

Zed supplements ecosystem-native package managers; it does not replace them.
The source-of-truth rollout contract is [Public registry
reliability](docs/PUBLIC_REGISTRY_RELIABILITY.md). It assigns `zpkg.net` to the
human site, `api.zpkg.net` to the API, `registry.zpkg.net` to immutable
artifacts, `app.zpkg.net` to authenticated browser sessions, and
`user.zpkg.net` to an optional `308` alias.

Linear mirrors the live incident and promotion gates in [Public registry
reliability, R2 mirroring, and incident recovery —
2026-08-20](https://linear.app/denman/document/public-registry-reliability-r2-mirroring-and-incident-recovery-2026-08-5f461fd0bb83).

The 2026-08-20 live observation is a failure baseline: the two configured
machine endpoints returned Cloudflare Tunnel error `1033`, the two requested
browser names had no DNS, and the latest visible AWS/Hetzner deployment run
failed before apply because protected deployment inputs were absent. Linear
must remain in progress until its update links the exact reviewed heads and
records separate owners for DNS/control-plane access, both cluster deployment
identities, production SOPS recovery recipients, metadata-database authority,
R2/mirror verification, and test-organization certification.

## GitHub Projects v2

The organization board is verified as of 2026-08-08, via an authorized
`project`-scoped GraphQL session (`organization.projectsV2`). Verification is
tracked in [`zed-pkg/.github#13`](https://github.com/zed-pkg/.github/issues/13)
and Linear `DEN-2875`.

- Title: `zed-pkg-project`
- Owner: organization `zed-pkg`
- Project number: `1`
- Node ID: `PVT_kwDOEmIPx84BfYhg`
- URL: <https://github.com/orgs/zed-pkg/projects/1>
- Visibility/state: private, open

Why the 2026-08-05 probe saw `404`: it queried the legacy (classic)
organization-projects REST endpoint, and classic projects do not exist for this
organization. Projects v2 is reachable only through GraphQL (`projectsV2`) or
`gh project`; do not re-probe the legacy endpoint as evidence of absence.

Field schema (verified 2026-08-08, after configuration per `#13`):

| Field | Type / options |
| --- | --- |
| `Status` | single-select: Backlog, Ready, In progress, In review, Blocked, Done |
| `Linear` | text — DEN issue identifier(s) or Linear project link |
| `Package layer` | single-select: Interfaces, Clients, Library, CLI, Server, Test, Infra |
| `Release gate` | single-select: Source review, CI, Artifact, Publish, Certification |
| `Target branch` | text — `main`, or another explicitly reviewed branch |
| `Blocked by` | text — upstream PR, package, credential, or runner dependency |
| built-ins | Title, Assignees, Labels, Linked pull requests, Milestone, Repository, Reviewers, Parent issue, Sub-issues progress, Created/Updated/Closed |

Items seeded 2026-08-08 (statuses at seeding time):

- [`zed-pkg/zed-interfaces#45`](https://github.com/zed-pkg/zed-interfaces/issues/45)
  — registry protocol v1 RFC anchor; Linear `DEN-2862`/`DEN-2854`; Backlog.
- [`zed-pkg/zed-cli#131`](https://github.com/zed-pkg/zed-cli/pull/131)
  — deterministic mise export; Linear `DEN-1462`; In review.
- [`zed-pkg/zed-cli#203`](https://github.com/zed-pkg/zed-cli/pull/203)
  — clean-room certification; merged; Done.
- [`zed-pkg/zed-cli#204`](https://github.com/zed-pkg/zed-cli/pull/204)
  — hardened lock pin; **closed without merge as of 2026-08-08**, so the
  "Active ordered work" list below is stale on this point and needs review by
  the merge-train owner.
- Draft: `zed-lock v0.1.1 one-shot publisher (release/v0.1.1)`; Linear
  `DEN-2076`/`DEN-2503`; In progress.

Pre-existing board items (drafts for `DEN-1462`, `DEN-1468`, `DEN-1420`, and
issue `#21`) were left untouched; the `DEN-1462` draft overlaps PR `#131` and
should be consolidated by the owning thread.

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
   graph. Its carrier proved no non-lock package changes, removed itself, and
   left ordinary source for the full matrix.
3. [`zed-pkg/zed-cli#203`](https://github.com/zed-pkg/zed-cli/pull/203)
   certifies the real compiled global install, frozen restore, lock graph,
   PATH copy, transitive package, and uninstall lifecycle against a hermetic
   `file://` registry.
4. [`zed-pkg/zed-cli#131`](https://github.com/zed-pkg/zed-cli/pull/131)
   is the active ordinary-source deterministic, conflict-safe
   `zed env export mise` PR. Its single product commit preserves current
   task-runtime and standalone-lock modules, includes the typed write boundary,
   hermetic real-CLI tests, and case-insensitive reserved-path regressions.
5. The release-candidate branch `release/v0.1.0-rc.3` rebuilds all seven CLI
   target archives and checksums using the corrected Intel macOS runner. It is
   a retained review-artifact lane, not a public `v*` release.

Superseded work:

- [`zed-pkg/zed-cli#195`](https://github.com/zed-pkg/zed-cli/pull/195) is closed
  because it assumed the now-removed internal lock crate.
- [`zed-pkg/zed-cli#200`](https://github.com/zed-pkg/zed-cli/pull/200) is closed
  because its helper carrier was replaced by the ordinary single-commit source
  now reviewed in #131.
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
