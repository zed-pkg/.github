# Fleet credential management

The nightly cross-organization client audit uses the repository Actions secret
`ZED_FLEET_GH_TOKEN`. A SOPS-encrypted maintenance copy is tracked at
`env/enc/prod.env.enc`; plaintext is never committed.

The repository follows the canonical `ORESoftware/ores-sops` contract:

```text
env/enc/prod.env.enc     # tracked SOPS ciphertext
env/dec/prod.env         # ignored, mode 0600
.env -> env/dec/prod.env # ignored relative managed symlink
```

The SOPS age identity used by trusted automation is stored as the repository
Actions secret `SOPS_AGE_KEY`. The public recipient is recorded in `.sops.yaml`.
The nightly workflow consumes `ZED_FLEET_GH_TOKEN` directly from GitHub Actions;
it never needs to decrypt the maintenance copy during ordinary fleet runs.
Pull-request workflows perform keyless policy validation only; they do not receive
or decrypt production identities.

## Local activation

```sh
# Install an authorized age identity first, for example:
# ~/.config/sops/age/keys.txt (mode 0600)

nix develop
just env-use prod
# .env is now a relative symlink to env/dec/prod.env

just env-status
just env-lock
```

Every decrypting recipe runs `mkdir -p env/dec` first. `ores-sops use` writes to an
owner-only temporary file, validates the dotenv payload, atomically installs the
plaintext, and then atomically manages the root symlink.

For normal changes, edit ciphertext directly:

```sh
just env-edit prod
just env-verify
```

To encrypt an intentionally prepared ignored plaintext file:

```sh
mkdir -p env/dec
$EDITOR env/dec/prod.env
just env-enc prod
just env-lock
```

## Actions-secret bootstrap and canary

`tools/set-zed-fleet-secret.sh` installs the candidate credential through standard
input to `gh secret set`, verifies only the resulting secret name, dispatches the
nightly workflow with `apply=false` by default, resolves the newly created run,
and watches it through terminal completion.

Use the Just recipe from a network-enabled administrative environment:

```sh
just fleet-secret-set false
```

The helper reads `ZED_FLEET_GH_TOKEN` from the environment or, preferably for
interactive use, from a hidden terminal prompt. The value is never written to
disk or passed as a command-line argument. Shell xtrace is rejected.

A separate repository-administration credential may be supplied as
`ZED_FLEET_BOOTSTRAP_GH_TOKEN` (or `GH_TOKEN`). This separation is recommended:
the bootstrap credential needs permission to manage Actions secrets in
`zed-pkg/.github`, while the installed fleet credential should contain only the
cross-organization discovery, checkout, branch, pull-request, and issue access
required by the controller. When a separate bootstrap credential is omitted, the
candidate fleet credential is used for both operations for backwards compatibility.

Useful bounded modes:

```sh
# Set and verify the Actions secret without starting a workflow.
bash tools/set-zed-fleet-secret.sh --apply false --no-run

# Dispatch the read-only canary but return after its run is visible.
bash tools/set-zed-fleet-secret.sh --apply false --no-watch

# Restrict discovery to a small organization canary.
bash tools/set-zed-fleet-secret.sh --apply false --orgs zed-pkg
```

Run the keyless helper tests with:

```sh
just fleet-secret-test
```

## Recovery recipient

The bootstrap creates one age recipient whose private identity is held in the
`SOPS_AGE_KEY` Actions secret. Before treating the ciphertext as an independent
disaster-recovery copy, add a second age or KMS recipient controlled outside this
repository's Actions-secret store, update both exact creation rules in
`.sops.yaml`, and run `sops updatekeys env/enc/prod.env.enc`. Never commit either
private identity.

## Rotation

1. Create a replacement GitHub credential with the minimum repository and
   organization access required by discovery, checkout, PR creation, and issue
   updates.
2. Replace the value in the encrypted maintenance copy with `just env-edit prod`
   and verify it with `just env-verify`.
3. Install the new repository Actions secret with
   `just fleet-secret-set false`; this performs the non-applying canary and waits
   for its terminal result.
4. Inspect the canary artifact and exact repository accounting before enabling an
   applying run.
5. Revoke the previous credential only after the canary succeeds.

Never place token values, age private identities, decrypted dotenv files, or
service-account material in Git, pull-request text, issues, Linear, logs, caches,
or artifacts.
