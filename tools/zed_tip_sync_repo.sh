#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ZED_BIN:?ZED_BIN must point at current-tip zed-cli}"

repo="${1:?repository required}"
default_branch="${2:?default branch required}"
reason="${3:-graph-seed}"
package_map="${4:?packages.json required}"
RUN_BRANCH="${RUN_BRANCH:-automation/zed-tip-sync-20260914}"
RESULT_DIR="${RESULT_DIR:-$PWD/artifacts/zed-tip-sync/results}"
mkdir -p "$RESULT_DIR"
RESULT_DIR="$(cd "$RESULT_DIR" && pwd)"
DIAG_DIR="${DIAG_DIR:-$(dirname "$RESULT_DIR")/diagnostics}"
mkdir -p "$DIAG_DIR"
DIAG_DIR="$(cd "$DIAG_DIR" && pwd)"
package_map="$(cd "$(dirname "$package_map")" && pwd)/$(basename "$package_map")"

safe="${repo//\//__}"
result_file="$RESULT_DIR/$safe.tsv"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

log() { printf '[zed-tip-repo] %s: %s\n' "$repo" "$*"; }
warn() { printf '[zed-tip-repo] WARN %s: %s\n' "$repo" "$*" >&2; }
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$repo" "${2:-}" "${3:-}" >"$result_file"; }
preserve_diag() {
  local label="$1" src="$2"
  [[ -f "$src" ]] || return 0
  cp "$src" "$DIAG_DIR/${safe}__${label}" || true
}

update_zpkg_manifest() {
  local manifest="$1"
  ruby -rjson - "$package_map" "$manifest" <<'RUBY'
map_file, manifest = ARGV
packages = JSON.parse(File.read(map_file))
# Canonical package manifests provide candidate release versions. Publication
# admission is decided by current-tip Zed resolution below, not by requiring the
# release tag to equal today's repository tip. This lets immutable releases stay
# valid after main advances while still failing closed on unpublished versions.
versions = packages.to_h { |p| [p["coordinate"].downcase, p["version"]] }
triplet = ->(s) do
  m = s.match(/\A(\d+)\.(\d+)\.(\d+)\z/)
  m && [m[1].to_i, m[2].to_i, m[3].to_i]
end
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
  simple = current.match(/\A(\^|~|=)?(\d+\.\d+\.\d+)\z/)
  next line unless simple
  prefix = simple[1].to_s
  current_v = triplet.call(simple[2])
  target_v = triplet.call(target)
  next line unless current_v && target_v && target_v > current_v
  changed = true
  "#{m[1]}\"#{coord}\"#{m[3]}\"#{prefix}#{target}\"#{m[5]}\n"
end
File.write(manifest, lines.join) if changed
RUBY
}

update_cargo_git_revs() {
  local manifest="$1"
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
  dep_repo = repo_from_url.call($2)
  target = dep_repo && sha_by_repo[dep_repo]
  target && target != $3 ? "#{$1}#{target}#{$4}" : $&
end
parts = text.split(/(?=^\s*\[[^\]]+\]\s*$)/)
parts.map! do |part|
  git = part.match(/^\s*git\s*=\s*"([^"]+)"\s*(?:#.*)?$/i)
  next part unless git
  dep_repo = repo_from_url.call(git[1])
  target = dep_repo && sha_by_repo[dep_repo]
  next part unless target
  part.sub(/^(\s*rev\s*=\s*")([0-9a-f]{40})("\s*(?:#.*)?)$/i) do
    target == $2 ? $& : "#{$1}#{target}#{$3}"
  end
end
text = parts.join
File.write(manifest, text) if text != original
RUBY
}

update_package_json_git_refs() {
  local manifest="$1"
  ruby -rjson - "$package_map" "$manifest" <<'RUBY'
map_file, manifest = ARGV
packages = JSON.parse(File.read(map_file))
sha_by_repo = packages.to_h { |p| [p["repo"].downcase, p["sha"]] }
text = File.read(manifest)
original = text.dup
sha_by_repo.each do |dep_repo, sha|
  owner, name = dep_repo.split('/', 2)
  escaped = Regexp.escape("#{owner}/#{name}")
  text.gsub!(/((?:github:#{escaped}|git\+https:\/\/github\.com\/#{escaped}(?:\.git)?|https:\/\/github\.com\/#{escaped}(?:\.git)?)#)([0-9a-f]{7,40})/i) do
    $2 == sha ? $& : "#{$1}#{sha}"
  end
end
File.write(manifest, text) if text != original
RUBY
}

relevant_paths() {
  local p
  for p in .zpkg.toml .zpkg.lock Cargo.toml Cargo.lock package.json package-lock.json; do
    if [[ -e "$p" ]] || git ls-files --error-unmatch "$p" >/dev/null 2>&1; then
      printf '%s\n' "$p"
    fi
  done
}

log "clone $default_branch"
if ! git clone --quiet --filter=blob:none --depth=1 --branch "$default_branch" "https://github.com/$repo.git" "$work/repo"; then
  warn "branch-specific clone failed; retrying repository default branch through Git transport"
  rm -rf "$work/repo"
  if ! git clone --quiet --filter=blob:none --depth=1 "https://github.com/$repo.git" "$work/repo"; then
    record failure clone-failed "$default_branch"
    exit 20
  fi
  default_branch="$(git -C "$work/repo" branch --show-current 2>/dev/null || true)"
  if [[ -z "$default_branch" ]]; then
    if git -C "$work/repo" rev-parse --verify HEAD >/dev/null 2>&1; then
      default_branch="$(git -C "$work/repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    else
      record no-change empty-repository
      exit 0
    fi
  fi
  [[ -n "$default_branch" ]] || {
    record failure default-branch-unresolved
    exit 20
  }
fi
cd "$work/repo"
git config user.name 'zed-pkg tip sync'
git config user.email 'zed-pkg-tip-sync@users.noreply.github.com'
base_sha="$(git rev-parse HEAD)"
git fetch origin "refs/heads/$RUN_BRANCH:refs/remotes/origin/$RUN_BRANCH" >/dev/null 2>&1 || true
git checkout -q -B "$RUN_BRANCH"

if [[ -f .zpkg.toml ]]; then
  cp .zpkg.toml "$work/zpkg.before"
  had_lock=false
  if [[ -f .zpkg.lock ]]; then had_lock=true; cp .zpkg.lock "$work/zpkg.lock.before"; fi
  update_zpkg_manifest .zpkg.toml
  mkdir -p "$work/zed-home"
  if ! timeout 180s env ZED_HOME="$work/zed-home" "$ZED_BIN" install --install-mode copy >"$work/zed-install.log" 2>&1; then
    warn 'zed resolution failed; reverting zed manifest/lock changes'
    preserve_diag zed-install.log "$work/zed-install.log"
    cp "$work/zpkg.before" .zpkg.toml
    if $had_lock; then cp "$work/zpkg.lock.before" .zpkg.lock; else rm -f .zpkg.lock; fi
  elif ! "$ZED_BIN" validate --require-lock --json >"$work/zed-validate.json" 2>&1; then
    warn 'zed lock validation failed; reverting zed manifest/lock changes'
    preserve_diag zed-validate.json "$work/zed-validate.json"
    cp "$work/zpkg.before" .zpkg.toml
    if $had_lock; then cp "$work/zpkg.lock.before" .zpkg.lock; else rm -f .zpkg.lock; fi
  fi
fi

if [[ -f Cargo.toml ]]; then
  cp Cargo.toml "$work/Cargo.toml.before"
  had_cargo_lock=false
  if [[ -f Cargo.lock ]]; then had_cargo_lock=true; cp Cargo.lock "$work/Cargo.lock.before"; fi
  update_cargo_git_revs Cargo.toml
  if ! cmp -s Cargo.toml "$work/Cargo.toml.before"; then
    if ! timeout 180s cargo metadata --format-version 1 --no-deps >"$work/cargo-metadata.json" 2>"$work/cargo-metadata.err"; then
      warn 'cargo metadata failed; reverting Cargo dependency-tip changes'
      preserve_diag cargo-metadata.err "$work/cargo-metadata.err"
      cp "$work/Cargo.toml.before" Cargo.toml
      if $had_cargo_lock; then cp "$work/Cargo.lock.before" Cargo.lock; else rm -f Cargo.lock; fi
    fi
  fi
fi

if [[ -f package.json ]]; then
  cp package.json "$work/package.json.before"
  had_npm_lock=false
  if [[ -f package-lock.json ]]; then had_npm_lock=true; cp package-lock.json "$work/package-lock.json.before"; fi
  update_package_json_git_refs package.json
  if ! cmp -s package.json "$work/package.json.before" && $had_npm_lock; then
    if ! timeout 180s npm install --package-lock-only --ignore-scripts --no-audit --no-fund >"$work/npm-lock.log" 2>&1; then
      warn 'npm lock refresh failed; reverting package.json Git-tip changes'
      preserve_diag npm-lock.log "$work/npm-lock.log"
      cp "$work/package.json.before" package.json
      cp "$work/package-lock.json.before" package-lock.json
    fi
  fi
fi

rm -rf .vendor/.zed .zed_modules zed_modules node_modules target >/dev/null 2>&1 || true
mapfile -t paths < <(relevant_paths)
if (( ${#paths[@]} == 0 )); then
  record no-change "$base_sha"
  exit 0
fi
if git diff --quiet -- "${paths[@]}"; then
  record no-change "$base_sha"
  exit 0
fi
for p in "${paths[@]}"; do git add -A -- "$p"; done
if git diff --cached --quiet; then
  record no-change "$base_sha"
  exit 0
fi

diffstat="$(git diff --cached --stat | tr '\n' '; ' | sed 's/; $//')"
git commit -m 'chore: sync dependency tips through zed' >/dev/null
head_sha="$(git rev-parse HEAD)"
if remote_sha="$(git rev-parse "refs/remotes/origin/$RUN_BRANCH" 2>/dev/null)"; then
  git push --quiet --force-with-lease="refs/heads/$RUN_BRANCH:$remote_sha" origin "HEAD:refs/heads/$RUN_BRANCH"
else
  git push --quiet --force-with-lease origin "HEAD:refs/heads/$RUN_BRANCH"
fi

cat >"$work/pr-body.md" <<EOF_BODY
Synchronizes admitted dependency identities to current repository tips using the current \`zed-pkg/zed-cli\` resolver.

Safety rules:
- Zed registry requirements move only to a newer canonical package version that current-tip Zed can actually resolve and validate into \`.zpkg.lock\`; an immutable release remains valid after its source repository advances.
- Exact Git \`rev\` dependencies move to the dependency repository's exact current tip SHA.
- \`.zpkg.lock\` is regenerated by current-tip \`zed\` and retained only when \`zed validate --require-lock --json\` succeeds.
- Cargo Git-revision changes are retained only when \`cargo metadata --format-version 1 --no-deps\` succeeds.
- Existing npm locks are refreshed with install scripts disabled when a Git SHA changes; a failed lock refresh reverts that npm change.
- This automation does not merge the PR; exact-head repository CI and normal review remain the admission gate.

Base before sync: \`$base_sha\`
Candidate head: \`$head_sha\`
Discovery reason: \`$reason\`
Changed files: \`$diffstat\`
EOF_BODY

pr_number="$(gh pr list --repo "$repo" --head "$RUN_BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
if [[ -n "$pr_number" ]]; then
  if ! gh pr edit "$pr_number" --repo "$repo" --title 'chore: sync dependency tips through zed' --body-file "$work/pr-body.md" >/dev/null; then
    record pushed "$head_sha" "https://github.com/$repo/tree/$RUN_BRANCH"
    warn 'branch pushed but PR refresh is REST-rate-limited or unauthorized'
    exit 0
  fi
else
  if ! gh pr create --repo "$repo" --base "$default_branch" --head "$RUN_BRANCH" --title 'chore: sync dependency tips through zed' --body-file "$work/pr-body.md" >/dev/null; then
    record pushed "$head_sha" "https://github.com/$repo/tree/$RUN_BRANCH"
    warn 'branch pushed but PR creation is REST-rate-limited or unauthorized'
    exit 0
  fi
  pr_number="$(gh pr list --repo "$repo" --head "$RUN_BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
fi
pr_url=""
[[ -n "$pr_number" ]] && pr_url="https://github.com/$repo/pull/$pr_number"
if [[ -n "$pr_url" ]]; then
  record updated "$head_sha" "$pr_url"
  log "opened/refreshed $pr_url"
else
  record pushed "$head_sha" "https://github.com/$repo/tree/$RUN_BRANCH"
  warn 'dependency-tip branch pushed, but PR number could not be resolved'
fi
