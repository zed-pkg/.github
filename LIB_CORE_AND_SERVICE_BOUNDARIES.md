# Canonical `*-lib-core` Data Plane and Rust Web/API Boundary

**Status:** adopted architecture addendum — 2026-08-09  
**Scope:** every database-backed product organization with separate browser web and product API services  
**Linear authority:** [Canonical `*-lib-core` data plane and Rust web/API ownership standard](https://linear.app/denman/document/canonical-lib-core-data-plane-and-rust-webapi-ownership-standard-66b5df7d09c7)  
**Program:** [DEN-3033](https://linear.app/denman/issue/DEN-3033/cross-org-architecture-conformance-program-repo-layers-shared)

> This addendum supersedes older portfolio text that names a standalone `*-orm-core` repository, a general-purpose `*-lib`, an API-server repository, or `ORESoftware/k8s-libs-and-shared-defs` as the human-authored product database authority. Those locations may remain temporary compatibility packages, generated mirrors, deployment registries, or implementation consumers, but they must not remain a second source of truth.


> **Persistence authority (2026-08-29):** Product SQL and ORM generation are owned in this org’s `*-lib-core` under the dual TypeSpec (P0) + authored JSON Schema (P1) model. Diesel + diesel-async is the primary Rust runtime; SeaORM is secondary. See [`docs/PERSISTENCE_AUTHORITY.md`](docs/PERSISTENCE_AUTHORITY.md). Claims that `ORESoftware/k8s-libs-and-shared-defs` authors this org’s product tables, or that SeaORM is the sole Rust ORM / schema authority, are superseded for product persistence.

## Executive decision

Each database-backed product organization maintains exactly one repository named `<product>-lib-core`.

`*-lib-core` is the product data-plane source of truth for:

- authored persistence TypeSpec (P0 canonical AST) and independently authored persistence JSON Schema (P1 secondary-primary with veto);
- PostgreSQL extensions SQL (RLS, guards, triggers) shared by both dual-source pipelines;
- release `desired.sql` and ORM artifacts published only after dual-source catalog/ORM parity (Diesel primary, SeaORM secondary);
- explicit mappings from public interfaces;
- migration inputs, compatibility declarations, backfills, verification checks, and forward-fix metadata;
- generator configuration and generated ORM/model adapters for supported languages;
- named, typed, authorization-aware database read operations;
- named, typed write and transaction primitives for trusted product-domain writers;
- schema parity, migration replay, permissions, and cross-language conformance evidence;
- the Zed package manifest, lock, immutable package digest, and generated-artifact provenance consumed by deployables.

`*-interfaces` remains authoritative for public HTTP, event, error, pagination, and versioning contracts. A persistence table or generated ORM entity does not automatically become a public API contract.

Both `<product>-api-server.rs` and `<product>-web-server.rs` install the same immutable `*-lib-core` Zed package version and digest. They select different capability profiles and receive different database principals.

## Product read/write boundary

The fleet default is intentionally asymmetric:

| Runtime | Product reads | Product writes | Product DDL | Other writes |
| --- | --- | --- | --- | --- |
| Product API server | Yes | Yes; sole request-serving writer | No | Domain-owned queues, object storage, webhooks, and outbox when delegated |
| Browser web server | Through API by default; bounded direct projections by exception | No; mutations call the API | No | Only isolated browser/session state through a separate store or schema |
| Domain worker | Yes | Only when explicitly delegated by the same domain owner | No | Narrow worker-owned effects |
| Migration job | Verification reads | Declared backfills only | Yes; narrowly scoped and serialized | Migration evidence only |

Do **not** give both web and API servers general product write access merely because both import the same library. Shared code prevents duplication; it does not establish service ownership or least privilege.

Allowing two request-serving tiers to mutate the same domain creates two policy enforcement points for authorization, invariants, tenancy, transaction boundaries, idempotency, audit logging, outbox/event publication, cache invalidation, and rollout compatibility. It also makes browser behavior diverge from CLI, desktop, mobile, and third-party API behavior. The API therefore remains the single request-serving mutation boundary.

A process that renders browser UI and performs product-domain writes is a `combined-bff-api`, not a read-only web server. That shape is permitted only as an explicit modular-monolith or transitional exception with an ADR, internally separated credentials/capabilities, a review date, and a documented split trigger.

## Repository and dependency direction

```text
<product>-interfaces
        |
        v
<product>-lib-core  <---- declarative-migrations / dpm tooling
   |       |       |
   |       |       +---- generated multi-language ORM/model adapters
   |       +------------ named read/write operations and conformance
   +-------------------- desired SQL, persistence JSON Schema, migration inputs
        |                         |
        v                         v
<product>-api-server.rs     <product>-web-server.rs
        |                         |
        +-----------+-------------+
                    v
              <product>-e2e
```

`*-clients` remains the generated or handwritten network SDK layer. The browser web server uses a generated product client for every product mutation and for reads that are not approved direct projections.

`*-lib` may remain a reusable pure-domain library. It is not a second schema, ORM, or migration authority. New database-backed organizations create `*-lib-core` directly rather than adding another standalone `*-orm-core` source.

## Zed package capability profiles

The `*-lib-core` Zed package exposes logical profiles even when language-specific packaging differs:

- `contracts`: persistence JSON Schema, desired-SQL metadata, mappings, and public digests; no database connection code;
- `read`: opaque read context plus named, bounded, policy-aware reads;
- `write`: opaque write/transaction context plus named mutation primitives; available only to API servers and explicitly delegated domain workers;
- `migrator`: desired-state and migration assets for a separate release job; never an automatic API/web startup path;
- language adapters such as `rust-seaorm`, `typescript-drizzle`, `typescript-prisma`, `typescript-typeorm`, `go-ent`, and `dart-drift`.

API and web consumers pin the same exact Zed version and digest. The API may select `contracts`, `read`, and `write`; the web selects `contracts` and, only when direct reads are approved, `read`. The migration job selects `migrator`. Cargo features and Zed export selection are compile-time hygiene, not the security boundary. Database grants, workload identity, secret distribution, and NetworkPolicy are authoritative.

The web target must not compile or name product write contexts or operations. Runtime application code must not invoke the Zed CLI; package installation and lock resolution happen during development, build, or release preparation.

## Source-authority model

The canonical inputs coexist in `*-lib-core` without becoming competing authorities:

1. `contracts/database/desired.sql` defines the reviewed desired relational catalog, including schemas, tables, constraints, indexes, views, grants, and supported engine-specific details.
2. Persistence JSON Schema defines the language-neutral data model and generation metadata.
3. Explicit mapping files describe intentional differences between public interfaces, persistence models, and storage representation.
4. CI parity checks prove that desired SQL, JSON Schema, mappings, and generated adapters describe one compatible model.
5. Generated ORM/model output is derived evidence. It is never hand-edited or treated as an independent schema source.

A change that cannot be represented consistently across these inputs fails conformance and requires an explicit design decision; tooling must not silently choose one interpretation.

## Suggested `*-lib-core` layout

```text
.zpkg.toml
.zpkg.lock
contracts/
  database/
    schema.json
    desired.sql
    compatibility.json
  mappings/
    interfaces-to-persistence/
migrations/
  declarative/
  backfills/
  checks/
  fixtures/
generators/
  rust-seaorm/
  typescript-drizzle/
  typescript-prisma/
  typescript-typeorm/
  go-ent/
  dart-drift/
generated/
  rust/
  typescript/
  go/
  dart/
operations/
  read/
  write/
  admin/
conformance/
  schema-parity/
  migration-replay/
  cross-language/
  permissions/
```

Exact paths may vary, but every package publishes a machine-readable manifest identifying the canonical desired SQL, JSON bundle, migration head, generator versions, generated-output digests, exported capability profiles, and supported database engines.

## Multi-language ORM baseline

Generated adapters are derived from the same reviewed persistence inputs:

- **Rust:** SeaORM is required for Rust services.
- **TypeScript/Node.js:** Drizzle is the primary typed SQL adapter; Prisma and TypeORM adapters are generated and tested where consumers exist.
- **Go:** Ent is the primary generated ORM adapter.
- **Dart:** Drift is the primary generated persistence adapter for Flutter and local/offline stores. A server-side Postgres adapter is added only where a real Dart server workload exists.

Every adapter records the source schema digest and generator version. Hand-edited generated output fails CI. PostgreSQL and CockroachDB support are separate tested claims, including transaction, constraint, index, isolation, retry, and migration behavior.

## API server responsibilities

The Rust API server normally owns `api.<domain>` and:

- exposes versioned machine contracts from `*-interfaces`;
- validates Shared Auth tokens or service identities and applies product authorization;
- owns every request-serving product-domain mutation;
- owns validation, tenant checks, transaction boundaries, idempotency, audit behavior, outbox/event publication, and cache invalidation;
- uses opaque `*-lib-core/read` and `*-lib-core/write` contexts rather than raw ORM handles;
- owns delegated object-store, queue, webhook, and provider mutation capabilities for its domain;
- returns stable typed errors and mutation responses suitable for immediate UI reconciliation;
- receives DML privileges but no broad DDL and never runs production schema migration at replica startup.

`*-lib-core` may provide an atomic transaction routine, but the API composes it with the product policy and external effects required for a complete mutation.

## Browser web server responsibilities

The Rust web server normally owns `app.<domain>` and:

- renders Maud/HTMX HTML and browser fragments;
- owns browser navigation, cookies, exact host/origin checks, CSRF, PKCE handoff, and encrypted browser-session state;
- uses the generated product API client for all product mutations;
- uses API-mediated reads by default;
- may use `*-lib-core/read` only for approved direct projections with a `__web_ro` principal;
- may write only an isolated browser-state schema/store through `__web_state_rw`;
- never receives the API writer, product migrator, Supabase service-role, broad object-store, or queue-mutation credential.

A same-origin `/api/*` route or HTMX form handler in the web server is a presentation adapter. It is not the authoritative product API merely because it accepts `POST` or returns JSON.

## Direct web-read exception

Direct web-to-database reads are allowed only for bounded SSR, list, or detail projections with a measured latency or availability benefit. API reads remain the default for authorization-sensitive, composite, rapidly evolving, or consistency-sensitive views.

Every direct read requires:

- a distinct `<namespace>__web_ro` principal;
- database-enforced `SELECT` allowlists and no DML, DDL, ownership, or role-switch capability;
- pinned `search_path` and verified `default_transaction_read_only=on`;
- bounded statement, lock, connection-acquisition, idle-transaction, and request timeouts;
- bounded result sizes and explicit field redaction;
- a named operation from `*-lib-core/read`, never a raw connection, entity manager, active model, or unrestricted query builder;
- explicit actor and tenant context for every user-scoped operation;
- cross-tenant and write-attempt negative tests;
- RLS where practical as a second database-enforced boundary;
- fail-closed behavior with no fallback to a writer credential.

Immediately after an API mutation, the web server uses the mutation response, an API primary read, or an explicit consistency token rather than assuming a replica or direct read projection is current.

## Database contexts and principals

`*-lib-core` exposes opaque contexts such as:

```text
ProductReadContext
ProductWriteContext
ProductMigrationBundle
ActorContext
TenantContext
RequestContext
```

Raw SeaORM `DatabaseConnection`, unrestricted entity managers, query builders, and generated active models remain private to the persistence boundary.

Each product namespace registers separate principals and secrets:

```text
<namespace>__api_rw
<namespace>__web_ro
<namespace>__web_state_rw
<namespace>__migrator
```

Optional worker identities are narrower than `api_rw` and named by capability. Role switching is denied. A single shared `DATABASE_URL` across web, API, worker, and migration workloads is non-conforming.

## Shared Auth boundary

`shared-auth-server.rs` is the shared identity, session-assurance, MFA/passkey, revocation, and token-exchange plane. It is not the product database writer.

- The browser web server performs the redirect/authorization-code/PKCE and origin-scoped session flow.
- The product API validates an audience-bound user token or an internal service identity carrying explicit actor context.
- Shared Auth owns identity assurance and authentication state.
- Product APIs own organization/project membership, resource authorization, and business policy.
- Neither the web tier nor Shared Auth bypasses the product API for product-domain mutations.
- Product repositories consume `shared-auth-interfaces` and generated `shared-auth-clients`; they do not import Shared Auth's private persistence package or connect directly to auth tables.

The Shared Auth organization may maintain its own `shared-auth-lib-core` for its auth-owned databases under this same standard. That package remains internal to Shared Auth runtimes and migration jobs rather than becoming a cross-product database shortcut.

## Declarative migration lifecycle

`*-lib-core` contains the canonical desired SQL and migration inputs consumed by [`declarative-migrations/declarative-postgres-migrate.rs`](https://github.com/declarative-migrations/declarative-postgres-migrate.rs) (`dpm`). DPM remains ORM-agnostic: every generated adapter converges on the same reviewed catalog state rather than defining a separate migration history.

Production flow:

1. Change persistence JSON Schema, desired SQL, mappings, compatibility metadata, and any backfill/check definitions in `*-lib-core`.
2. Materialize the desired schema in an ephemeral database and regenerate each supported adapter.
3. Run schema/JSON parity, generated-output drift, migration replay, RLS/permission, engine, and cross-language conformance checks.
4. Use DPM to diff the reviewed desired state against a target snapshot/catalog and produce deterministic SQL plus a machine-readable plan.
5. Verify the plan against an ephemeral or shadow database and require an empty post-apply diff.
6. Require explicit review and destructive-operation consent where applicable.
7. Publish the exact `*-lib-core` Zed package and record source, SQL, JSON, generator, migration, and package digests.
8. Execute the reviewed plan from a serialized one-shot migration Job using `<namespace>__migrator` and a Fiducia lease/fencing token.
9. Read back the live catalog and require convergence before promoting API/web consumers.
10. Roll out expand/backfill/contract changes across compatible releases; contract removal occurs only after all consumers cross the compatibility boundary.

Ordinary web, API, and worker replicas have no DDL and do not run `AUTO_MIGRATE`, `db push`, `synchronize`, `EnsureCreated`, or equivalent at startup. A disposable, single-replica local/CI stack may opt in explicitly and default-off, but that setting must not promote into durable Kubernetes manifests.

## Existing `*-orm-core` and legacy sources

An existing standalone `*-orm-core` repository becomes exactly one of:

1. a compatibility package whose canonical source and release pipeline point into `*-lib-core`;
2. a generated mirror carrying an exact source commit/digest and rejecting hand edits; or
3. an archived repository after consumers move to the `*-lib-core` Zed package.

It must not retain independent SQL, migration history, generated entities, or write operations. Legacy copies in `*-lib`, `*-interfaces`, monorepo roots, Kubernetes mirrors, or central shared-definition repositories are frozen after semantic reconciliation.

`ORESoftware/k8s-libs-and-shared-defs` remains the central registry for source pins, namespace/role registration, deployment targets, digests, and optional generated snapshots. It is not the human-authored product schema source or provider Git-integration root for every product.

## Rollout and conformance

Per organization:

1. Inventory SQL, JSON Schema, ORM models, migration histories, direct database access, principals, and boot-migration behavior.
2. Create `<product>-lib-core`, reconcile divergent histories semantically, and publish its Zed manifest/lock.
3. Move desired SQL, persistence JSON Schema, generation, operations, and migration inputs into that one authority; freeze legacy edits.
4. Generate only adapters required by real consumers, while keeping the baseline generator contract available.
5. Pin one exact `*-lib-core` Zed package/digest in API and web repositories with different profiles.
6. Move API persistence to opaque read/write contexts; move web reads to the API or approved read context; route every product mutation through the API.
7. Provision separate principals/secrets and deny role switching.
8. Add DPM plan/verify/apply as a serialized release job and certify it first in the paired `*-test` organization.
9. Add E2E evidence for browser mutation routing, write denial, cross-tenant isolation, read-after-write behavior, migration convergence, and forward-fix/rollback behavior.
10. Convert, freeze, or retire every duplicate ORM/schema/migration authority.

A product is conforming only when exact-revision evidence proves:

- exactly one `*-lib-core` owns product persistence and migration authority;
- API and web pin the same immutable Zed package digest while exposing different capabilities;
- the API can perform approved DML but cannot run product DDL;
- the web can perform only approved reads and the database rejects product writes;
- isolated web-state writes cannot cross into the product schema;
- no raw/unrestricted ORM handle crosses the `*-lib-core` boundary;
- generated adapters match canonical input digests;
- DPM plan/verify/apply converges through a serialized migrator identity;
- Shared Auth and product authorization boundaries are tested independently;
- migration compatibility follows expand → backfill → contract rather than coordinated downtime.
