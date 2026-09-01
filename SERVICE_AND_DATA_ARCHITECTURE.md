# Rust Web Server vs API Server Architecture Plan

Status: **adopted; audited and revised 2026-08-08**  
Applies to: `fiducia-cloud`, `sonus-auris`, and `zed-pkg`; this document is mirrored in each organization’s `.github` repository and corresponding Linear project.  
Tracking: **DEN-3033** (cross-org conformance), **DEN-3043** (fleet linter), **DEN-2787 / DEN-2788 / DEN-2789** (organization rollouts), **DEN-2785** (shared-definitions segmentation), **DEN-2786** (ownership-aware naming).


> **Persistence authority (2026-08-29):** Product SQL and ORM generation are owned in this org’s `*-lib-core` under the dual TypeSpec (P0) + authored JSON Schema (P1) model. Diesel + diesel-async is the primary Rust runtime; SeaORM is secondary. See [`docs/PERSISTENCE_AUTHORITY.md`](docs/PERSISTENCE_AUTHORITY.md). Claims that `ORESoftware/k8s-libs-and-shared-defs` authors this org’s product tables, or that SeaORM is the sole Rust ORM / schema authority, are superseded for product persistence.

## Executive decision

The boundary is defined by **capabilities and credentials**, not by a repository name, binary name, programming language, or whether the process returns HTML or JSON.

1. A **product API server** owns product-domain mutations, mutation authorization, invariants, audit behavior, cache invalidation, and the domain schema’s compatibility window.
2. A **browser web server** owns presentation, browser-session handling, CSRF/origin enforcement, HTML/HTMX responses, and browser-specific state. It sends product-domain mutations through the API.
3. A web server may write only to a **separate web-owned state store or schema**—for example encrypted browser sessions, PKCE state, CSRF state, or a disposable render cache. This does not grant write access to product-domain tables.
4. API-mediated reads are the fleet default. A direct web-to-database read is an explicit optimization for a bounded, stable read projection, and requires a separate database-enforced read-only identity plus the controls in this plan.
5. A process that renders browser UI and performs product-domain writes is a **combined BFF/API**, not a read-only web server. Combined services are transitional exceptions that must be named accurately, privilege-separated internally, and tracked toward either an intentional modular monolith or a dedicated API split.
6. Traditional web/API services normally run as separate Rust deployables through [`ORESoftware/k8s-cluster`](https://github.com/ORESoftware/k8s-cluster). Specialized Fiducia coordination services such as `fiducia-node.rs` and `fiducia-brain.rs` remain on the separate Fiducia cluster.

The preferred implementation language is Rust, but the ownership rules apply equally to any implementation.

## Role taxonomy

| Runtime role | Browser HTML / fragments | Product-domain reads | Product-domain writes | Web-owned state writes | DDL | Typical public surface |
| --- | --- | --- | --- | --- | --- | --- |
| Browser web / presentation server | Yes | Through API by default; bounded direct projection by exception | No | Yes, only in separately owned state | Only through a separate web-state migration job | `app.<domain>` |
| Product API server | Usually no, except narrow callbacks/download responses | Yes | Yes; sole request-serving writer | No, unless the API explicitly owns that state | No at ordinary runtime | `api.<domain>` |
| Combined BFF/API | Yes | Yes | Only for the explicitly declared domain it owns | Yes, separately identified | No at ordinary runtime | Transitional; must be documented |
| Domain worker / consumer | No | Yes | Yes when delegated by the same domain owner | No | No | Private cluster service |
| Migration job | No | Verification reads only | Backfills declared by the migration | Only for its owned schema | Yes, narrowly scoped and serialized | No public ingress |
| Specialized coordination service | Service-specific | Service-specific | Only its owned coordination domain | No browser state | Separate release process | Separate Fiducia cluster |

A route prefix such as `/api/*` inside a web repository does not make that process the product API. Same-origin JSON or HTMX endpoints in a web server are **presentation adapters/BFF routes** unless they own the product domain under an explicit exception.

## Default repository and deployment shape

When both browser and API responsibilities exist, the default is:

```text
<product>-interfaces
<product>-clients
<product>-orm-core
<product>-api-server.rs
<product>-web-server.rs
<product>-e2e
<product>-infra
```

The API and web servers have separate:

- repositories and release identities;
- Kubernetes Deployments, Services, ServiceAccounts, and NetworkPolicies;
- secrets and database principals;
- health/readiness semantics and autoscaling budgets;
- public origins—normally `api.<domain>` and `app.<domain>`;
- telemetry service names and dashboards.

`www.<domain>` remains marketing/static unless an architecture decision explicitly assigns another responsibility.

A combined single Rust binary is permitted only by an ADR that records why separate deployables are not currently justified, the exact domain it owns, its distinct database pools/credentials, the future split trigger, and an expiry or review date. “The repository is called web/backend” is not an ADR.

## Rust implementation baseline

### Common process structure

Rust servers should keep `main.rs` thin: initialize typed configuration and telemetry, build application state/router, install graceful shutdown, and call `serve`. Business logic does not accumulate in `main.rs`.

A conventional layout is:

```text
src/
  main.rs
  server.rs or app.rs
  config.rs
  authn.rs
  authz.rs
  routes/
  domain/ or application/
  persistence/
  clients/
  telemetry.rs
  health.rs
```

Normative rules:

- Axum is the default HTTP framework for these servers.
- Browser servers normally use Maud plus HTMX when server-rendered HTML is appropriate.
- Diesel + diesel-async is the primary Rust persistence runtime; SeaORM is the secondary generated adapter. Do not add a parallel bare SQLx/tokio-postgres application layer. See [`docs/PERSISTENCE_AUTHORITY.md`](docs/PERSISTENCE_AUTHORITY.md).
- Raw SeaORM connections, entity managers, and unrestricted query builders stay private to the persistence/ORM boundary.
- Request/response, event, error, route, and authorization contracts come from `*-interfaces` and generated `*-clients`; do not duplicate ad hoc structs between web and API repositories.
- `*-lib` remains domain/pure where practical. Database-generated code lives in the dedicated `*-orm-core` repository and is not re-exported through a general library as a compatibility shortcut.
- A Cargo feature such as `read-write` expresses intent but is **not** a security boundary. Database grants and separate runtime credentials are authoritative; CI must also prove the web target cannot obtain the write surface.
- Configuration is typed and auditable, normally through `flags-2-env`; credentials remain environment/secret-store only and never appear in flags, examples, logs, or generated manifests.

### Product API server

The API server:

- exposes versioned JSON contracts, normally `/v1/*` or `/api/v1/*`;
- owns mutation validation, product authorization, tenant checks, idempotency, audit events, and transactional boundaries;
- is the only request-serving process with product-schema DML rights;
- owns object-store write credentials, provider service-role credentials, webhook verification secrets, and internal-worker credentials when those capabilities belong to the product domain;
- returns typed errors and stable machine-readable error codes;
- publishes human- and machine-readable HTTP route documentation;
- uses generated clients so browser, desktop, mobile, CLI, and other services consume the same contract;
- does not run production DDL during ordinary replica startup.

Narrow HTML responses are acceptable for OAuth callbacks, signed downloads, or compatibility pages, but new signed-in product UI belongs in the web server.

### Browser web server

The web server:

- renders HTML and HTMX fragments and owns browser navigation;
- may expose same-origin form/BFF endpoints, but product mutations call the API using a generated client;
- owns browser cookies, CSRF/origin validation, PKCE handoff state, and encrypted browser-session state;
- never receives API writer credentials, the domain migrator credential, a Supabase/service-role secret, or broad object-store credentials;
- does not mint product credentials or bypass the API’s authorization rules;
- propagates the signed-in actor using an audience-bound user token, token exchange, or an explicit internal service identity plus actor context;
- sends authenticated/private responses with suitable `Cache-Control` and prevents shared-cache leakage;
- treats rendering helpers as pure presentation code—rendering modules do not issue ad hoc SQL.

Browser-facing WebSocket or SSE endpoints are allowed for live UI updates. They must transport bounded notifications or presentation data and do not change the internal web-to-API transport rule below.

## Database ownership

### Product-domain schema

One domain owner controls each product schema. The API repository/domain owns:

- schema compatibility requirements;
- product-domain migrations;
- generated entity provenance;
- product read/write operations;
- authorization-aware read models;
- the expand/backfill/contract sequence for destructive changes.

Runtime roles should be separately provisioned from a centrally registered namespace:

```text
<db_namespace>__api_rw
<db_namespace>__web_ro
<db_namespace>__web_state_rw
<db_namespace>__migrator
```

The exact namespace is recorded in `k8s-libs-and-shared-defs`; repositories must not invent independent truncation or alias rules.

The API runtime role gets only required DML and no broad DDL. The web read role gets schema `USAGE` plus an explicit `SELECT` allowlist. The migrator gets project-scoped DDL only during the release job. Role switching between these principals is denied.

### Web-owned state

A browser server may own a separate schema/store for state that is genuinely presentation-tier state:

- encrypted browser sessions;
- PKCE and one-time login state;
- CSRF nonces;
- browser preference cache or render cache;
- short-lived UI coordination state.

That state must have a distinct owner, credential, migration set, and retention policy. It must not become a shadow product database, duplicate credential authority, or cross-schema shortcut.

Web-owned state:

- must not contain product records merely to avoid an API call;
- must not use foreign keys into the product-domain schema;
- must not share the API writer or product migrator credential;
- may be migrated only by a separate one-shot web-state migration job;
- may not auto-migrate at production process startup.

This corrects the earlier overbroad phrase “the web server carries no migration tooling”: the web server carries no **product-domain** migration authority. Its repository may own migration definitions for its isolated browser-state schema, executed separately from normal replicas.

### Direct web reads

API-mediated reads are preferred because they centralize authorization, consistency, caching, and schema abstraction. A direct database read from the web tier is allowed only when its latency/availability value is documented and every condition below holds:

1. A dedicated read-only DSN is used. It is never the API writer, migrator, or web-state writer URL.
2. The database principal has an explicit `SELECT` allowlist, no DML/DDL/ownership/role-switch privileges, and a pinned `search_path`.
3. Every connection also sets and verifies `default_transaction_read_only=on`.
4. `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, connection counts, and acquisition timeouts are bounded.
5. The canonical `*-orm-core` exposes an opaque read context and named, policy-aware operations—not a raw connection or query builder.
6. Every operation requires explicit actor/tenant authorization context, bounds result size, and redacts fields.
7. Cross-tenant and write attempts are covered by negative tests; RLS is used where practical as a second boundary.
8. Failure to establish the read-only property fails closed or degrades the affected view to an unavailable/offline state. It never falls back to a writer credential.
9. Read-after-write behavior is defined. Immediately after an API mutation, use the mutation response, an API primary read, or an explicit consistency token rather than assuming a replica is current.

Direct reads are a read-model optimization, not permission to move business logic into the presentation tier.

## Shared ORM layer

Each organization uses one dedicated SeaORM repository:

- [`fiducia-cloud/fiducia-orm-core`](https://github.com/fiducia-cloud/fiducia-orm-core)
- [`sonus-auris/sonus-auris-orm-core`](https://github.com/sonus-auris/sonus-auris-orm-core)
- [`zed-pkg/zed-orm-core`](https://github.com/zed-pkg/zed-orm-core)

The ORM package:

- consumes only the organization/project slice from [`ORESoftware/k8s-libs-and-shared-defs`](https://github.com/ORESoftware/k8s-libs-and-shared-defs);
- records the exact shared-definitions commit plus schema-input and generated-output digests;
- fails CI when generated entities drift from the pinned input;
- exposes opaque read contexts and named reads by default;
- exposes the write context/operations only to explicit API/worker consumers;
- contains no production migration runner;
- tests PostgreSQL and CockroachDB separately when dual-engine support is claimed.

Generated code provenance, not a moving branch or copied entity directory, is the source of truth.

## Web-to-API transport

Internal web-to-API communication uses ordinary request/response HTTP over the private cluster network.

- Use one process-wide HTTP client, normally a shared `reqwest::Client`, with bounded HTTP/1.1 keep-alive or HTTP/2 connection reuse.
- HTTP keep-alive already uses pooled persistent TCP connections. The deferred item is a custom long-lived application protocol/session, bespoke framing, connection-affine state, or streaming RPC between web and API.
- Configure explicit connect, pool-idle, request, read, and total deadlines; the upstream deadline must be shorter than the browser request deadline.
- Retry only proven-idempotent operations. Mutations require an idempotency key/contract before any automatic retry.
- Bound concurrency and queueing so an unhealthy API cannot exhaust web workers or sockets.
- Propagate request IDs, trace context, authenticated actor context, and an explicit audience.
- Use Kubernetes Service discovery and NetworkPolicies; do not route private service calls back through the public Cloudflare/load-balancer path.
- Circuit breaking, load shedding, and stale-cache fallback are allowed when their authorization and consistency behavior is documented.

A future gRPC or custom transport proposal must present measured latency/throughput evidence, operational and failure-isolation analysis, observability, rollout/rollback, and generated-client compatibility. Protocol novelty alone is not justification.

## Authentication and authorization

Shared Auth is the canonical identity, session-assurance, MFA, passkey, and token-exchange plane. Product services retain product authorization.

### Web responsibilities

- establish the browser session and enforce exact cookie, host, origin, and CSRF rules;
- keep bearer/refresh tokens out of browser JavaScript when server-mediated sessions are used;
- bind session/token exchange to the correct customer/admin audience;
- forward or exchange identity without broadening privileges;
- avoid duplicate identity stores or service-role keys.

### API responsibilities

- verify token issuer, audience, expiry, assurance, tenant, and actor;
- enforce product roles, ownership, field-level access, and mutation policy;
- treat service-to-service identity and end-user actor identity as distinct inputs;
- never rely on the web server’s UI checks as authorization.

Customer and admin planes use separate cookies, audiences, credentials, and databases where the product architecture calls for that separation.

## Migrations and release discipline

[`declarative-migrations`](https://github.com/declarative-migrations) / `dpm` is the production migration mechanism for PostgreSQL and CockroachDB.

- The owning API/domain repository owns the product migration source.
- A separate, serialized pre-deploy Job applies it under the migrator identity and an advisory/fencing lock.
- Ordinary API, web, and worker replicas do not receive DDL privileges and do not migrate on boot.
- A migration failure blocks rollout and records the source revision, bundle digest, target, starting/ending catalog version, result, and duration.
- Destructive changes use **expand → mixed-version/backfill → contract**, with each phase independently deployable and revertible.
- ORM/code-first tools may help author SQL, but reviewed committed declarative SQL/catalog state is authoritative.
- `AUTO_MIGRATE`, `db push`, `synchronize: true`, `EnsureCreated`, or equivalent startup mutation is forbidden in durable environments.
- A clearly labeled, single-replica, disposable local/CI stack may opt into boot migration; the default remains off and the exception may not appear in Kubernetes production manifests.
- Web-owned state follows the same release-job rule, using its own migration identity and affecting only its own schema.
- PostgreSQL/CockroachDB compatibility is tested per engine, including constraints, indexes, isolation, DDL behavior, transactions, and retryable serialization failures.

## Object storage, queues, and workers

The API/domain owner or its delegated worker owns product object-store and queue mutations.

- Browser servers do not receive R2/S3 secret keys. They obtain bounded presigned URLs or call the API.
- Background workers that mutate product data use an explicitly delegated API-domain identity and the same invariants/idempotency contracts.
- WebSocket/SSE refresh workers do not become an alternate mutation path.
- Cross-cluster Fiducia communication uses authenticated APIs, events, or another explicit versioned contract; two clusters do not share broad database writers.

## Deployment topology

Traditional web/API/worker/migration workloads run through [`ORESoftware/k8s-cluster`](https://github.com/ORESoftware/k8s-cluster). Their GitOps definitions identify:

- runtime role (`web`, `api`, `combined-bff-api`, `worker`, `migrator`);
- owner organization/project and database namespace;
- public origin and private service name;
- ServiceAccount and allowed network peers;
- secret references for web state, domain read, domain write, and migration identities;
- database/object-store/HTTP connection budgets;
- migration bundle and ordering;
- health, readiness, graceful shutdown, PDB, and rollback behavior.

Specialized `fiducia-node.rs`, `fiducia-brain.rs`, and related coordination services remain on the separate Fiducia cluster. The traditional and specialized clusters do not jointly mutate one schema with shared credentials.

Cloudflare may provide TLS termination, WAF/rate limiting, caching, and public routing, but it does not redefine service ownership or replace application authorization.

## Audit findings — 2026-08-08

| Organization | Observed state | Classification | Required follow-through |
| --- | --- | --- | --- |
| `sonus-auris` | `sonus-auris-api-server.rs` is the consolidated product API and owns domain writes. `sonus-auris-web-server.rs` writes only its encrypted browser-session table and currently reads user-domain data through the typed API. | Conforming split. Web-session writes are a valid web-owned-state exception. | Keep shared direct reads optional/read-only; keep the web session migrator isolated; finish exact ORM provenance and live permission evidence under DEN-2787. |
| `zed-pkg` | `zed-api-server.rs` still has legacy migration-at-boot behavior on `main`; `zed-web-server.rs` directly reads the registry DB and mirrors entities. Draft PRs `zed-api-server.rs#19` and `zed-web-server.rs#6` move migration out of startup and enforce the read-only web identity. | Intended split, implementation incomplete. | Merge only after exact-head Rust/Kustomize tests, provision `api_rw`/`web_ro`/`migrator` roles, add the discrete DPM Job, consume canonical `zed-orm-core`, and run `zed-pkg-test` permission/E2E lanes. |
| `fiducia-cloud` | `fiducia-customer.rs` renders the customer app and still owns narrowly scoped customer profile/preferences/session/notification mutations; credential lifecycle is delegated to `fiducia-auth`. Coordination services remain on the specialized cluster. | Explicit combined BFF/API transition—not a read-only web server. | Keep customer and shared-coordination credentials separate; classify routes by owner; plan a dedicated customer API when mutation volume/stability justifies it; never extend the BFF writer into shared coordination data. |

The audit therefore corrects four common ambiguities:

1. “Web server is read-only” means **read-only toward product-domain data**, not incapable of writing its isolated browser-state store.
2. “API owns migrations” means the **API/domain repository owns the migration source**, while a separate release job executes DDL.
3. “No stateful TCP” means no custom stateful **internal web-to-API** protocol; HTTP keep-alive and browser WebSocket/SSE are permitted.
4. Repository names are descriptive, not authoritative. A mixed service must be classified as `combined-bff-api` until it is split.

## Required tests and conformance gates

Every product pair must provide evidence for:

### Static/build gates

- formatting, Clippy with warnings denied, unit/integration tests, and locked release build;
- thin-entrypoint/module architecture checks;
- no direct product write dependency or migration crate in the web target;
- negative compile fixture proving a default web consumer cannot name ORM write types/functions;
- generated interface/client/ORM provenance and digest checks;
- route ownership inventory identifying browser, BFF, API, worker, and migration surfaces.

### Database gates

- API DML succeeds and undeclared DDL fails;
- approved web reads succeed;
- web `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `CREATE`, `ALTER`, and `DROP` fail;
- web/API cannot assume each other’s or the migrator’s role;
- web-state migrator cannot affect product objects;
- product migrator cannot affect another organization/project namespace;
- read-only session settings and timeouts are verified at startup;
- PostgreSQL and CockroachDB lanes are independent when both are supported.

### HTTP/browser gates

- generated-client contract tests between web/API/CLI/mobile/desktop;
- exact Host/Origin/CSRF/cookie/audience tests;
- idempotent retry and duplicate-mutation tests;
- timeout, API unavailability, load-shedding, and graceful-degradation tests;
- cache-control and cross-user/cross-tenant leakage tests;
- WebSocket/SSE authentication, origin, replay, and bounded-payload tests;
- trace/request-id propagation across the web→API hop.

### GitOps/edge gates

- separate Deployments, Services, ServiceAccounts, secrets, and NetworkPolicies;
- `app.<domain>`, `api.<domain>`, and `www.<domain>` route ownership;
- no API writer or migrator credential in the web deployment;
- no production boot-migration flag;
- rendered-manifest and rollback evidence;
- canaries run in representative `*-test` organizations before fleet promotion.

DEN-3043 owns the machine-readable linter/exception format and must detect capability drift, not merely repository-name drift.

## Remediation order

1. Merge this role taxonomy into the three canonical `.github`/Linear plans and the cross-org architecture registry.
2. Finish `*-orm-core` provenance, opaque-context, compile-fail, and live database evidence.
3. Complete Zed’s discrete migration job and read-only web credential, then certify exact heads in `zed-pkg-test`.
4. Keep Sonus Auris shared reads API-mediated unless a measured direct-read case satisfies every exception gate.
5. Maintain the explicit `combined-bff-api` classification for `fiducia-customer.rs`; create/split a customer API as a focused rollout rather than silently treating presentation code as the domain boundary.
6. Extend DEN-3043 so fleet checks cover web-owned schemas, combined services, migration-at-boot, object-store secrets, internal transport, and browser WebSocket/SSE—not only subdomain names.
7. Attach exact PR, commit, rendered-manifest, and test evidence before marking organization conformance complete.

## Exceptions

Any deviation requires an ADR in the organization’s `.github` repository and a linked Linear issue. The ADR must state:

- the runtime role and domain owner;
- why the default split is unsuitable;
- exact database, object-store, auth, and migration privileges;
- affected public/private routes;
- consistency, authorization, and failure-mode consequences;
- tests and observability;
- rollback;
- an owner and review/expiry date.

An exception may relax deployment shape, but it may not silently share broad writer credentials, bypass product authorization, run uncontrolled production DDL, or erase organization/project namespace boundaries.
