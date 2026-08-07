# Service & Data Architecture Plan

Status: **adopted** — 2026-08-07  
Applies to: `fiducia-cloud`, `sonus-auris`, and `zed-pkg`. This policy is intentionally mirrored in each organization’s `.github` repository and corresponding Linear project.

## Decision summary

1. **The Rust API server is the sole runtime writer of business data in PostgreSQL.** It owns mutation authorization, validation, invariants, audit behavior, and transaction boundaries. The API may also read its data.
2. **The web server may read the database directly, but it may never write to the API-owned business schema.** This is a constrained read-model exception, enforced by database grants and a restricted shared-library surface rather than by convention.
3. **The web server calls the API server over HTTP with keep-alive.** HTTP connection reuse is allowed; a custom application-level stateful TCP session, streaming protocol, WebSocket channel, gRPC transport, or manually managed long-lived TCP pool is not part of the initial design.
4. **Shared database definitions come from [`github.com/oresoftware/k8s-libs-and-shared-defs`](https://github.com/oresoftware/k8s-libs-and-shared-defs).** Every schema, module, generated artifact, credential, and migration target must be segmented by both GitHub organization and project.
5. **Migrations use the tooling and declarative format from [`github.com/declarative-migrations`](https://github.com/declarative-migrations)** for PostgreSQL and CockroachDB. The owning API service remains the semantic owner of its schema and compatibility window.
6. **Specialized Fiducia coordination services run on a separate Kubernetes cluster.** Traditional API servers and web servers run on [`github.com/oresoftware/k8s-cluster`](https://github.com/oresoftware/k8s-cluster).

## Ownership and privilege matrix

| Concern | Rust API server | Web server | Migration job |
| --- | --- | --- | --- |
| Business reads | Allowed | Allowed only through approved read surfaces | Only when required to verify a migration |
| Business writes | Sole runtime owner | Forbidden | Data backfills only when declared by a migration |
| DDL/schema changes | Defines compatibility requirements; no DDL at app boot | Forbidden | Sole DDL executor |
| Authorization | Owns mutation authorization and API-mediated reads | Must enforce identity, tenant scope, and redaction for direct reads | Not a request-serving identity |
| Database role | Namespaced read/write runtime role | Namespaced `SELECT`-only role | Namespaced DDL role used only by a discrete job |
| Deployment | `oresoftware/k8s-cluster` for traditional APIs | `oresoftware/k8s-cluster` | Same release environment as the owned database |

The migration job executes DDL, but that does not make it a second schema owner. It applies the schema contract owned by the API service and pinned by the API release.

## Organization and project namespace contract

Database objects may never rely on a global, unqualified application namespace.

### Canonical identifiers

Normalize GitHub organization and project slugs to lowercase snake case, then derive the application namespace as:

```text
<org_slug>__<project_slug>
```

Examples:

```text
fiducia_cloud__fiducia_api
sonus_auris__sonus_api
zed_pkg__registry
```

Associated roles should preserve the same prefix:

```text
<namespace>__api_rw
<namespace>__web_ro
<namespace>__migrator
```

PostgreSQL identifiers are length-limited. A centrally recorded slug mapping must be used when the generated identifier would be too long; repositories must not invent independent truncation rules.

### Required isolation rules

- Application tables, views, functions, types, sequences, migration history, and generated ORM metadata must live in the project-owned namespace—not in `public`.
- Runtime `search_path` must be pinned to `pg_catalog` plus the single owned namespace. Do not inherit an ambient or user-writable schema.
- Migrations and shared queries must schema-qualify application objects. CI should reject unqualified DDL and cross-namespace references unless an approved architecture decision record explicitly allows them.
- Cross-organization foreign keys, direct joins, views, and shared write tables are prohibited by default. Cross-project interaction should use an API, event, or explicitly versioned data contract.
- `k8s-libs-and-shared-defs` artifacts and Rust module paths must include both organization and project identity. One organization’s database module must not silently re-export another organization’s ORM entities or credentials.
- Each API deployment pins the exact version or digest of its namespaced shared definitions and migration bundle.
- PostgreSQL and CockroachDB compatibility must be tested explicitly. Similar SQL syntax is not permission to assume identical locking, transaction, index, or DDL behavior.

## Web-tier direct-read boundary

Direct reads are permitted only when all of these conditions hold:

1. The web server uses a distinct database principal whose grants are enforced as read-only in the database.
2. The shared library exposes **named, policy-aware query functions or stable read views**, not a raw ORM session, unrestricted query builder, or public entity manager. For example, prefer `get_published_posts_for_tenant(tenant_id)` over exposing `DatabaseConnection` to request handlers.
3. Every query carries the required tenant/user scope and applies field redaction. Read authorization is not weaker than write authorization.
4. The approved read surface is allowlisted. Grant `USAGE` on the owned schema and `SELECT` only on the required views/tables; do not grant DML, DDL, role switching, broad function execution, or ownership.
5. PostgreSQL web roles set read-only transactions by default in addition to grants. This is defense in depth, not a substitute for least-privilege grants.
6. CI includes negative tests proving that the web identity cannot `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `CREATE`, `ALTER`, or `DROP` within the business schema.

A web-owned concern such as sessions, CSRF state, or a view cache may use a separate web-owned store or schema with a separate owner. It must not become an exception that gives the web tier write access to API-owned tables.

If a read replica is introduced later, the user experience must account for replication lag. Immediately after an API mutation, use the mutation response or an API-mediated primary read until the consistency requirement is satisfied.

## Web-to-API transport contract

The initial transport is ordinary service-to-service HTTP on the private Kubernetes network.

- Use an HTTP client with keep-alive and bounded connection reuse. Keep-alive reuses TCP connections internally; it does **not** create an application-level stateful session.
- Do not introduce a custom persistent TCP protocol, gRPC streaming, WebSockets, or connection-affine request state without a later architecture decision and measured need.
- Configure explicit connect, request, read, and total timeouts. The upstream timeout must be shorter than the web request deadline.
- Retry only operations proven idempotent. Mutation retries require an explicit idempotency contract; never blindly retry a `POST`.
- Bound concurrency and connection counts so a slow API cannot exhaust the web tier’s workers or the cluster’s sockets.
- Propagate request IDs and trace context across the HTTP boundary.
- Kubernetes Services and NetworkPolicies should keep the API private and permit only required callers and ports.

A future TCP-pool, HTTP/2, or gRPC experiment must compare latency, throughput, failure isolation, operational complexity, and observability against the HTTP keep-alive baseline before adoption.

## Migration ownership and release discipline

- `declarative-migrations` supplies the migration engine/format. Every migration bundle is namespaced by organization and project, checksummed, reviewable, and pinned by the owning API release.
- Migrations run as a discrete pre-deploy Kubernetes Job or equivalent release stage—not during ordinary application boot. Multiple API replicas must never race to apply DDL.
- Only the namespaced migrator role receives DDL privileges. The API runtime role receives only required DML privileges; the web role remains read-only.
- A migration failure blocks the application rollout. Migration evidence should record the bundle digest, target database, starting version, ending version, execution result, and duration.
- Destructive changes follow **expand → migrate/backfill → contract** across independently deployable releases. Do not combine a breaking column/table removal with the first code release that stops using it.
- ORM/code-first tools may help author a migration, but generated SQL must be reviewed and committed. Production must not use auto-sync, `db push`, `synchronize: true`, `EnsureCreated`, or an equivalent schema-mutating startup mode.
- PostgreSQL and CockroachDB lanes must run their own migration validation and rollback/forward-repair tests. A migration marked compatible must have evidence for both engines.
- Prefer forward repair over unsafe automatic down-migrations. Any irreversible step must be declared before rollout and paired with backup/restore evidence appropriate to the data risk.

## Deployment topology

### Traditional application tier

All conventional Rust API servers and web servers for these organizations deploy through [`oresoftware/k8s-cluster`](https://github.com/oresoftware/k8s-cluster). Their manifests must identify:

- organization and project namespace;
- API, web-read-only, and migrator secret references;
- migration bundle/version;
- database engine and owned schema;
- pool and connection budgets;
- NetworkPolicy relationships between web, API, migration job, and database.

### Specialized Fiducia tier

Distributed coordination and consensus-oriented services such as `fiducia-cloud/fiducia-node.rs` and `fiducia-cloud/fiducia-brain.rs` run on a separate Kubernetes cluster. This separation is intentional and must not be erased by placing them in the traditional application cluster for convenience.

The specialized cluster and the traditional application cluster must not share broad database credentials. Cross-cluster interaction should use an authenticated API, event stream, or other explicit contract rather than two clusters mutating the same application schema.

## Required delivery checks

A project is conformant only when its implementation demonstrates all of the following:

- the API identity can perform required reads/writes but cannot perform undeclared DDL;
- the web identity can execute approved reads and is denied every tested write/DDL operation;
- the migrator identity can apply only the project’s namespaced migration set;
- schema, role, secret, shared-definition, and migration identifiers include organization and project identity;
- SQL linting or review prevents accidental use of `public`, unqualified application objects, and unapproved cross-project references;
- HTTP keep-alive, timeout, retry, concurrency, and connection-pool limits are configured and observable;
- migrations execute once as a release step, with expand/contract compatibility and retained evidence;
- PostgreSQL and CockroachDB compatibility claims are backed by engine-specific tests;
- deployment manifests route traditional web/API services to `oresoftware/k8s-cluster` and specialized Fiducia services to their separate cluster.

## Exceptions and future work

Any exception requires an architecture decision record in the organization’s `.github` repository, a linked Linear record, an owner, explicit security/consistency consequences, and a review or expiry date.

Future work may evaluate a dedicated TCP pool, HTTP/2, gRPC, read replicas, or additional shared read models. None of those experiments may weaken the single-writer rule, namespace isolation, migration ownership, or database-enforced web read-only boundary.