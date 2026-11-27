#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ZED_BIN:?ZED_BIN must point at current-tip zed-cli}"

MIN_REPOS="${MIN_REPOS:-100}"
MAX_REPOS="${MAX_REPOS:-220}"
MAX_PARALLEL="${MAX_PARALLEL:-10}"
RUN_BRANCH="${RUN_BRANCH:-automation/zed-tip-sync-20260914}"
REPORT_DIR="${REPORT_DIR:-$PWD/artifacts/zed-tip-sync}"
SELECTED_SEED="${SELECTED_SEED:-tools/zed-tip-selected-20260914.txt}"
PACKAGE_SEED="${PACKAGE_SEED:-tools/zed-tip-package-repos-20260914.txt}"
REPORT_DIR="$(mkdir -p "$REPORT_DIR" && cd "$REPORT_DIR" && pwd)"
RESULT_DIR="$REPORT_DIR/results"
DIAG_DIR="$REPORT_DIR/diagnostics"
PKG_WORK="$REPORT_DIR/package-work"
mkdir -p "$RESULT_DIR" "$DIAG_DIR" "$PKG_WORK"

log() { printf '[zed-tip-quota-light] %s\n' "$*"; }
warn() { printf '[zed-tip-quota-light] WARN: %s\n' "$*" >&2; }

[[ -f "$SELECTED_SEED" ]] || { echo "missing selected seed: $SELECTED_SEED" >&2; exit 41; }
[[ -f "$PACKAGE_SEED" ]] || { echo "missing package seed: $PACKAGE_SEED" >&2; exit 41; }

# Configure the Git credential helper once. Workers never mutate global config.
gh auth setup-git >/dev/null

clone_default() {
  local repo="$1" dest="$2"
  rm -rf "$dest"
  if git clone --quiet --filter=blob:none --depth=1 --branch main "https://github.com/$repo.git" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -rf "$dest"
  git clone --quiet --filter=blob:none --depth=1 "https://github.com/$repo.git" "$dest" 2>/dev/null
}

manifest_identity() {
  local manifest="$1"
  ruby - "$manifest" <<'RUBY'
path = ARGV[0]
section = nil
org = name = version = repo_url = nil
File.foreach(path) do |line|
  if (m = line.match(/^\s*\[([^\]]+)\]/))
    section = m[1]
    next
  end
  if section == 'package'
    org = $1 if line =~ /^\s*org\s*=\s*"([^"]+)"/
    name = $1 if line =~ /^\s*name\s*=\s*"([^"]+)"/
    version = $1 if line =~ /^\s*version\s*=\s*"([^"]+)"/
  elsif section == 'package.repository'
    repo_url = $1 if line =~ /^\s*url\s*=\s*"([^"]+)"/
  end
end
exit 2 unless org && name && version
puts ["#{org}/#{name}", version, repo_url.to_s].join("\t")
RUBY
}

canonical_repo_from_url() {
  local url="$1"
  [[ -n "$url" ]] || return 1
  sed -E 's#^https://github\.com/##; s#^git@github\.com:##; s#\.git/?$##; s#/$##' <<<"$url"
}

log 'building canonical package authority map from Git transport only'
: >"$REPORT_DIR/packages.tsv"
: >"$REPORT_DIR/package-clone-failures.tsv"
declare -A seen_canonical=()
while IFS= read -r seed_repo; do
  [[ "$seed_repo" == */* ]] || continue
  seed_key="${seed_repo//\//__}"
  seed_dir="$PKG_WORK/seed-$seed_key"
  if ! clone_default "$seed_repo" "$seed_dir"; then
    printf '%s\tseed-clone-failed\n' "$seed_repo" >>"$REPORT_DIR/package-clone-failures.tsv"
    continue
  fi
  [[ -f "$seed_dir/.zpkg.toml" ]] || continue
  seed_identity="$(manifest_identity "$seed_dir/.zpkg.toml" 2>/dev/null || true)"
  [[ -n "$seed_identity" ]] || continue
  repo_url="$(cut -f3 <<<"$seed_identity")"
  canonical="$seed_repo"
  if declared="$(canonical_repo_from_url "$repo_url" 2>/dev/null)" && [[ "$declared" == */* ]]; then
    canonical="$declared"
  fi
  canonical_lc="${canonical,,}"
  [[ -z "${seen_canonical[$canonical_lc]:-}" ]] || continue
  seen_canonical[$canonical_lc]=1

  canonical_dir="$seed_dir"
  if [[ "${canonical,,}" != "${seed_repo,,}" ]]; then
    canonical_key="${canonical//\//__}"
    canonical_dir="$PKG_WORK/canonical-$canonical_key"
    if ! clone_default "$canonical" "$canonical_dir"; then
      printf '%s\tcanonical-clone-failed\t%s\n' "$seed_repo" "$canonical" >>"$REPORT_DIR/package-clone-failures.tsv"
      continue
    fi
  fi
  [[ -f "$canonical_dir/.zpkg.toml" ]] || {
    printf '%s\tcanonical-manifest-missing\t%s\n' "$seed_repo" "$canonical" >>"$REPORT_DIR/package-clone-failures.tsv"
    continue
  }
  identity="$(manifest_identity "$canonical_dir/.zpkg.toml" 2>/dev/null || true)"
  [[ -n "$identity" ]] || {
    printf '%s\tcanonical-manifest-invalid\t%s\n' "$seed_repo" "$canonical" >>"$REPORT_DIR/package-clone-failures.tsv"
    continue
  }
  coordinate="$(cut -f1 <<<"$identity")"
  version="$(cut -f2 <<<"$identity")"
  head_sha="$(git -C "$canonical_dir" rev-parse HEAD)"
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || continue
  printf '%s\t%s\t%s\t%s\n' "$coordinate" "$canonical" "$version" "$head_sha" >>"$REPORT_DIR/packages.tsv"
done <"$PACKAGE_SEED"
sort -fu "$REPORT_DIR/packages.tsv" -o "$REPORT_DIR/packages.tsv"
jq -Rn '[inputs | split("\t") | select(length==4) | {coordinate:.[0],repo:.[1],version:.[2],sha:.[3]}]' \
  <"$REPORT_DIR/packages.tsv" >"$REPORT_DIR/packages.json"
package_count="$(wc -l <"$REPORT_DIR/packages.tsv" | tr -d ' ')"
log "canonical authority map contains $package_count package roots"

mapfile -t selected < <(grep -E '^[^[:space:]]+/[^[:space:]]+$' "$SELECTED_SEED" | awk '!seen[tolower($0)]++' | head -n "$MAX_REPOS")
selected_count="${#selected[@]}"
(( selected_count >= MIN_REPOS )) || {
  echo "Need at least $MIN_REPOS selected repositories; found $selected_count" >&2
  exit 42
}
printf '%s\n' "${selected[@]}" >"$REPORT_DIR/selected.txt"

export RUN_BRANCH RESULT_DIR DIAG_DIR ZED_BIN GH_TOKEN ZED_PKG_TOKEN
PACKAGE_MAP="$REPORT_DIR/packages.json"
export PACKAGE_MAP
rm -f "$RESULT_DIR"/*.tsv "$DIAG_DIR"/* 2>/dev/null || true

worker="$REPORT_DIR/worker.sh"
cat >"$worker" <<'WORKER'
#!/usr/bin/env bash
set -uo pipefail
repo="$1"
if ! tools/zed_tip_sync_repo.sh "$repo" main quota-light-seed "$PACKAGE_MAP"; then
  safe="${repo//\//__}"
  if [[ ! -f "$RESULT_DIR/$safe.tsv" ]]; then
    printf 'failure\t%s\tworker-failed\t\n' "$repo" >"$RESULT_DIR/$safe.tsv"
  fi
fi
exit 0
WORKER
chmod +x "$worker" tools/zed_tip_sync_repo.sh

log "synchronizing $selected_count repositories with max parallelism $MAX_PARALLEL"
printf '%s\n' "${selected[@]}" | xargs -P "$MAX_PARALLEL" -n 1 bash -c '"$0" "$1"' "$worker"

processed="$(find "$RESULT_DIR" -maxdepth 1 -name '*.tsv' -type f | wc -l | tr -d ' ')"
updated="$(awk -F '\t' '$1=="updated" {n++} END {print n+0}' "$RESULT_DIR"/*.tsv 2>/dev/null || true)"
pushed="$(awk -F '\t' '$1=="pushed" {n++} END {print n+0}' "$RESULT_DIR"/*.tsv 2>/dev/null || true)"
no_change="$(awk -F '\t' '$1=="no-change" {n++} END {print n+0}' "$RESULT_DIR"/*.tsv 2>/dev/null || true)"
failed="$(awk -F '\t' '$1=="failure" {n++} END {print n+0}' "$RESULT_DIR"/*.tsv 2>/dev/null || true)"

cat >"$REPORT_DIR/summary.md" <<EOF_SUMMARY
# Zed dependency-tip fleet sync — quota-light seed

- repositories selected from immutable seed: **$selected_count**
- repositories processed with a terminal result: **$processed**
- canonical package roots in Git-derived authority map: **$package_count**
- repositories with actual dependency-update PRs: **$updated**
- dependency-update branches pushed but PR publication unavailable: **$pushed**
- repositories already current / no admitted delta: **$no_change**
- repository-level failures: **$failed**
- current-tip zed-cli: **${ZED_CLI_SHA:-unknown}**
- controller: **${GITHUB_SHA:-unknown}**

Only `updated` rows count toward the 100-repository PR floor. `pushed`, no-op, and failure rows do not count.
EOF_SUMMARY

if (( updated > 0 )); then
  {
    echo
    echo '## Pull requests'
    echo
    awk -F '\t' '$1=="updated" {printf "- `%s`: %s\n", $2, $4}' "$RESULT_DIR"/*.tsv | sort -f
  } >>"$REPORT_DIR/summary.md"
fi
if (( pushed > 0 )); then
  {
    echo
    echo '## Branches awaiting PR publication'
    echo
    awk -F '\t' '$1=="pushed" {printf "- `%s`: %s\n", $2, $4}' "$RESULT_DIR"/*.tsv | sort -f
  } >>"$REPORT_DIR/summary.md"
fi
if (( failed > 0 )); then
  {
    echo
    echo '## Failures'
    echo
    awk -F '\t' '$1=="failure" {printf "- `%s`: %s\n", $2, $3}' "$RESULT_DIR"/*.tsv | sort -f
  } >>"$REPORT_DIR/summary.md"
fi
cat "$REPORT_DIR/summary.md"

(( processed >= MIN_REPOS )) || exit 44
if (( updated < MIN_REPOS )); then
  echo "Need at least $MIN_REPOS actual dependency-update PRs; produced $updated (plus $pushed pushed branches)" >&2
  exit 43
fi
