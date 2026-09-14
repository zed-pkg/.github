# Exact-head CI evidence

Fleet changes are mergeable only when verification is bound to the current pull-request head commit.

- Record the repository and exact head SHA alongside every CI or trusted indie-runner result.
- A GitHub Actions job with no executed steps (for example, runner admission or billing refusal) is **non-evidence**: it is neither green nor a source failure.
- Do not publish a terminal success result for a superseded or stale SHA.
- Keep reproducibility and security gates fail-closed. Do not remove `--locked`, suppress dependency audits, or ignore required checks merely to make a branch mergeable.
- Merge using the expected head SHA so a moved branch cannot reuse older evidence.
- For TypeSpec and authored JSON Schema peer authorities, retain TJSV parity evidence for the exact head; generated schemas are projections, not replacement authorities.
- Trusted local/indie-runner evidence must record the exact SHA, commands executed, and terminal results with the same standard as hosted CI.

When a check cannot start, fix runner/admission capacity or obtain equivalent exact-head execution; do not reinterpret the absence of execution as success.
