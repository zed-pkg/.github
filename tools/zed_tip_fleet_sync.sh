#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ZED_BIN:?ZED_BIN must point at the current-tip zed binary}"

MIN_REPOS="${MIN_REPOS:-100}"
MAX_REPOS="${MAX_REPOS:-180}"
RUN_BRANCH="${RUN_BRANCH:-chatgpt/zed-tip-sync-20260914}"
REPORT_DIR="${REPORT_DIR:-artifacts/zed-tip-sync}"
mkdir -p "$REPORT_DIR"

FALLBACK_OWNERS="${ZED_FLEET_OWNERS:-ORESoftware,zed-pkg,fiducia-cloud,shared-auth,messaging-intel,claritas-viz,opto-sync,quaestor-ledger,sonus-auris,voxletra,elenkos-systems,hhaus-org,hacker-house-medellin,gha-indie-worker,ores-legal,ores-rate-limit,ores-redis-lru-cache,ores-middleware,ores-chat,3FA-app,fanwaave,daedalus-fab,happy-wakey,pal-trace,bait-bikes,embedded-alerts,evento-globolo,discrete-event-systems,claimgraph,drone-mngr,led-dynamo,ores-aerial,premarital-asset-protection,canonical-cloud,ores-forms,ores-wasm-loaders}"

log() { printf '[zed-tip-sync] %s\n' "$*"; }
warn() { printf '[zed-tip-sync] WARN: %s\n' "$*" >&2; }

decode_file() {
  local repo="$1" path="$2"
  gh api "repos/$repo/contents/$path" --jq '.content' 2>/dev/null | tr -d '\n' | base64 --decode 2>/dev/null
}

owner_repos() {
  local owner="$1"
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

owners_file="$REPORT_DIR/owners.txt"
repos_file="$REPORT_DIR/repos.tsv"
packages_file="$REPORT_DIR/packages.tsv"
candidates_file="$REPORT_DIR/candidates.tsv"
: >"$owners_file"; : >"$repos_file"; : >"$packages_file"; : >"$candidates_file"

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

log "discovering root Zed package manifests"
while IFS=$'\t' read -r repo branch; do
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
        printf '%s\t%s\t%s\t%s\t%s\n' "$coordinate" "$repo" "$version" "$head_sha" "$tagged" >>"$packages_file"
        printf '%s\t%s\tmanifest\n' "$repo" "$branch" >>"$candidates_file"
      fi
    fi
  fi
  rm -f "$tmp"
done <"$repos_file"
sort -fu "$packages_file" -o "$packages_file"

cut -f2 "$packages_file" | sort -fu >"$REPORT_DIR/package-repos.txt"

log "discovering reverse consumers of Zed package repositories"
while IFS=$'\t' read -r repo branch; do
  grep -Fqx "$repo" "$REPORT_DIR/package-repos.txt" && continue
  matched=false
  for path in Cargo.toml package.json pubspec.yaml go.mod .zpkg.toml; do
    tmp="$(mktemp)"
    if decode_file "$repo" "$path" >"$tmp" && [[ -s "$tmp" ]]; then
      while IFS= read -r dep_repo; do
        if grep -Fqi "github.com/$dep_repo" "$tmp" || grep -Fqi "github:$dep_repo" "$tmp" || grep -Fqi "$dep_repo" "$tmp"; then
          matched=true
          break
        fi
      done <"$REPORT_DIR/package-repos.txt"
    fi
    rm -f "$tmp"
    $matched && break
  done
  if $matched; then
    printf '%s\t%s\tconsumer\n' "$repo" "$branch" >>"$candidates_file"
  fi
done <"$repos_file"
sort -fu "$candidates_file" -o "$candidates_file"

candidate_count="$(wc -l <"$candidates_file" | tr -d ' ')"
package_count="$(wc -l <"$packages_file" | tr -d ' ')"
repo_count="$(wc -l <"$repos_file" | tr -d ' ')"
log "discovered $package_count package owners and $candidate_count package/dependent repositories from $repo_count active repos"
if (( candidate_count < MIN_REPOS )); then
  echo "Need at least $MIN_REPOS Zed package/dependent repositories; discovered $candidate_count" >&2
  exit 42
fi

head -n "$MAX_REPOS" "$candidates_file" >"$REPORT_DIR/selected.tsv"
selected_count="$(wc -l <"$REPORT_DIR/selected.tsv" | tr -d ' ')"

# Build compact JSON maps once. Registry-version updates use only versions whose
# v<version> tag resolves to the dependency repository's current default-branch tip.
jq -Rn '
  [inputs | split("\t") | select(length==5) |
   {coordinate:.[0], repo:.[1], version:.[2], sha:.[3], tagged:(.[4]=="true")}]
' <"$packages_file" >"$REPORT_DIR/packages.json"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
changed=0
failed=0
processed=0
: >"$REPORT_DIR/prs.tsv"
: >"$REPORT_DIR/failures.tsv"

gh auth setup-git >/dev/null

sync_repo() {
  local repo="$1" default_branch="$2" reason="$3"
  local dir="$work/${repo//\//__}"
  processed=$((processed + 1))
  log "[$processed/$selected_count] $repo ($reason)"

  if ! git clone --quiet --filter=blob:none --depth=1 --branch "$default_branch" "https://github.com/$repo.git" "$dir"; then
    warn "$repo: clone failed"
    printf '%s\tclone-failed\n' "$repo" >>"$REPORT_DIR/failures.tsv"
    failed=$((failed + 1)); return 0
  fi
  (
    set -euo pipefail
    cd "$dir"
    git config user.name 'zed-pkg tip sync'
    git config user.email 'zed-pkg-tip-sync@users.noreply.github.com'
    base_sha="$(git rev-parse HEAD)"
    git checkout -q -B "$RUN_BRANCH"

    zpkg_changed=false
    if [[ -f .zpkg.toml ]]; then
      cp .zpkg.toml "$RUNNER_TEMP/zpkg-before-$processed.toml"
      ruby -rjson - "$REPORT_DIR/packages.json" .zpkg.toml <<'RUBY'
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
  # Keep a requirement that already names the exact current tip version.
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
      if ! cmp -s .zpkg.toml "$RUNNER_TEMP/zpkg-before-$processed.toml"; then
        zpkg_changed=true
      fi

      # Always let the current-tip resolver refresh a committed lock to the
      # newest versions allowed by the (possibly updated) direct requirements.
      zed_home="$RUNNER_TEMP/zed-home-$processed"
      mkdir -p "$zed_home"
      if ! ZED_HOME="$zed_home" "$ZED_BIN" install --install-mode copy >/tmp/zed-tip-install.log 2>&1; then
        warn "$repo: current-tip Zed resolution failed; preserving authored manifest/lock"
        cp "$RUNNER_TEMP/zpkg-before-$processed.toml" .zpkg.toml
        git checkout -- .zpkg.lock 2>/dev/null || rm -f .zpkg.lock
        zpkg_changed=false
      elif ! "$ZED_BIN" validate --require-lock --json >/tmp/zed-tip-validate.log 2>&1; then
        warn "$repo: regenerated Zed lock did not validate; reverting Zed changes"
        cp "$RUNNER_TEMP/zpkg-before-$processed.toml" .zpkg.toml
        git checkout -- .zpkg.lock 2>/dev/null || rm -f .zpkg.lock
        zpkg_changed=false
      fi
    fi

    cargo_changed=false
    if [[ -f Cargo.toml ]]; then
      cp Cargo.toml "$RUNNER_TEMP/cargo-before-$processed.toml"
      ruby -rjson - "$REPORT_DIR/packages.json" Cargo.toml <<'RUBY'
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
# Inline dependency tables.
text.gsub!(/^([^\n]*git\s*=\s*"([^"]+)"[^\n]*rev\s*=\s*")([0-9a-f]{40})("[^\n]*)$/i) do
  repo = repo_from_url.call($2)
  target = repo && sha_by_repo[repo]
  target ? "#{$1}#{target}#{$4}" : $&
end
# Section-form dependency tables. Only touch a rev when that same TOML table
# contains the GitHub URL, avoiding cross-dependency replacements.
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
      if ! cmp -s Cargo.toml "$RUNNER_TEMP/cargo-before-$processed.toml"; then
        cargo_changed=true
        if [[ -f Cargo.lock ]]; then
          if ! timeout 120s cargo metadata --format-version 1 --no-deps >/dev/null 2>&1; then
            warn "$repo: Cargo metadata failed after tip rewrite; reverting Cargo changes"
            cp "$RUNNER_TEMP/cargo-before-$processed.toml" Cargo.toml
            git checkout -- Cargo.lock 2>/dev/null || true
            cargo_changed=false
          fi
        fi
      fi
    fi

    node_changed=false
    if [[ -f package.json ]]; then
      cp package.json "$RUNNER_TEMP/package-before-$processed.json"
      ruby -rjson - "$REPORT_DIR/packages.json" package.json <<'RUBY'
map_file, manifest = ARGV
packages = JSON.parse(File.read(map_file))
sha_by_repo = packages.to_h { |p| [p["repo"].downcase, p["sha"]] }
text = File.read(manifest)
original = text.dup
sha_by_repo.each do |repo, sha|
  escaped = Regexp.escape(repo)
  text.gsub!(%r{((?:git\+)?https://github\.com/#{escaped}(?:\.git)?#)[0-9a-f]{40}}i, "\\1#{sha}")
  text.gsub!(%r{(github:#{escaped}#)[0-9a-f]{40}}i, "\\1#{sha}")
end
File.write(manifest, text) if text != original
RUBY
      if ! cmp -s package.json "$RUNNER_TEMP/package-before-$processed.json"; then
        node_changed=true
        if [[ -f package-lock.json ]]; then
          if ! timeout 120s npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1; then
            warn "$repo: npm lock refresh failed; reverting package dependency changes"
            cp "$RUNNER_TEMP/package-before-$processed.json" package.json
            git checkout -- package-lock.json 2>/dev/null || true
            node_changed=false
          fi
        fi
      fi
    fi

    git diff --check
    git add .zpkg.toml .zpkg.lock Cargo.toml Cargo.lock package.json package-lock.json 2>/dev/null || true
    if git diff --cached --quiet; then
      exit 10
    fi

    git commit -q -m 'chore: sync Zed dependency tips'
    git push --quiet --force-with-lease origin "HEAD:$RUN_BRANCH"

    body="$RUNNER_TEMP/zed-tip-pr-$processed.md"
    cat >"$body" <<EOF
This automated dependency-edge sync compares this repository against current default-branch tips of repositories that publish a root \`.zpkg.toml\`.

Rules used:
- direct Zed requirements advance only when the dependency's declared \`v<version>\` tag resolves to that dependency repository's current tip;
- \`.zpkg.lock\` is regenerated by the **current-tip zed-cli** and must pass \`zed validate --require-lock --json\` before being kept;
- exact Git \`rev\` references to Zed package repositories advance to the dependency's current default-branch SHA;
- Cargo/package locks are refreshed only when the corresponding source manifest changed successfully;
- no default branch is rewritten and no PR is merged automatically.

Base head before this sync: \`$base_sha\`.
Fleet controller: \`zed-pkg/.github@$GITHUB_SHA\`.
EOF
    pr="$(gh pr list --repo "$repo" --head "$RUN_BRANCH" --state open --json number,url --jq '.[0] // empty' 2>/dev/null || true)"
    if [[ -n "$pr" ]]; then
      number="$(jq -r '.number' <<<"$pr")"
      gh pr edit "$number" --repo "$repo" --title 'chore: sync Zed dependency tips' --body-file "$body" >/dev/null
      url="$(jq -r '.url' <<<"$pr")"
    else
      url="$(gh pr create --repo "$repo" --base "$default_branch" --head "$RUN_BRANCH" --title 'chore: sync Zed dependency tips' --body-file "$body")"
    fi
    printf '%s\t%s\n' "$repo" "$url" >>"$REPORT_DIR/prs.tsv"
  )
  rc=$?
  if [[ $rc -eq 10 ]]; then
    return 0
  elif [[ $rc -ne 0 ]]; then
    warn "$repo: sync failed with exit $rc"
    printf '%s\tsync-exit-%s\n' "$repo" "$rc" >>"$REPORT_DIR/failures.tsv"
    failed=$((failed + 1)); return 0
  fi
  changed=$((changed + 1))
}

while IFS=$'\t' read -r repo branch reason; do
  sync_repo "$repo" "$branch" "$reason"
done <"$REPORT_DIR/selected.tsv"

cat >"$REPORT_DIR/summary.md" <<EOF
# Zed dependency-tip fleet sync

- active repositories enumerated: **$repo_count**
- Zed package-owner repositories: **$package_count**
- dependency/dependent repositories discovered: **$candidate_count**
- repositories processed this run: **$processed**
- repositories with PR updates: **$changed**
- repository-level failures: **$failed**
- minimum requested breadth: **$MIN_REPOS**

The processed count includes repositories already current at their dependency tips; PR count includes only repositories with a real source/lock delta.
EOF

if [[ -s "$REPORT_DIR/prs.tsv" ]]; then
  {
    echo
    echo '## Pull requests'
    echo
    sed 's/^/- `/' "$REPORT_DIR/prs.tsv" | sed $'s/\t/`: /'
  } >>"$REPORT_DIR/summary.md"
fi
if [[ -s "$REPORT_DIR/failures.tsv" ]]; then
  {
    echo
    echo '## Failures'
    echo
    sed 's/^/- `/' "$REPORT_DIR/failures.tsv" | sed $'s/\t/`: /'
  } >>"$REPORT_DIR/summary.md"
fi

cat "$REPORT_DIR/summary.md"
(( processed >= MIN_REPOS ))
