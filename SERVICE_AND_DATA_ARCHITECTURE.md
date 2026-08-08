# Service & Data Architecture Plan

Status: **adopted** — 2026-08-07 (revised same day: folded the `docs/WEB_API_DB_ARCHITECTURE.md` draft PRs into this canonical doc, added the database topology section, linked the landed implementation)
Tracking: **DEN-2785** (shared-defs org segmentation — implemented), **DEN-2189 / DEN-2191 / DEN-2193** (auth data planes), **DEN-2786** (dd→ores naming, deferred)
Applies to: `fiducia-cloud`, `sonus-auris`, `zed-pkg` (this plan is mirrored in each org's `.github` repo and in the corresponding Linear projects).

## The plan

1. **The Rust API server handles all database writes** (writes to Postgres). It is the sole writer and the single owner of business logic, validation, authorization, audit logging, and cache invalidation for mutations.
2. **The web server may read from the database but must never write.** Read-only access is enforced in the database itself — the web tier connects with a separate `SELECT`-only DB user/grant — not by convention.
3. **The web server talks to the API server over HTTP** with keep-alive — ordinary bounded HTTP/1.1 or HTTP/2 connection reuse, which does use pooled persistent TCP connections. What is excluded is a *custom long-lived application protocol or session* (bespoke framing, sticky session state, streaming RPC); gRPC or a bespoke transport is a possible later experiment, gated on measured evidence. See §External review hardening item 7.
4. **Shared DB/schema code comes from [`github.com/oresoftware/k8s-libs-and-shared-defs`](https://github.com/oresoftware/k8s-libs-and-shared-defs).** The schema **must be carefully namespaced/segmented by GitHub org/project** — no cross-org tables, name collisions, or shared unqualified names.
5. **Database migrations use [`github.com/declarative-migrations`](https://github.com/declarative-migrations)** (dpm) for both Postgres and CockroachDB. The API server's repository owns the schema and the migration set; the web server carries no migration tooling.
6. **`k8s-libs-and-shared-defs` is broken apart (segmented/namespaced) by GitHub org**, so each org depends only on its own slice of the shared definitions. *Implemented and merged via [k8s-libs-and-shared-defs#22](https://github.com/ORESoftware/k8s-libs-and-shared-defs/pull/22) (DEN-2785): per-org sources under [`pg-defs/schema/orgs/<org>/`](https://github.com/ORESoftware/k8s-libs-and-shared-defs/tree/main/pg-defs/schema/orgs) (`*.sql` segments + `schema.json` JSON model + README), the canonical `schema/schema.sql` assembled from them, and a JSON↔SQL parity gate (`node pg-defs/src/parity.mjs --check`) in CI.*

## Database topology

- **Most orgs share one RDS Postgres instance** (`shared-platform`): one database, org separation via Postgres schemas (`fiducia.*`, `t2v.*`, `daedalus.*`, …) or enforced table prefixes. The platform CDC publication (`cdc_pub`, one logical-replication slot per cluster via wal-gateway-rs) pins its member tables to this instance.
- **Authentication gets dedicated instances.** The `shared-auth` org is the authority for general authentication (it is the shared auth server). Alongside the shared instance there are **two more RDS instances: one for customer auth and one for admin auth** (DEN-2189/DEN-2191). The `shared_auth` schema DDL deploys to both until realm/audience isolation lands in the schema itself (DEN-2193). Operator-facing session stores in product schemas (e.g. `daedalus.web_sessions`) are candidates to migrate to the admin-auth instance.
- **Supabase-resident contracts stay in Supabase** (RLS-based schemas such as the `communications` policies and `cliptown`, which FK into Supabase `auth.users`).
- Placement is recorded machine-readably in [`pg-defs/schema/orgs/index.json`](https://github.com/ORESoftware/k8s-libs-and-shared-defs/blob/main/pg-defs/schema/orgs/index.json) (`rdsInstances` + per-org `rdsInstance`), so tooling and reviews share one source of truth.

## Deployment topology

- Specialized fiducia services — e.g. `fiducia-cloud/fiducia-node.rs`, `fiducia-cloud/fiducia-brain.rs` — run on a **separate k8s cluster**, not on `k8s-cluster`.
- All traditional API servers and web servers run on [`github.com/ORESoftware/k8s-cluster`](https://github.com/ORESoftware/k8s-cluster).

## Rationale

The through-line: **the schema is a private implementation detail of exactly one service (the API server), and the API is the contract everything else negotiates with.**

- **One service owns a schema.** The moment two deployables issue writes against the same tables, every migration becomes a coordinated release, and the API's invariants (validation, authorization, audit logging, cache invalidation) can be silently bypassed. The Rust API server is the sole write path and the sole owner of migrations.
- **Reads are permitted from the web tier, but hardened at the boundary.** Reads need authorization too (tenant scoping, row-level filtering, field redaction) — most data leaks are read leaks. The web tier's read access is a deliberate, bounded exception governed by the guardrails below, not a license to embed business logic in web-tier queries.
- **Security.** The web server sits closer to the public internet. It must never hold write-capable database credentials; if it is compromised, the blast radius is read-only.
- **Shared-lib coupling is build-time coupling.** Sharing DB code between API and web trades runtime drift for lockfile-invisible version coupling. Segmenting `k8s-libs-and-shared-defs` by org keeps the blast radius of a schema change inside one org; strict schema namespacing keeps one org's migration from touching another org's tables.
- **HTTP keep-alive first, fancy transports later.** Reusing connections removes most per-request latency; a bespoke long-lived protocol or gRPC adds operational complexity we don't need yet, and is revisited only with evidence that the HTTP hop is the bottleneck.
- **Migration discipline.** Migrations run as a discrete deploy step (never on app boot with N replicas racing). Destructive changes follow expand → backfill → contract across separate releases.
- **Connection-pool math.** The web tier scales wider than the API tier; web replicas × pool size must be budgeted against `max_connections` (prefer pointing web reads at a replica, and plan for read-after-write staleness).

## Guardrails

- **Split DB credentials three ways.** The dpm migration user has DDL rights; the API runtime user has DML but no DDL; the web-tier user is `SELECT`-only. Enforced in Postgres/CockroachDB grants, not in application code.
- **Web-tier reads go through named query functions** (a shared repository layer exporting e.g. `get_published_items_for_tenant(tenant_id)`), never a raw ORM session or query builder handed to the web tier. The named functions are the read contract.
- **Do not run migrations on app boot.** With N replicas rolling out you get N concurrent migration attempts. Migrations run as a discrete pre-deploy step (CI stage, init container, or job) via declarative-migrations, with human review of the generated SQL.
- **Expand/contract for destructive schema changes.** Add new column → deploy code writing both → backfill → deploy code reading new → drop old column in a later release. Each step independently revertible.
- **Web→API HTTP hygiene:** explicit connect/read timeouts shorter than the upstream request timeout; retries only on idempotent methods with jittered backoff; traffic stays on the private cluster network, never back out through the public load balancer.
- **Read-after-write staleness:** if web-tier reads are ever pointed at a replica, plan for sticky reads or a short primary-read window after writes.
- **Shared-defs namespacing:** every schema/definition consumed from `k8s-libs-and-shared-defs` must live in that repo's per-org segmentation (`pg-defs/schema/orgs/<org>/`) so org-level changes cannot collide or bleed across orgs; the CI parity and assembly gates enforce it.

## Non-goals / future work (explicitly deferred)

- No custom long-lived application protocol/session or gRPC between web and API (revisit only if bounded HTTP connection reuse proves insufficient; ordinary keep-alive pooling is already in scope).
- No web-tier writes of any kind, including "just this one table" — web-owned state (sessions, view cache) belongs in a separate web-owned store/schema if it's ever needed.
- Caching layer in front of API reads as an alternative to widening direct web-tier DB access.
- Renaming legacy `dd`-prefixed generated packages/paths (`dd-pg-defs-sea-orm`, `dd.pgdefs.*`, …) — one coordinated wave under DEN-2786 phase 4, deliberately not mixed into the segmentation work.

## Shared ORM layer — `*-orm-core` (SeaORM)

Adopted 2026-08-07, later the same day as the baseline plan. This section records the crate-placement decision; it refines (does not reverse) the shared-boundary work tracked in DEN-2787 / DEN-2788 / DEN-2789.

Because both the web server and the API server read from the database, ORM code is shared through one dedicated per-organization SeaORM crate repository, rather than duplicated per service or embedded in a general-purpose `*-lib` repo:

- **Repos:** [`fiducia-cloud/fiducia-orm-core`](https://github.com/fiducia-cloud/fiducia-orm-core), [`sonus-auris/sonus-auris-orm-core`](https://github.com/sonus-auris/sonus-auris-orm-core), [`zed-pkg/zed-orm-core`](https://github.com/zed-pkg/zed-orm-core) (scaffold PR #1 in each).
- **The Rust ORM is always SeaORM** — already the fleet standard per `pg-defs/rust-server-consumers.json` (`ordinaryPersistence: "SeaORM generated entities and repositories"`; no plain sqlx/tokio-postgres).
- **Entities come from the generated SeaORM adapter in `k8s-libs-and-shared-defs`** (`pg-defs/generated/rust/sea-orm`, currently packaged as `dd-pg-defs-sea-orm`; the `dd` → owner-root rename is deliberately deferred to DEN-2786 phase 4). Each `*-orm-core` crate consumes only its own org's slice (`pg-defs/schema/orgs/<org>/`) and never defines an independent schema. Shared defs are imported as zed packages (`.zpkg.toml` dependency on `oresoftware/k8s-libs-and-shared-defs`), rev-pinned.
- **Role-aware connect:** API servers use the ReadWrite connector (full entity surface, `read-write` cargo feature); web servers use the ReadOnly connector (`default_transaction_read_only=on` as defense in depth) and get only named, policy-aware query functions — no raw `DatabaseConnection`, query builder, or entity-manager export to web request handlers — on top of the web tier's `SELECT`-only database role.
- **No migrations in the crate.** The owning API server keeps sole migration authority via declarative-migrations (`dpm`); `*-orm-core` is entity/query code only.
- **Versioning:** each `*-orm-core` release pins the exact shared-defs revision it was generated against; major bumps are schema events and participate in the expand/contract compatibility window.

**Reconciliation with in-flight PRs (DEN-2787/2788/2789):** the role-aware connector, org schema namespacing, and named-query-function patterns from the `*-lib` orm-crate PRs are the adopted content — they relocate to (or are re-exported from) the org's `*-orm-core` repo. The api-server/web-server consumer wiring in those PR sets stays as designed, with the import retargeted to `<org>/<org>-orm-core` via zed-pkg.

## External review hardening (DEN-2882)

ChatGPT reviewed this plan through the ORESoftware ai-agent-bridge and approved the direction while
conditioning merge on the following. These are **normative requirements**, not aspirations; each one names the
control that is authoritative so no future reader mistakes a convenience for a boundary.

1. **A Cargo feature is not a security boundary — the database principal is.** Cargo feature resolution is
   *additive* across a dependency graph: any crate in a web server's graph that enables `read-write` turns the
   write surface on everywhere, silently. The `read-only` default in `*-orm-core` is therefore an
   ergonomics-and-intent mechanism only. The authoritative controls are (a) the web tier's `SELECT`-only database
   role and (b) a sealed public API — raw `DatabaseConnection`, entity mutation APIs, and write helpers are
   crate-private and unreachable from a default build. CI must carry a **negative compile check** proving a
   default-feature consumer cannot name a write symbol, and must assert the web target's resolved feature set.
2. **Direct web→DB reads require an authorization contract, not merely named query functions.** Every named read
   function must take an explicit tenant/actor authorization context — an opaque capability, never a bare
   `tenant_id` string a caller can forge or omit. CI must prove that a cross-tenant identifier cannot bypass
   scoping. Where practical, Postgres RLS plus per-role grants provide the second, database-enforced boundary.
   Reads leak data at least as often as writes do; "the API validates it" is not available to a direct-read path.
3. **`default_transaction_read_only=on` is defense in depth, not the primary control.** Also pin the web role's
   grants and `search_path`, and set bounded `statement_timeout`, `lock_timeout`, and
   `idle_in_transaction_session_timeout` so a read-only web tier cannot become a resource-exhaustion path.
4. **Migration ownership is repository/domain ownership, not runtime ownership.** The API *repository* owns the
   migration set; production migrations run as a separately fenced, serialized release job (with an advisory
   lock), never opportunistically at API replica startup — N replicas rolling out means N concurrent attempts.
   Each destructive change records its expand → mixed-version → contract compatibility gates explicitly.
5. **A shared SeaORM codebase does not make PostgreSQL and CockroachDB behave identically.** Dual-engine support
   requires a dialect/conformance lane covering generated entities, transaction and isolation semantics, index
   and constraint behavior, migration application, and **retryable serialization errors** (CockroachDB surfaces
   these routinely where Postgres does not). Dual-engine support is a tested claim, never an inferred one.
6. **Pin generated-code provenance mechanically.** Each `*-orm-core` release records the shared-defs commit *and*
   a digest of the schema input it was generated from; CI fails when generated entities drift from that exact
   input. A Zed/Cargo revision pin proves which source was selected, not that the generated output is current —
   those are different claims and only the digest checks the second.
7. **Transport wording, corrected.** HTTP keep-alive *does* use pooled, persistent TCP connections; the earlier
   "no stateful TCP connections" phrasing was self-contradictory. What is actually excluded is a **custom
   long-lived application protocol or session** between web and API (bespoke framing, sticky server-side session
   state, streaming RPC). Ordinary bounded HTTP/1.1 or HTTP/2 connection reuse is expected and encouraged.
   Revisiting gRPC or a bespoke transport requires measured evidence that connection reuse is the bottleneck.
8. **Dedicated `*-orm-core` repos are the confirmed placement.** The review endorsed dedicated repos over
   embedding ORM code in a general-purpose `*-lib`, given the generated-schema cadence and the database-specific
   dependency surface. `*-lib` stays domain/pure, and **must not re-export write-capable ORM APIs** as a
   compatibility shortcut — a re-export re-creates precisely the boundary this plan removes.

Full review: DEN-2882 and the review comment on the canonical-doc PRs (fiducia-cloud/.github#31,
sonus-auris/.github#23, zed-pkg/.github#34).
