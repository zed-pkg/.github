#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ZED_BIN:?ZED_BIN must point at current-tip zed-cli}"

MIN_REPOS="${MIN_REPOS:-100}"
MAX_REPOS="${MAX_REPOS:-220}"
MAX_PARALLEL="${MAX_PARALLEL:-10}"
RUN_BRANCH="${RUN_BRANCH:-automation/zed-tip-sync-20260914}"
REPORT_DIR="${REPORT_DIR:-$PWD/artifacts/zed-tip-sync}"
REPORT_DIR="$(mkdir -p "$REPORT_DIR" && cd "$REPORT_DIR" && pwd)"
RESULT_DIR="$REPORT_DIR/results"
mkdir -p "$RESULT_DIR"

FLEET_ORGS="${ZED_FLEET_ORGS:-zed-pkg,fiducia-cloud,shared-auth,messaging-intel,claritas-viz,opto-sync,quaestor-ledger,sonus-auris,voxletra,elenkos-systems,hhaus-org,hacker-house-medellin,gha-indie-worker,ores-legal,ores-rate-limit,ores-redis-lru-cache,ores-middleware,ores-chat,3FA-app,fanwaave,daedalus-fab,happy-wakey,pal-trace,bait-bikes,embedded-alerts,evento-globolo,discrete-event-systems,claimgraph,drone-mngr,led-dynamo,ores-aerial,premarital-asset-protection,canonical-cloud,ores-forms,ores-wasm-loaders,praxonne,hypesiege,honeypot-r-us,scintilla-run,flags-2-env,benefactor-cc,chapter-publishing,athlet-o,agent-pontifex,cliptown,ecma-d,anticaptrad}"

log() { printf '[zed-tip-fast] %s\n' "$*"; }
warn() { printf '[zed-tip-fast] WARN: %s\n' "$*" >&2; }

gh auth setup-git >/dev/null

owners="$REPORT_DIR/owners.txt"
: >"$owners"
printf '%s\n' ORESoftware >>"$owners"
IFS=',' read -r -a orgs <<<"$FLEET_ORGS"
for raw in "${orgs[@]}"; do
  org="$(xargs <<<"$raw")"
  [[ -n "$org" ]] || continue
  printf '%s\n' "$org" >>"$owners"
  if [[ "$org" != *-test ]] && gh api "orgs/${org}-test" --silent >/dev/null 2>&1; then
    printf '%s\n' "${org}-test" >>"$owners"
  fi
done
sort -fu "$owners" -o "$owners"

allowed_repo() {
  local repo="$1" owner="${repo%%/*}"
  grep -Fqix "$owner" "$owners"
}

candidate_repos="$REPORT_DIR/candidate-repos.txt"
package_repos="$REPORT_DIR/package-repos.txt"
: >"$candidate_repos"; : >"$package_repos"

log 'discovering typed client packages and reverse consumers'
mkdir -p "$REPORT_DIR/client-discovery"
GITHUB_TOKEN="$GH_TOKEN" python3 tools/discover_clients_fleet.py \
  --orgs "$FLEET_ORGS" \
  --output "$REPORT_DIR/client-discovery/fleet.json" \
  --matrix-output "$REPORT_DIR/client-discovery/matrix.json" \
  --markdown "$REPORT_DIR/client-discovery/summary.md" \
  --allow-empty
jq -r '.include[] | .repo, (.consumers[]? // empty)' \
  "$REPORT_DIR/client-discovery/matrix.json" >>"$candidate_repos"

log 'discovering root .zpkg.toml package owners'
manifest_hits="$REPORT_DIR/manifest-search.txt"
: >"$manifest_hits"
gh api -X GET search/code -f q='filename:.zpkg.toml' -f per_page=100 \
  --paginate --jq '.items[].repository.full_name' 2>/dev/null >"$manifest_hits" || true
while IFS= read -r repo; do
  [[ "$repo" == */* ]] || continue
  if allowed_repo "$repo"; then
    printf '%s\n' "$repo" >>"$package_repos"
    printf '%s\n' "$repo" >>"$candidate_repos"
  fi
done <"$manifest_hits"

log 'adding repositories from prior Zed range-sync PR evidence'
prior_hits="$REPORT_DIR/prior-range-sync.txt"
: >"$prior_hits"
gh api -X GET search/issues \
  -f q='"sync dependency ranges" type:pr' -f per_page=100 --paginate \
  --jq '.items[].repository_url | sub("https://api.github.com/repos/"; "")' 2>/dev/null \
  >"$prior_hits" || true
while IFS= read -r repo; do
  [[ "$repo" == */* ]] || continue
  allowed_repo "$repo" && printf '%s\n' "$repo" >>"$candidate_repos"
done <"$prior_hits"

sort -fu "$candidate_repos" -o "$candidate_repos"
sort -fu "$package_repos" -o "$package_repos"

log 'resolving candidate default branches and access'
: >"$REPORT_DIR/candidates.tsv"
while IFS= read -r repo; do
  [[ "$repo" == */* ]] || continue
  meta="$(gh api "repos/$repo" 2>/dev/null || true)"
  [[ -n "$meta" ]] || continue
  [[ "$(jq -r '.archived // false' <<<"$meta")" == false ]] || continue
  [[ "$(jq -r '.disabled // false' <<<"$meta")" == false ]] || continue
  branch="$(jq -r '.default_branch // "main"' <<<"$meta")"
  reason=graph-seed
  grep -Fqx "$repo" "$package_repos" && reason=package-owner
  printf '%s\t%s\t%s\n' "$repo" "$branch" "$reason" >>"$REPORT_DIR/candidates.tsv"
done <"$candidate_repos"
sort -fu "$REPORT_DIR/candidates.tsv" -o "$REPORT_DIR/candidates.tsv"

candidate_count="$(wc -l <"$REPORT_DIR/candidates.tsv" | tr -d ' ')"
log "discovered $candidate_count concrete package/dependent repositories"
if (( candidate_count < MIN_REPOS )); then
  echo "Need at least $MIN_REPOS concrete package/dependent repositories; found $candidate_count" >&2
  exit 42
fi
head -n "$MAX_REPOS" "$REPORT_DIR/candidates.tsv" >"$REPORT_DIR/selected.tsv"
selected_count="$(wc -l <"$REPORT_DIR/selected.tsv" | tr -d ' ')"

log 'building package coordinate -> current tip authority map'
: >"$REPORT_DIR/packages.tsv"
while IFS= read -r repo; do
  [[ "$repo" == */* ]] || continue
  meta="$(gh api "repos/$repo" 2>/dev/null || true)"
  [[ -n "$meta" ]] || continue
  branch="$(jq -r '.default_branch // "main"' <<<"$meta")"
  payload="$(gh api "repos/$repo/contents/.zpkg.toml?ref=$branch" 2>/dev/null || true)"
  [[ -n "$payload" ]] || continue
  manifest="$(jq -r '.content // empty' <<<"$payload" | tr -d '\n' | base64 --decode 2>/dev/null || true)"
  [[ -n "$manifest" ]] || continue
  identity="$(awk '
    BEGIN { section=""; org=""; name=""; version="" }
    /^[[:space:]]*\[/ { line=$0; sub(/^[[:space:]]*\[/,"",line); sub(/\].*$/,"",line); section=line; next }
    section=="package" && /^[[:space:]]*org[[:space:]]*=/ { line=$0; sub(/^[^=]*=[[:space:]]*"/,"",line); sub(/".*$/,"",line); org=line }
    section=="package" && /^[[:space:]]*name[[:space:]]*=/ { line=$0; sub(/^[^=]*=[[:space:]]*"/,"",line); sub(/".*$/,"",line); name=line }
    section=="package" && /^[[:space:]]*version[[:space:]]*=/ { line=$0; sub(/^[^=]*=[[:space:]]*"/,"",line); sub(/".*$/,"",line); version=line }
    END { if (org!="" && name!="" && version!="") printf "%s/%s\t%s", org, name, version }
  ' <<<"$manifest")"
  [[ -n "$identity" ]] || continue
  coordinate="${identity%%$'\t'*}"
  version="${identity#*$'\t'}"
  head_sha="$(gh api "repos/$repo/commits/$branch" --jq '.sha' 2>/dev/null || true)"
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || continue
  tagged=false
  ref="$(gh api "repos/$repo/git/ref/tags/v$version" 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then
    kind="$(jq -r '.object.type // empty' <<<"$ref")"
    tag_sha="$(jq -r '.object.sha // empty' <<<"$ref")"
    if [[ "$kind" == tag && "$tag_sha" =~ ^[0-9a-f]{40}$ ]]; then
      tagobj="$(gh api "repos/$repo/git/tags/$tag_sha" 2>/dev/null || true)"
      kind="$(jq -r '.object.type // empty' <<<"$tagobj")"
      tag_sha="$(jq -r '.object.sha // empty' <<<"$tagobj")"
    fi
    [[ "$kind" == commit && "$tag_sha" == "$head_sha" ]] && tagged=true
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$coordinate" "$repo" "$version" "$head_sha" "$tagged" >>"$REPORT_DIR/packages.tsv"
done <"$package_repos"
sort -fu "$REPORT_DIR/packages.tsv" -o "$REPORT_DIR/packages.tsv"
jq -Rn '[inputs | split("\t") | select(length==5) | {coordinate:.[0],repo:.[1],version:.[2],sha:.[3],tagged:(.[4]=="true")}]' \
  <"$REPORT_DIR/packages.tsv" >"$REPORT_DIR/packages.json"
package_count="$(wc -l <"$REPORT_DIR/packages.tsv" | tr -d ' ')"
log "selected $selected_count repositories; authority map contains $package_count root Zed packages"

export RUN_BRANCH RESULT_DIR ZED_BIN GH_TOKEN ZED_PKG_TOKEN
PACKAGE_MAP="$REPORT_DIR/packages.json"
export PACKAGE_MAP
rm -f "$RESULT_DIR"/*.tsv 2>/dev/null || true

log "synchronizing selected repositories with max parallelism $MAX_PARALLEL"
worker="$REPORT_DIR/worker.sh"
cat >"$worker" <<'WORKER'
#!/usr/bin/env bash
set -uo pipefail
repo="$1"; branch="$2"; reason="$3"
if ! tools/zed_tip_sync_repo.sh "$repo" "$branch" "$reason" "$PACKAGE_MAP"; then
  safe="${repo//\//__}"
  if [[ ! -f "$RESULT_DIR/$safe.tsv" ]]; then
    printf 'failure\t%s\tworker-failed\t\n' "$repo" >"$RESULT_DIR/$safe.tsv"
  fi
fi
exit 0
WORKER
chmod +x "$worker" tools/zed_tip_sync_repo.sh
awk -F '\t' '{print $1 "\t" $2 "\t" $3}' "$REPORT_DIR/selected.tsv" \
  | xargs -P "$MAX_PARALLEL" -n 3 bash -c '"$0" "$1" "$2" "$3"' "$worker"

processed="$(find "$RESULT_DIR" -maxdepth 1 -name '*.tsv' -type f | wc -l | tr -d ' ')"
updated="$(awk -F '\t' '$1=="updated" {n++} END {print n+0}' "$RESULT_DIR"/*.tsv 2>/dev/null || true)"
no_change="$(awk -F '\t' '$1=="no-change" {n++} END {print n+0}' "$RESULT_DIR"/*.tsv 2>/dev/null || true)"
failed="$(awk -F '\t' '$1=="failure" {n++} END {print n+0}' "$RESULT_DIR"/*.tsv 2>/dev/null || true)"

cat >"$REPORT_DIR/summary.md" <<EOF_SUMMARY
# Zed dependency-tip fleet sync

- concrete package/dependent repositories discovered: **$candidate_count**
- repositories selected: **$selected_count**
- repositories processed with a terminal result: **$processed**
- root Zed packages in current-tip authority map: **$package_count**
- repositories with actual dependency-update PRs: **$updated**
- repositories already at admitted tips / no safe delta: **$no_change**
- repository-level failures: **$failed**
- current-tip zed-cli: **${ZED_CLI_SHA:-unknown}**
- controller: **${GITHUB_SHA:-unknown}**

Only real validated dependency/lock deltas receive PRs; no-op repositories are not counted toward the 100-repository update floor.
EOF_SUMMARY

if (( updated > 0 )); then
  {
    echo
    echo '## Pull requests'
    echo
    awk -F '\t' '$1=="updated" {printf "- `%s`: %s\n", $2, $4}' "$RESULT_DIR"/*.tsv | sort -f
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
  echo "Need at least $MIN_REPOS actual dependency-update PRs; produced $updated" >&2
  exit 43
fi
