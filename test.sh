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
WEEK_FUTURE=$(( $(date +%s) + 3 * 86400 ))

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

# The self-calibration scan forks a background job that reads the real
# ~/.claude/projects transcripts and overwrites the calibration cache. Disable
# it for the whole suite by putting the sampling floor out of reach; the tests
# that need a calibration value seed the cache file directly instead.
export CLAUDE_HUD_CALIB_MIN_PCT=101

# Snapshots go to a scratch dir so the suite never writes to the real cache.
SNAPSHOT_DIR=$(mktemp -d)
export CLAUDE_HUD_SNAPSHOT_DIR="$SNAPSHOT_DIR"

# Cost and duration are opt-in (off by default) -- turn them on for the suite
# as a whole, since most existing tests below assume they're on the line.
# Their actual default-off/opt-in behavior gets its own dedicated section.
export CLAUDE_HUD_SHOW_COST=1
export CLAUDE_HUD_SHOW_DURATION=1

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
assert_matches "shows clock time next to 5h%" "$out" '[0-9]+(:[0-9]+)?(am|pm)'

# Not shown when resets_at is missing/zero. Scoped to the 5h segment itself
# (up to the duration icon) rather than the whole line -- the host-stats
# segment further right always carries its own wall-clock time, which
# legitimately contains "am"/"pm" regardless of resets_at.
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":0}}}')")
out_5h_area=${out%%⏱️*}
assert_not_contains "no clock time without resets_at" "$out_5h_area" "am"
assert_not_contains "no clock time without resets_at" "$out_5h_area" "pm"

section "Weekly (7-day) usage"
weekly() {
  with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":'"$FUTURE"'},
                "seven_day":{"used_percentage":'"$1"',"resets_at":'"${2:-$WEEK_FUTURE}"'}}}'
}

# Hidden by default — BASE carries no seven_day window at all.
out=$(run "$BASE")
assert_not_contains "hidden when there is no weekly window" "$out" "7d "

# Hidden below the threshold, shown at it. Default WEEKLY_SHOW_AT_REMAINING=80
# means it appears from 20% used onward.
out=$(run "$(weekly 19)")
assert_not_contains "hidden below the threshold" "$out" "7d "

out=$(run "$(weekly 20)")
assert_contains "shown at the threshold" "$out" "7d "
assert_contains "shows weekly percentage" "$out" "20%"

out=$(run "$(weekly 93)")
assert_contains "shows high weekly percentage" "$out" "93%"

# Sits immediately to the right of the 5h window.
out=$(run "$(weekly 42)")
assert_matches "sits right of the 5h segment" "$out" '5h .*55%.*│ 7d '

# Reset label: weekday when it is days out, clock time when it lands today.
assert_matches "shows weekday when days away" "$out" '7d [^│]*(mon|tue|wed|thu|fri|sat|sun)'

out=$(run "$(weekly 88 "$(( $(date +%s) + 4000 ))")")
assert_matches "shows clock time when resetting today" "$out" '7d [^│]*[0-9]+:[0-9]+(am|pm)'

# resets_at is documented as an ISO 8601 string; accept that as well as epoch.
out=$(run "$(weekly 64 "\"$(date -Iseconds -d "@$WEEK_FUTURE")\"")")
assert_contains "handles ISO 8601 resets_at" "$out" "64%"

# Threshold is tunable from the environment.
out=$(WEEKLY_SHOW_AT_REMAINING=100 bash -c 'echo "$1" | bash statusline.sh' _ "$(weekly 3)" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "WEEKLY_SHOW_AT_REMAINING=100 always shows it" "$out" "7d "

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
git -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main

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

section "Prompt cache"
out=$(run "$BASE")
assert_not_contains "hidden when prompt_cache is absent" "$out" "warm"
assert_not_contains "hidden when prompt_cache is absent" "$out" "cold"

out=$(run "$(with_fields '{"prompt_cache":{"warm":true,"hit_ratio":0.87,"caching_observed":true,"expires_at":'"$FUTURE"'}}')")
assert_contains "shows warm status" "$out" "warm"
assert_contains "shows hit ratio percentage" "$out" "hit 87%"
assert_matches "shows countdown to expiry" "$out" '~[0-9]+(m|s)'

out=$(run "$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":0},"prompt_cache":{"warm":false,"hit_ratio":0.62,"caching_observed":true}}')")
assert_contains "shows cold status" "$out" "cold"
assert_not_contains "hides hit ratio when cold (stale/irrelevant)" "$out" "hit 62%"
assert_not_contains "no countdown when cold" "$out" "cold ~"

out=$(run "$(with_fields '{"prompt_cache":{"warm":true,"caching_observed":false}}')")
assert_not_contains "hidden when caching_observed is false" "$out" "warm"

# Color ramp: green while plenty of TTL left, yellow inside the last 20%.
run_raw() { echo "$1" | bash statusline.sh 2>/dev/null; }
NEAR_EXPIRY=$(( $(date +%s) + 30 ))    # 30s left on a 5m TTL = well inside the last 20% (60s)
FAR_EXPIRY=$(( $(date +%s) + 280 ))    # 280s left on a 5m TTL = outside the warn window

out=$(run_raw "$(with_fields '{"prompt_cache":{"warm":true,"ttl":"5m","hit_ratio":0.9,"caching_observed":true,"expires_at":'"$NEAR_EXPIRY"'}}')")
assert_contains "yellow near expiry" "$out" "${YELLOW}warm"

out=$(run_raw "$(with_fields '{"prompt_cache":{"warm":true,"ttl":"5m","hit_ratio":0.9,"caching_observed":true,"expires_at":'"$FAR_EXPIRY"'}}')")
assert_contains "green far from expiry" "$out" "${GREEN}warm"

# Cold reheat cost — the tokens a cache-miss re-write burns, plus that priced
# as a share of the 5h window. Only computable when
# context_window.total_input_tokens is present; depends on this machine's real
# ~/.claude/.credentials.json for the window value (same pre-existing
# dependency the burn-rate tests have), so only the format is asserted here.
out=$(run "$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":40000},"prompt_cache":{"warm":false,"ttl":"1h","hit_ratio":0.62,"caching_observed":true}}')")
assert_matches "shows reheat tokens" "$out" 'cold 40k'
assert_matches "shows reheat cost as % of 5h window" "$out" 'cold 40k (<1|[0-9]+)(-(<1|[0-9]+))?% 5h'

out=$(run "$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":0},"prompt_cache":{"warm":false,"hit_ratio":0.62,"caching_observed":true}}')")
assert_not_contains "no reheat cost without a token count" "$out" "cold ~"

section "Plan budgets"

# Neither budget is printed, so both are read back through the cold-reheat
# segment. BASE is an Opus model ($5/MTok input), and a 1h TTL prices a cache
# write at 2x input, so 1,200,000 context tokens cost 1200c ($12.00) to
# re-cache. The rendered percentage is therefore 1200 / window_cents.
# Each case gets a throwaway XDG_CACHE_HOME so the 60s budget cache and the
# calibration file from a previous case can't leak in.
budget_payload=$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":1200000},"prompt_cache":{"warm":false,"ttl":"1h","hit_ratio":0.62,"caching_observed":true}}')

run_with_plan() {
  local plan="$1" tier="$2" cache_home creds
  cache_home=$(mktemp -d); creds=$(mktemp)
  jq -n --arg p "$plan" --arg t "$tier" \
    '{claudeAiOauth: {subscriptionType: $p, rateLimitTier: $t}}' > "$creds"
  echo "$budget_payload" | XDG_CACHE_HOME="$cache_home" CLAUDE_HUD_CREDENTIALS="$creds" \
    bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
  rm -rf "$cache_home" "$creds"
}

out=$(run_with_plan pro default_claude_pro)
assert_contains "pro window (\$24)" "$out" "cold 1.2M 50% 5h"

out=$(run_with_plan max default_claude_max_5x)
assert_contains "max 5x window (\$120)" "$out" "cold 1.2M 10% 5h"

out=$(run_with_plan max default_claude_max_20x)
assert_contains "max 20x window (\$480)" "$out" "cold 1.2M 3% 5h"

# Unrecognized tier on a max plan still lands on the 5x window, not the Pro one.
out=$(run_with_plan max some_future_max_tier)
assert_contains "unknown max tier falls back to 5x" "$out" "cold 1.2M 10% 5h"

# A 5m TTL writes at 1.25x rather than 2x, so the same context costs less.
budget_payload=$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":1200000},"prompt_cache":{"warm":false,"ttl":"5m","hit_ratio":0.62,"caching_observed":true}}')
out=$(run_with_plan max default_claude_max_5x)
assert_contains "5m TTL writes at 1.25x, not 2x" "$out" "cold 1.2M 6% 5h"

# Model matters: Sonnet input is $2/MTok against Opus's $5, so the same
# context is 2.5x cheaper to re-cache.
budget_payload=$(echo "$BASE" | jq '. + {"model":{"display_name":"claude-sonnet-5"},"context_window":{"used_percentage":42,"total_input_tokens":1200000},"prompt_cache":{"warm":false,"ttl":"1h","hit_ratio":0.62,"caching_observed":true}}')
out=$(run_with_plan max default_claude_max_5x)
assert_contains "sonnet is cheaper to re-cache than opus" "$out" "cold 1.2M 4% 5h"

budget_payload=$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":1200000},"prompt_cache":{"warm":false,"ttl":"1h","hit_ratio":0.62,"caching_observed":true}}')

# Manual escape hatch for plans the tier table doesn't cover.
cache_home=$(mktemp -d)
out=$(echo "$budget_payload" | XDG_CACHE_HOME="$cache_home" CLAUDE_HUD_WINDOW_CENTS=6000 \
  bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
rm -rf "$cache_home"
assert_contains "CLAUDE_HUD_WINDOW_CENTS overrides detection" "$out" "cold 1.2M 20% 5h"

# A reheat too cheap to round to a whole percent reads as "<1%", not "0%".
budget_payload=$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":20000},"prompt_cache":{"warm":false,"ttl":"1h","hit_ratio":0.62,"caching_observed":true}}')
out=$(run_with_plan max default_claude_max_5x)
assert_contains "sub-percent reheat reads as <1%" "$out" "cold 20k <1% 5h"
budget_payload=$(with_fields '{"context_window":{"used_percentage":42,"total_input_tokens":1200000},"prompt_cache":{"warm":false,"ttl":"1h","hit_ratio":0.62,"caching_observed":true}}')

# With no credentials and no override there is no denominator at all, so the
# segment falls back to the token count on its own rather than inventing one.
cache_home=$(mktemp -d)
out=$(echo "$budget_payload" | XDG_CACHE_HOME="$cache_home" \
  CLAUDE_HUD_CREDENTIALS="$cache_home/absent.json" \
  bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
rm -rf "$cache_home"
assert_contains "no budget falls back to tokens alone" "$out" "cold 1.2M to reheat"
assert_not_contains "no invented percentage without a budget" "$out" "% 5h"

section "Self-calibrated window"

# When a calibration sample exists it is shown alongside the plan estimate,
# low end first: 1200c against the Max 5x table ($120) is 10%, against a measured
# $60 window it is 20%.
cache_home=$(mktemp -d); creds=$(mktemp)
mkdir -p "$cache_home/claude-hud"
echo 6000 > "$cache_home/claude-hud/calib-cents"
jq -n '{claudeAiOauth: {subscriptionType: "max", rateLimitTier: "default_claude_max_5x"}}' > "$creds"
out=$(echo "$budget_payload" | XDG_CACHE_HOME="$cache_home" CLAUDE_HUD_CREDENTIALS="$creds" \
  bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "shows plan and measured estimates side by side" "$out" "cold 1.2M 10-20% 5h"

# A corrupt calibration file is ignored rather than rendered.
echo "not-a-number" > "$cache_home/claude-hud/calib-cents"
out=$(echo "$budget_payload" | XDG_CACHE_HOME="$cache_home" CLAUDE_HUD_CREDENTIALS="$creds" \
  bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "corrupt calibration file is ignored" "$out" "cold 1.2M 10% 5h"
rm -rf "$cache_home" "$creds"

section "Compaction count"
# The ↻ badge was removed: counting compactions meant grepping the session
# transcript on every render, and transcripts grow unbounded (750 MB was real).
# The number wasn't worth a scan that scales with session length.
COMPACT_TRANSCRIPT=$(mktemp)
printf '%s\n%s\n' \
  '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}' \
  '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}' \
  > "$COMPACT_TRANSCRIPT"
out=$(run "$(with_fields "$(printf '{"transcript_path":"%s"}' "$COMPACT_TRANSCRIPT")")")
assert_not_contains "compaction badge is gone" "$out" "↻"

# The point of removing it: no render may read the transcript at all.
assert_not_contains "transcript is never read" \
  "$(grep -v '^[[:space:]]*#' statusline.sh)" 'transcript'
rm -f "$COMPACT_TRANSCRIPT"

section "Missing / null fields"
out=$(run '{}')
assert_contains "handles empty JSON" "$out" '?'

out=$(run "$(with_fields '{"model":{"display_name":null}}')")
assert_contains "handles null model" "$out" '?'

out=$(run "$(with_fields '{"rate_limits":null}')")
assert_not_contains "no crash on null rate_limits" "$out" "error"

section "Cost / duration opt-in"
# Both are off by default -- run without the suite-wide export above.
out=$(CLAUDE_HUD_SHOW_COST=0 CLAUDE_HUD_SHOW_DURATION=0 bash -c 'echo "$1" | bash statusline.sh' _ "$BASE" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "cost hidden by default" "$out" '$'
assert_not_contains "duration hidden by default" "$out" "⏱️"

out=$(CLAUDE_HUD_SHOW_COST=1 CLAUDE_HUD_SHOW_DURATION=0 bash -c 'echo "$1" | bash statusline.sh' _ "$BASE" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "cost shown when opted in" "$out" '$1.23'
assert_not_contains "duration still hidden" "$out" "⏱️"

out=$(CLAUDE_HUD_SHOW_COST=0 CLAUDE_HUD_SHOW_DURATION=1 bash -c 'echo "$1" | bash statusline.sh' _ "$BASE" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "cost still hidden" "$out" '$'
assert_contains "duration shown when opted in" "$out" "⏱️"

section "Environment badges"
out=$(run "$(with_fields '{"transcript_path":""}')")
assert_contains "renders without crashing" "$out" "%"

section "Snapshot file"
SNAP_SESSION="test-session-$$"
run "$(echo "$BASE" | jq '.session_id = "'"$SNAP_SESSION"'"')" >/dev/null
snap="$SNAPSHOT_DIR/${SNAP_SESSION}.txt"
assert_contains "writes a per-session snapshot" "$([ -f "$snap" ] && echo yes || echo no)" "yes"
assert_contains "snapshot holds the rendered line" "$(cat "$snap" 2>/dev/null)" "claude-opus-4-6"
assert_not_contains "snapshot is stripped of ANSI codes" "$(cat "$snap" 2>/dev/null)" $'\e['

# Two sessions must not overwrite each other.
run "$(echo "$BASE" | jq '.session_id = "other-session"')" >/dev/null
assert_contains "a second session gets its own file" \
  "$([ -f "$SNAPSHOT_DIR/other-session.txt" ] && echo yes || echo no)" "yes"
assert_contains "the first session's file survives" \
  "$([ -f "$snap" ] && echo yes || echo no)" "yes"

# Opt-out writes nothing.
before=$(ls -1 "$SNAPSHOT_DIR" | wc -l | tr -d ' ')
CLAUDE_HUD_SNAPSHOT_DIR=none run "$(echo "$BASE" | jq '.session_id = "opt-out"')" >/dev/null
assert_contains "CLAUDE_HUD_SNAPSHOT_DIR=none writes nothing" \
  "$(ls -1 "$SNAPSHOT_DIR" | wc -l | tr -d ' ')" "$before"

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

rm -rf "$FIXTURE_DIR" "$SNAPSHOT_DIR"

# ── Summary ───────────────────────────────────────────────────────────────────

echo
total=$(( pass + fail ))
if [ "$fail" -eq 0 ]; then
  echo "${GREEN}${BOLD}All ${total} tests passed.${RESET}"
else
  echo "${RED}${BOLD}${fail} of ${total} tests failed.${RESET}"
  exit 1
fi
