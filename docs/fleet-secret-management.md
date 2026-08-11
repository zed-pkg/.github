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

## Rotation

1. Create a replacement GitHub credential with the minimum repository and
   organization access required by discovery, checkout, PR creation, and issue
   updates.
2. Update `ZED_FLEET_GH_TOKEN` in repository Actions secrets.
3. Run `just env-edit prod` and replace the encrypted dotenv value.
4. Run a manual nightly workflow with `apply=false` before enabling writes.
5. Revoke the previous credential after the canary succeeds.

Never place token values, age private identities, decrypted dotenv files, or
service-account material in Git, pull-request text, issues, Linear, logs, caches,
or artifacts.
