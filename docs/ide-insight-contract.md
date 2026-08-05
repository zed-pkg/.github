# Zed IDE integration parity contract

Every integration is a native editor shell over the same read-only Zed Package
Manager inspection model. Package resolution remains owned by `zed-cli`.

## Levels

1. **Core conformance** — deterministic report model, argv process execution,
   bounded execution, schema validation, output redaction, safe action metadata,
   and unit tests.
2. **Native shell** — editor-native diagnostics, package tree/tool window,
   refresh triggers, exact-command preview, and explicit mutation confirmation.
3. **Distribution** — reproducible package, retained CI artifact, clean-profile
   installation tests, marketplace/update-channel publication, and provenance.

A candidate may pass core conformance without being described as production
ready. Only integrations satisfying all three levels are “up to par” for users.

## Required diagnostics

- no manifest, unreadable/malformed manifest, and invalid package identity;
- no lockfile, unreadable/malformed/unsupported/stale lockfile;
- declared dependency missing from the lock;
- materialization missing or inconsistent;
- interrupted `.zpkg-staging` transaction;
- unavailable, timed-out, failing, unsupported, or wrong `zed` executable;
- integrity/provenance mismatch when reported by the CLI.

## Process boundary

The preferred command is:

```text
zed inspect --workspace <absolute-root> --json
```

The process adapter MUST invoke an executable and argument vector without a
shell, set an explicit working directory, enforce a timeout or cancellation
boundary, reject unknown schema versions, redact credentials, and fail closed
to a visible diagnostic. It never executes returned actions.

## Action boundary

Mutating actions are recommendations. Before execution the native shell MUST
show the executable, arguments, and working directory and obtain explicit user
confirmation. Refresh/startup paths are read-only.

## Sandbox evidence

`zed-pkg-test/zed-pkg-e2e` owns cross-editor fixtures and native toolchain jobs.
Tests run in temporary workspaces and must not use real credentials, user package
homes, or mutable production registries.
