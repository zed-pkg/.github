# zed-pkg organization handbook

> Shared operating defaults for repositories maintained under **zed-pkg**. Repository-local policy may strengthen these rules but should not silently weaken them.

## Mission

zed-pkg maintains package, dependency, development-environment, and release tooling. This `.github` repository is the canonical home for shared policy, reusable templates, community health files, and planning links.

Zed supplements ecosystem-native package managers; it does not replace them.

## Public registry operations

The canonical public roles, multi-cluster availability contract, verified
artifact-mirror rules, promotion gates, and exact
`env/enc/*.env.enc` to `env/dec/*.env` SOPS path contract are defined in
[Public registry reliability](PUBLIC_REGISTRY_RELIABILITY.md). A source change
or report-only check is not deployment evidence; the promoted commit must have
authoritative DNS, ready replicas, storage-integrity checks, and an independent
test-organization certification record.

## Repository contract

Each active repository must document purpose, ownership, maturity, supported platforms and languages, development and test commands, authoritative manifest and lock formats, release and rollback procedures, compatibility policy, and GitHub Project/Linear links. Package components should also document resolution, pinning, integrity verification, caching, locking, concurrency, offline behavior, workspace and submodule interaction, environment precedence, and migration semantics.

## Change workflow

1. Anchor work in an issue, Linear item, or documented maintenance objective.
2. Keep branches and pull requests focused.
3. Explain motivation, scope, resolver and compatibility risk, validation, migration, and rollback.
4. Test clean, cached, offline, concurrent, recursive, conflicting, corrupt, interrupted, and multi-version paths as relevant.
5. Resolve conflicts semantically by reconstructing both sides' intent.
6. Prefer squash merges for focused work unless commit structure materially improves auditability.

## Evidence, security, and documentation

Pull requests should include reproducible commands, fixture repositories, expected and observed manifests and locks, negative-path coverage, documentation updates, and CI or local-equivalent evidence. Never commit credentials, signing keys, private registry tokens, or sensitive logs. Follow `SECURITY.md` for private reporting. Verify artifact integrity, pin automation dependencies, keep formats and compatibility matrices documented, and record important resolver, environment, migration, and operational decisions.

## Planning ownership

GitHub owns code, reviews, checks, releases, and delivery evidence. Linear owns priority, dependencies, sequencing, and cross-project planning. The organization GitHub Project is the cross-repository execution view; see `PROJECTS.md` for routing details.

## Organization health

- [ ] Profiles, descriptions, topics, and READMEs are current.
- [ ] Community health files and reusable issue/PR guidance are present.
- [ ] Manifest, lock, integrity, resolution, cache, concurrency, and migration behavior is documented.
- [ ] Required checks cover supported platforms, offline and concurrent behavior, compatibility, and supply-chain risk.
- [ ] Stale repositories are archived or clearly marked.
- [ ] GitHub Project and Linear links resolve and reflect completed work.
