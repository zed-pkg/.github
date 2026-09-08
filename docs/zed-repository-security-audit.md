# Zed repository security audit

`tools/zed_repository_security_audit.py` complements the package-family checks in
`tools/zed_fleet_audit.py`. The family auditor answers whether producers and
consumers form the intended Zed graph. This auditor answers whether each
repository can be inspected and built without crossing a known security or
provenance boundary.

## Read-only contract

The tool performs GitHub `GET` requests only. It inventories active repositories,
pins every read to the exact default-branch commit and recursive tree, and emits
JSON plus Markdown receipts. It never creates branches, commits, issues, pull
requests, secrets, releases, packages, deployments, or cloud resources.

A truncated Git tree or unreadable file is a critical finding. The auditor does
not interpret missing evidence as success.

## Checks

The first contract covers:

- immutable 40-hex GitHub Action pins and explicit workflow permissions;
- privileged `pull_request_target` head checkouts and event-text shell injection;
- network downloads piped directly to a shell;
- committed credential-shaped literals in workflows;
- plaintext environment files in public repositories;
- public backend-only ORM and admin-server repositories;
- `generated/README.md` provenance markers for generated trees;
- valid `.zpkg.toml`, dependency lock presence, and repository identity;
- fail-closed `[interop.flags-2-env]` bindings, including a nonempty
  `[build].outputs` list that retains the package-owned flags contract;
- local `AGENTS.md` and package CI presence.

Findings are `warning`, `error`, or `critical`. Scheduled and manually dispatched
runs fail at a configurable threshold. Pull requests execute deterministic unit
fixtures only; they do not let contributor code use a broader organization token.

A merge push that changes the auditor or its contract also runs the live inventory
with `--fail-on never`. That push receipt establishes a current baseline without
making known fleet debt block the merge that introduced the detector. Incomplete
API evidence still exits with an operational failure, and scheduled/manual runs
continue to enforce their selected severity threshold.

## Local usage

```bash
export GITHUB_TOKEN='from an approved secret manager'
python3 tools/zed_repository_security_audit.py \
  --orgs zed-pkg \
  --fail-on critical \
  --json zed-repository-security-audit.json \
  --markdown zed-repository-security-audit.md
```

Never paste a token into a command transcript, issue, workflow input, repository
file, or generated report.

## Triage semantics

- **Critical** findings represent an unsafe trust boundary, leaked plaintext
  configuration, a public backend repository, or incomplete audit evidence.
- **Error** findings represent a broken deterministic package/workflow contract.
- **Warning** findings require review but may be an intentional transitional
  state.

Fix product-owned findings in the owning repository. Fix shared generation or
workflow defects at their canonical source and regenerate consumers. Do not
mass-edit generated output or use blanket conflict strategies.
