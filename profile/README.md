# zed-pkg

This organization maintains the independent **zed-pkg** multi-language package
manager, interfaces, clients, services, infrastructure, certification, and
supporting documentation. It is unrelated to the Zed text editor.

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

- [GitHub Project: zed-pkg-project](https://github.com/orgs/zed-pkg/projects/1)
- [Linear planning project](https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc)
- [Detailed project-routing contract](../docs/PROJECTS.md)

GitHub owns code and delivery evidence; Linear owns planning and dependencies. The linked organization Project provides the cross-repository execution view.
<!-- org-project-routing:end -->

<!-- ore-org-baseline:begin -->
This GitHub account maintains software, infrastructure, research, and supporting documentation under the [`zed-pkg`](https://github.com/zed-pkg) GitHub owner.

Planning and delivery context is tracked in [github.com/zed-pkg](https://linear.app/denman/project/githubcomzed-pkg-5a53230ae6cc). Public contribution, security, and governance defaults are maintained in [`.github`](https://github.com/zed-pkg/.github).

Repository descriptions and repository-local documentation remain authoritative for each project. Do not infer production readiness, support commitments, or security guarantees from this profile alone.
<!-- ore-org-baseline:end -->
