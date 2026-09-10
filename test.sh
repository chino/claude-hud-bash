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
# The suite exercises plan detection, budget fallbacks and the reheat maths, so
# it must not inherit a user's own overrides -- with CLAUDE_HUD_WINDOW_CENTS set
# in ~/.claude/settings.json (a perfectly reasonable thing to do), nine tests
# fail against a value the suite never chose.
unset CLAUDE_HUD_WINDOW_CENTS CLAUDE_HUD_TOKEN_BUDGET CLAUDE_HUD_SNAPSHOT_DIR
unset CLAUDE_HUD_USAGE_INTERVAL CLAUDE_HUD_USAGE_DRIFT CLAUDE_HUD_CREDENTIALS

export CLAUDE_HUD_CALIB_MIN_PCT=101

# The per-model usage fetch is on by default, so without this the whole suite
# makes live authenticated API calls and renders whatever the account happens to
# be at -- which collides with fixtures (a real "7d 56%" breaks the weekly-window
# tests) and makes results depend on the network. The section that tests this
# feature re-enables it explicitly against a fixture cache.
export CLAUDE_HUD_USAGE_API=0

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
assert_matches "shows burn rate as percent-of-window per hour" "$out" '[0-9]+(\.[0-9])?%/h'
assert_matches "shows time-to-cap" "$out" '~[0-9]+(m|h)'

# No plan constants involved: burn rate must still appear with no credentials
# file and no CLAUDE_HUD_WINDOW_CENTS, since it derives from the payload alone.
out=$(CLAUDE_HUD_CREDENTIALS=/nonexistent bash -c 'echo "$1" | bash statusline.sh' _ \
  "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":'"$PAST_RESET"'}}}')" \
  2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_matches "burn rate needs no plan constants" "$out" '[0-9]+(\.[0-9])?%/h'
assert_matches "time-to-cap needs no plan constants" "$out" '~[0-9]+(m|h)'

# A slow burn must not floor to 0%/h -- that is why it is tracked in tenths.
SLOW_RESET=$(( $(date +%s) + 3600 ))
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":2,"resets_at":'"$SLOW_RESET"'}}}')")
assert_matches "a slow burn keeps one decimal" "$out" '0\.[1-9]%/h'
assert_not_contains "never shows a bare 0%/h" "$out" "0%/h "

# No burn rate when usage is 0%
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":'"$FUTURE"'}}}')")
assert_not_contains "no burn rate at 0%" "$out" "/m"

# No time-to-cap at 100%
out=$(run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":'"$FUTURE"'}}}')")
assert_not_contains "no time-to-cap at 100%" "$out" "cap ~"

section "Weekly burn rate"
w7() { with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":'"$PAST_RESET"'},
       "seven_day":{"used_percentage":'"$1"',"resets_at":'"$2"'}}}'; }
# 7d window ~3 days in, 60% used -> ~20%/day, ~2 days left.
SEVEN_MID=$(( $(date +%s) + 4*86400 ))
out=$(run "$(w7 60 "$SEVEN_MID")")
assert_matches "shows weekly burn as percent per day" "$out" '[0-9]+(\.[0-9])?%/d'
assert_matches "shows weekly time-to-cap" "$out" '7d [^|]*~[0-9]+'
assert_matches "weekly burn sits inside the 7d segment" "$out" '7d .*%/d'

# Durations read as time, not fractions: under a day must not render as "0d".
out=$(run "$(w7 95 "$(( $(date +%s) + 86400 ))")")
assert_not_contains "never renders a bare 0d duration" "$out" "~0d"
assert_matches "sub-day weekly cap reads in hours or minutes" "$out" '7d [^|]*~[0-9]+[hm]'

# Hidden with the segment it belongs to, not on its own rule.
out=$(run "$(w7 5 "$SEVEN_MID")")
assert_not_contains "no weekly burn when the 7d segment is hidden" "$out" "%/d"

section "Binding limit (sidecar)"
bl_session="binding-$$"
BL_5H=$(( $(date +%s) + 3600 ))     # 5h window 4h in
BL_7D=$(( $(date +%s) + 5*86400 ))  # 7d window 2d in
run "$(echo "$BASE" | jq '.session_id="'"$bl_session"'"
  | .rate_limits={five_hour:{used_percentage:90,resets_at:'"$BL_5H"'},
                  seven_day:{used_percentage:20,resets_at:'"$BL_7D"'}}')" >/dev/null
bl="$SNAPSHOT_DIR/${bl_session}.json"
assert_contains "sidecar is valid JSON with the new fields" "$(jq -e . "$bl" >/dev/null 2>&1 && echo yes || echo no)" "yes"
assert_contains "names 5h as binding when it trips first" "$(jq -r .binding_limit "$bl")" "five_hour"
assert_contains "reports both burn rates" "$(jq -r '[.burn_5h_pct_per_hour,.burn_7d_pct_per_day]|map(type)|unique|join(",")' "$bl")" "number"
assert_contains "not blocked yet" "$(jq -r .blocked_now "$bl")" "false"

# Weekly binding: nearly exhausted weekly, fresh 5h.
run "$(echo "$BASE" | jq '.session_id="weekly-'"$$"'"
  | .rate_limits={five_hour:{used_percentage:5,resets_at:'"$BL_5H"'},
                  seven_day:{used_percentage:97,resets_at:'"$BL_7D"'}}')" >/dev/null
assert_contains "names 7d as binding when the weekly wall is closer" \
  "$(jq -r .binding_limit "$SNAPSHOT_DIR/weekly-$$.json")" "seven_day"

# Already capped: blocked_now plus a real reset time to wait for.
run "$(echo "$BASE" | jq '.session_id="capped-'"$$"'"
  | .rate_limits={five_hour:{used_percentage:100,resets_at:'"$BL_5H"'},
                  seven_day:{used_percentage:40,resets_at:'"$BL_7D"'}}')" >/dev/null
cap="$SNAPSHOT_DIR/capped-$$.json"
assert_contains "blocked_now true at 100%" "$(jq -r .blocked_now "$cap")" "true"
assert_contains "blocked_until carries the tripped window reset" "$(jq -r .blocked_until "$cap")" "$BL_5H"

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

section "Measured token throughput"
# tokens/min comes from the background calibration scan's own sum, cached.
tok_cache=$(mktemp -d); mkdir -p "$tok_cache/claude-hud"
tok_run() {
  echo "$1" > "$tok_cache/claude-hud/calib-tokens"
  run "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":'"$PAST_RESET"'}}}')" >/dev/null
  echo "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":'"$PAST_RESET"'}}}')" \
    | CLAUDE_HUD_CALIB_MIN_PCT=101 XDG_CACHE_HOME="$tok_cache" CLAUDE_HUD_SNAPSHOT_DIR=none \
      bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}
assert_contains "renders millions as M/m" "$(tok_run 1240000)" "1.2M/m"
assert_contains "renders thousands as k/m" "$(tok_run 579609)" "579k/m"
assert_contains "renders small counts bare" "$(tok_run 850)" "850/m"
assert_contains "sits beside the percentage, not instead of it" "$(tok_run 579609)" "%/h"

# Absent or unusable cache must degrade to percentage-only, never print junk.
rm -f "$tok_cache/claude-hud/calib-tokens"
out=$(echo "$(with_fields '{"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":'"$PAST_RESET"'}}}')" \
  | CLAUDE_HUD_CALIB_MIN_PCT=101 XDG_CACHE_HOME="$tok_cache" CLAUDE_HUD_SNAPSHOT_DIR=none \
    bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
assert_matches "still shows the percentage with no token cache" "$out" '[0-9]+(\.[0-9])?%/h'
assert_not_contains "no stray /m when the cache is missing" "$out" "/m"
echo "corrupt" > "$tok_cache/claude-hud/calib-tokens"
assert_not_contains "ignores a corrupt token cache" "$(tok_run corrupt)" "corrupt"
rm -rf "$tok_cache"

section "Per-model usage (opt-in)"
# Never hits the network: a fixture cache stands in for the fetch, and the
# feature is off by default so the rest of the suite never reaches out either.
api_cache=$(mktemp -d); mkdir -p "$api_cache/claude-hud"
cat > "$api_cache/claude-hud/usage-api.json" <<'FIXTURE'
{"five_hour":{"utilization":66},"seven_day":{"utilization":10},
 "limits":[{"kind":"session","percent":66,"scope":null},
           {"kind":"weekly_all","percent":10,"scope":null},
           {"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Fable"}}}]}
FIXTURE
# CLAUDE_HUD_CREDENTIALS points at nothing, so the background fetcher exits
# before it can reach the network. Without this, any test that ages the cache
# past the interval fires a real request whose response lands asynchronously and
# overwrites the fixture -- a race that made these tests flaky, not offline.
api_run() { echo "$BASE" | XDG_CACHE_HOME="$api_cache" CLAUDE_HUD_CALIB_MIN_PCT=101   CLAUDE_HUD_SNAPSHOT_DIR=none CLAUDE_HUD_CREDENTIALS=/nonexistent "$@" bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }

assert_contains "on by default -- renders the scoped weekly window" \
  "$(api_run env CLAUDE_HUD_USAGE_API=1)" "Fable 7%"
assert_not_contains "CLAUDE_HUD_USAGE_API=0 disables it" "$(api_run env CLAUDE_HUD_USAGE_API=0)" "Fable"
# Prove the default really is on, without the suite-wide override in the way.
assert_contains "unset means enabled" \
  "$(echo "$BASE" | env -u CLAUDE_HUD_USAGE_API XDG_CACHE_HOME="$api_cache" \
     CLAUDE_HUD_CALIB_MIN_PCT=101 CLAUDE_HUD_SNAPSHOT_DIR=none \
     CLAUDE_HUD_CREDENTIALS=/nonexistent bash statusline.sh 2>/dev/null \
     | sed 's/\x1b\[[0-9;]*m//g')" "Fable 7%"
# Only weekly_scoped rows are models; the aggregate rows must not leak in.
out=$(api_run env CLAUDE_HUD_USAGE_API=1)
assert_not_contains "does not render unscoped aggregate rows" "$out" "session"
assert_not_contains "does not render weekly_all" "$out" "weekly_all"

# Server aggregates render beside the local ones so the two can be compared.
out=$(api_run env CLAUDE_HUD_USAGE_API=1)
assert_contains "shows the server's own 5h figure" "$out" "5h 66%"
assert_contains "shows the server's own 7d figure" "$out" "7d 10%"
assert_contains "labels the section" "$out" "api "
# The local numbers must still be there -- this is a comparison, not a swap.
assert_matches "local 5h bar survives alongside the server figure" "$out" '5h [█░]+ 55%'

# Sampled data must show its age, so a stalled fetch is visible rather than
# looking like a live value that happens not to move.
assert_matches "fresh data shows an age in seconds" "$out" 'api .*[0-9]+s'
touch -d '5 minutes ago' "$api_cache/claude-hud/usage-api.json"
assert_matches "stale data shows minutes, not a frozen-looking number" \
  "$(api_run env CLAUDE_HUD_USAGE_API=1)" 'api .*5m'
touch -d '3 hours ago' "$api_cache/claude-hud/usage-api.json"
assert_matches "very stale data shows hours" "$(api_run env CLAUDE_HUD_USAGE_API=1)" 'api .*3h'
touch "$api_cache/claude-hud/usage-api.json"

# CLAUDE_HUD_USAGE_DRIFT hides the aggregates while the two sources agree, and
# surfaces them the moment they diverge. Per-model rows have no local
# counterpart, so they show either way.
# Both windows must be pinned: drift fires if EITHER disagrees, and BASE has no
# seven_day at all (local 0 vs server 10 is already a 10-point divergence).
drift_run() { echo "$BASE" | jq '.rate_limits={five_hour:{used_percentage:'"$1"',resets_at:'"$PAST_RESET"'},seven_day:{used_percentage:10,resets_at:'"$WEEK_FUTURE"'}}' \
  | XDG_CACHE_HOME="$api_cache" CLAUDE_HUD_CALIB_MIN_PCT=101 CLAUDE_HUD_SNAPSHOT_DIR=none \
    CLAUDE_HUD_CREDENTIALS=/nonexistent CLAUDE_HUD_USAGE_API=1 CLAUDE_HUD_USAGE_DRIFT="$2" \
    bash statusline.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
assert_not_contains "drift threshold hides agreeing aggregates" "$(drift_run 66 5)" "5h 66%"
assert_contains "but keeps the per-model row" "$(drift_run 66 5)" "Fable 7%"
assert_contains "shows aggregates once they diverge past the threshold" "$(drift_run 40 5)" "5h 66%"
assert_contains "drift=0 always shows them" "$(drift_run 66 0)" "5h 66%"

# Every failure mode degrades to the ordinary line rather than breaking it.
echo 'not json at all' > "$api_cache/claude-hud/usage-api.json"
out=$(api_run env CLAUDE_HUD_USAGE_API=1)
assert_contains "corrupt cache still renders the status line" "$out" "claude-opus-4-6"
assert_not_contains "corrupt cache prints no junk segment" "$out" "null"
echo '{"limits":[]}' > "$api_cache/claude-hud/usage-api.json"
assert_not_contains "empty limits array adds nothing" "$(api_run env CLAUDE_HUD_USAGE_API=1)" "%|"
rm -f "$api_cache/claude-hud/usage-api.json"
assert_contains "missing cache still renders" "$(api_run env CLAUDE_HUD_USAGE_API=1)" "claude-opus-4-6"

# The endpoint 429s intermittently (claude-code#30930). A failed fetch must back
# off rather than retry on the same cadence, or an occasional refusal becomes a
# sustained one. Tested offline by seeding the backoff file directly.
echo '{"five_hour":{"utilization":66},"seven_day":{"utilization":10},"limits":[]}' \
  > "$api_cache/claude-hud/usage-api.json"
touch -d '1 hour ago' "$api_cache/claude-hud/usage-api.json"
printf '%s 3\n' "$(( $(date +%s) + 600 ))" > "$api_cache/claude-hud/usage-api.backoff"
api_run env CLAUDE_HUD_USAGE_API=1 >/dev/null; sleep 1
assert_contains "an active backoff suppresses the fetch" \
  "$([ -d "$api_cache/claude-hud/usage-api.lock" ] && echo fetched || echo held)" "held"
assert_contains "backoff state is left alone while holding" \
  "$(cut -d' ' -f2 "$api_cache/claude-hud/usage-api.backoff")" "3"

# An expired backoff must not block forever.
printf '%s 3\n' "$(( $(date +%s) - 10 ))" > "$api_cache/claude-hud/usage-api.backoff"
api_run env CLAUDE_HUD_USAGE_API=1 >/dev/null; sleep 1
assert_not_contains "an expired backoff no longer holds" \
  "$(cut -d' ' -f1 "$api_cache/claude-hud/usage-api.backoff" 2>/dev/null || echo gone)" "$(( $(date +%s) - 10 ))"
rm -f "$api_cache/claude-hud/usage-api.backoff"

# Serving a stale cache during a backoff is the point: the line keeps its last
# known numbers with an honest age rather than losing the segment.
printf '%s 2\n' "$(( $(date +%s) + 600 ))" > "$api_cache/claude-hud/usage-api.backoff"
echo '{"five_hour":{"utilization":66},"seven_day":{"utilization":10},"limits":[{"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Fable"}}}]}' \
  > "$api_cache/claude-hud/usage-api.json"
touch -d '1 hour ago' "$api_cache/claude-hud/usage-api.json"
out=$(api_run env CLAUDE_HUD_USAGE_API=1)
assert_contains "stale data still renders while backing off" "$out" "Fable 7%"
assert_matches "and shows its real age" "$out" 'api .*1h'
rm -f "$api_cache/claude-hud/usage-api.backoff"
touch "$api_cache/claude-hud/usage-api.json"

# A stale lock from a crashed fetch must not wedge it forever.
mkdir -p "$api_cache/claude-hud/usage-api.lock"
touch -d '10 minutes ago' "$api_cache/claude-hud/usage-api.lock"
api_run env CLAUDE_HUD_USAGE_API=1 >/dev/null
sleep 1
assert_contains "clears a lock older than 2 minutes" \
  "$([ -d "$api_cache/claude-hud/usage-api.lock" ] && echo held || echo cleared)" "cleared"
rm -rf "$api_cache"

section "Model pricing"
# Reheat cost must scale with the model's real input price: Fable $10 > Opus $5
# > Sonnet $2 > Haiku $1 per MTok. Fable used to fall through to the Sonnet arm
# and be priced 5x under.
price_pct() {
  local d=$(mktemp -d)
  echo "$BASE" | jq '.model.display_name="'"$1"'"
    | .context_window={used_percentage:50,total_input_tokens:4000000}
    | .prompt_cache={caching_observed:true,warm:false,ttl:"1h"}' \
    | CLAUDE_HUD_CALIB_MIN_PCT=101 CLAUDE_HUD_WINDOW_CENTS=48000 XDG_CACHE_HOME="$d" \
      CLAUDE_HUD_SNAPSHOT_DIR=none bash statusline.sh 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'cold [0-9.]+M ([0-9]+)%' | grep -oE '[0-9]+%$' | tr -d '%'
  rm -rf "$d"
}
f=$(price_pct "Fable 5.1"); o=$(price_pct "Opus 5"); s=$(price_pct "Sonnet 5"); h=$(price_pct "Haiku 4.5")
assert_contains "Fable priced above Opus" "$([ "${f:-0}" -gt "${o:-0}" ] && echo yes || echo "no (fable=$f opus=$o)")" "yes"
assert_contains "Opus priced above Sonnet" "$([ "${o:-0}" -gt "${s:-0}" ] && echo yes || echo "no (opus=$o sonnet=$s)")" "yes"
assert_contains "Sonnet priced above Haiku" "$([ "${s:-0}" -gt "${h:-0}" ] && echo yes || echo "no (sonnet=$s haiku=$h)")" "yes"
assert_contains "Fable is 5x Sonnet, not equal to it" "$([ "${f:-0}" -ge $(( ${s:-0} * 4 )) ] && echo yes || echo "no (fable=$f sonnet=$s)")" "yes"

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

section "Snapshot JSON sidecar"
JSON_SESSION="json-test-$$"
json_payload=$(echo "$BASE" | jq '.session_id = "'"$JSON_SESSION"'"
  | .prompt_cache = {caching_observed:true, warm:true, ttl:"1h", hit_ratio:0.99, expires_at:'"$FUTURE"'}
  | .rate_limits.seven_day = {used_percentage:87, resets_at:'"$WEEK_FUTURE"'}')
run "$json_payload" >/dev/null
jsnap="$SNAPSHOT_DIR/${JSON_SESSION}.json"

assert_contains "writes a .json beside the .txt" "$([ -f "$jsnap" ] && echo yes || echo no)" "yes"
assert_contains "is valid JSON" "$(jq -e . "$jsnap" >/dev/null 2>&1 && echo yes || echo no)" "yes"

# Epochs, not clock strings -- the whole point of the sidecar.
assert_contains "resets_5h is the raw epoch" "$(jq -r .resets_5h "$jsnap" 2>/dev/null)" "$FUTURE"
assert_contains "resets_7d is the raw epoch" "$(jq -r .resets_7d "$jsnap" 2>/dev/null)" "$WEEK_FUTURE"
assert_contains "carries 7d usage" "$(jq -r .used_7d_pct "$jsnap" 2>/dev/null)" "87"
assert_contains "cache_warm is a real boolean" "$(jq -r '.cache_warm|type' "$jsnap" 2>/dev/null)" "boolean"
assert_contains "cost is a number, not a \$-string" "$(jq -r '.cost_usd|type' "$jsnap" 2>/dev/null)" "number"
assert_contains "rendered_at is recent" \
  "$(jq -r --argjson now "$(date +%s)" 'if ($now - .rendered_at) < 60 then "fresh" else "stale" end' "$jsnap" 2>/dev/null)" "fresh"

# An absent timestamp must be null, not 0 -- 0 is a real epoch and renders as
# 1970-01-01, which a consumer cannot distinguish from a genuine date.
absent="json-absent-$$"
run "$(echo "$BASE" | jq '.session_id = "'"$absent"'" | del(.rate_limits) | del(.prompt_cache)')" >/dev/null
abs_json="$SNAPSHOT_DIR/${absent}.json"
assert_contains "still valid JSON with nulls" "$(jq -e . "$abs_json" >/dev/null 2>&1 && echo yes || echo no)" "yes"
assert_contains "absent resets_5h is null" "$(jq -r '.resets_5h|type' "$abs_json" 2>/dev/null)" "null"
assert_contains "absent resets_7d is null" "$(jq -r '.resets_7d|type' "$abs_json" 2>/dev/null)" "null"
assert_contains "absent cache_expires_at is null" "$(jq -r '.cache_expires_at|type' "$abs_json" 2>/dev/null)" "null"
assert_not_contains "never renders as 1970" \
  "$(jq -r '[.resets_5h,.resets_7d,.cache_expires_at]|map(if .==null then "null" else (.|todate) end)|join(",")' "$abs_json" 2>/dev/null)" "1970"
# A real percentage of 0 is still 0 -- only timestamps become null.
assert_contains "a genuine 0 percent stays 0" "$(jq -r '.used_5h_pct' "$abs_json" 2>/dev/null)" "0"

# Present timestamps are unaffected.
assert_contains "present resets_5h is still a number" "$(jq -r '.resets_5h|type' "$jsnap" 2>/dev/null)" "number"

# A quote in cwd must not produce invalid JSON.
q_session="json-quote-$$"
run "$(echo "$BASE" | jq '.session_id = "'"$q_session"'" | .cwd = "/tmp/a \"b\" c"')" >/dev/null
assert_contains "survives a quote in cwd" \
  "$(jq -e . "$SNAPSHOT_DIR/${q_session}.json" >/dev/null 2>&1 && echo yes || echo no)" "yes"

# Never leave a half-written object behind.
assert_contains "no .tmp files left" "$(ls -1 "$SNAPSHOT_DIR" | grep -c '\.tmp$')" "0"

# Opt-out covers the sidecar too.
CLAUDE_HUD_SNAPSHOT_DIR=none run "$(echo "$BASE" | jq '.session_id = "json-optout"')" >/dev/null
assert_contains "opt-out writes no sidecar" \
  "$([ -f "$SNAPSHOT_DIR/json-optout.json" ] && echo yes || echo no)" "no"

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
