#!/usr/bin/env bash
# Tests for statusline.sh — feeds JSON payloads and checks output

set -euo pipefail
cd "$(dirname "$0")"

RESET=$'\e[0m'; BOLD=$'\e[1m'; DIM=$'\e[2m'
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'

pass=0; fail=0

# ── Helpers ───────────────────────────────────────────────────────────────────

run() {
  echo "$1" | bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

run_cols() {
  local cols="$1" json="$2"
  COLUMNS="$cols" bash -c 'echo "$1" | bash statusline.sh' _ "$json" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF "$expected"; then
    echo "  ${GREEN}✓${RESET} ${label}"
    (( pass++ )) || true
  else
    echo "  ${RED}✗${RESET} ${label}"
    echo "    ${DIM}expected:${RESET} ${YELLOW}${expected}${RESET}"
    echo "    ${DIM}got:${RESET} ${output}"
    (( fail++ )) || true
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if ! echo "$output" | grep -qF "$unexpected"; then
    echo "  ${GREEN}✓${RESET} ${label}"
    (( pass++ )) || true
  else
    echo "  ${RED}✗${RESET} ${label}"
    echo "    ${DIM}expected NOT to contain:${RESET} ${YELLOW}${unexpected}${RESET}"
    echo "    ${DIM}got:${RESET} ${output}"
    (( fail++ )) || true
  fi
}

assert_matches() {
  local label="$1" output="$2" pattern="$3"
  if echo "$output" | grep -qE "$pattern"; then
    echo "  ${GREEN}✓${RESET} ${label}"
    (( pass++ )) || true
  else
    echo "  ${RED}✗${RESET} ${label}"
    echo "    ${DIM}expected to match:${RESET} ${YELLOW}${pattern}${RESET}"
    echo "    ${DIM}got:${RESET} ${output}"
    (( fail++ )) || true
  fi
}

section() { echo; echo "${BOLD}${CYAN}$1${RESET}"; }

# ── Fixtures ──────────────────────────────────────────────────────────────────

FUTURE=$(( $(date +%s) + 7200 ))

# Non-git fixture directory, not the machine's own checkout — keeps the
# suite portable and free of any local path/username.
FIXTURE_DIR=$(mktemp -d)
FIXTURE_PROJECT=$(basename "$FIXTURE_DIR")

BASE='{
  "model": { "display_name": "claude-opus-4-6" },
  "context_window": {
    "used_percentage": 42,
    "total_input_tokens": 8000,
    "total_output_tokens": 2000
  },
  "cost": { "total_cost_usd": 1.23, "total_duration_ms": 75000 },
  "rate_limits": { "five_hour": { "used_percentage": 55, "resets_at": '"$FUTURE"' } },
  "cwd": "'"$FIXTURE_DIR"'",
  "transcript_path": ""
}'

with_fields() {
  echo "$BASE" | jq ". + $1"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

section "Model"
out=$(run "$BASE")
assert_contains "shows model name" "$out" "claude-opus-4-6"

section "Context window"
out=$(run "$BASE")
assert_contains "shows ctx percentage" "$out" "42%"

out=$(run "$(with_fields '{"context_window":{"used_percentage":87,"total_input_tokens":0,"total_output_tokens":0}}')")
assert_contains "shows high ctx percentage" "$out" "87%"

section "5-hour usage"
out=$(run "$BASE")
assert_contains "shows 5h percentage" "$out" "55%"

out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":'"$FUTURE"'}}}')")
assert_contains "shows 0% usage" "$out" "0%"

out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":0}}}')")
assert_contains "shows 99% usage" "$out" "99%"

section "Reset time"
# Always shown when resets_at is in the future
out=$(run "$BASE")
assert_matches "shows clock time next to 5h%" "$out" '[0-9]+:[0-9]+(am|pm)'

# Not shown when resets_at is missing/zero
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":0}}}')")
assert_not_contains "no clock time without resets_at" "$out" "am"
assert_not_contains "no clock time without resets_at" "$out" "pm"

section "Burn rate & time-to-cap"
# resets_at 1h in past = window 4h elapsed, 55% used → should show burn rate
PAST_RESET=$(( $(date +%s) + 3600 ))  # 1h left in window = 4h elapsed
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":'"$PAST_RESET"'}}}')")
assert_matches "shows burn rate" "$out" '[0-9]+[k]?/m'
assert_matches "shows time-to-cap" "$out" '~[0-9]+(m|h)'

# No burn rate when usage is 0%
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":'"$FUTURE"'}}}')")
assert_not_contains "no burn rate at 0%" "$out" "/m"

# No time-to-cap at 100%
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":'"$FUTURE"'}}}')")
assert_not_contains "no time-to-cap at 100%" "$out" "cap ~"

section "Cost"
out=$(run "$BASE")
assert_contains "shows dollar sign" "$out" '$'
assert_contains "shows cost value" "$out" "1.23"

out=$(run "$(with_fields '{"cost":{"total_cost_usd":0,"total_duration_ms":0}}')")
assert_contains "shows zero cost" "$out" '$0'

section "Duration"
out=$(run "$(with_fields '{"cost":{"total_cost_usd":0,"total_duration_ms":5000}}')")
assert_contains "shows seconds" "$out" "5s"

out=$(run "$(with_fields '{"cost":{"total_cost_usd":0,"total_duration_ms":90000}}')")
assert_contains "shows minutes" "$out" "1m"

out=$(run "$(with_fields '{"cost":{"total_cost_usd":0,"total_duration_ms":3720000}}')")
assert_contains "shows hours and minutes" "$out" "1h2m"

section "Git branch"
out=$(run "$BASE")
assert_contains "shows project name" "$out" "$FIXTURE_PROJECT"

section "Git branch (detached HEAD)"
DETACHED_REPO=$(mktemp -d)
git -C "$DETACHED_REPO" init -q
git -C "$DETACHED_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
git -C "$DETACHED_REPO" tag v1.0.0
git -C "$DETACHED_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
git -C "$DETACHED_REPO" checkout -q --detach v1.0.0

out=$(run "$(with_fields "$(printf '{"cwd":"%s"}' "$DETACHED_REPO")")")
assert_contains "shows exact tag on detached HEAD" "$out" "v1.0.0"

git -C "$DETACHED_REPO" checkout -q --detach HEAD~0 2>/dev/null
git -C "$DETACHED_REPO" tag -d v1.0.0 >/dev/null
SHORT_SHA=$(git -C "$DETACHED_REPO" rev-parse --short HEAD)
out=$(run "$(with_fields "$(printf '{"cwd":"%s"}' "$DETACHED_REPO")")")
assert_contains "shows short SHA on untagged detached HEAD" "$out" "$SHORT_SHA"
rm -rf "$DETACHED_REPO"

section "Git branch (ahead/behind)"
REMOTE_REPO=$(mktemp -d)
git -C "$REMOTE_REPO" init -q --bare

LOCAL_REPO=$(mktemp -d)
git -C "$LOCAL_REPO" init -q -b main
git -C "$LOCAL_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$LOCAL_REPO" remote add origin "$REMOTE_REPO"
git -C "$LOCAL_REPO" push -q origin main
git -C "$LOCAL_REPO" branch -q --set-upstream-to=origin/main main

# In sync → no arrows.
out=$(run "$(with_fields "$(printf '{"cwd":"%s"}' "$LOCAL_REPO")")")
assert_not_contains "no arrows when in sync" "$out" "↑"
assert_not_contains "no arrows when in sync" "$out" "↓"

# 2 ahead → up arrow with count, no down arrow.
git -C "$LOCAL_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m a1
git -C "$LOCAL_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m a2
out=$(run "$(with_fields "$(printf '{"cwd":"%s"}' "$LOCAL_REPO")")")
assert_contains "shows ahead count" "$out" "↑2"
assert_not_contains "no down arrow when only ahead" "$out" "↓"

# Push, then have origin move ahead → down arrow with count, no up arrow.
git -C "$LOCAL_REPO" push -q origin main
CLONE_REPO=$(mktemp -d)
git clone -q "$REMOTE_REPO" "$CLONE_REPO"
git -C "$CLONE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m b1
git -C "$CLONE_REPO" push -q origin main
git -C "$LOCAL_REPO" fetch -q
out=$(run "$(with_fields "$(printf '{"cwd":"%s"}' "$LOCAL_REPO")")")
assert_contains "shows behind count" "$out" "↓1"
assert_not_contains "no up arrow when only behind" "$out" "↑"

rm -rf "$REMOTE_REPO" "$LOCAL_REPO" "$CLONE_REPO"

section "Missing / null fields"
out=$(run '{}')
assert_contains "handles empty JSON" "$out" '?'

out=$(run "$(with_fields '{"model":{"display_name":null}}')")
assert_contains "handles null model" "$out" '?'

out=$(run "$(with_fields '{"rate_limits":null}')")
assert_not_contains "no crash on null rate_limits" "$out" "error"

section "Environment badges"
out=$(run "$(with_fields '{"transcript_path":""}')")
assert_contains "renders without crashing" "$out" "%"

section "Terminal width (COLUMNS)"
# No COLUMNS set → no wrapping, everything on one line.
out=$(run "$BASE")
assert_contains "no COLUMNS: shows duration" "$out" "⏱️"
assert_contains "no COLUMNS: single line" "$(echo "$out" | wc -l | tr -d ' ')" "1"

# Plenty of width → still fits on one line.
out=$(run_cols 200 "$BASE")
assert_contains "wide COLUMNS: shows duration" "$out" "⏱️"
assert_contains "wide COLUMNS: single line" "$(echo "$out" | wc -l | tr -d ' ')" "1"

# Narrow width → wraps onto multiple lines, but nothing is dropped.
out=$(run_cols 50 "$BASE")
line_count=$(echo "$out" | wc -l | tr -d ' ')
assert_matches "narrow COLUMNS: wraps onto multiple lines" "$line_count" '^[2-9][0-9]*$'
assert_contains "narrow COLUMNS: keeps model" "$out" "claude-opus-4-6"
assert_contains "narrow COLUMNS: keeps project" "$out" "$FIXTURE_PROJECT"
assert_contains "narrow COLUMNS: keeps duration" "$out" "⏱️"
assert_contains "narrow COLUMNS: keeps cost" "$out" "1.23"

# Every wrapped line respects COLUMNS (small tolerance for emoji-width
# rounding — the goal is no gross overflow, not pixel-perfect wcwidth).
too_long=$(echo "$out" | awk -v max=53 'length($0) > max { print }')
assert_contains "narrow COLUMNS: no line grossly exceeds width" "${too_long:-<none>}" "<none>"

section "Terminal width (todos)"
TODO_TRANSCRIPT=$(mktemp)
cat > "$TODO_TRANSCRIPT" <<'EOF'
{"message":{"content":[{"name":"TodoWrite","input":{"todos":[{"status":"completed","content":"Fix the crash bug in the parser that happens when input is empty"}]}}]}}
EOF
TODO_BASE=$(with_fields "$(printf '{"transcript_path":"%s"}' "$TODO_TRANSCRIPT")")

out=$(run "$TODO_BASE")
assert_contains "no COLUMNS: full todo text" "$out" "happens when input is empty"

out=$(run_cols 40 "$TODO_BASE")
assert_not_contains "narrow COLUMNS: no ellipsis" "$out" "…"
assert_contains "narrow COLUMNS: wraps todo, keeps full text" "$(echo "$out" | tr -d '\n')" "happens when input is empty"
rm -f "$TODO_TRANSCRIPT"
rm -rf "$FIXTURE_DIR"

# ── Summary ───────────────────────────────────────────────────────────────────

echo
total=$(( pass + fail ))
if [ "$fail" -eq 0 ]; then
  echo "${GREEN}${BOLD}All ${total} tests passed.${RESET}"
else
  echo "${RED}${BOLD}${fail} of ${total} tests failed.${RESET}"
  exit 1
fi
