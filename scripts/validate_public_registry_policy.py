#!/usr/bin/env python3
"""Fail closed when the public registry contract drifts across org docs."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
CANONICAL_WORDING = (
    "Zed supplements ecosystem-native package managers; it does not replace them."
)


def require(path: str, fragments: tuple[str, ...]) -> list[str]:
    text = (ROOT / path).read_text(encoding="utf-8")
    return [f"{path}: missing {fragment!r}" for fragment in fragments if fragment not in text]


def main() -> int:
    failures: list[str] = []
    for path in ("README.md", "profile/README.md", "docs/ORGANIZATION_HANDBOOK.md"):
        failures.extend(require(path, (CANONICAL_WORDING,)))

    failures.extend(
        require(
            "docs/PUBLIC_REGISTRY_RELIABILITY.md",
            (
                CANONICAL_WORDING,
                "`zpkg.net`",
                "`api.zpkg.net`",
                "`registry.zpkg.net`",
                "`app.zpkg.net`",
                "`user.zpkg.net`",
                "Permanent `308` redirect",
                "env/enc/*.env.enc",
                "env/dec/*.env",
                "nix develop --command just env-verify",
                "AWS EC2 Kubernetes",
                "Hetzner Kubernetes",
            ),
        )
    )

    gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
    for fragment in ("/env/dec/", "/env/enc/*", "!/env/enc/*.env.enc"):
        if fragment not in gitignore:
            failures.append(f".gitignore: missing {fragment!r}")

    if failures:
        print("public registry policy validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("public registry policy validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
