set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

default:
    @just --list

# Create the canonical env layout and SOPS policy. This never creates tracked plaintext.
env-init:
    mkdir -p env/dec
    nix develop --command ores-sops init

# Decrypt dev or prod, create env/dec/<profile>.env mode 0600, and atomically link .env.
env-use profile="prod":
    mkdir -p env/dec
    nix develop --command ores-sops use "{{profile}}"

# Alias for callers that prefer enc/dec terminology.
env-dec profile="prod":
    mkdir -p env/dec
    nix develop --command ores-sops use "{{profile}}"

# Encrypt the selected ignored plaintext file into env/enc/<profile>.env.enc.
env-enc profile="prod":
    mkdir -p env/dec
    nix develop --command ores-sops encrypt "{{profile}}"

# Edit ciphertext directly; preferred for ordinary secret changes.
env-edit profile="prod":
    mkdir -p env/dec
    nix develop --command ores-sops edit "{{profile}}"

env-refresh:
    mkdir -p env/dec
    nix develop --command ores-sops refresh

env-status:
    mkdir -p env/dec
    nix develop --command ores-sops status

env-verify:
    mkdir -p env/dec
    nix develop --command ores-sops verify

# Remove managed plaintext and the managed root .env symlink.
env-lock:
    mkdir -p env/dec
    nix develop --command ores-sops lock

# Install ZED_FLEET_GH_TOKEN and run a non-applying canary by default.
fleet-secret-set apply="false":
    bash tools/set-zed-fleet-secret.sh --apply "{{apply}}"

# Keyless validation for the secret bootstrap helper.
fleet-secret-test:
    bash -n tools/set-zed-fleet-secret.sh
    python -m unittest -v tools/test_set_zed_fleet_secret.py
