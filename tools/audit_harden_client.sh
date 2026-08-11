#!/usr/bin/env bash
set -Eeuo pipefail

: "${CLIENT_REPO:?CLIENT_REPO is required}"
: "${CLIENT_ORG:?CLIENT_ORG is required}"
: "${CLIENT_NAME:?CLIENT_NAME is required}"
: "${CLIENT_PREFIX:?CLIENT_PREFIX is required}"
: "${ZED_ORG:?ZED_ORG is required}"
: "${ZED_NAME:?ZED_NAME is required}"
: "${ZED_COORDINATE:?ZED_COORDINATE is required}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
: "${TEST_ORG:?TEST_ORG is required}"
: "${CONSUMERS_JSON:=[]}"
: "${TEST_CONSUMERS_JSON:=[]}"
: "${DISCOVERY_ERRORS_JSON:=[]}"
: "${DISCOVERY_WARNINGS_JSON:=[]}"
: "${APPLY:=true}"
: "${GITHUB_WORKSPACE:=$(pwd)}"

WORKSPACE_ROOT="$GITHUB_WORKSPACE/fleet-workspace"
TARGET="$WORKSPACE_ROOT/target"
CONSUMERS_ROOT="$WORKSPACE_ROOT/consumers"
TOOLCHAIN="$GITHUB_WORKSPACE/toolchain"
ZED="$TOOLCHAIN/zed"
HARDENER="$TOOLCHAIN/harden_client_contract.py"
SCHEMA="$TOOLCHAIN/client-api.schema.json"
REPORT="$GITHUB_WORKSPACE/reports/${CLIENT_ORG}__${CLIENT_NAME}"
BRANCH="automation/nightly-client-hardening"
MEMBERS_FILE="$REPORT/workspace-members.txt"
PACKAGE_DIRS_FILE="$REPORT/consumer-package-dirs.txt"
CONSUMER_REPOS_FILE="$REPORT/consumer-repositories.txt"
export ZED_HOME="${ZED_HOME:-$GITHUB_WORKSPACE/.zed-home}"
mkdir -p "$REPORT" "$CONSUMERS_ROOT" "$ZED_HOME"
: >"$MEMBERS_FILE"
: >"$PACKAGE_DIRS_FILE"
: >"$CONSUMER_REPOS_FILE"
STATUS=0
CHANGED=false

json_lines() {
  python - "$1" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
if not isinstance(value, list):
    raise SystemExit("expected a JSON array")
for item in value:
    print(str(item))
PY
}

json_count() {
  python - "$1" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
print(len(value) if isinstance(value, list) else 0)
PY
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

run_logged() {
  local name
  name="$(safe_name "$1")"
  shift
  echo "::group::$name"
  set +e
  "$@" >"$REPORT/${name}.log" 2>&1
  local rc=$?
  set -e
  cat "$REPORT/${name}.log"
  echo "::endgroup::"
  printf '%s\n' "$rc" >"$REPORT/${name}.exit-code"
  if (( rc != 0 )); then
    STATUS=1
    echo "::error title=${CLIENT_REPO}: ${name} failed::exit code ${rc}"
  fi
  return 0
}

node_install_command() {
  local directory="$1"
  if [[ -f "$directory/pnpm-lock.yaml" ]]; then
    printf '%s' 'corepack enable && pnpm install --frozen-lockfile'
  elif [[ -f "$directory/yarn.lock" ]]; then
    printf '%s' 'corepack enable && yarn install --immutable'
  elif [[ -f "$directory/package-lock.json" || -f "$directory/npm-shrinkwrap.json" ]]; then
    printf '%s' 'npm ci'
  else
    printf '%s' 'npm install --no-package-lock --ignore-scripts=false'
  fi
}

node_run_command() {
  local directory="$1"
  if [[ -f "$directory/pnpm-lock.yaml" ]]; then
    printf 'pnpm run %q' "$2"
  elif [[ -f "$directory/yarn.lock" ]]; then
    printf 'yarn run %q' "$2"
  else
    printf 'npm run %q' "$2"
  fi
}

run_native_tests() {
  local root="$1"
  local label="$2"
  local roots_file="$REPORT/$(safe_name "$label").roots"
  (
    cd "$root"
    find . -maxdepth 7 \
      \( -path './.git' -o -path '*/.git' -o -path '*/node_modules' -o -path '*/target' -o -path '*/.venv' -o -path '*/zed_modules' -o -path '*/.vendor' -o -path '*/.zed-build' -o -path '*/build' \
         -o -path '*/dist' -o -path '*/vendor' \) -prune -o \
      \( -name Cargo.toml -o -name package.json -o -name deno.json -o -name deno.jsonc \
         -o -name go.mod -o -name pubspec.yaml -o -name pyproject.toml -o -name mix.exs \
         -o -name gleam.toml -o -name rebar.config -o -name CMakeLists.txt -o -name build.zig \
         -o -name build.gradle -o -name build.gradle.kts -o -name settings.gradle -o -name settings.gradle.kts \
         -o -name Package.swift -o -name composer.json -o -name '*.gemspec' -o -name .zpkg.toml \) \
      -printf '%h\n' | sort -u
  ) >"$roots_file"

  if [[ ! -s "$roots_file" ]]; then
    STATUS=1
    echo "::error title=${CLIENT_REPO}: ${label} compile coverage::No supported native package roots found under ${root}"
    return 0
  fi

  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    local directory="$root/${relative#./}"
    local safe
    safe="$(safe_name "$relative")"

    if [[ -f "$directory/.zpkg.toml" ]]; then
      zed_test_script="$(python -c 'import sys,tomllib,pathlib; value=tomllib.loads(pathlib.Path(sys.argv[1]).read_text()); scripts=value.get("scripts",{}); print("test" if isinstance(scripts,dict) and isinstance(scripts.get("test"),str) and scripts["test"].strip() else "")' "$directory/.zpkg.toml" 2>/dev/null || true)"
      if [[ -n "$zed_test_script" ]]; then
        run_logged "${label}-${safe}-zed-script-test" bash -lc "cd '$directory' && '$ZED' run test"
      fi
    fi

    if [[ -f "$directory/CMakeLists.txt" ]]; then
      run_logged "${label}-${safe}-cmake" bash -lc \
        "cd '$directory' && rm -rf .zed-build && cmake -S . -B .zed-build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build .zed-build --parallel && ctest --test-dir .zed-build --output-on-failure"
    fi

    if [[ -f "$directory/build.zig" ]]; then
      run_logged "${label}-${safe}-zig" bash -lc "cd '$directory' && zig build"
    fi

    if [[ -f "$directory/Cargo.toml" ]]; then
      local cargo_locked=""
      [[ -f "$directory/Cargo.lock" ]] && cargo_locked="--locked"
      run_logged "${label}-${safe}-cargo-test" bash -lc \
        "cd '$directory' && cargo test $cargo_locked --workspace --all-targets --all-features"
      if [[ "$relative" == *"wasm"* || -f "$directory/.zed-client-contract.json" ]] && \
         grep -q 'cdylib' "$directory/Cargo.toml" 2>/dev/null; then
        run_logged "${label}-${safe}-cargo-wasm-check" bash -lc \
          "cd '$directory' && cargo check $cargo_locked --target wasm32-unknown-unknown --all-features"
      fi
    fi

    if [[ -f "$directory/go.mod" ]]; then
      run_logged "${label}-${safe}-go-test" bash -lc "cd '$directory' && go test ./..."
    fi

    if [[ -f "$directory/package.json" ]]; then
      local install_cmd scripts script_cmd
      install_cmd="$(node_install_command "$directory")"
      scripts="$(node - "$directory/package.json" <<'NODE'
const fs = require('fs');
const p = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
for (const name of ['test', 'check', 'typecheck', 'build']) {
  const value = p.scripts && p.scripts[name];
  if (!value) continue;
  if (name === 'test' && /no test specified/i.test(value)) continue;
  console.log(name);
}
NODE
)"
      run_logged "${label}-${safe}-node-install" bash -lc "cd '$directory' && $install_cmd"
      if [[ -n "$scripts" ]]; then
        while IFS= read -r script; do
          [[ -n "$script" ]] || continue
          script_cmd="$(node_run_command "$directory" "$script")"
          run_logged "${label}-${safe}-node-${script}" bash -lc "cd '$directory' && $script_cmd"
        done <<<"$scripts"
      else
        if find "$directory" -maxdepth 5 -type f -name '*.ts' -not -path '*/node_modules/*' -print -quit | grep -q .; then
          run_logged "${label}-${safe}-typescript-check" bash -lc \
            "cd '$directory' && mapfile -d '' files < <(find . -maxdepth 5 -type f -name '*.ts' -not -path './node_modules/*' -print0); tsc --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext \"\${files[@]}\""
        elif find "$directory" -maxdepth 5 -type f -name '*.js' -not -path '*/node_modules/*' -print -quit | grep -q .; then
          run_logged "${label}-${safe}-javascript-check" bash -lc \
            "cd '$directory' && find . -maxdepth 5 -type f -name '*.js' -not -path './node_modules/*' -print0 | xargs -0 -r -n1 node --check"
        else
          STATUS=1
          echo "::error title=${CLIENT_REPO}: ${label} Node coverage::${directory}/package.json has no test/check/typecheck/build script and no JavaScript/TypeScript source"
        fi
      fi
    fi

    if [[ -f "$directory/deno.json" || -f "$directory/deno.jsonc" ]]; then
      local deno_config="deno.json"
      [[ -f "$directory/deno.json" ]] || deno_config="deno.jsonc"
      if grep -qE '"test"[[:space:]]*:' "$directory/$deno_config"; then
        run_logged "${label}-${safe}-deno-test" bash -lc "cd '$directory' && deno task --config '$deno_config' test"
      else
        run_logged "${label}-${safe}-deno-check" bash -lc \
          "cd '$directory' && mapfile -d '' files < <(find . -maxdepth 5 -type f -name '*.ts' -print0); (( \${#files[@]} > 0 )) && deno check --config '$deno_config' \"\${files[@]}\""
      fi
    fi

    if [[ -f "$directory/pubspec.yaml" ]]; then
      run_logged "${label}-${safe}-dart-analyze" bash -lc "cd '$directory' && dart pub get && dart analyze"
      if [[ -d "$directory/test" ]]; then
        run_logged "${label}-${safe}-dart-test" bash -lc "cd '$directory' && dart test"
      fi
    fi

    if [[ -f "$directory/pyproject.toml" ]]; then
      run_logged "${label}-${safe}-python-build" bash -lc \
        "cd '$directory' && (python -m pip install --disable-pip-version-check -e '.[test]' || python -m pip install --disable-pip-version-check -e .) && python -m compileall -q ."
      if [[ -d "$directory/tests" || -f "$directory/pytest.ini" || -f "$directory/pyproject.toml" && -d "$directory/test" ]]; then
        run_logged "${label}-${safe}-python-test" bash -lc "cd '$directory' && python -m pytest"
      fi
    fi

    if [[ -f "$directory/mix.exs" ]]; then
      run_logged "${label}-${safe}-mix-test" bash -lc \
        "cd '$directory' && mix local.hex --force && mix local.rebar --force && mix deps.get && mix compile --warnings-as-errors && mix test"
    fi

    if [[ -f "$directory/gleam.toml" ]]; then
      run_logged "${label}-${safe}-gleam-test" bash -lc \
        "cd '$directory' && gleam deps download && gleam build && gleam test"
    fi

    if [[ -f "$directory/rebar.config" ]]; then
      run_logged "${label}-${safe}-rebar-test" bash -lc "cd '$directory' && rebar3 compile && rebar3 eunit"
    fi

    if [[ -f "$directory/build.gradle" || -f "$directory/build.gradle.kts" || -f "$directory/settings.gradle" || -f "$directory/settings.gradle.kts" ]]; then
      local gradle_cmd="gradle"
      [[ -x "$directory/gradlew" ]] && gradle_cmd="./gradlew"
      run_logged "${label}-${safe}-gradle-test" bash -lc \
        "cd '$directory' && $gradle_cmd --no-daemon --stacktrace test"
    fi

    if [[ -f "$directory/Package.swift" ]]; then
      if [[ -d "$directory/Tests" ]]; then
        run_logged "${label}-${safe}-swift-test" bash -lc "cd '$directory' && swift test"
      else
        run_logged "${label}-${safe}-swift-build" bash -lc "cd '$directory' && swift build"
      fi
    fi

    if [[ -f "$directory/composer.json" ]]; then
      run_logged "${label}-${safe}-composer" bash -lc \
        "cd '$directory' && composer validate --no-check-publish && composer install --no-interaction --prefer-dist --no-progress && find . -maxdepth 6 -type f -name '*.php' -not -path './vendor/*' -print0 | xargs -0 -r -n1 php -l"
    fi

    if find "$directory" -maxdepth 1 -type f -name '*.gemspec' -print -quit | grep -q .; then
      run_logged "${label}-${safe}-ruby-gem" bash -lc \
        "cd '$directory' && gem build ./*.gemspec && find . -maxdepth 6 -type f -name '*.rb' -not -path './vendor/*' -print0 | xargs -0 -r -n1 ruby -c"
      if [[ -f "$directory/Gemfile" && -f "$directory/Rakefile" ]]; then
        run_logged "${label}-${safe}-ruby-test" bash -lc \
          "cd '$directory' && bundle install && bundle exec rake test"
      fi
    fi
  done <"$roots_file"
}

find_consumer_packages() {
  local repository_root="$1"
  python - "$repository_root" "$ZED_COORDINATE" "$CLIENT_REPO" <<'PY'
from __future__ import annotations
import sys, tomllib
from pathlib import Path
root = Path(sys.argv[1]).resolve()
coordinates = {sys.argv[2].casefold(), sys.argv[3].casefold()}
ignored = {".git", "node_modules", "target", ".venv", "zed_modules", ".vendor", "vendor", "dist", "build"}
for manifest in sorted(root.rglob(".zpkg.toml")):
    relative = manifest.relative_to(root)
    if any(part in ignored for part in relative.parts):
        continue
    try:
        text = manifest.read_text(encoding="utf-8")
        parsed = tomllib.loads(text)
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
        continue
    dependencies: set[str] = set()
    for key in ("dependencies", "build-dependencies", "build_dependencies"):
        value = parsed.get(key, {})
        if isinstance(value, dict):
            dependencies.update(str(item).casefold() for item in value)
    folded = text.casefold()
    if dependencies & coordinates or any(value in folded for value in coordinates):
        print(manifest.parent)
PY
}

write_workspace_manifest() {
  python - "$WORKSPACE_ROOT" "$MEMBERS_FILE" "$CLIENT_PREFIX" <<'PY'
from __future__ import annotations
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
members = [line.strip() for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines() if line.strip()]
slug = re.sub(r"[^a-z0-9]+", "-", sys.argv[3].casefold()).strip("-") or "client"
unique = []
for item in ["target", *members]:
    if item not in unique:
        unique.append(item)
lines = [
    "[package]",
    'org = "zed-local"',
    f'name = "nightly-{slug}-clients-workspace"',
    'version = "0.0.0"',
    'description = "Ephemeral nightly current-tip client consumer workspace"',
    'license = "MIT"',
    "",
    "[package.repository]",
    'vcs = "git"',
    f'url = "https://localhost/zed-local/nightly-{slug}-clients-workspace"',
    "",
    "[workspace]",
    "members = [",
]
lines.extend(f"  {json.dumps(item)}," for item in unique)
lines.extend(["]", ""])
(root / ".zpkg.toml").write_text("\n".join(lines), encoding="utf-8")
PY
}

chmod +x "$ZED" "$HARDENER"
if [[ ! -x "$ZED" || ! -f "$HARDENER" || ! -f "$SCHEMA" || ! -f "$TOOLCHAIN/tips.json" ]]; then
  echo "canonical toolchain artifact is incomplete" >&2
  exit 2
fi
if [[ ! -d "$TARGET/.git" ]]; then
  echo "target checkout is missing at $TARGET" >&2
  exit 2
fi

json_lines "$DISCOVERY_ERRORS_JSON" >"$REPORT/discovery-errors.txt"
json_lines "$DISCOVERY_WARNINGS_JSON" >"$REPORT/discovery-warnings.txt"
if [[ -s "$REPORT/discovery-errors.txt" ]]; then
  STATUS=1
  while IFS= read -r error; do
    echo "::error title=${CLIENT_REPO} discovery::${error}"
  done <"$REPORT/discovery-errors.txt"
fi
while IFS= read -r warning; do
  [[ -n "$warning" ]] && echo "::warning title=${CLIENT_REPO} discovery::${warning}"
done <"$REPORT/discovery-warnings.txt"

if [[ "$(json_count "$TEST_CONSUMERS_JSON")" -lt 1 ]]; then
  STATUS=1
  echo "::error title=${CLIENT_REPO} test coverage::No consumer was discovered in ${TEST_ORG}"
fi

git -C "$TARGET" config user.name "zed-pkg automation"
git -C "$TARGET" config user.email "zed-pkg-automation@users.noreply.github.com"
git -C "$TARGET" fetch origin "$DEFAULT_BRANCH" "$BRANCH" || git -C "$TARGET" fetch origin "$DEFAULT_BRANCH"
git -C "$TARGET" checkout -B "$BRANCH" "origin/$DEFAULT_BRANCH"

run_logged hardener-write python "$HARDENER" \
  --root "$TARGET" \
  --schema "$SCHEMA" \
  --org "$ZED_ORG" \
  --repo "$ZED_NAME" \
  --prefix "$CLIENT_PREFIX" \
  --write \
  --output "$REPORT/hardener-write.json"
run_logged hardener-check python "$HARDENER" \
  --root "$TARGET" \
  --schema "$SCHEMA" \
  --org "$ZED_ORG" \
  --repo "$ZED_NAME" \
  --prefix "$CLIENT_PREFIX" \
  --check \
  --output "$REPORT/hardener-check.json"
run_logged normalize-zed-repository-url python - "$TARGET/.zpkg.toml" "$CLIENT_REPO" <<'PY'
from pathlib import Path
import sys, tomlkit
path = Path(sys.argv[1])
data = tomlkit.parse(path.read_text(encoding="utf-8"))
package = data.setdefault("package", tomlkit.table())
repository = package.setdefault("repository", tomlkit.table())
repository["vcs"] = "git"
repository["url"] = f"https://github.com/{sys.argv[2]}"
path.write_text(tomlkit.dumps(data), encoding="utf-8")
PY
run_logged zed-validate bash -lc "cd '$TARGET' && '$ZED' validate --json"
run_logged zed-install-target bash -lc "cd '$TARGET' && '$ZED' install"
run_logged git-diff-check git -C "$TARGET" diff --check

if ! git -C "$TARGET" diff --quiet || [[ -n "$(git -C "$TARGET" ls-files --others --exclude-standard)" ]]; then
  CHANGED=true
  git -C "$TARGET" add -A
  if ! git -C "$TARGET" commit -m "feat: harden canonical polyglot client contract"; then
    STATUS=1
    echo "::error title=${CLIENT_REPO} commit::Unable to commit generated hardening changes"
  fi
fi

run_native_tests "$TARGET" "client"
run_logged zed-release-preflight bash -lc "cd '$TARGET' && '$ZED' release preflight"
run_logged zed-r2g bash -lc "cd '$TARGET' && '$ZED' r2g"

while IFS= read -r consumer; do
  [[ -n "$consumer" ]] || continue
  key="${consumer//\//__}"
  destination="$CONSUMERS_ROOT/$key"
  run_logged "clone-$key" gh repo clone "$consumer" "$destination" -- --depth=1
  if [[ ! -d "$destination/.git" ]]; then
    continue
  fi
  printf '%s\t%s\n' "$consumer" "$(python - "$WORKSPACE_ROOT" "$destination" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[2]).resolve().relative_to(Path(sys.argv[1]).resolve()).as_posix())
PY
)" >>"$CONSUMER_REPOS_FILE"

  found=0
  while IFS= read -r package_dir; do
    [[ -n "$package_dir" ]] || continue
    found=$((found + 1))
    relative="$(python - "$WORKSPACE_ROOT" "$package_dir" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[2]).resolve().relative_to(Path(sys.argv[1]).resolve()).as_posix())
PY
)"
    printf '%s\n' "$relative" >>"$MEMBERS_FILE"
    printf '%s\t%s\n' "$consumer" "$relative" >>"$PACKAGE_DIRS_FILE"
    run_logged "consumer-$key-package-$found-zed-validate" bash -lc "cd '$package_dir' && '$ZED' validate --json"
  done < <(find_consumer_packages "$destination")

  if (( found == 0 )); then
    STATUS=1
    echo "::error title=${CLIENT_REPO} consumer contract::${consumer} was discovered but no .zpkg.toml dependency on ${ZED_COORDINATE} was found after checkout"
  fi
done < <(json_lines "$CONSUMERS_JSON")

if [[ -s "$MEMBERS_FILE" ]]; then
  sort -u -o "$MEMBERS_FILE" "$MEMBERS_FILE"
  write_workspace_manifest
  run_logged workspace-zed-validate bash -lc "cd '$WORKSPACE_ROOT' && '$ZED' validate --json"
  run_logged workspace-zed-install bash -lc "cd '$WORKSPACE_ROOT' && '$ZED' install"
  while IFS=$'\t' read -r consumer relative; do
    [[ -n "$relative" ]] || continue
    run_logged "workspace-${consumer//\//__}-$(safe_name "$relative")-zed-build" \
      bash -lc "cd '$WORKSPACE_ROOT/$relative' && '$ZED' build --force"
  done <"$PACKAGE_DIRS_FILE"
  while IFS=$'\t' read -r consumer repository_relative; do
    [[ -n "$repository_relative" ]] || continue
    run_native_tests "$WORKSPACE_ROOT/$repository_relative" "consumer-${consumer//\//__}"
  done <"$CONSUMER_REPOS_FILE"
else
  STATUS=1
  echo "::error title=${CLIENT_REPO} workspace coverage::No current-tip Zed consumer packages could be linked into the workspace"
fi

TIPS="$(cat "$TOOLCHAIN/tips.json")"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-zed-pkg/.github}/actions/runs/${GITHUB_RUN_ID:-unknown}"
{
  echo "# ${CLIENT_REPO} nightly hardening"
  echo
  echo "- Zed coordinate: \`${ZED_COORDINATE}\`"
  echo "- changed: **${CHANGED}**"
  echo "- paired test organization: \`${TEST_ORG}\`"
  echo "- consumers tested: **$(json_count "$CONSUMERS_JSON")**"
  echo "- paired test consumers: **$(json_count "$TEST_CONSUMERS_JSON")**"
  echo "- workspace consumer packages: **$(wc -l <"$MEMBERS_FILE" | tr -d ' ')**"
  echo "- target matrix: **20 runtimes** (hard minimum: 15)"
  echo "- final status: **$([[ "$STATUS" -eq 0 ]] && echo passed || echo failed)**"
  echo "- run: ${RUN_URL}"
  echo
  echo '```json'
  echo "$TIPS"
  echo '```'
} >"$REPORT/summary.md"
cat "$REPORT/summary.md" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

PR_NUMBER=""
if [[ "$CHANGED" == true && "$APPLY" == true ]]; then
  if ! git -C "$TARGET" push --force-with-lease origin "HEAD:$BRANCH" >"$REPORT/git-push.log" 2>&1; then
    cat "$REPORT/git-push.log"
    STATUS=1
    echo "::error title=${CLIENT_REPO} push::Unable to push ${BRANCH}"
  else
    PR_NUMBER="$(gh pr list --repo "$CLIENT_REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
    body_file="$REPORT/pr-body.md"
    {
      echo "Automated nightly hardening against the current \`zed-pkg/zed-clients\`, \`zed-pkg/zed-cli\`, and \`zed-pkg/zed-api-server.rs\` tips."
      echo
      cat "$REPORT/summary.md"
      echo
      echo "The branch contains a 20-target client matrix, canonical public/private API schema, deterministic parity fingerprints, current Zed manifest normalization, and paired-test-org consumer verification."
    } >"$body_file"
    if [[ -n "$PR_NUMBER" ]]; then
      if ! gh pr edit "$PR_NUMBER" --repo "$CLIENT_REPO" --title "chore: nightly polyglot client hardening" --body-file "$body_file"; then
        STATUS=1
      fi
    else
      if ! PR_URL="$(gh pr create --repo "$CLIENT_REPO" --base "$DEFAULT_BRANCH" --head "$BRANCH" --title "chore: nightly polyglot client hardening" --body-file "$body_file")"; then
        STATUS=1
      else
        PR_NUMBER="$(gh pr view "$PR_URL" --repo "$CLIENT_REPO" --json number --jq .number)"
      fi
    fi
    if [[ -n "$PR_NUMBER" ]]; then
      gh pr comment "$PR_NUMBER" --repo "$CLIENT_REPO" --body-file "$REPORT/summary.md" || true
    fi
  fi
elif [[ "$CHANGED" == true ]]; then
  echo "::notice title=${CLIENT_REPO} dry run::Changes were generated but APPLY is false"
fi

ISSUE_TITLE="[nightly] client fleet hardening failures"
if [[ "$APPLY" == true ]]; then
  ISSUE_NUMBER="$(gh issue list --repo "$CLIENT_REPO" --state open --search "${ISSUE_TITLE} in:title" --json number,title --jq '.[] | select(.title == "[nightly] client fleet hardening failures") | .number' | head -n1 || true)"
  if (( STATUS != 0 )); then
    if [[ -n "$ISSUE_NUMBER" ]]; then
      gh issue comment "$ISSUE_NUMBER" --repo "$CLIENT_REPO" --body-file "$REPORT/summary.md" || true
    else
      gh issue create --repo "$CLIENT_REPO" --title "$ISSUE_TITLE" --body-file "$REPORT/summary.md" || true
    fi
  elif [[ -n "$ISSUE_NUMBER" ]]; then
    gh issue comment "$ISSUE_NUMBER" --repo "$CLIENT_REPO" --body "Resolved by successful nightly run: ${RUN_URL}" || true
    gh issue close "$ISSUE_NUMBER" --repo "$CLIENT_REPO" --reason completed || true
  fi
fi

exit "$STATUS"
