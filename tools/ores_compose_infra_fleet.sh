#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${COMPOSE_SHA:?COMPOSE_SHA is required}"

MAX_REPOS="${MAX_REPOS:-120}"
MAX_PARALLEL="${MAX_PARALLEL:-6}"
RUN_BRANCH="${RUN_BRANCH:-automation/ores-compose-infra-20260914}"
WORK_ROOT="${RUNNER_TEMP:-/tmp}/ores-compose-infra-fleet-${GITHUB_RUN_ID:-local}"
RESULT_ROOT="$WORK_ROOT/results"
COMPOSE_DIR="$WORK_ROOT/ores-compose"
VALIDATOR_DIR="$WORK_ROOT/validator"
SUMMARY="$WORK_ROOT/summary.tsv"

mkdir -p "$RESULT_ROOT"
printf 'repository\tmonorepo\tmonorepo_sha\tstatus\tpr\tdetail\n' > "$SUMMARY"

gh auth setup-git >/dev/null

echo "::group::Verify exact ores-compose runtime candidate"
git clone --filter=blob:none https://github.com/ORESoftware/ores-compose.git "$COMPOSE_DIR"
git -C "$COMPOSE_DIR" fetch --no-tags origin "$COMPOSE_SHA"
git -C "$COMPOSE_DIR" checkout --detach "$COMPOSE_SHA"
test "$(git -C "$COMPOSE_DIR" rev-parse HEAD)" = "$COMPOSE_SHA"
git -C "$COMPOSE_DIR" diff --quiet
cargo +stable fmt --manifest-path "$COMPOSE_DIR/Cargo.toml" --all --check
cargo +stable clippy --manifest-path "$COMPOSE_DIR/Cargo.toml" --all-targets --locked -- -D warnings
cargo +stable test --manifest-path "$COMPOSE_DIR/Cargo.toml" --all-targets --locked

echo "::endgroup::"

mkdir -p "$VALIDATOR_DIR/src"
cat > "$VALIDATOR_DIR/Cargo.toml" <<EOF
[package]
name = "ores-compose-fleet-validator"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
ores-compose = { path = "$COMPOSE_DIR" }
EOF
cat > "$VALIDATOR_DIR/src/main.rs" <<'EOF'
use std::env;
use std::fs;

fn main() {
    let path = env::args().nth(1).expect("manifest path");
    let input = fs::read_to_string(&path).expect("read manifest");
    let project = ores_compose::parse_compose_yaml(&input).expect("valid .ores-compose.yaml");
    let source = project.source.as_ref().expect("infra manifests must pin source");
    assert_eq!(source.commit.len(), 40, "source must use a full SHA");
    assert!(project.services().count() > 0, "manifest must declare services");
}
EOF
cargo +stable build --quiet --manifest-path "$VALIDATOR_DIR/Cargo.toml"
VALIDATOR_BIN="$VALIDATOR_DIR/target/debug/ores-compose-fleet-validator"

sanitize() {
  printf '%s' "$1" | tr '/.' '__'
}

project_label() {
  local base="$1"
  printf '%s' "$base" \
    | tr '[:upper:]_.' '[:lower:]--' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

find_monorepo() {
  local owner="$1" infra_name="$2" base candidate
  base="${infra_name%-infra}"
  base="${base%.infra}"
  for candidate in "${base}-monorepo" "${owner,,}-monorepo"; do
    if gh repo view "$owner/$candidate" --json name,isArchived --jq 'select(.isArchived == false) | .name' 2>/dev/null | grep -qx "$candidate"; then
      printf '%s/%s\n' "$owner" "$candidate"
      return 0
    fi
  done

  mapfile -t matches < <(
    gh repo list "$owner" --limit 300 --json name,isArchived \
      --jq '.[] | select(.isArchived == false and (.name | endswith("-monorepo"))) | .name' 2>/dev/null || true
  )
  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s/%s\n' "$owner" "${matches[0]}"
    return 0
  fi
  return 1
}

server_kind() {
  local name="$1"
  case "$name" in
    *-admin-api-server.rs) printf 'admin-api\n' ;;
    *-admin-web-server.rs) printf 'admin-web\n' ;;
    *-api-server.rs) printf 'api\n' ;;
    *-web-server.rs) printf 'web\n' ;;
    *) return 1 ;;
  esac
}

port_for_kind() {
  case "$1" in
    api) printf '18080\n' ;;
    web) printf '18081\n' ;;
    admin-api) printf '18082\n' ;;
    admin-web) printf '18083\n' ;;
    *) return 1 ;;
  esac
}

append_environment() {
  local service_dir="$1" port="$2" output="$3"
  local evidence=""
  [[ -f "$service_dir/.cli-flags.toml" ]] && evidence+="$(cat "$service_dir/.cli-flags.toml")"$'\n'
  if [[ -d "$service_dir/src" ]]; then
    evidence+="$(grep -R -h -E 'BIND_ADDR|SERVICE_HOST|PORT' "$service_dir/src" --include='*.rs' 2>/dev/null | head -200 || true)"
  fi

  if grep -q 'BIND_ADDR' <<<"$evidence"; then
    cat >> "$output" <<EOF
    environment:
      BIND_ADDR:
        value: "127.0.0.1:${port}"
EOF
    return 0
  fi
  if grep -q 'SERVICE_HOST' <<<"$evidence" && grep -q 'PORT' <<<"$evidence"; then
    cat >> "$output" <<EOF
    environment:
      SERVICE_HOST:
        value: "127.0.0.1"
      PORT:
        value: "${port}"
EOF
    return 0
  fi
  if grep -q 'PORT' <<<"$evidence"; then
    cat >> "$output" <<EOF
    environment:
      PORT:
        value: "${port}"
EOF
    return 0
  fi
  return 1
}

process_repo() {
  set +e
  local infra="$1" default_branch="$2"
  local owner="${infra%%/*}" infra_name="${infra#*/}"
  local result="$RESULT_ROOT/$(sanitize "$infra").tsv"
  local mono mono_branch mono_sha base label mono_dir infra_dir manifest server_count=0 detail=""

  if [[ "$owner" == *-test || "$infra_name" == *-test* ]]; then
    printf '%s\t\t\tskipped\t\ttest organization/repository\n' "$infra" > "$result"
    return 0
  fi

  mono="$(find_monorepo "$owner" "$infra_name")"
  if [[ -z "$mono" ]]; then
    printf '%s\t\t\tblocked\t\tno unambiguous paired *-monorepo\n' "$infra" > "$result"
    return 0
  fi

  mono_branch="$(gh repo view "$mono" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
  mono_sha="$(gh api "repos/$mono/commits/$mono_branch" --jq '.sha' 2>/dev/null)"
  if [[ ! "$mono_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf '%s\t%s\t\tblocked\t\tmonorepo default-branch SHA unavailable\n' "$infra" "$mono" > "$result"
    return 0
  fi

  local repo_root="$WORK_ROOT/repos/$(sanitize "$infra")"
  mono_dir="$repo_root/mono"
  infra_dir="$repo_root/infra"
  mkdir -p "$repo_root"

  if ! gh repo clone "$mono" "$mono_dir" -- --filter=blob:none --no-checkout >/dev/null 2>&1; then
    printf '%s\t%s\t%s\tblocked\t\tmonorepo clone failed\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  fi
  git -C "$mono_dir" checkout --detach "$mono_sha" >/dev/null 2>&1 || {
    printf '%s\t%s\t%s\tblocked\t\tmonorepo exact SHA checkout failed\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  }
  if [[ ! -f "$mono_dir/.gitmodules" ]]; then
    printf '%s\t%s\t%s\tblocked\t\tmonorepo has no .gitmodules; layout needs explicit adapter\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  fi

  mapfile -t server_paths < <(
    git -C "$mono_dir" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
      | awk '{print $2}' \
      | grep -E '(-admin-api-server\.rs|-admin-web-server\.rs|-api-server\.rs|-web-server\.rs)$' \
      | sort -u
  )
  if [[ "${#server_paths[@]}" -eq 0 ]]; then
    printf '%s\t%s\t%s\tblocked\t\tno standard Rust server submodules discovered\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  fi

  base="${infra_name%-infra}"
  base="${base%.infra}"
  label="$(project_label "$base")"
  manifest="$repo_root/.ores-compose.yaml"
  cat > "$manifest" <<EOF
schema_version: ores.compose.v1
project: ${label}
allow_lazy_start: true
source:
  repository: https://github.com/${mono}.git
  commit: ${mono_sha}
  recurse_submodules: true
services:
EOF

  declare -A seen_kind=()
  for path in "${server_paths[@]}"; do
    local name kind port service_dir locked_args
    name="${path##*/}"
    kind="$(server_kind "$name")" || continue
    if [[ -n "${seen_kind[$kind]:-}" ]]; then
      detail="duplicate ${kind} server submodules"
      server_count=0
      break
    fi
    seen_kind[$kind]=1
    port="$(port_for_kind "$kind")"

    if ! git -C "$mono_dir" submodule update --init "$path" >/dev/null 2>&1; then
      detail="failed to materialize submodule ${path}"
      server_count=0
      break
    fi
    service_dir="$mono_dir/$path"
    if [[ ! -f "$service_dir/Cargo.toml" ]]; then
      detail="${path} is not a Cargo service"
      server_count=0
      break
    fi
    if ! grep -R -q -F '"/readyz"' "$service_dir/src" --include='*.rs' 2>/dev/null; then
      detail="${path} has no /readyz route"
      server_count=0
      break
    fi

    if [[ -f "$service_dir/Cargo.lock" ]]; then
      locked_args=', "--locked"'
    else
      locked_args=''
    fi

    cat >> "$manifest" <<EOF
  ${kind}:
    runtime: host
    command: ["cargo", "run"${locked_args}]
    build:
      - ["cargo", "build"${locked_args}]
    working_dir: "${path}"
    replicas: 1
EOF
    if ! append_environment "$service_dir" "$port" "$manifest"; then
      detail="${path} has no supported local bind environment contract"
      server_count=0
      break
    fi
    cat >> "$manifest" <<EOF
    healthcheck:
      command: ["curl", "--fail", "--silent", "--show-error", "http://127.0.0.1:${port}/readyz"]
      interval_ms: 1000
      timeout_ms: 750
      retries: 20
EOF
    server_count=$((server_count + 1))
  done

  if [[ "$server_count" -eq 0 ]]; then
    printf '%s\t%s\t%s\tblocked\t\t%s\n' "$infra" "$mono" "$mono_sha" "${detail:-no admissible services}" > "$result"
    return 0
  fi

  if ! "$VALIDATOR_BIN" "$manifest" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\tblocked\t\tgenerated manifest rejected by exact ores-compose candidate\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  fi

  if ! gh repo clone "$infra" "$infra_dir" -- --filter=blob:none >/dev/null 2>&1; then
    printf '%s\t%s\t%s\tblocked\t\tinfra clone failed\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  fi
  git -C "$infra_dir" checkout "$default_branch" >/dev/null 2>&1 || true
  local base_sha branch="$RUN_BRANCH"
  base_sha="$(git -C "$infra_dir" rev-parse HEAD)"
  if git -C "$infra_dir" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    branch="${RUN_BRANCH}-${base_sha:0:8}"
  fi
  git -C "$infra_dir" checkout -b "$branch" >/dev/null 2>&1 || {
    printf '%s\t%s\t%s\tblocked\t\tcould not create rollout branch\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  }

  cp "$manifest" "$infra_dir/.ores-compose.yaml"
  touch "$infra_dir/.gitignore"
  if ! grep -qxF '.ores/checkouts/' "$infra_dir/.gitignore"; then
    printf '\n# ores-compose content-addressed local source checkouts\n.ores/checkouts/\n' >> "$infra_dir/.gitignore"
  fi

  if [[ -f "$mono_dir/.ores-compose.yaml" ]]; then
    detail="; paired monorepo currently has duplicate .ores-compose.yaml and needs follow-up removal after infra authority lands"
  fi

  git -C "$infra_dir" add .ores-compose.yaml .gitignore
  if git -C "$infra_dir" diff --cached --quiet; then
    printf '%s\t%s\t%s\tno-change\t\tmanifest already current%s\n' "$infra" "$mono" "$mono_sha" "$detail" > "$result"
    return 0
  fi
  git -C "$infra_dir" -c user.name='ORESoftware' -c user.email='alexander.d.mills@gmail.com' \
    commit -m 'chore: make infra the ores-compose authority' >/dev/null 2>&1 || {
      printf '%s\t%s\t%s\tblocked\t\tcommit failed\n' "$infra" "$mono" "$mono_sha" > "$result"
      return 0
    }
  if ! git -C "$infra_dir" push origin "$branch" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\tblocked\t\tbranch push failed\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  fi

  local pr_url
  pr_url="$(gh pr create --repo "$infra" --head "$branch" --base "$default_branch" \
    --title 'chore: make infra the ores-compose authority' \
    --body "Adds the canonical root \`.ores-compose.yaml\` for local system activation. The manifest pins \`${mono}@${mono_sha}\`, materializes that exact monorepo revision (including recorded submodule SHAs), assigns distinct loopback binds to discovered Rust server services, and gates each service on \`/readyz\`. Generated source lives under ignored \`.ores/checkouts/\`; no compose manifest is added to the monorepo. Validated against \`ORESoftware/ores-compose@${COMPOSE_SHA}\`.${detail}" 2>/dev/null)"
  if [[ -z "$pr_url" ]]; then
    printf '%s\t%s\t%s\tblocked\t\tPR creation failed\n' "$infra" "$mono" "$mono_sha" > "$result"
    return 0
  fi
  gh pr edit "$pr_url" --add-reviewer the1mills >/dev/null 2>&1 || true
  printf '%s\t%s\t%s\tpr-open\t%s\t%d services%s\n' "$infra" "$mono" "$mono_sha" "$pr_url" "$server_count" "$detail" > "$result"
  return 0
}

export -f sanitize project_label find_monorepo server_kind port_for_kind append_environment process_repo
export GH_TOKEN COMPOSE_SHA MAX_REPOS MAX_PARALLEL RUN_BRANCH WORK_ROOT RESULT_ROOT VALIDATOR_BIN

CANDIDATES="$WORK_ROOT/candidates.tsv"
gh api --method GET /user/repos \
  -f per_page=100 \
  -f affiliation='owner,collaborator,organization_member' \
  --paginate \
  --jq '.[] | select(.archived == false and .disabled == false) | select((.name | endswith("-infra")) or (.name | endswith(".infra"))) | [.full_name, .default_branch] | @tsv' \
  | sort -u \
  | head -n "$MAX_REPOS" > "$CANDIDATES"

candidate_count="$(wc -l < "$CANDIDATES" | tr -d ' ')"
echo "Discovered ${candidate_count} active infra repositories"

if [[ "$candidate_count" -gt 0 ]]; then
  xargs -r -P "$MAX_PARALLEL" -n 2 bash -c 'process_repo "$1" "$2"' _ < "$CANDIDATES"
fi

while IFS= read -r result; do
  tail -n +1 "$result" >> "$SUMMARY"
done < <(find "$RESULT_ROOT" -type f -name '*.tsv' | sort)

open_count="$(awk -F '\t' '$4 == "pr-open" {n++} END {print n+0}' "$SUMMARY")"
blocked_count="$(awk -F '\t' '$4 == "blocked" {n++} END {print n+0}' "$SUMMARY")"
no_change_count="$(awk -F '\t' '$4 == "no-change" {n++} END {print n+0}' "$SUMMARY")"

echo "PRs opened: $open_count; blocked: $blocked_count; no-change: $no_change_count"

# Exact-head merge pass. A PR must expose at least one completed successful
# check-run at the exact head. No-check and red/queued/zero-step-style outcomes
# are never interpreted as merge evidence. The REST merge call carries the exact
# SHA so a concurrent push invalidates the attempt rather than merging stale code.
while IFS=$'\t' read -r repo mono mono_sha status pr_url detail; do
  [[ "$status" == "pr-open" ]] || continue
  number="${pr_url##*/}"
  for _ in $(seq 1 12); do
    head_sha="$(gh pr view "$pr_url" --json headRefOid --jq '.headRefOid' 2>/dev/null)"
    [[ -n "$head_sha" ]] || break
    checks_json="$(gh api "repos/$repo/commits/$head_sha/check-runs" 2>/dev/null || true)"
    total="$(jq -r '.total_count // 0' <<<"$checks_json" 2>/dev/null)"
    pending="$(jq -r '[.check_runs[]? | select(.status != "completed")] | length' <<<"$checks_json" 2>/dev/null)"
    bad="$(jq -r '[.check_runs[]? | select(.status == "completed" and (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped"))] | length' <<<"$checks_json" 2>/dev/null)"
    if [[ "$total" -gt 0 && "$pending" -eq 0 ]]; then
      if [[ "$bad" -eq 0 ]]; then
        if gh api --method PUT "repos/$repo/pulls/$number/merge" \
          -f sha="$head_sha" -f merge_method=merge \
          --jq '.merged' 2>/dev/null | grep -qx true; then
          sed -i "s#^${repo}\t${mono}\t${mono_sha}\tpr-open\t${pr_url}\t#${repo}\t${mono}\t${mono_sha}\tmerged\t${pr_url}\t#" "$SUMMARY" || true
        fi
      fi
      break
    fi
    sleep 20
  done
done < <(tail -n +2 "$SUMMARY")

merged_count="$(awk -F '\t' '$4 == "merged" {n++} END {print n+0}' "$SUMMARY")"
echo "Merged with exact-head successful check evidence: $merged_count"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '## ores-compose infra fleet rollout'
    echo
    echo "- Exact ores-compose candidate: \`${COMPOSE_SHA}\`"
    echo "- Infra repositories audited: **${candidate_count}**"
    echo "- PRs opened: **${open_count}**"
    echo "- PRs merged with exact-head checks: **${merged_count}**"
    echo "- Blocked for layout/readiness/source reasons: **${blocked_count}**"
    echo "- Already current: **${no_change_count}**"
    echo
    echo '```tsv'
    cat "$SUMMARY"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

cp "$SUMMARY" "${GITHUB_WORKSPACE:-.}/ores-compose-infra-fleet-summary.tsv"
