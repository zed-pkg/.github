# `zed-pkg` repository relationships

Generated from reviewed policy and the current **public** repository inventory.

- Public repositories declared: **23**
- Private repository names withheld: **0**
- Relationship edges: **61**

## Repository roles

| Repository | Role | Lifecycle |
|---|---|---|
| [`.github`](https://github.com/zed-pkg/.github) | `organization_governance` | `active` |
| [`zed-interfaces`](https://github.com/zed-pkg/zed-interfaces) | `interfaces` | `active` |
| [`zed-clients`](https://github.com/zed-pkg/zed-clients) | `client_sdk` | `active` |
| [`zed-api-server.rs`](https://github.com/zed-pkg/zed-api-server.rs) | `api_service` | `active` |
| [`zed-sync`](https://github.com/zed-pkg/zed-sync) | `sync_service` | `active` |
| [`zed-web-server.rs`](https://github.com/zed-pkg/zed-web-server.rs) | `web_bff` | `active` |
| [`zed-cli`](https://github.com/zed-pkg/zed-cli) | `cli` | `active` |
| [`zed-pkg.github.io`](https://github.com/zed-pkg/zed-pkg.github.io) | `site` | `active` |
| [`zed-infra`](https://github.com/zed-pkg/zed-infra) | `infrastructure` | `active` |
| [`zed-e2e`](https://github.com/zed-pkg/zed-e2e) | `end_to_end_tests` | `active` |
| [`zed-monorepo`](https://github.com/zed-pkg/zed-monorepo) | `composition_workspace` | `active` |
| [`zed-eclipse`](https://github.com/zed-pkg/zed-eclipse) | `library` | `active` |
| [`zed-intellij`](https://github.com/zed-pkg/zed-intellij) | `library` | `active` |
| [`zed-jetbrains-air`](https://github.com/zed-pkg/zed-jetbrains-air) | `library` | `active` |
| [`zed-orm-core`](https://github.com/zed-pkg/zed-orm-core) | `library` | `active` |
| [`zed-qtcreator`](https://github.com/zed-pkg/zed-qtcreator) | `library` | `active` |
| [`zed-sublimetext`](https://github.com/zed-pkg/zed-sublimetext) | `library` | `active` |
| [`zed-visual-studio`](https://github.com/zed-pkg/zed-visual-studio) | `library` | `active` |
| [`zed-vscode`](https://github.com/zed-pkg/zed-vscode) | `library` | `active` |
| [`zed-xcode`](https://github.com/zed-pkg/zed-xcode) | `library` | `active` |
| [`zed-docs`](https://github.com/zed-pkg/zed-docs) | `uncategorized` | `active` |
| [`zed-lib`](https://github.com/zed-pkg/zed-lib) | `uncategorized` | `active` |
| [`zed-lock`](https://github.com/zed-pkg/zed-lock) | `uncategorized` | `active` |

## Declared edges

| From | Relationship | To | Status/basis |
|---|---|---|---|
| `organization://zed-pkg` | `reconciles_via` | `platform://opto-sync` | `platform-default` / `platform-policy`: product sync wraps the generic reconciliation engine |
| `organization://zed-pkg` | `deployed_via` | `platform://ORESoftware/k8s-cluster` | `platform-default` / `platform-policy`: immutable artifacts are promoted by digest through GitOps |
| `organization://zed-pkg` | `packaged_via` | `platform://zed-pkg` | `platform-default` / `platform-policy`: Zed resolves artifacts while submodules compose editable source |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-api-server.rs` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-cli` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-clients` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-docs` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-e2e` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-eclipse` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-infra` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-intellij` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-interfaces` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-jetbrains-air` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-lib` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-lock` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-monorepo` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-orm-core` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-pkg.github.io` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-qtcreator` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-sublimetext` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-sync` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-visual-studio` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-vscode` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-web-server.rs` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/.github` | `governs` | `zed-pkg/zed-xcode` | `inferred` / `role-convention`: organization defaults, safety, and relationship declarations |
| `zed-pkg/zed-api-server.rs` | `implements_contracts_from` | `zed-pkg/zed-interfaces` | `inferred` / `role-convention`: service boundary implements canonical contracts |
| `zed-pkg/zed-cli` | `calls` | `zed-pkg/zed-api-server.rs` | `inferred` / `role-convention`: client uses the product service boundary |
| `zed-pkg/zed-clients` | `generated_from` | `zed-pkg/zed-interfaces` | `inferred` / `role-convention`: SDK bindings derive from canonical contracts |
| `zed-pkg/zed-e2e` | `tests` | `zed-pkg/zed-api-server.rs` | `inferred` / `role-convention`: black-box compatibility verification |
| `zed-pkg/zed-e2e` | `tests` | `zed-pkg/zed-cli` | `inferred` / `role-convention`: black-box compatibility verification |
| `zed-pkg/zed-e2e` | `tests` | `zed-pkg/zed-pkg.github.io` | `inferred` / `role-convention`: black-box compatibility verification |
| `zed-pkg/zed-e2e` | `tests` | `zed-pkg/zed-sync` | `inferred` / `role-convention`: black-box compatibility verification |
| `zed-pkg/zed-e2e` | `tests` | `zed-pkg/zed-web-server.rs` | `inferred` / `role-convention`: black-box compatibility verification |
| `zed-pkg/zed-infra` | `deploys` | `zed-pkg/zed-api-server.rs` | `inferred` / `role-convention`: product infrastructure declares runtime resources |
| `zed-pkg/zed-infra` | `deploys` | `zed-pkg/zed-cli` | `inferred` / `role-convention`: product infrastructure declares runtime resources |
| `zed-pkg/zed-infra` | `deploys` | `zed-pkg/zed-sync` | `inferred` / `role-convention`: product infrastructure declares runtime resources |
| `zed-pkg/zed-infra` | `deploys` | `zed-pkg/zed-web-server.rs` | `inferred` / `role-convention`: product infrastructure declares runtime resources |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-api-server.rs` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-cli` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-clients` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-docs` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-e2e` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-eclipse` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-infra` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-intellij` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-interfaces` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-jetbrains-air` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-lib` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-lock` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-orm-core` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-pkg.github.io` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-qtcreator` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-sublimetext` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-sync` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-visual-studio` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-vscode` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-web-server.rs` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-monorepo` | `composes` | `zed-pkg/zed-xcode` | `inferred` / `role-convention`: development workspace and release bill of materials |
| `zed-pkg/zed-sync` | `synchronizes_with` | `zed-pkg/zed-api-server.rs` | `inferred` / `role-convention`: sync exchanges state through the product service boundary |
| `zed-pkg/zed-sync` | `uses_contracts_from` | `zed-pkg/zed-interfaces` | `inferred` / `role-convention`: sync payloads follow canonical schemas |
| `zed-pkg/zed-web-server.rs` | `calls` | `zed-pkg/zed-api-server.rs` | `inferred` / `role-convention`: client uses the product service boundary |

## Composition, service, and observability contract

Git submodules compose editable source; Zed packages resolve packages/artifacts; dual-managed commits must match. Production deploys immutable image digests, not runtime source builds. Cross-service access uses APIs/SDKs/events rather than another service database. MCP uses the product API/SDK. Services emit OpenTelemetry traces, bounded metrics, and correlated structured logs.

## Privacy boundary

This public registry deliberately omits private repository names and edges; the count above makes the boundary explicit.
