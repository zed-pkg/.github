# Zed IDE insight contract

All Zed IDE integrations should be thin native shells over one stable diagnostic protocol supplied by `zed-cli`.

## Proposed command

```sh
zed inspect --workspace <absolute-path> --json
```

The command must be read-only. It must never install, remove, update, publish, or mutate package state. IDEs may refresh it when a solution/workspace opens, when `.zpkg.toml` or `.zpkg.lock` changes, and on explicit user request.

## JSON envelope

```json
{
  "schemaVersion": 1,
  "workspaceRoot": "/workspace",
  "zedVersion": "0.1.0",
  "package": {
    "name": "acme/widget",
    "manifestPath": "/workspace/.zpkg.toml",
    "lockPath": "/workspace/.zpkg.lock"
  },
  "dependencies": [],
  "issues": [
    {
      "id": "lock.stale",
      "severity": "warning",
      "title": "Lockfile is older than the manifest",
      "detail": "Dependency intent changed after the last resolution.",
      "files": [".zpkg.toml", ".zpkg.lock"],
      "actions": [
        {
          "id": "install",
          "title": "Resolve and install",
          "kind": "command",
          "command": "zed",
          "arguments": ["install"],
          "requiresConfirmation": true
        }
      ]
    }
  ]
}
```

## Severity and action rules

Severities are `info`, `warning`, and `error`. Each issue must have a stable machine-readable ID. Actions are recommendations, not automatic execution. Every mutating action requires an explicit user confirmation in the IDE. The extension must show the exact command and working directory before execution.

## Minimum diagnostics

- missing or malformed `.zpkg.toml`
- missing, malformed, or stale `.zpkg.lock`
- declared dependency absent from the lockfile
- locked dependency no longer declared directly or transitively
- integrity/provenance mismatch
- unavailable `zed` executable or unsupported CLI version
- offline state when a requested action needs network access
- incompatible adapter/target configuration
- available safe updates and yanked versions

## Recommended architecture

Each IDE repository should contain a native UI layer and a small process adapter. Common schemas belong in `zed-interfaces`; command behavior belongs in `zed-cli`. IDE implementations must not independently resolve dependency graphs.
