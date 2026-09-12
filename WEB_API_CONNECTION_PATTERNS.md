# zed-pkg web/API connection patterns

Status: organization architecture guidance, tracked by [DEN-4258](https://linear.app/denman/issue/DEN-4258/document-zed-pkg-webapi-connection-patterns).

This policy applies to registry/catalog web surfaces, administrative BFFs, package APIs, publishing services, and background workers. It supplements the existing service architecture policy.

## Four supported avenues

| Avenue | Appropriate use | Boundary |
| --- | --- | --- |
| Direct database read | Named public package-metadata or search projection with a measured need | Never publisher identity, private packages, credentials, grants, audit evidence, install authorization, or writes; use a distinct `SELECT`-only, `READ ONLY`, non-owner, `NOBYPASSRLS` role |
| Stateless HTTP/JSON | Default for synchronous web-to-registry/API work | Required for publishing, install authorization, private metadata, administration, and every mutation |
| Stateful TCP | Measured high-frequency registry stream or replication feed | Not the authority for publishing or access control; require ADR, mTLS/delegated identity, bounded frames, deadlines, backpressure, and reconnect policy |
| NATS/message queue | Durable post-commit indexing, mirroring, scanning, or notification | Never login, publish approval, install authorization, or the immediate client response; require outbox plus idempotent consumers |

HTTP is the default. Direct reads, TCP, and messaging are explicit workload exceptions, not interchangeable transport choices.

## Decision and ownership

1. Publishing, private-package access, install authorization, credential handling, administration, and every mutation go through the API over HTTP.
2. An immediate authoritative response uses HTTP with versioned interfaces, bounded bodies/timeouts, correlation context, and mutation idempotency.
3. Indexing, mirroring, scanning, and notifications publish from a transactional outbox to NATS.
4. A measured stream may use TCP only after an ADR and API authorization.
5. A direct query remains limited to a documented public/read projection under its own restricted database role.

The browser/BFF owns HTML, opaque secure sessions, CSRF, and authorization-code plus PKCE. The registry API owns product authorization and all state changes. A data/core package owns typed mappings and queries. The canonical migration repository owns DDL; services verify compatibility and do not migrate production at boot.

Shared Auth proves identity and assurance, not registry entitlements. Validate realm, issuer, audience, tenant, app/client, scopes, session, freshness, and assurance. Protected introspection uses a service credential while carrying the user's token separately in the body. Never log bearer tokens, cookies, codes, PKCE verifiers, signing material, package credentials, or raw introspection data.

Package and service dependencies use immutable revisions, checksums, and declared provenance. `zed-pkg` remains the dependency mechanism, not an authorization bypass. `opto-sync` may implement declared synchronization/outbox flows, and `ores-otel` carries redacted telemetry; neither owns source-of-truth data.

## Operational requirements

- Bound HTTP bodies, TCP frames, deadlines, retries, queues, and buffers; propagate trace and correlation context.
- Make publishing and other mutations idempotent; make message consumers duplicate-safe.
- Fail closed. A failed API authorization must never fall back to public projection data.
- Record an owner and review/expiry date for every direct-read or TCP exception.
- Code comments at the call site identify the avenue and why its domain constraints are satisfied.

This organization document is the durable policy. A repository ADR may be stricter and should link back here.
