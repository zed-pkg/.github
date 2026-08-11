# Nightly `*-clients` fleet hardening

The organization-wide controller lives in `zed-pkg/.github` and runs at **3:00 AM
America/Chicago**. GitHub Actions cron is UTC-only, so the workflow registers both
08:00 UTC and 09:00 UTC and admits only the trigger whose Chicago local hour is
03. This keeps the schedule correct through CST/CDT transitions without manual
edits.

## Scope and fail-closed rules

Discovery enumerates every accessible, active repository whose name ends exactly
in `-clients`. For each client repository it:

1. reads the root `.zpkg.toml` to determine the canonical Zed package coordinate;
2. requires the paired `${production-org}-test` organization to be accessible;
3. searches `.zpkg.toml` files for every observable Zed consumer;
4. requires at least one real consumer in the paired test organization; and
5. emits deterministic four-repository batches so one failure does not hide the
   rest of the fleet and polyglot toolchains are not reinstalled per repository.

A missing paired organization, inaccessible repository, missing test consumer,
or discovered repository without a matching Zed manifest is a hard failure. The
workflow still continues with other client repositories and publishes a complete
failure ledger.

## Canonical contract

Every run checks out current `main` tips of:

- `zed-pkg/zed-clients` for the canonical schema and hardener;
- `zed-pkg/zed-cli` for validation, install, build, release-preflight, and `r2g`;
- `zed-pkg/zed-api-server.rs` for the current API-side package format.

The controller builds the CLI from source, checks the API server, validates both
canonical package manifests, records all three commit SHAs, and distributes the
result as a checksummed workflow artifact.

The hardener preserves existing implementation files and guarantees a standard
20-target matrix under `clients/` (hard floor: 15): C, C++, Zig, WebAssembly,
Gleam, Erlang, Elixir, Dart, Rust, Java, Go, Python, Ruby, PHP, Kotlin, Swift,
TypeScript/Node.js, TypeScript/Deno, TypeScript/Bun, and TypeScript/edge.

Each repository receives a Draft 2020-12 JSON Schema and repository-specific API
surface covering public and private classes, constructors, methods, functions,
interfaces, types, fields, parameters, return values, async/static behavior, and
errors. Deterministic SHA-256 markers in every runtime make cross-language drift
machine-detectable. Missing targets, stale fingerprints, unresolved types,
duplicate symbols, or incomplete public/private coverage fail closed.

## Consumer verification

The hardened client and all discovered consumer package directories are placed
in one ephemeral Zed workspace. Workspace membership makes consumers resolve the
freshly hardened working tree by local path instead of silently testing an older
published registry version. The controller then runs Zed validation/install/build
plus native compile and test adapters for Cargo, CMake, Zig, Go, Node package
managers, TypeScript, Deno, Dart, Python, Mix, Gleam, Rebar3, Gradle, Swift,
Composer/PHP, and RubyGems.

When the hardener changes a client repository, the job updates the stable branch
`automation/nightly-client-hardening` and creates or refreshes a pull request.
Failures create or update a single deduplicated GitHub issue in that client
repository; a later successful run closes it. Per-repository reports and the
fleet summary are retained as Actions artifacts for 30 days.

## Credential boundary

Cross-organization private checkouts and writes use the repository Actions secret
`ZED_FLEET_GH_TOKEN`. The workflow fails closed when that secret is absent; it
must contain a fine-grained token or GitHub App token with read access to all
source/test organizations and contents, pull-request, and issue write access to
the `*-clients` repositories. Credentials are never written to source, reports,
artifacts, command output, or generated pull requests.

## Manual verification

A dry run can be dispatched with `apply=false` and an optional comma-separated
organization subset. Scheduled and normal manual runs use `apply=true`; the
discovery report, canonical toolchain checks, bounded batch results, per-client
reports, pull requests, and failure issues provide the execution evidence.
