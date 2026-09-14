# Fleet contract dependency boundary

This organization follows the fleet dependency DAG instead of duplicating authority across repositories.

- Product/domain contracts remain in the owning `*-interfaces` repository.
- Fleet-generic semantic primitives may depend on `ORESoftware/ores-interfaces`.
- Shared deployment/runtime topology belongs in `ORESoftware/k8s-libs-and-shared-defs`; product-specific database and domain definitions do not.
- Distributed coordination uses `ORESoftware/ores-locks-and-leases` rather than importing a concrete Fiducia, Redis, or Cloudflare Durable Object backend directly.
- Authored TypeSpec and authored JSON Schema Draft 2020-12 remain independent peer authorities. `ORESoftware/typespec-json-schema-validator` provides fail-closed parity evidence; generated schemas are projections, not replacement authorities.
- Package/dependency identity and frozen replay use Zed metadata/locks. `ORESoftware/ores-cli` consumes that resolved evidence for fleet governance rather than implementing a second dependency solver.
- Shared config contracts such as `.cli-flags.toml`, `.ores-mw.toml`, `.ores-rl.toml`, `.ores-lru.toml`, `.auth-shared.toml`, and related TOMLs keep their owning tool/library as authority; fleet checks compare and report drift without silently rewriting values.

A cross-repository change should therefore identify one authority, one generated/evidence path, and one consumer path. New cyclic authority relationships are not acceptable.