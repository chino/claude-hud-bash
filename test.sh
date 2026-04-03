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
