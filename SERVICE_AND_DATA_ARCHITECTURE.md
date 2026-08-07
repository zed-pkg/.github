# Service & Data Architecture Plan

Status: **adopted** — 2026-08-07
Applies to: `fiducia-cloud`, `sonus-auris`, `zed-pkg` (this plan is mirrored in each org's `.github` repo and in the corresponding Linear projects).

## The plan

1. **The Rust API server handles all database writes** (writes to Postgres). It is the single owner of business logic, validation, and authorization for mutations.
2. **The web server may read from the database but must never write.** Read-only access is enforced in the database itself (a `SELECT`-only DB user/grant), not by convention.
3. **The web server talks to the API server over HTTP** with keep-alive (connection reuse). No stateful TCP connections for now — a dedicated TCP connection pool (or gRPC) is a possible later experiment, not part of this plan.
4. **Shared DB/schema code comes from [`github.com/oresoftware/k8s-libs-and-shared-defs`](https://github.com/oresoftware/k8s-libs-and-shared-defs).** The schema **must be carefully namespaced/segmented by GitHub org/project** — no cross-org tables or shared unqualified names.
5. **Database migrations use [`github.com/declarative-migrations`](https://github.com/declarative-migrations)** for both Postgres and CockroachDB. The API server owns the schema and the migration set.
6. **`k8s-libs-and-shared-defs` will be broken apart (segmented/namespaced) by GitHub org**, so each org depends only on its own slice of the shared definitions.

## Deployment topology

- Specialized fiducia services — e.g. `fiducia-cloud/fiducia-node.rs`, `fiducia-cloud/fiducia-brain.rs` — run on a **separate k8s cluster**.
- All traditional API servers and web servers run on [`github.com/ORESoftware/k8s-cluster`](https://github.com/ORESoftware/k8s-cluster).

## Rationale

- **One service owns a schema.** The moment two deployables issue writes against the same tables, every migration becomes a coordinated release, and the API's invariants (validation, authorization, audit logging, cache invalidation) can be silently bypassed. The Rust API server is the sole write path and the sole owner of migrations.
- **Reads are permitted from the web tier, but hardened at the boundary.** Reads need authorization too (tenant scoping, field redaction) — most data leaks are read leaks. Hence: a separate `SELECT`-only DB user, and the shared lib should export **named query functions** (e.g. `get_published_posts_for_tenant(tenant_id)`) rather than exposing a raw ORM session/query builder.
- **Shared-lib coupling is build-time coupling.** Sharing DB code between API and web trades runtime drift for lockfile-invisible version coupling. Segmenting `k8s-libs-and-shared-defs` by org keeps the blast radius of a schema change inside one org; strict schema namespacing keeps one org's migration from touching another org's tables.
- **HTTP keep-alive first, fancy transports later.** Reusing connections removes most per-request latency; a stateful TCP pool / gRPC adds operational complexity we don't need yet. If we revisit it: explicit connect/read timeouts shorter than the upstream request timeout, retries only on idempotent methods with jittered backoff, and a bulkhead/circuit breaker so a slow API can't exhaust the web tier's workers.
- **Migration discipline.** Migrations run as a discrete deploy step (never on app boot with N replicas racing). The migration user has DDL rights; runtime users (API read-write, web read-only) do not. Destructive changes follow expand → backfill → contract across separate releases.
- **Connection-pool math.** The web tier scales wider than the API tier; web replicas × pool size must be budgeted against `max_connections` (prefer pointing web reads at a replica, and plan for read-after-write staleness).

## Non-goals (for now)

- No stateful TCP connection pool or gRPC between web and API (revisit later).
- No web-tier writes of any kind, including "just this one table" — web-owned state (sessions, view cache) belongs in a separate web-owned store/schema if it's ever needed.
