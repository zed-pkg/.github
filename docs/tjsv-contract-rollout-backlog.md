# TJSV cross-runtime contract rollout backlog

Tracking: Linear `DEN-3828`, `DEN-3959`, `DEN-3600`, `DEN-3982`, `DEN-3908` and the [Linear project document](https://linear.app/denman/document/tjsv-cross-runtime-follow-on-backlog-2026-09-09-909929fde7f5).

Current tested baseline when this queue was created:
`ORESoftware/typespec-json-schema-validator@d60d0d79d83e075077382623ec9e23a401ab601f`.

This document is a planning/index artifact, not a floating instruction to repin blindly. Each consumer must prove a newer immutable TJSV revision with its own exact-head checks before adopting it.

## Contract authority invariants

1. Human-authored TypeSpec and independently human-authored JSON Schema Draft 2020-12 are peer authorities.
2. Neither authority is generated from or ranked below the other.
3. TypeSpec-generated JSON Schema (Schema B) is comparison evidence only.
4. TJSV reports, verification receipts, Contract IR, operation IR and generated language artifacts are downstream evidence, never a third editable authority.
5. Admission is fail-closed and current-input-bound. Missing, stale, tombstoned or mismatched evidence is not success.
6. External certification must pin tested merge commits and rerun after the producer merge.
7. Public/client/edge and private/server scopes remain independently inventoried; server-only declarations must never leak into public bundles.
8. TJSV remains the CLI/options authority for its tool. Do not add a parallel parser around it.

## New executable tasks

| Issue | Task | Primary Linear authority |
| --- | --- | --- |
| [#67](https://github.com/zed-pkg/.github/issues/67) | Publish one reusable TJSV admission workflow/action and migrate initial consumers. | DEN-3828 |
| [#68](https://github.com/zed-pkg/.github/issues/68) | Detect stale TJSV pins and minimum admission-capability drift. | DEN-3982 |
| [#69](https://github.com/zed-pkg/.github/issues/69) | Admit private/server contracts separately and prevent public export leakage. | DEN-3828 |
| [#70](https://github.com/zed-pkg/.github/issues/70) | Require verified Contract IR before client generation and bind output provenance. | DEN-3600 |
| [#71](https://github.com/zed-pkg/.github/issues/71) | Compile/typecheck every supported SDK language against one admitted inventory. | DEN-3551 / DEN-3600 |
| [#72](https://github.com/zed-pkg/.github/issues/72) | Add Linux/macOS/Windows external TJSV consumer certification with merge-commit pins. | DEN-3828 |
| [#73](https://github.com/zed-pkg/.github/issues/73) | Prove Rust/TypeScript/Dart runtime validators against shared TJSV corpora. | DEN-3959 |
| [#74](https://github.com/zed-pkg/.github/issues/74) | Sign TJSV evidence and bind it to package releases. | DEN-3908 |
| [#75](https://github.com/zed-pkg/.github/issues/75) | Couple API/MCP/RPC operation projections to admitted data-contract IR. | DEN-3828 |
| [#76](https://github.com/zed-pkg/.github/issues/76) | Run scheduled fleet TJSV drift scans with exception expiry. | DEN-3982 |

## Suggested execution order

### Phase 1 — make policy reusable

- #67 reusable admission action.
- #68 pin/capability inventory.
- Define a machine-readable capability vocabulary before broad repinning.

### Phase 2 — extend authority coverage

- #69 private/server declarations and leak canaries.
- #70 generator admission and provenance binding.
- Preserve existing public evidence while adding these scopes; do not replace it with one aggregate receipt that hides boundaries.

### Phase 3 — prove runtime/language behavior

- #73 primary runtime validation evidence first, because it can expose transformation drift even when types compile.
- #71 all-language compile/typecheck/export coverage.
- #72 external OS matrix after the producer workflows are stable.

### Phase 4 — couple and release

- #75 operation/API/MCP/RPC projection coupling.
- #74 signed release provenance and install-time verification.
- #76 recurring fleet enforcement only after the policy/capability model is stable enough not to create noisy false positives.

## Evidence already established

Do not redo this work without a concrete regression reason. Recent merged work already demonstrates TJSV-backed evidence in:

- `zed-pkg/zed-interfaces` public peer-authority validation;
- `zed-pkg/zed-clients` Contract IR admission and conditional-witness regression;
- `zed-pkg/zed-lib-core` and `zed-pkg/zed-orm-core` public consumer admission;
- `zed-pkg/zed-pub-lib-core` durable public-core verification receipts;
- `ORESoftware/org-mcp-server-template.rs` plus `zed-pkg/zed-mcp-server.rs` real MCP/Rust conformance;
- `zed-pkg-test/contract-conformance-tests` independent merge-commit-pinned certification.

The next work should expand proof coverage and reuse rather than substitute metadata-only checks for those executable gates.

## Linear issue-capacity note

New Linear issue creation was attempted but rejected because the workspace has reached its free issue-row limit. The ten GitHub issues above are therefore the executable task rows. The Linear project description and project document mirror this queue until additional Linear issue capacity exists. Do not delete or collapse the existing parent Linear issues to make room.
