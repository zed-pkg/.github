#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ZED_BIN:?ZED_BIN must point at current-tip zed-cli}"

MIN_REPOS="${MIN_REPOS:-100}"
MAX_REPOS="${MAX_REPOS:-180}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
RUN_BRANCH="${RUN_BRANCH:-chatgpt/zed-tip-sync-20260914}"
REPORT_DIR="${REPORT_DIR:-$PWD/artifacts/zed-tip-sync}"
REPORT_DIR="$(mkdir -p "$REPORT_DIR" && cd "$REPORT_DIR" && pwd)"
export REPORT_DIR RUN_BRANCH ZED_BIN GH_TOKEN ZED_PKG_TOKEN GITHUB_SHA

FLEET_ORGS="${ZED_FLEET_ORGS:-zed-pkg,fiducia-cloud,shared-auth,messaging-intel,claritas-viz,opto-sync,quaestor-ledger,sonus-auris,voxletra,elenkos-systems,hhaus-org,hacker-house-medellin,gha-indie-worker,ores-legal,ores-rate-limit,ores-redis-lru-cache,ores-middleware,ores-chat,3FA-app,fanwaave,daedalus-fab,happy-wakey,pal-trace,bait-bikes,embedded-alerts,evento-globolo,discrete-event-systems,claimgraph,drone-mngr,led-dynamo,ores-aerial,premarital-asset-protection,canonical-cloud,ores-forms,ores-wasm-loaders,praxonne,hypesiege,honeypot-r-us,scintilla-run,flags-2-env,benefactor-cc,chapter-publishing,athlet-o,agent-pontifex,cliptown,ecma-d,anticaptrad}"

log() { printf '[zed-tip-fast] %s\n' "$*"; }
warn() { printf '[zed-tip-fast] WARN: %s\n' "$*" >&2; }
export -f log warn

gh auth setup-git >/dev/null

# 1. Reuse the already-tested client/consumer discoverer. It uses package
# coordinates and exact GitHub references instead of repository-name guessing.
log 'discovering typed client packages and their consumers'
mkdir -p "$REPORT_DIR/client-discovery"
GITHUB_TOKEN="$GH_TOKEN" python3 tools/discover_clients_fleet.py \
  --orgs "$FLEET_ORGS" \
  --output "$REPORT_DIR/client-discovery/fleet.json" \
  --matrix-output "$REPORT_DIR/client-discovery/matrix.json" \
  --markdown "$REPORT_DIR/client-discovery/summary.md" \
  --allow-empty

jq -r '.include[] | .repo, (.consumers[]? // empty)' \
  "$REPORT_DIR/client-discovery/matrix.json" >"$REPORT_DIR/candidate-repos.txt"

# 2. Add every accessible repository that actually owns a root .zpkg.toml.
# GitHub code search is much cheaper than probing every repository one-by-one.
log 'discovering root .zpkg.toml package owners'
gh api -X GET search/code -f q='filename:.zpkg.toml' -f per_page=100 \
  --paginate --jq '.items[].repository.full_name' 2>/dev/null \
  >>"$REPORT_DIR/candidate-repos.txt" || true

# 3. Recheck repositories from the earlier Zed range-sync campaign. They are
# real historical consumers and may have moved since that campaign.
log 'adding repositories from prior Zed dependency-range sync evidence'
gh api -X GET search/issues \
  -f q='"chore(zed): sync dependency ranges to current versions" type:pr' \
  -f per_page=100 --paginate \
  --jq '.items[].repository_url | sub("https://api.github.com/repos/"; "")' 2>/dev/null \
  >>"$REPORT_DIR/candidate-repos.txt" || true

sort -fu "$REPORT_DIR/candidate-repos.txt" -o "$REPORT_DIR/candidate-repos.txt"

# Resolve current default branches and discard inaccessible/archived/disabled repos.
: >"$REPORT_DIR/candidates.tsv"
while IFS= read -r repo; do
  [[ "$repo" == */* ]] || continue
  meta="$(gh api "repos/$repo" 2>/dev/null || true)"
  [[ -n "$meta" ]] || continue
  archived="$(jq -r '.archived // false' <<<"$meta")"
  disabled="$(jq -r '.disabled // false' <<<"$meta")"
  [[ "$archived" == false && "$disabled" == false ]] || continue
  branch="$(jq -r '.default_branch // "main"' <<<"$meta")"
  printf '%s\t%s\tgraph-seed\n' "$repo" "$branch" >>"$REPORT_DIR/candidates.tsv"
done <"$REPORT_DIR/candidate-repos.txt"
sort -fu "$REPORT_DIR/candidates.tsv" -o "$REPORT_DIR/candidates.tsv"

candidate_count="$(wc -l <"$REPORT_DIR/candidates.tsv" | tr -d ' ')"
log "discovered $candidate_count concrete Zed package/dependent repositories"
if (( candidate_count < MIN_REPOS )); then
  echo "Need at least $MIN_REPOS concrete Zed package/dependent repositories; found $candidate_count" >&2
  exit 42
fi
head -n "$MAX_REPOS" "$REPORT_DIR/candidates.tsv" >"$REPORT_DIR/selected.tsv"
selected_count="$(wc -l <"$REPORT_DIR/selected.tsv" | tr -d ' ')"

# Build the package identity/tip table only for selected repos that actually
# publish a root Zed manifest. The mutation worker uses this as its authority.
: >"$REPORT_DIR/packages.tsv"
while IFS=$'\t' read -r repo branch _; do
  payload="$(gh api "repos/$repo/contents/.zpkg.toml" 2>/dev/null || true)"
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
done <"$REPORT_DIR/selected.tsv"
sort -fu "$REPORT_DIR/packages.tsv" -o "$REPORT_DIR/packages.tsv"

jq -Rn '[inputs | split("\t") | select(length==5) | {coordinate:.[0],repo:.[1],version:.[2],sha:.[3],tagged:(.[4]=="true")}]' \
  <"$REPORT_DIR/packages.tsv" >"$REPORT_DIR/packages.json"

package_count="$(wc -l <"$REPORT_DIR/packages.tsv" | tr -d ' ')"
log "selected $selected_count repositories; $package_count publish root Zed manifests"

# Reuse the mutation implementation from the slower controller, but execute
# independent repositories in bounded parallel workers. The worker shell omits
# errexit outside sync_repo so the no-diff sentinel remains data, not failure.
sed -n '/^sync_repo() {/,/^while IFS=.*selected.tsv/p' tools/zed_tip_fleet_sync.sh \
  | sed '$d' >"$REPORT_DIR/sync-function.sh"

work="$RUNNER_TEMP/zed-tip-fast-work"
mkdir -p "$work"
export work selected_count
: >"$REPORT_DIR/prs.tsv"
: >"$REPORT_DIR/failures.tsv"

worker="$REPORT_DIR/worker.sh"
cat >"$worker" <<'WORKER'
#!/usr/bin/env bash
set -uo pipefail
repo="$1"; branch="$2"; reason="$3"; ordinal="$4"
processed=$((ordinal - 1)); changed=0; failed=0
source "$REPORT_DIR/sync-function.sh"
sync_repo "$repo" "$branch" "$reason"
exit 0
WORKER
chmod +x "$worker"

awk -F '\t' '{print NR "\t" $0}' "$REPORT_DIR/selected.tsv" \
  | xargs -P "$MAX_PARALLEL" -n 4 bash -c '"$0" "$2" "$3" "$4" "$1"' "$worker"

changed="$(wc -l <"$REPORT_DIR/prs.tsv" | tr -d ' ')"
failed="$(wc -l <"$REPORT_DIR/failures.tsv" | tr -d ' ')"
processed="$selected_count"

cat >"$REPORT_DIR/summary.md" <<EOF
# Zed dependency-tip fleet sync

- concrete Zed package/dependent repositories discovered: **$candidate_count**
- repositories processed: **$processed**
- root Zed package publishers in selected set: **$package_count**
- repositories with real dependency/lock PR deltas: **$changed**
- repository-level failures: **$failed**
- current-tip zed-cli: **${ZED_CLI_SHA:-unknown}**
- controller: **${GITHUB_SHA:-unknown}**

A processed repository was selected from a root Zed manifest, a discovered typed-client consumer edge, or prior Zed dependency-sync evidence. Only repositories with a real validated delta receive a PR.
EOF

if [[ -s "$REPORT_DIR/prs.tsv" ]]; then
  { echo; echo '## Pull requests'; echo; awk -F '\t' '{printf "- `%s`: %s\n", $1, $2}' "$REPORT_DIR/prs.tsv" | sort -f; } >>"$REPORT_DIR/summary.md"
fi
if [[ -s "$REPORT_DIR/failures.tsv" ]]; then
  { echo; echo '## Repository failures'; echo; awk -F '\t' '{printf "- `%s`: %s\n", $1, $2}' "$REPORT_DIR/failures.tsv" | sort -f; } >>"$REPORT_DIR/summary.md"
fi
cat "$REPORT_DIR/summary.md"
(( processed >= MIN_REPOS ))
