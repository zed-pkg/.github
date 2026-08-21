# Public registry reliability contract

Status: implementation in progress; public cutover is not certified

Canonical planning project: [`github.com/zed-pkg`](https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc)

Linear incident document: [Public registry reliability, R2 mirroring, and incident recovery — 2026-08-20](https://linear.app/denman/document/public-registry-reliability-r2-mirroring-and-incident-recovery-2026-08-5f461fd0bb83)

Last live observation: 2026-08-20 America/Los_Angeles

## Product boundary

Zed supplements ecosystem-native package managers; it does not replace them.

Cargo, npm, pub, Go modules, SwiftPM, and similar tools remain authoritative for
their native build and release semantics. Zed adds a repository-family package
graph, cross-ecosystem coordination, reproducible locks, policy, and artifact
verification around those ecosystems.

## Canonical public hosts

| Host | Contract | Session or mutation policy |
| --- | --- | --- |
| `zpkg.net` | Human-facing project and documentation site | No registry mutation or authenticated session |
| `api.zpkg.net` | Versioned API, authentication handoff, metadata, publish, yank, and other control-plane operations | The only public write origin; mutations never fail over by replaying to an unrelated authority |
| `registry.zpkg.net` | Immutable artifact download surface | Public content-addressed reads; no browser session cookies |
| `app.zpkg.net` | Canonical authenticated browser UI | Host-only secure cookies and exact-origin CSRF checks |
| `user.zpkg.net` | Optional browser-friendly alias | Permanent `308` redirect to `app.zpkg.net`; it must not establish a second session scope |

`web.zpkg.net` is a legacy name and, once the browser service is promoted,
should redirect permanently to `app.zpkg.net`. It is not a second canonical UI.

Optional domains such as `zpkg.dev` or `zpkg.pub` may redirect human traffic to
`zpkg.net` after ownership and DNS control are verified. They must not become
independent writable registry authorities. Any machine-readable alias must
prove the same stable logical registry identity and exact artifact digests.

## Availability architecture

The public edge and the authoritative data planes have different failure
boundaries:

1. `api.zpkg.net` routes to authenticated, rate-limited API replicas in both
   the AWS EC2 Kubernetes and Hetzner Kubernetes clusters. Both clouds use one
   authoritative registry metadata database. Active-active compute must never
   imply two divergent writable databases.
2. `app.zpkg.net` routes to stateless browser replicas in both clusters. The web
   tier uses a read-only database identity or the private API and never receives
   registry writer or object-store writer credentials.
3. `registry.zpkg.net` serves immutable, SHA-256-addressed artifacts from
   Cloudflare R2 and may fall back only to a second-provider object that has
   been independently verified for key, length, content type, and digest.
4. Publication writes once through `api.zpkg.net`. An outbox or equivalent
   durable repair queue copies committed artifacts to the mirror and records
   verification state. A blind or unverified mirror is never eligible for
   download failover.
5. The direct certification convention is
   `api/registry/app/user.{aws,hetzner}.zpkg.net`.
   `origin-{aws,hetzner}.zpkg.net` is reserved for transport/connector probes.
   These names are not alternate registry identities.

A Cloudflare Tunnel connector on an operator workstation is not a production
origin. If Cloudflare Tunnel remains the ingress mechanism, each canonical
tunnel must have multiple `cloudflared` replicas in each cluster, a
PodDisruptionBudget, topology spreading, resource limits, and connector health
alerts. A low-cost third compute provider may be added only as another
stateless, digest-pinned deployment; it does not replace independent artifact
storage or the authoritative database.

[Google Cloud Run](https://cloud.google.com/run/pricing) is the preferred
third-provider evaluation target for
stateless standby capacity because it is outside the AWS, Hetzner, and
Cloudflare compute failure domains and supports container scale-to-zero. It is
not part of the production pool until a project, workload identity, private
database path, digest-pinned image, bounded R2 credential, readiness probe,
minimum-instance decision, budget alert, direct canary, and rollback evidence
are reviewed. A nominal free tier is not an availability guarantee.

## Health and failover semantics

Every server exposes separate probes:

- `/livez` proves only that the process can serve requests;
- `/readyz` proves required database contexts, the expected migration
  revision, and at least one verified artifact store are usable;
- `/healthz` may remain as a compatibility summary but is not used as both
  liveness and readiness.

The edge removes an origin when `/readyz` fails. Read retries are bounded by a
total deadline and may cover connection errors, timeouts, `429`, and `5xx`.
They do not cross an authentication failure, malformed metadata, registry
identity mismatch, or checksum mismatch. Mutations require one authoritative
origin and are not automatically replayed after an ambiguous timeout unless an
idempotency/status-query contract proves that replay safe.

Scheduled public probes fail when a canonical hostname lacks DNS or TLS,
returns a Cloudflare-generated error such as Tunnel error `1033`, violates its
redirect contract, or returns a body from the wrong service. Direct AWS and
Hetzner probes remain separate so one healthy cloud cannot hide another.

## Artifact and R2 controls

Production package objects are immutable and content addressed. Required
controls are:

- a bucket-scoped R2 runtime credential per cluster, not an account-wide
  administration token;
- separate credentials for DNS administration, R2 bucket administration,
  production runtime writes, read-only verification, and test/E2E;
- a distinct non-production bucket and credential for every test environment;
- conditional create (`If-None-Match: *`) and digest/metadata verification for
  retries and races;
- retention or bucket-lock rules for canonical `artifacts/` objects, with no
  production expiry rule;
- bounded lifecycle rules for abandoned multipart uploads and disposable
  development/test objects;
- exact-origin, least-method CORS only when browser access requires it;
- metrics and alerts for object operations, throttling, integrity failures,
  missing referenced objects, and mirror lag.

Public downloads should use the immutable artifact domain. If a presigned URL
is unavoidable, its lifetime is short, redirect responses prevent referrer and
cache leakage, and query strings never enter logs, issues, Linear, or retained
CI evidence.

## Secret file contract

Every participating repository uses these exact wildcard paths:

```text
env/enc/*.env.enc  # tracked SOPS ciphertext
env/dec/*.env      # ignored local plaintext, mode 0600
```

An active root `.env` may be only a relative symlink to one file under
`env/dec/`. The directory is prepared with mode `0700`, symlinked `env` or
`env/dec` paths are rejected, and plaintext installation is atomic. CI and
deployments should prefer `sops exec-env` so `env/dec/*.env` is never created
there.

The standard interface is:

```sh
nix develop --command just env-edit <profile>
nix develop --command just env-use <profile>
nix develop --command just env-diff <profile>
nix develop --command just env-encrypt <profile>
nix develop --command just env-verify
nix develop --command just env-lock
```

Profiles may be compartmentalized—for example `prod-api`,
`prod-cloudflare-dns`, `prod-r2-admin`, and `test-r2`—while preserving the
wildcard path contract. Production and non-production use different recipient
sets. Production has at least two independently held recovery recipients;
automation should prefer OIDC to a narrowly scoped KMS identity over a
long-lived age private key.

## Promotion and recovery gates

Promotion is additive and proceeds in this order:

1. Render and validate digest-pinned production manifests without cluster
   credentials.
2. Configure protected `aws` and `hetzner` deployment identities, or land
   exact GitOps revisions in the canonical cluster repository.
3. Run the serialized migration once and verify the schema revision from the
   secondary cluster.
4. Certify each direct cloud origin independently: publish in an approved test
   organization, fetch metadata, download, verify SHA-256, install, erase the
   local cache, and frozen-reinstall with a byte-identical lock.
5. Disable one compute origin and repeat read/install certification through the
   other. Disable the primary artifact path and prove only a verified mirror is
   selected.
6. Route the canonical hosts only after both direct origins, storage paths,
   authentication, rate limits, TLS, and monitoring pass.

Rollback is a reviewed GitOps revision or removal of one unhealthy edge pool.
It is not deletion of ingress, namespaces, artifacts, metadata, or audit
evidence.

## Current evidence and blockers

The 2026-08-20 observation is a failure baseline, not deployment evidence:

- `api.zpkg.net` and `registry.zpkg.net` resolved through Cloudflare but
  returned HTTP `530` with error `1033`, meaning no healthy `cloudflared`
  connector was available;
- `app.zpkg.net` and `user.zpkg.net` had no DNS records;
- the latest visible dual-cloud deployment run failed before rendering or
  applying manifests because the protected AWS and Hetzner environment
  credentials were absent;
- the existing Cloudflare drift workflow can report success without a token or
  zone identifier, and the existing public-edge schedule is report-only.

No source change, green report-only job, or local render is proof that the
public service is live. Completion requires authoritative DNS, deployment,
ready-replica, object-store, and test-organization evidence recorded against
the exact promoted commits.

## Linear status mirror

Linear owns priority, sequencing, cross-repository dependencies, and rollout
status. The canonical project update for this work must link the exact GitHub
pull requests and immutable heads, record the live failure baseline above,
track AWS credentials, Hetzner credentials/billing, Cloudflare control-plane
access, production SOPS recipients, database authority, R2 mirror readiness,
and the public certification run as separate blockers, and remain in progress
until the canonical-host probes enforce successfully.
