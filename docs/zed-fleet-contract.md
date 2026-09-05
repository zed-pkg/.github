# Zed repository-family contract

This document defines the repository, package, SDK, CLI, and monorepo contract used by product organizations that expose reusable clients.

The contract is evaluated against real GitHub repository contents by `tools/zed_fleet_audit.py`. Repository names help discovery, but package dependencies are always checked against the package identity declared by each dependency's own `.zpkg.toml`.

## Repository family

A product family that benefits from a public or internal SDK should normally provide:

- `<prefix>-clients`
- `<prefix>-interfaces`
- exactly one shared-library repository: `<prefix>-lib-core`, `<prefix>-lib`, `<prefix>-libs`, or an explicitly documented equivalent
- `<prefix>-cli` or `<prefix>-cli.rs`
- `<prefix>-monorepo`

Do not create two repositories for the same role merely to satisfy alternate naming conventions. Existing canonical repositories should be retained and package coordinates should be read from their manifests.
When a historical `<prefix>-lib` coexists temporarily with its canonical
`<prefix>-lib-core` successor, the auditor selects `-lib-core`; the predecessor
should remain read-only until the reviewed migration and archival process finishes.

Test, fixture, archived, and intentionally application-only organizations may be excluded from the production fleet list.

## Package identities

The canonical coordinate is:

```text
<package.org>/<package.name>
```

from the dependency repository's `.zpkg.toml`:

```toml
[package]
org = "example"
name = "example-interfaces"
```

The GitHub organization and repository name are not a safe substitute. For example, a repository hosted at `fiducia-cloud/fiducia-clients` currently publishes the package identity `fiducia/fiducia-clients`.

Every package manifest should include, as applicable:

- `[package]` with `org`, `name`, `version`, description, and license policy
- `[package.repository]`
- `[install]` with an isolated destination such as `.vendor/.zed`
- `[dependencies]` using real package coordinates
- one or more `[targets.*]` sections rooted at real package directories
- `[publish]` exclusions that keep materialized dependencies, secrets, and build output out of artifacts
- `[scripts]` for reproducible validation

A lock file must be produced by the real resolver. Never fabricate dependency SHAs or hand-author resolver output merely to make a repository look complete.

## Clients package

`<prefix>-clients` must be a Zed package and depend on both:

1. the canonical interfaces package; and
2. the canonical shared-library package.

The repository umbrella target may publish the complete source tree. Each supported ecosystem should also have a first-class target rooted at its implementation directory.

### Required language surfaces

The `clients/` directory should contain real, buildable SDKs for:

- C
- C++
- Zig
- Gleam
- Erlang
- Elixir
- Dart
- Rust
- Java
- Go
- Python 3
- Ruby
- PHP
- TypeScript

Kotlin and Swift are required when the product has mobile, Android, iOS, Flutter, or equivalent client surfaces.

C and C++ use the CMake ecosystem in current Zed language metadata. Zig uses the Zig ecosystem. They should be declared as `[targets.c]`, `[targets.cpp]`, and `[targets.zig]`, not hidden only inside a repository snapshot.

Generated SDK repositories should add ecosystems through the canonical schema/template/generator pipeline. Do not hand-maintain generated output that will be overwritten on the next generation run.

### TypeScript runtimes

The TypeScript package must make these runtime entry points explicit:

- Node.js
- Deno
- Bun
- edge runtimes such as workers or standards-based fetch environments

They may share one artifact, but the source tree, package exports, tests, and documentation must make runtime boundaries visible. Runtime-specific code should not leak Node-only APIs into Deno, Bun, or edge entry points.

## CLI package

The family CLI must be a Zed package and depend on the real package coordinates for:

- clients
- interfaces
- shared library

The CLI may additionally have a native-language package manifest such as Cargo, npm, Go modules, or SwiftPM. Zed dependencies do not replace native build dependencies; they define the repository-family composition and artifact contract.

Do not point the CLI at a library package until the library repository and package actually exist.

## Monorepo package and Git submodules

The family monorepo must be a Zed package with a repository target. It may combine Zed dependencies and pinned Git submodules, but each repository has exactly one owner inside the composition:

- package-layer repositories are normally Zed dependencies;
- runtime applications and independently versioned service repositories may be pinned Git submodules;
- no repository may appear both as a Zed dependency and as a gitlink.

The monorepo must not import the family CLI or infrastructure repository through either mechanism:

- no `*-cli`, `*-cli.rs`, or `*-infra` Zed dependency;
- no `*-cli`, `*-cli.rs`, or `*-infra` Git submodule.

Submodules must be real index gitlinks pinned to exact commits. A `.gitmodules` file without matching `160000` index entries is not a valid integration workspace. Clone, sync, recursive initialization, pin updates, and ownership validation should be documented and exercised in CI.

## Fleet audit

Run locally with a token that can read every selected organization and private repository:

```bash
GITHUB_TOKEN=... python3 tools/zed_fleet_audit.py \
  --orgs org-one,org-two \
  --json zed-fleet-report.json \
  --markdown zed-fleet-report.md
```

The script exits nonzero when contract errors are found. Pass `--allow-errors` only when producing a debt report without enforcing it.

The GitHub Actions workflow behaves in two modes:

- pull-request and push runs validate the auditor itself and publish a report without blocking on pre-existing fleet debt;
- scheduled and manually dispatched runs enforce the selected organizations and fail when the report contains errors.

Set the repository variable `ZED_FLEET_ORGS` to the comma-separated production organization list used by the schedule. Set the `ZED_FLEET_GH_TOKEN` secret to a read-only fine-grained token or GitHub App token that can read those organizations. The default `github.token` generally has access only to the repository running the workflow and is insufficient for a private multi-organization audit.

Each run publishes:

- `zed-fleet-report.json` for automation and issue synchronization;
- `zed-fleet-report.md` for review and the Actions job summary.

## Remediation order

Apply findings in dependency order:

1. establish one interfaces package and one shared-library package;
2. correct the clients manifest and complete its language/runtime matrix;
3. correct the CLI package graph;
4. correct the monorepo package/submodule ownership model;
5. generate resolver locks and publish only after the graph validates against real packages.

A partial, truthful package graph is preferable to a manifest that references nonexistent repositories or fabricated releases.
