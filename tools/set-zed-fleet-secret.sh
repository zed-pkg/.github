#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO="${ZED_FLEET_REPO:-zed-pkg/.github}"
SECRET_NAME="${ZED_FLEET_SECRET_NAME:-ZED_FLEET_GH_TOKEN}"
WORKFLOW="${ZED_FLEET_WORKFLOW:-nightly-clients-fleet-hardening.yml}"
REF="${ZED_FLEET_REF:-main}"
APPLY="false"
ORGS=""
RUN_WORKFLOW="true"
WATCH_WORKFLOW="true"

usage() {
  cat <<'USAGE'
Usage: set-zed-fleet-secret.sh [options]

Securely installs the cross-organization GitHub credential as an Actions secret
and optionally dispatches a bounded fleet canary.

Options:
  --apply true|false    Workflow apply mode (default: false)
  --orgs CSV            Optional organization override for the canary
  --repo OWNER/REPO     Secret/workflow repository (default: zed-pkg/.github)
  --secret-name NAME    Actions secret name (default: ZED_FLEET_GH_TOKEN)
  --workflow FILE       Workflow file/name to dispatch
  --ref REF             Workflow ref (default: main)
  --no-run              Set and verify the secret without dispatching a workflow
  --no-watch            Dispatch but do not wait for terminal completion
  -h, --help            Show this help

Credential input:
  ZED_FLEET_GH_TOKEN contains the credential being installed. When unset, an
  interactive hidden prompt is used. ZED_FLEET_BOOTSTRAP_GH_TOKEN (or GH_TOKEN)
  may hold a separate repository-administration credential. If neither is set,
  the fleet credential is used for both operations.

The candidate secret is sent to `gh secret set` over standard input. It is never
written to disk or passed as a command-line argument.
USAGE
}

while (($#)); do
  case "$1" in
    --apply)
      [[ $# -ge 2 ]] || { echo "--apply requires true or false" >&2; exit 2; }
      APPLY="$2"
      [[ "$APPLY" == "true" || "$APPLY" == "false" ]] || {
        echo "--apply must be true or false" >&2
        exit 2
      }
      shift 2
      ;;
    --orgs)
      [[ $# -ge 2 ]] || { echo "--orgs requires a value" >&2; exit 2; }
      ORGS="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "--repo requires OWNER/REPO" >&2; exit 2; }
      REPO="$2"
      shift 2
      ;;
    --secret-name)
      [[ $# -ge 2 ]] || { echo "--secret-name requires a value" >&2; exit 2; }
      SECRET_NAME="$2"
      shift 2
      ;;
    --workflow)
      [[ $# -ge 2 ]] || { echo "--workflow requires a value" >&2; exit 2; }
      WORKFLOW="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || { echo "--ref requires a value" >&2; exit 2; }
      REF="$2"
      shift 2
      ;;
    --no-run)
      RUN_WORKFLOW="false"
      shift
      ;;
    --no-watch)
      WATCH_WORKFLOW="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$-" in
  *x*)
    echo "Refusing to handle a secret while shell xtrace is enabled" >&2
    exit 2
    ;;
esac

[[ "$REPO" == */* && "$REPO" != */*/* ]] || {
  echo "--repo must use OWNER/REPO form" >&2
  exit 2
}
[[ "$SECRET_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
  echo "Invalid Actions secret name: $SECRET_NAME" >&2
  exit 2
}

command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI (gh) is required: https://cli.github.com/" >&2
  exit 1
}

FLEET_TOKEN="${ZED_FLEET_GH_TOKEN:-}"
if [[ -z "$FLEET_TOKEN" ]]; then
  [[ -t 0 ]] || {
    echo "ZED_FLEET_GH_TOKEN is unset and no interactive terminal is available" >&2
    exit 1
  }
  read -r -s -p "GitHub token for the cross-organization fleet job: " FLEET_TOKEN
  printf '\n' >&2
fi
[[ -n "$FLEET_TOKEN" ]] || { echo "Token was empty" >&2; exit 1; }
[[ "$FLEET_TOKEN" != *$'\n'* && "$FLEET_TOKEN" != *$'\r'* ]] || {
  echo "Token must be a single line" >&2
  exit 1
}

BOOTSTRAP_TOKEN="${ZED_FLEET_BOOTSTRAP_GH_TOKEN:-${GH_TOKEN:-$FLEET_TOKEN}}"
[[ -n "$BOOTSTRAP_TOKEN" ]] || { echo "Bootstrap token was empty" >&2; exit 1; }

GH_CONFIG_TMP="$(mktemp -d)"
cleanup() {
  FLEET_TOKEN=""
  BOOTSTRAP_TOKEN=""
  unset FLEET_TOKEN BOOTSTRAP_TOKEN ZED_FLEET_GH_TOKEN \
    ZED_FLEET_BOOTSTRAP_GH_TOKEN GH_TOKEN
  rm -rf "$GH_CONFIG_TMP"
}
trap cleanup EXIT HUP INT TERM

# Remove inherited secret-bearing variables after copying them into shell memory.
unset ZED_FLEET_GH_TOKEN ZED_FLEET_BOOTSTRAP_GH_TOKEN GH_TOKEN
export GH_CONFIG_DIR="$GH_CONFIG_TMP"

if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  printf '::add-mask::%s\n' "$FLEET_TOKEN"
  if [[ "$BOOTSTRAP_TOKEN" != "$FLEET_TOKEN" ]]; then
    printf '::add-mask::%s\n' "$BOOTSTRAP_TOKEN"
  fi
fi

run_gh() {
  GH_TOKEN="$BOOTSTRAP_TOKEN" gh "$@"
}

login="$(run_gh api user --jq .login)"
resolved_repo="$(run_gh api "repos/$REPO" --jq .full_name)"
[[ "$resolved_repo" == "$REPO" ]] || {
  echo "Unexpected repository: $resolved_repo" >&2
  exit 1
}
printf 'Authenticated as %s; repository access confirmed for %s.\n' "$login" "$resolved_repo"

# This probe returns secret metadata only; GitHub never returns secret values.
run_gh api "repos/$REPO/actions/secrets?per_page=1" >/dev/null

# `gh secret set` encrypts locally and reads the candidate value from stdin.
printf '%s' "$FLEET_TOKEN" | run_gh secret set "$SECRET_NAME" --repo "$REPO" --app actions

run_gh secret list --repo "$REPO" --app actions --json name \
  --jq 'map(select(.name == "'"$SECRET_NAME"'")) | if length == 1 then .[0].name else empty end' \
  | grep -qx "$SECRET_NAME" || {
    echo "Secret write returned without a matching secret-list entry" >&2
    exit 1
  }
printf 'Verified repository Actions secret name: %s\n' "$SECRET_NAME"

if [[ "$RUN_WORKFLOW" != "true" ]]; then
  exit 0
fi

previous_id="$(run_gh run list --repo "$REPO" --workflow "$WORKFLOW" \
  --event workflow_dispatch --branch "$REF" --limit 1 --json databaseId \
  --jq '.[0].databaseId // empty' 2>/dev/null || true)"

run_gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$REF" \
  -f "apply=$APPLY" -f "orgs=$ORGS"
printf 'Workflow dispatch accepted for %s at %s (apply=%s).\n' "$WORKFLOW" "$REF" "$APPLY"

run_id=""
for _ in $(seq 1 30); do
  candidate="$(run_gh run list --repo "$REPO" --workflow "$WORKFLOW" \
    --event workflow_dispatch --branch "$REF" --limit 1 --json databaseId \
    --jq '.[0].databaseId // empty' 2>/dev/null || true)"
  if [[ -n "$candidate" && "$candidate" != "$previous_id" ]]; then
    run_id="$candidate"
    break
  fi
  sleep 1
done

[[ -n "$run_id" ]] || {
  echo "No new workflow_dispatch run became visible within 30 seconds" >&2
  exit 1
}

run_url="$(run_gh run view "$run_id" --repo "$REPO" --json url --jq .url 2>/dev/null || true)"
if [[ -n "$run_url" ]]; then
  printf 'Workflow run: %s\n' "$run_url"
else
  printf 'Workflow run id: %s\n' "$run_id"
fi

if [[ "$WATCH_WORKFLOW" == "true" ]]; then
  run_gh run watch "$run_id" --repo "$REPO" --compact --exit-status
fi
