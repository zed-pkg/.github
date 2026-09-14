# Immutable release provenance

A declared version is not sufficient evidence that an artifact or interface is releasable.

- Release evidence binds the exact source commit, immutable version tag, package identity, artifact digest, and generated/projection inputs.
- Authored TypeSpec and authored JSON Schema Draft 2020-12 remain independent peer authorities; interface releases require fail-closed TJSV parity evidence before tagging or publishing.
- Version tags and release references are immutable. Do not force-move a release tag to make downstream checks pass.
- Zed packages must survive a clean registry readback and deterministic `--frozen` replay before consumers advance to the new version.
- Downstream automation promotes only immutable provenance evidence. A newer default branch, mutable branch name, or generated artifact without its source identity is not release proof.
- Provenance and environment manifests may record key names, types, requiredness, hashes, digests, and source identities, but never secret values.
- A failed security, parity, reproducibility, or provenance gate blocks promotion rather than being converted into advisory success.

Consumers should be able to reconstruct why a version was admitted without consulting mutable branch state.
