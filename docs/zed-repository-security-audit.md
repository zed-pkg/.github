# Zed repository security audit

`tools/zed_repository_security_audit.py` provides the stable receipt engine and
`tools/zed_repository_security_policy.py` applies the current Zed repository
conventions. Together they complement the package-family checks in
`tools/zed_fleet_audit.py`: the family auditor validates producer/consumer
shape, while the security audit asks whether every exact default-branch tree can
be inspected and built without crossing a known trust or provenance boundary.

## Read-only contract

The tools perform GitHub `GET` requests only. They inventory active repositories,
pin every read to the exact default-branch commit and recursive tree, and emit
JSON plus Markdown receipts. They never create branches, commits, issues, pull
requests, secrets, releases, packages, deployments, or cloud resources.

A truncated Git tree or unreadable file is a critical finding. The auditor does
not interpret missing evidence as success.

## Checks

The contract covers:

- immutable 40-hex GitHub Action pins and explicit workflow permissions;
- privileged `pull_request_target` head checkouts and event-text shell injection;
- network downloads piped directly to a shell;
- committed credential-shaped literals in workflows;
- plaintext environment files in public repositories;
- content-aware public `.envrc` inspection: safe flake/tool activation is
  permitted, while plaintext dotenv/source operations, dynamic environment
  sources, committed sensitive assignments, malformed syntax, and unreadable
  content remain findings;
- public backend-only ORM and admin-server repositories;
- `generated/README.md` provenance markers for generated trees;
- valid `.zpkg.toml`, dependency lock presence, and repository identity;
- fail-closed `[interop.flags-2-env]` bindings, including a nonempty
  `[build].outputs` list that retains the package-owned flags contract;
- root-level `AGENTS.md` or `agents.md`, consistent with the repository policy
  hierarchy, and package CI presence.

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
python3 tools/zed_repository_security_policy.py \
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
