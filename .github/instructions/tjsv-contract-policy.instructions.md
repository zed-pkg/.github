# TJSV contract policy for zed-pkg repositories

Applies when work changes interface definitions, schema validation, client generation, RPC/API/MCP projections, runtime validators, or package/release provenance.

## Required authority model

- Keep TypeSpec and independently authored JSON Schema Draft 2020-12 as peer authorities.
- Never generate one authored authority from the other to manufacture parity.
- TypeSpec-generated JSON Schema is comparison evidence only.
- Contract IR, receipts, generated clients and operation/API projections are downstream, read-only evidence.

## Admission rules

- Use `ORESoftware/typespec-json-schema-validator` at an immutable reviewed revision.
- Verify exact current inputs and a complete expected declaration inventory.
- Do not treat an old passing receipt, matching hash alone, or a generated witness as current admission.
- Preserve positive and negative/differential evidence. Probe-disable flags cannot be used to make a release pass.
- If a producer PR is merged, external consumers must repin to the producer merge commit and rerun before their certification is accepted.
- Keep public/client/edge and private/server declaration scopes separate and test for leakage explicitly.

## Cross-runtime requirements

- Contract-sensitive generation must require a verified Contract IR/consumer receipt before emitting artifacts.
- Bind `irId`, receipt/run identity, validator revision and relevant source/declaration digests into generation/release provenance.
- Compile/typecheck required language outputs rather than accepting file-layout presence alone.
- For runtime validators, use shared recorded corpora and reject undocumented trimming, default insertion, coercion, nullability changes, Unicode-length drift, numeric-shape drift or closed-object drift.

## Git and CI

- Follow `ORESoftware/my-ai/AGENTS.md`: preserve history, merge rather than rebase, no reset/stash/force-push, and resolve conflicts semantically.
- Do not weaken unrelated native/runtime/Nix/security gates when updating TJSV.
- Exact-head checks must pass before merge. A cancelled or skipped required job is not success.
- External certification should be independent of the producer and should not copy the producer's validator implementation.

Detailed queue: `docs/tjsv-contract-rollout-backlog.md` and `zed-pkg/.github` issues #67–#76.
