#!/bin/sh
# ores-lint :: advisory Rust local-concurrency audit
#
# This scanner intentionally reports suspicious fan-out sites; it does not claim
# a lexical match proves a policy violation. Reviewed bounded sites may carry an
# `ores-concurrency: allow <reason>` marker on the same or immediately preceding
# source line.

set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/config.sh"
ROOT=${1:-.}
ROOT=$(CDPATH= cd -- "$ROOT" && pwd)

[ "${ORES_LINT_SKIP_CONCURRENCY_RUST}" = "1" ] && {
  echo "ores-lint[concurrency-rust]: skipped (ORES_LINT_SKIP_CONCURRENCY_RUST=1)"
  exit 0
}

TMP=$(mktemp) || exit 0
trap 'rm -f "$TMP"' EXIT HUP INT TERM

find "$ROOT" -maxdepth "${ORES_LINT_DEPTH}" \
  \( -name node_modules -o -name target -o -name .git -o -name vendor -o -name .vendor \
     -o -name build -o -name dist -o -name .ores-lint -o -name tmp -o -name temp \) -prune -o \
  -type f -name '*.rs' -print 2>/dev/null \
| while IFS= read -r file; do
    rel=${file#"$ROOT"/}
    awk -v rel="$rel" '
      function emit(rule, n, text,    allowed) {
        allowed = previous_allow || current_allow
        if (allowed) return
        printf "%s\t%s:%d\t%s\n", rule, rel, n, text
      }
      {
        line = $0
        current_allow = (line ~ /ores-concurrency:[[:space:]]*allow/)

        if (line ~ /(^|[^[:alnum:]_])(std::)?thread::spawn[[:space:]]*\(/) {
          emit("direct-thread-spawn", NR, line)
        }
        if (line ~ /(^|[^[:alnum:]_])[[:alnum:]_]*scope\.spawn[[:space:]]*\(/) {
          emit("scoped-thread-spawn", NR, line)
        }
        if (line ~ /(^|[^[:alnum:]_:])tokio(::task)?::spawn[[:space:]]*\(/ ||
            line ~ /(^|[^[:alnum:]_:])tokio::task::spawn_blocking[[:space:]]*\(/) {
          emit("tokio-task-spawn", NR, line)
        }
        if (line ~ /(std::sync::)?mpsc::channel[[:space:]]*\(/) {
          emit("unbounded-std-channel", NR, line)
        }
        if (line ~ /tokio::sync::mpsc::unbounded_channel[[:space:]]*\(/ ||
            line ~ /mpsc::unbounded_channel[[:space:]]*\(/) {
          emit("unbounded-tokio-channel", NR, line)
        }
        if (line ~ /crossbeam(_channel)?::unbounded[[:space:]]*\(/) {
          emit("unbounded-crossbeam-channel", NR, line)
        }

        if (builder_window > 0) {
          if (line ~ /\.spawn[[:space:]]*\(/) {
            emit("thread-builder-spawn", NR, line)
            builder_window = 0
          } else {
            builder_window--
          }
        }
        if (line ~ /(std::)?thread::Builder::new[[:space:]]*\(/) {
          builder_window = 8
        }

        previous_allow = current_allow
      }
    ' "$file"
  done > "$TMP"

COUNT=$(wc -l < "$TMP" | tr -d ' ')
if [ "$COUNT" -eq 0 ]; then
  echo "ores-lint[concurrency-rust]: no suspicious fan-out sites"
  exit 0
fi

echo "ores-lint[concurrency-rust]: $COUNT suspicious site(s); advisory review required"
for rule in direct-thread-spawn scoped-thread-spawn thread-builder-spawn tokio-task-spawn unbounded-std-channel unbounded-tokio-channel unbounded-crossbeam-channel; do
  RULE_COUNT=$(awk -F '\t' -v rule="$rule" '$1 == rule { count++ } END { print count + 0 }' "$TMP")
  [ "$RULE_COUNT" -eq 0 ] && continue
  echo "  $rule: $RULE_COUNT"
  awk -F '\t' -v rule="$rule" -v max="${ORES_LINT_MAX_EXAMPLES}" '
    $1 == rule && shown < max {
      printf "    %s\n", $2
      shown++
    }
  ' "$TMP"
done

echo "  note: lexical matches are review signals, not proof of unbounded behavior"
echo "  allow: add `ores-concurrency: allow <bounded reason>` on the finding line or the line immediately before it"

if [ "${ORES_LINT_CONCURRENCY_STRICT}" = "1" ]; then
  echo "ores-lint[concurrency-rust]: FAILING because ORES_LINT_CONCURRENCY_STRICT=1"
  exit 1
fi
exit 0
