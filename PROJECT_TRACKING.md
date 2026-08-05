# zed-pkg project tracking

Last verified: 2026-08-05

This document records only identifiers that were read from their canonical
systems. Do not infer a project number, channel name, or integration state from
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

Until the Projects v2 board is verified or created through an authorized
GraphQL/`gh project` session:

- use the Linear project above as the portfolio roadmap;
- use GitHub issues and pull requests as the repository execution ledger;
- do not fabricate a project URL in issue templates, automation, or status
  reports;
- once created, add the verified project number, node ID, URL, owner, and field
  schema to this file in a reviewed PR.

Recommended Projects v2 fields when the board is created:

| Field | Purpose |
| --- | --- |
| `Status` | Backlog, Ready, In progress, In review, Blocked, Done |
| `Repository` | Owning `zed-pkg/*` repository |
| `Linear` | DEN issue identifier or project link |
| `Package layer` | Interfaces, clients, library, CLI, server, test, infra |
| `Release gate` | Source review, CI, artifact, publish, certification |
| `Target branch` | `main`, `dev`, or another explicitly reviewed branch |
| `Blocked by` | Upstream PR, package, credential, or runner dependency |

## Current CLI merge train

The active dependency sequence is intentionally ordered:

1. [`zed-pkg/zed-lock#2`](https://github.com/zed-pkg/zed-lock/pull/2)
   hardens the standalone extracted locking package, verifies Linux/macOS/
   Windows conformance, and emits a reviewable crate artifact.
2. [`zed-pkg/zed-cli#195`](https://github.com/zed-pkg/zed-cli/pull/195)
   imports the concrete `zed-pkg/zed-lock` Zed package into the CLI package graph
   while retaining the byte-identical internal Cargo path during transition.
3. A follow-up PR must pin Cargo to the exact merged `zed-lock` commit,
   regenerate `Cargo.lock`, run all process-lock and platform suites, and only
   then remove the internal `crates/zed-lock` copy.

Independent feature work:

- [`zed-pkg/zed-cli#131`](https://github.com/zed-pkg/zed-cli/pull/131)
  materializes deterministic, conflict-safe `zed env export mise` product code
  on current `main`. The temporary write workflow has removed itself; only
  ordinary source, docs, flags, and tests remain.
- Global executable profiles were merged in
  [`zed-pkg/zed-cli#162`](https://github.com/zed-pkg/zed-cli/pull/162).

Merge rules:

- never merge a dependent PR before its canonical dependency is green and
  merged;
- never weaken the package graph to make an invented package coordinate pass;
- use a semantic merge or rebase when branches overlap, preserving the best
  compatible behavior and tests rather than choosing one side wholesale;
- publish a package or release only after immutable artifact, checksum,
  provenance, and repository-specific CI evidence are available.

## Review artifacts

CI artifacts are review evidence, not automatic public releases. For example,
`zed-lock` packages the exact `.crate` plus SHA-256 after its complete
three-platform matrix succeeds. Creating a GitHub release, tag, or crates.io
publication remains a separate explicit release decision.
