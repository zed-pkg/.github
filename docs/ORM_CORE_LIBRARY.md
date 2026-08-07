# Shared ORM Layer — `*-orm-core` (SeaORM)

**Status:** Adopted 2026-08-07
**Extends:** [`SERVICE_AND_DATA_ARCHITECTURE.md`](../SERVICE_AND_DATA_ARCHITECTURE.md) (the canonical service & data architecture policy). This addendum records one additional decision; it does not restate or override that policy.

## Decision

Because both the web server and the API server read from the database, the ORM code is shared through a dedicated per-organization library crate rather than duplicated in each service:

- **Each organization gets one shared ORM crate repo, named `<org-prefix>-orm-core`:**
  - `fiducia-cloud/fiducia-orm-core`
  - `sonus-auris/sonus-auris-orm-core`
  - `zed-pkg/zed-orm-core`
- **The Rust ORM is always [SeaORM](https://www.sea-ql.org/SeaORM/).**
- **Schema definitions are imported from [`oresoftware/k8s-libs-and-shared-defs`](https://github.com/oresoftware/k8s-libs-and-shared-defs)** — namespaced/segmented by GitHub org and project per the namespace contract in the canonical policy. `*-orm-core` derives its entities from those shared definitions; it never defines an independent, competing schema.

## Boundaries

- **API server** consumes the full read/write entity surface of `*-orm-core`.
- **Web server** consumes only the read-only surface: named, policy-aware query functions (or stable read views). The crate must not export a raw `DatabaseConnection`, unrestricted query builder, or public entity manager to web-tier request handlers — this matches the web-tier direct-read boundary in the canonical policy, and the web tier still connects with its `SELECT`-only database identity.
- **Migrations are not part of `*-orm-core`.** The owning API server keeps sole migration authority via [`declarative-migrations`](https://github.com/declarative-migrations); the ORM crate carries entity and query code only. SeaORM codegen may help author entities, but the shared definitions in `k8s-libs-and-shared-defs` plus reviewed migration SQL remain the source of truth.
- **Versioning:** a `*-orm-core` release pins the exact shared-definition version/digest it was generated against. Web and API services pin compatible `*-orm-core` versions; a schema expand/contract window is also an `*-orm-core` compatibility window, and lib major bumps are treated as schema events.

## Rationale

A shared crate fixes entity/mapping drift between the two consumers of the same schema. The known trade-off — build-time coupling replacing runtime coupling — is accepted and managed via the version-pinning rules above and the expand/contract release discipline in the canonical policy.
