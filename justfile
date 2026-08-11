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
