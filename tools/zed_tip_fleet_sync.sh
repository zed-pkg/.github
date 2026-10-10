#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

MODE="${1:-}"
ROOT_DIR="${GITHUB_WORKSPACE:-$PWD}"
REPORT_DIR="${REPORT_DIR:-$ROOT_DIR/artifacts/zed-tip-sync}"
case "$REPORT_DIR" in
  /*) ;;
  *) REPORT_DIR="$ROOT_DIR/$REPORT_DIR" ;;
esac
mkdir -p "$REPORT_DIR"

MIN_REPOS="${MIN_REPOS:-100}"
MAX_REPOS="${MAX_REPOS:-140}"
RUN_BRANCH="${RUN_BRANCH:-automation/zed-tip-sync-20260914}"
FALLBACK_OWNERS="${ZED_FLEET_OWNERS:-ORESoftware,zed-pkg,fiducia-cloud,shared-auth,messaging-intel,claritas-viz,opto-sync,quaestor-ledger,sonus-auris,voxletra,elenkos-systems,hhaus-org,hacker-house-medellin,gha-indie-worker,ores-legal,ores-rate-limit,ores-redis-lru-cache,ores-middleware,ores-chat,3FA-app,fanwaave,daedalus-fab,happy-wakey,pal-trace,bait-bikes,embedded-alerts,evento-globolo,discrete-event-systems,claimgraph,drone-mngr,led-dynamo,ores-aerial,premarital-asset-protection,canonical-cloud,ores-forms,ores-wasm-loaders}"

log() { printf '[zed-tip-sync] %s\n' "$*"; }
warn() { printf '[zed-tip-sync] WARN: %s\n' "$*" >&2; }

decode_file() {
  local repo="$1" path="$2"
  gh api "repos/$repo/contents/$path" --jq '.content' 2>/dev/null \
    | tr -d '\n' \
    | base64 --decode 2>/dev/null
}

owner_repos() {
  local owner="$1"
  if [[ "$owner" == ORESoftware ]]; then
    if gh api --paginate 'user/repos?affiliation=owner&sort=full_name&direction=asc&per_page=100' \
      --jq '.[] | select(.owner.login == "ORESoftware" and .archived == false and .disabled == false) | [.full_name, (.default_branch // "main")] | @tsv' 2>/dev/null; then
      return 0
    fi
  fi
  if gh api "orgs/$owner" --silent >/dev/null 2>&1; then
    gh api --paginate "orgs/$owner/repos?type=all&sort=full_name&direction=asc&per_page=100" \
      --jq '.[] | select(.archived == false and .disabled == false) | [.full_name, (.default_branch // "main")] | @tsv'
  elif gh api "users/$owner" --silent >/dev/null 2>&1; then
    gh api --paginate "users/$owner/repos?type=owner&sort=full_name&direction=asc&per_page=100" \
      --jq '.[] | select(.archived == false and .disabled == false) | [.full_name, (.default_branch // "main")] | @tsv'
  fi
}

resolve_tag_commit() {
  local repo="$1" tag="$2" payload type sha
  payload="$(gh api "repos/$repo/git/ref/tags/$tag" 2>/dev/null || true)"
  [[ -n "$payload" ]] || return 1
  type="$(jq -r '.object.type // empty' <<<"$payload")"
  sha="$(jq -r '.object.sha // empty' <<<"$payload")"
  [[ -n "$sha" ]] || return 1
  if [[ "$type" == tag ]]; then
    payload="$(gh api "repos/$repo/git/tags/$sha" 2>/dev/null || true)"
    type="$(jq -r '.object.type // empty' <<<"$payload")"
    sha="$(jq -r '.object.sha // empty' <<<"$payload")"
  fi
  [[ "$type" == commit && "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}

parse_manifest_identity() {
  awk '
    BEGIN { section=""; org=""; name=""; version="" }
    /^[[:space:]]*\[/ {
      line=$0; sub(/^[[:space:]]*\[/,"",line); sub(/\].*$/,"",line); section=line; next
    }
    section=="package" && /^[[:space:]]*org[[:space:]]*=/ {
      line=$0; sub(/^[^=]*=[[:space:]]*"/,"",line); sub(/".*$/,"",line); org=line
    }
    section=="package" && /^[[:space:]]*name[[:space:]]*=/ {
      line=$0; sub(/^[^=]*=[[:space:]]*"/,"",line); sub(/".*$/,"",line); name=line
    }
    section=="package" && /^[[:space:]]*version[[:space:]]*=/ {
      line=$0; sub(/^[^=]*=[[:space:]]*"/,"",line); sub(/".*$/,"",line); version=line
    }
    END { if (org!="" && name!="" && version!="") printf "%s/%s\t%s\n", org, name, version }
  '
}

manifest_mentions_package() {
  local text="$1" packages="$2"
  while IFS=$'\t' read -r coord dep_repo _version _sha _tagged; do
    [[ -n "$coord" && -n "$dep_repo" ]] || continue
    if grep -Fqi "$coord" "$text" \
      || grep -Fqi "github.com/$dep_repo" "$text" \
      || grep -Fqi "github:$dep_repo" "$text"; then
      return 0
    fi
  done <"$packages"
  return 1
}

discover() {
  local owners_file="$REPORT_DIR/owners.txt"
  local repos_file="$REPORT_DIR/repos.tsv"
  local packages_file="$REPORT_DIR/packages.tsv"
  local candidates_file="$REPORT_DIR/candidates.tsv"
  : >"$owners_file"; : >"$repos_file"; : >"$packages_file"; : >"$candidates_file"

  local raw owner test_owner
  IFS=',' read -r -a base_owners <<<"$FALLBACK_OWNERS"
  for raw in "${base_owners[@]}"; do
    owner="$(xargs <<<"$raw")"
    [[ -n "$owner" ]] || continue
    printf '%s\n' "$owner" >>"$owners_file"
    if [[ "$owner" != ORESoftware && "$owner" != *-test ]]; then
      test_owner="${owner}-test"
      if gh api "orgs/$test_owner" --silent >/dev/null 2>&1; then
        printf '%s\n' "$test_owner" >>"$owners_file"
      fi
    fi
  done
  sort -fu "$owners_file" -o "$owners_file"

  log "enumerating repositories for $(wc -l <"$owners_file" | tr -d ' ') owners"
  while IFS= read -r owner; do
    owner_repos "$owner" >>"$repos_file" || warn "could not enumerate $owner"
  done <"$owners_file"
  sort -fu "$repos_file" -o "$repos_file"

  log "discovering root Zed package manifests and immutable tip identities"
  local repo branch tmp identity coordinate version head_sha tag_sha tagged
  while IFS=$'\t' read -r repo branch; do
    [[ -n "$repo" && -n "$branch" ]] || continue
    tmp="$(mktemp)"
    if decode_file "$repo" .zpkg.toml >"$tmp" && [[ -s "$tmp" ]]; then
      identity="$(parse_manifest_identity <"$tmp" || true)"
      if [[ -n "$identity" ]]; then
        coordinate="${identity%%$'\t'*}"
        version="${identity#*$'\t'}"
        head_sha="$(gh api "repos/$repo/commits/$branch" --jq '.sha' 2>/dev/null || true)"
        if [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
          tagged=false
          tag_sha="$(resolve_tag_commit "$repo" "v$version" || true)"
          [[ "$tag_sha" == "$head_sha" ]] && tagged=true
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "$coordinate" "$repo" "$version" "$head_sha" "$tagged" >>"$packages_file"
          printf '%s\t%s\tmanifest\n' "$repo" "$branch" >>"$candidates_file"
        fi
      fi
    fi
    rm -f "$tmp"
  done <"$repos_file"
  sort -fu "$packages_file" -o "$packages_file"

  cut -f2 "$packages_file" | sort -fu >"$REPORT_DIR/package-repos.txt"

  log "discovering reverse dependents across root package manifests"
  local matched path
  while IFS=$'\t' read -r repo branch; do
    [[ -n "$repo" && -n "$branch" ]] || continue
    if grep -Fqx "$repo" "$REPORT_DIR/package-repos.txt"; then
      continue
    fi
    matched=false
    for path in .zpkg.toml Cargo.toml package.json pubspec.yaml go.mod; do
      tmp="$(mktemp)"
      if decode_file "$repo" "$path" >"$tmp" && [[ -s "$tmp" ]]; then
        if manifest_mentions_package "$tmp" "$packages_file"; then
          matched=true
        fi
      fi
      rm -f "$tmp"
      if $matched; then
        break
      fi
    done
    if $matched; then
      printf '%s\t%s\tconsumer\n' "$repo" "$branch" >>"$candidates_file"
    fi
  done <"$repos_file"
  sort -fu "$candidates_file" -o "$candidates_file"

  local candidate_count package_count repo_count selected_count
  candidate_count="$(wc -l <"$candidates_file" | tr -d ' ')"
  package_count="$(wc -l <"$packages_file" | tr -d ' ')"
  repo_count="$(wc -l <"$repos_file" | tr -d ' ')"
  log "discovered $package_count package owners and $candidate_count package/dependent repos from $repo_count active repos"
  if (( candidate_count < MIN_REPOS )); then
    echo "Need at least $MIN_REPOS Zed package/dependent repositories; discovered $candidate_count" >&2
    return 42
  fi

  head -n "$MAX_REPOS" "$candidates_file" >"$REPORT_DIR/selected.tsv"
  selected_count="$(wc -l <"$REPORT_DIR/selected.tsv" | tr -d ' ')"

  jq -Rn '
    [inputs | split("\t") | select(length==5) |
     {coordinate:.[0], repo:.[1], version:.[2], sha:.[3], tagged:(.[4]=="true")}]
  ' <"$packages_file" >"$REPORT_DIR/packages.json"

  jq -Rn '
    {include: [inputs | split("\t") | select(length==3) |
      {repo:.[0], default_branch:.[1], reason:.[2]}]}
  ' <"$REPORT_DIR/selected.tsv" >"$REPORT_DIR/matrix.json"

  cat >"$REPORT_DIR/summary.md" <<EOF_SUMMARY
# Zed current-tip fleet discovery

- Active repositories scanned: **$repo_count**
- Zed package owners discovered: **$package_count**
- Package/dependent repositories discovered: **$candidate_count**
- Repositories selected for this run: **$selected_count**
- Minimum required: **$MIN_REPOS**

Registry requirements are only rewritten to a package version when the package's declared \`v<version>\` tag resolves to its current default-branch tip. Exact Git \`rev\` consumers are updated to the dependency repository's exact current tip SHA. Generated locks are accepted only after current-tip \`zed validate --require-lock --json\` succeeds.
EOF_SUMMARY

  printf '%s\n' "matrix=$(tr -d '\n' <"$REPORT_DIR/matrix.json")"
  printf '%s\n' "selected_count=$selected_count"
}

update_zpkg_manifest() {
  local manifest="$1" package_map="$2"
  ruby -rjson - "$package_map" "$manifest" <<'RUBY'
map_file, manifest = ARGV
packages = JSON.parse(File.read(map_file))
versions = packages.select { |p| p["tagged"] }.to_h { |p| [p["coordinate"].downcase, p["version"]] }
lines = File.readlines(manifest, chomp: false)
section = nil
changed = false
lines.map! do |line|
  if (m = line.match(/^\s*\[([^\]]+)\]\s*(?:#.*)?$/))
    section = m[1]
    next line
  end
  next line unless section == "dependencies"
  m = line.match(/^(\s*)"([^"]+)"(\s*=\s*)"([^"]+)"(.*)$/)
  next line unless m
  coord = m[2]
  target = versions[coord.downcase]
  next line unless target
  current = m[4]
  next line if current.include?(target)
  replacement = if current.start_with?("^")
    "^#{target}"
  elsif current.start_with?("~")
    "~#{target}"
  elsif current.start_with?("=")
    "=#{target}"
  else
    target
  end
  changed = true
  "#{m[1]}\"#{coord}\"#{m[3]}\"#{replacement}\"#{m[5]}\n"
end
File.write(manifest, lines.join) if changed
RUBY
}

update_cargo_git_revs() {
  local manifest="$1" package_map="$2"
  ruby -rjson - "$package_map" "$manifest" <<'RUBY'
map_file, manifest = ARGV
packages = JSON.parse(File.read(map_file))
sha_by_repo = packages.to_h { |p| [p["repo"].downcase, p["sha"]] }
text = File.read(manifest)
original = text.dup
repo_from_url = ->(url) do
  s = url.sub(/^git\+/, "").sub(/\.git$/, "")
  m = s.match(%r{github\.com[:/]([^/]+/[^/#]+)$}i)
  m && m[1].downcase
end
text.gsub!(/^([^\n]*git\s*=\s*"([^"]+)"[^\n]*rev\s*=\s*")([0-9a-f]{40})("[^\n]*)$/i) do
  repo = repo_from_url.call($2)
  target = repo && sha_by_repo[repo]
  target ? "#{$1}#{target}#{$4}" : $&
end
parts = text.split(/(?=^\s*\[[^\]]+\]\s*$)/)
parts.map! do |part|
  git = part.match(/^\s*git\s*=\s*"([^"]+)"\s*(?:#.*)?$/i)
  next part unless git
  repo = repo_from_url.call(git[1])
  target = repo && sha_by_repo[repo]
  next part unless target
  part.sub(/^(\s*rev\s*=\s*")([0-9a-f]{40})("\s*(?:#.*)?)$/i, "\\1#{target}\\3")
end
text = parts.join
File.write(manifest, text) if text != original
RUBY
}

update_package_json_git_refs() {
  local manifest="$1" package_map="$2"
  ruby -rjson - "$package_map" "$manifest" <<'RUBY'
map_file, manifest = ARGV
packages = JSON.parse(File.read(map_file))
sha_by_repo = packages.to_h { |p| [p["repo"].downcase, p["sha"]] }
text = File.read(manifest)
original = text.dup
sha_by_repo.each do |repo, sha|
  owner, name = repo.split('/', 2)
  escaped = Regexp.escape("#{owner}/#{name}")
  text.gsub!(/((?:github:#{escaped}|git\+https:\/\/github\.com\/#{escaped}(?:\.git)?|https:\/\/github\.com\/#{escaped}(?:\.git)?)#)[0-9a-f]{7,40}/i) do
    "#{$1}#{sha}"
  end
end
File.write(manifest, text) if text != original
RUBY
}

sync_one() {
  : "${ZED_BIN:?ZED_BIN must point at the current-tip zed binary}"
  local repo="${2:?repository required}"
  local default_branch="${3:?default branch required}"
  local reason="${4:-candidate}"
  local package_map="${PACKAGE_MAP:-$REPORT_DIR/packages.json}"
  [[ -f "$package_map" ]] || { echo "missing package map: $package_map" >&2; return 2; }

  local work dir before_zpkg before_cargo before_pkg remote_sha pr_number diffstat
  work="$(mktemp -d)"
  dir="$work/repo"
  log "syncing $repo ($reason) from $default_branch"

  gh auth setup-git >/dev/null
  if ! git clone --quiet --filter=blob:none --depth=1 --branch "$default_branch" "https://github.com/$repo.git" "$dir"; then
    warn "$repo: clone failed"
    rm -rf "$work"
    return 20
  fi

  cd "$dir"
  git config user.name 'zed-pkg tip sync'
  git config user.email 'zed-pkg-tip-sync@users.noreply.github.com'
  local base_sha
  base_sha="$(git rev-parse HEAD)"
  git fetch origin "refs/heads/$RUN_BRANCH:refs/remotes/origin/$RUN_BRANCH" >/dev/null 2>&1 || true
  git checkout -q -B "$RUN_BRANCH"

  if [[ -f .zpkg.toml ]]; then
    before_zpkg="$work/zpkg.before"
    cp .zpkg.toml "$before_zpkg"
    update_zpkg_manifest .zpkg.toml "$package_map"

    local had_lock=false
    [[ -f .zpkg.lock ]] && had_lock=true
    local before_lock="$work/zpkg.lock.before"
    if $had_lock; then cp .zpkg.lock "$before_lock"; fi

    local zed_home="$work/zed-home"
    mkdir -p "$zed_home"
    if ! timeout 180s env ZED_HOME="$zed_home" "$ZED_BIN" install --install-mode copy >"$work/zed-install.log" 2>&1; then
      warn "$repo: Zed resolution failed; reverting Zed changes"
      cp "$before_zpkg" .zpkg.toml
      if $had_lock; then cp "$before_lock" .zpkg.lock; else rm -f .zpkg.lock; fi
    elif ! "$ZED_BIN" validate --require-lock --json >"$work/zed-validate.json" 2>&1; then
      warn "$repo: regenerated Zed lock failed validation; reverting Zed changes"
      cp "$before_zpkg" .zpkg.toml
      if $had_lock; then cp "$before_lock" .zpkg.lock; else rm -f .zpkg.lock; fi
    fi
  fi

  if [[ -f Cargo.toml ]]; then
    before_cargo="$work/Cargo.toml.before"
    cp Cargo.toml "$before_cargo"
    local had_cargo_lock=false before_cargo_lock="$work/Cargo.lock.before"
    if [[ -f Cargo.lock ]]; then
      had_cargo_lock=true
      cp Cargo.lock "$before_cargo_lock"
    fi
    update_cargo_git_revs Cargo.toml "$package_map"
    if ! cmp -s Cargo.toml "$before_cargo"; then
      if ! timeout 180s cargo metadata --format-version 1 --no-deps >"$work/cargo-metadata.json" 2>"$work/cargo-metadata.err"; then
        warn "$repo: cargo metadata failed after Git-rev update; reverting Cargo changes"
        cp "$before_cargo" Cargo.toml
        if $had_cargo_lock; then cp "$before_cargo_lock" Cargo.lock; else rm -f Cargo.lock; fi
      fi
    fi
  fi

  if [[ -f package.json ]]; then
    before_pkg="$work/package.json.before"
    cp package.json "$before_pkg"
    local had_npm_lock=false before_npm_lock="$work/package-lock.json.before"
    if [[ -f package-lock.json ]]; then
      had_npm_lock=true
      cp package-lock.json "$before_npm_lock"
    fi
    update_package_json_git_refs package.json "$package_map"
    if ! cmp -s package.json "$before_pkg" && $had_npm_lock; then
      if ! timeout 180s npm install --package-lock-only --ignore-scripts --no-audit --no-fund >"$work/npm-lock.log" 2>&1; then
        warn "$repo: npm lock refresh failed after Git-ref update; reverting package.json change"
        cp "$before_pkg" package.json
        cp "$before_npm_lock" package-lock.json
      fi
    fi
  fi

  rm -rf .vendor/.zed .zed_modules zed_modules node_modules target >/dev/null 2>&1 || true

  if git diff --quiet -- .zpkg.toml .zpkg.lock Cargo.toml Cargo.lock package.json package-lock.json 2>/dev/null; then
    log "$repo: already at admitted dependency tips"
    printf 'no-change\t%s\t%s\n' "$repo" "$base_sha" >>"$GITHUB_STEP_SUMMARY"
    rm -rf "$work"
    return 0
  fi

  git add -A -- .zpkg.toml .zpkg.lock Cargo.toml Cargo.lock package.json package-lock.json 2>/dev/null || true
  if git diff --cached --quiet; then
    log "$repo: no admitted staged change"
    rm -rf "$work"
    return 0
  fi

  diffstat="$(git diff --cached --stat | tr '\n' '; ' | sed 's/; $//')"
  git commit -m 'chore: sync dependency tips through zed' >/dev/null
  local head_sha
  head_sha="$(git rev-parse HEAD)"

  if remote_sha="$(git rev-parse "refs/remotes/origin/$RUN_BRANCH" 2>/dev/null)"; then
    git push --quiet --force-with-lease="refs/heads/$RUN_BRANCH:$remote_sha" origin "HEAD:refs/heads/$RUN_BRANCH"
  else
    git push --quiet --force-with-lease origin "HEAD:refs/heads/$RUN_BRANCH"
  fi

  local body_file="$work/pr-body.md"
  cat >"$body_file" <<EOF_BODY
Synchronizes admitted dependency identities to current repository tips using the current \`zed-pkg/zed-cli\` resolver.

Safety rules for this run:
- Zed registry requirements move only when the dependency package's declared \`v<version>\` tag resolves to that dependency repository's current default-branch tip.
- Exact Git \`rev\` dependencies move to the dependency repository's exact current tip SHA.
- \`.zpkg.lock\` is regenerated by current-tip \`zed\` and retained only when \`zed validate --require-lock --json\` succeeds.
- Cargo Git-revision changes are retained only when \`cargo metadata --format-version 1 --no-deps\` succeeds.
- Existing npm locks are refreshed with scripts disabled when a Git SHA changes; a failed lock refresh reverts that npm change.
- No dependency branch is merged automatically; repository CI and review remain the admission gate.

Base before sync: \`$base_sha\`
Candidate head: \`$head_sha\`
Reason discovered: \`$reason\`
Changed files: \`$diffstat\`
EOF_BODY

  pr_number="$(gh pr list --repo "$repo" --head "$RUN_BRANCH" --state open --json number --jq '.[0].number // empty')"
  if [[ -n "$pr_number" ]]; then
    gh pr edit "$pr_number" --repo "$repo" \
      --title 'chore: sync dependency tips through zed' \
      --body-file "$body_file" >/dev/null
  else
    gh pr create --repo "$repo" --base "$default_branch" --head "$RUN_BRANCH" \
      --title 'chore: sync dependency tips through zed' \
      --body-file "$body_file" >/dev/null
    pr_number="$(gh pr list --repo "$repo" --head "$RUN_BRANCH" --state open --json number --jq '.[0].number // empty')"
  fi

  local pr_url=""
  if [[ -n "$pr_number" ]]; then
    pr_url="https://github.com/$repo/pull/$pr_number"
  fi
  printf 'updated\t%s\t%s\t%s\n' "$repo" "$head_sha" "$pr_url" >>"$GITHUB_STEP_SUMMARY"
  log "$repo: opened/refreshed PR ${pr_url:-unknown}"
  rm -rf "$work"
}

case "$MODE" in
  discover)
    discover
    ;;
  sync)
    sync_one "$@"
    ;;
  *)
    echo "usage: $0 discover | sync OWNER/REPO DEFAULT_BRANCH [reason]" >&2
    exit 64
    ;;
esac
