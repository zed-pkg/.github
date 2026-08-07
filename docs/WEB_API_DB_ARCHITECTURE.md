# Web / API / Database Architecture Plan

**Status:** Adopted 2026-08-07
**Scope:** Org-wide — applies to `fiducia-cloud`, `sonus-auris`, and `zed-pkg` services.

## Decisions

1. **The Rust API server handles all database writes.** It is the sole writer to Postgres. All mutations — along with validation, authorization, audit logging, and cache invalidation — live in the API server.
2. **The web server may read from the database, but never write.** Read-only access is enforced in the database itself, not by convention: the web tier connects with a separate DB user that has `SELECT`-only grants.
3. **The web server calls the API server over HTTP.** Use HTTP keep-alive so TCP connections are reused rather than opened per request. No stateful/persistent TCP connections for now — a dedicated TCP connection pool (or gRPC) may be evaluated later if the HTTP hop proves to be a bottleneck.
4. **Kubernetes libs and shared definitions come from [oresoftware/k8s-libs-and-shared-defs](https://github.com/oresoftware/k8s-libs-and-shared-defs).** Shared schemas and definitions **must be carefully namespaced/segmented by GitHub org and project** — no cross-org collisions in names, labels, or schema keys.
5. **Database migrations use [declarative-migrations](https://github.com/declarative-migrations)** for both Postgres and CockroachDB. The API server's repository owns the schema and the migration files; the web server does not carry migration tooling.

## Cluster placement

- All traditional API servers and web servers run on [oresoftware/k8s-cluster](https://github.com/oresoftware/k8s-cluster).
- Specialized workloads — e.g. `fiducia-cloud/fiducia-node.rs` and `fiducia-cloud/fiducia-brain.rs` — run on a **different** Kubernetes cluster, not on `k8s-cluster`.

## Rationale

The through-line: **the schema is a private implementation detail of exactly one service (the API server), and the API is the contract everything else negotiates with.**

- **One service owns a schema.** The moment two deployables issue arbitrary SQL against the same tables, every migration becomes a coordinated release, and the API's invariants (validation, authorization, audit logging, cache invalidation) can be silently bypassed by the other path.
- **Reads need authorization too.** Tenant scoping, row-level filtering, and field redaction matter as much on reads as on writes — most data leaks are read leaks. Allowing the web tier read access is a deliberate, bounded exception (see guardrails below), not a license to embed business logic in web-tier queries.
- **Security.** The web server sits closer to the public internet. It must never hold write-capable database credentials; if it is compromised, the blast radius is read-only.
- **Connection reuse over per-request connections.** Opening a new TCP connection per web→API request adds avoidable latency; keep-alive gets most of the benefit of a connection pool without the operational complexity of managing stateful connections. Revisit pooling/gRPC only with evidence.

## Guardrails

- **Split DB credentials.** The migration user has DDL rights; the API runtime user has DML but no DDL; the web-tier user is `SELECT`-only. Enforced in Postgres/CockroachDB grants, not in application code.
- **Web-tier reads go through named query functions** (a shared repository layer exporting e.g. `get_published_items_for_tenant(tenant_id)`), never a raw ORM session or query builder handed to the web tier. The named functions are the read contract.
- **Do not run migrations on app boot.** With N replicas rolling out you get N concurrent migration attempts. Migrations run as a discrete pre-deploy step (CI stage, init container, or job) via declarative-migrations.
- **Expand/contract for destructive schema changes.** Add new column → deploy code writing both → backfill → deploy code reading new → drop old column in a later release. Each step independently revertible.
- **Web→API HTTP hygiene:** explicit connect/read timeouts shorter than the upstream request timeout; retries only on idempotent methods with jittered backoff; traffic stays on the private cluster network, never back out through the public load balancer.
- **Read-after-write staleness:** if web-tier reads are ever pointed at a replica, plan for sticky reads or a short primary-read window after writes.
- **Shared-defs namespacing:** every schema/definition consumed from `k8s-libs-and-shared-defs` must be segmented by GitHub org and project so that org-level changes cannot collide or bleed across orgs.

## Future work (explicitly deferred)

- Stateful TCP connection pool (or gRPC) between web and API servers — only if keep-alive HTTP proves insufficient.
- Caching layer in front of API reads as an alternative to widening direct web-tier DB access.
