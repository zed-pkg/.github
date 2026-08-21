# zed-pkg

This organization maintains the independent **zed-pkg** multi-language package
manager, interfaces, clients, services, infrastructure, certification, and
supporting documentation. It is unrelated to the Zed text editor.

Zed supplements ecosystem-native package managers; it does not replace them.

Public endpoints have distinct roles: [`zpkg.net`](https://zpkg.net) is the
human site, `api.zpkg.net` is the API, `registry.zpkg.net` is the immutable
artifact surface, and `app.zpkg.net` is the canonical authenticated browser
UI. `user.zpkg.net` is an optional permanent redirect to the app, not a second
session origin. Availability, recovery, and promotion requirements are in the
[public registry reliability contract](../docs/PUBLIC_REGISTRY_RELIABILITY.md).

## Planning and delivery

- **Canonical Linear project:** [`github.com/zed-pkg`](https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc)
- **Canonical GitHub Project:** [`zed-pkg-project`](https://github.com/orgs/zed-pkg/projects/1) (project 1)
- **Cross-system registry:** [`zed-pkg/zed-docs` doc 33](https://github.com/zed-pkg/zed-docs/blob/main/docs/33-github-linear-project-registry.md)
- **Machine-readable mapping:** [`github-linear-project-registry.toml`](https://github.com/zed-pkg/zed-docs/blob/main/config/github-linear-project-registry.toml)
- **Linear registry document:** [GitHub organization → Linear project → GitHub Project registry](https://linear.app/denman/document/github-organization-linear-project-github-project-registry-997be66819bb)

Project 1 is the verified canonical organization board. Fleet reconciliation
keeps its exact title, active state, governance issue, and routing documentation
aligned with the Linear project.

## Repository families

- `zed-cli` owns the `zed` command and package-manager lifecycle.
- `zed-interfaces` owns shared Rust types and generated schemas.
- `zed-clients` owns polyglot SDKs and interoperability readers.
- `zed-api-server.rs` and `zed-web-server.rs` own registry service surfaces.
- `zed-sync` owns shared synchronization contracts.
- `zed-infra` owns deployment infrastructure.
- `zed-e2e` and the `zed-pkg-test` organization own independent certification.
- `zed-docs` owns architecture, governance, and cross-system registries.
- `zed-monorepo` composes product repositories without importing CLI or infra as
  application dependencies.

## Artifact policy

Pull-request and main-branch artifacts are commit-addressed review and
certification evidence. Stable CLI, schema, SDK, package, and Nix interoperability
releases originate from reviewed immutable tags and retain checksums and
provenance. Personal tokens must never be embedded in workflows, documentation,
issues, Project fields, or generated artifacts.

## Working principles

- Keep changes reviewable, tested, and reversible.
- Treat security, privacy, compatibility, and data durability as design constraints.
- Resolve merge conflicts semantically: reconstruct both sides' intent, preserve compatible behavior, and document deliberate trade-offs.
- Prefer canonical repositories and short, stable names; deprecate duplicates with migration notes rather than silently deleting history.
- Keep cross-repository dependencies explicit and pinned where reproducibility matters.

Organization-wide contribution and security guidance lives in this `.github` repository.

<!-- org-project-routing:start -->
## Planning and delivery
## Planning and delivery routing

- [GitHub Project: zed-pkg-project](https://github.com/orgs/zed-pkg/projects/1)
- [Linear planning project](https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc)
- [Detailed project-routing contract](../docs/PROJECTS.md)

GitHub owns code and delivery evidence; Linear owns planning and dependencies. The linked organization Project provides the cross-repository execution view.
<!-- org-project-routing:end -->

<!-- ore-org-baseline:begin -->
## Planning and governance

- Canonical Linear project: https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc
- Organization defaults: https://github.com/zed-pkg/.github
- Canonical agent policy: https://github.com/zed-pkg/.github/blob/main/agents.md
- Security policy: https://github.com/zed-pkg/.github/security/policy

Repositories in this organization use semantic conflict resolution with 3–10 relevant prior commits when useful, full cross-repository context, pull-request delivery, and a hard automated-agent denylist for destructive or history-rewriting operations.
<!-- ore-org-baseline:end -->

<!-- BEGIN MANAGED REPOSITORY RELATIONSHIPS v1 -->
## Repository relationship registry

`zed-pkg` declares repository roles, dependency edges, cross-organization capabilities, deployment ownership, and the git-submodule/Zed-package contract:

- [Human-readable map](architecture/REPOSITORY_RELATIONSHIPS.md)
- [Machine-readable manifest](architecture/repository-relationships.json)
- [JSON Schema](architecture/repository-relationships.schema.json)

The public registry withholds private repository names and edges.
<!-- END MANAGED REPOSITORY RELATIONSHIPS v1 -->
