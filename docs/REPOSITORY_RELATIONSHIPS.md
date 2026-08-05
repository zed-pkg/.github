<!-- ore-org-baseline:begin -->
# Repository relationships for `zed-pkg`

This file is rendered from `repository-relationships.json`. The JSON registry is authoritative.

- Audience: `public`
- Repositories represented: **15**
- Relationships represented: **21**
- Inventory digest: `sha256:9d3ca6e1b77d3461489af42f430dd242f64dbcfe915bf2b9061dc1de979a60de`

## Immutable routing identity

| Field | Value |
|---|---|
| Mapping ID | `context:zed-pkg` |
| GitHub owner ID | `308416455` |
| Linear project ID | `9107ce62-1112-43ff-89bc-f442613c4156` |
| Linear team ID | `eb8ab169-5afe-4b6f-9cab-3f2aa3e887dc` |

## Repositories

| Repository | Visibility | Roles | Archived |
|---|---|---|---|
| `zed-pkg/.github` | `public` | `community-health`, `governance`, `relationship-registry` | no |
| `zed-pkg/zed-api-server.rs` | `public` | `api-server` | no |
| `zed-pkg/zed-cli` | `public` | `repository` | no |
| `zed-pkg/zed-clients` | `public` | `clients` | no |
| `zed-pkg/zed-docs` | `public` | `repository` | no |
| `zed-pkg/zed-e2e` | `public` | `end-to-end-tests` | no |
| `zed-pkg/zed-infra` | `public` | `infrastructure` | no |
| `zed-pkg/zed-intellij` | `public` | `repository` | no |
| `zed-pkg/zed-interfaces` | `public` | `interfaces` | no |
| `zed-pkg/zed-lock` | `public` | `repository` | no |
| `zed-pkg/zed-monorepo` | `public` | `monorepo` | no |
| `zed-pkg/zed-pkg.github.io` | `public` | `documentation-site` | no |
| `zed-pkg/zed-sublimetext` | `public` | `repository` | no |
| `zed-pkg/zed-sync` | `public` | `sync` | no |
| `zed-pkg/zed-web-server.rs` | `public` | `web-server` | no |

## Relationships

| From | Type | To | Status | Required |
|---|---|---|---|---|
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-api-server.rs` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-cli` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-clients` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-docs` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-e2e` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-infra` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-intellij` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-interfaces` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-lock` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-monorepo` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-pkg.github.io` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-sublimetext` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-sync` | `declared` | yes |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-web-server.rs` | `declared` | yes |
| `zed-pkg/zed-api-server.rs` | `depends_on` | `zed-pkg/zed-interfaces` | `inferred` | no |
| `zed-pkg/zed-clients` | `depends_on` | `zed-pkg/zed-interfaces` | `inferred` | no |
| `zed-pkg/zed-e2e` | `tests` | `zed-pkg/zed-monorepo` | `inferred` | no |
| `zed-pkg/zed-infra` | `deploys` | `zed-pkg/zed-monorepo` | `inferred` | no |
| `zed-pkg/zed-pkg.github.io` | `documents` | `zed-pkg/.github` | `inferred` | no |
| `zed-pkg/zed-sync` | `depends_on` | `zed-pkg/zed-interfaces` | `inferred` | no |
| `zed-pkg/zed-web-server.rs` | `depends_on` | `zed-pkg/zed-interfaces` | `inferred` | no |

## Editing relationships

Put reviewed public declarations in `repository-relationships.manual.json`; do not edit the generated registry directly.
Private repository names and private-only relationships belong in the private `ORESoftware/project-registry` mirror.
Inferred edges are advisory and must remain visibly labeled until reviewed.
<!-- ore-org-baseline:end -->
