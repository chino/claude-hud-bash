#!/usr/bin/env bash
# Claude Code statusLine script — claude-hud style
shopt -s extglob   # visible_width() strips ANSI with an extended glob
data=$(cat)

RESET=$'\e[0m'
DIM=$'\e[2m'
CYAN=$'\e[36m'
YELLOW=$'\e[33m'
MAGENTA=$'\e[35m'
GREEN=$'\e[32m'
RED=$'\e[31m'
BRIGHT_BLUE=$'\e[94m'
BRIGHT_MAGENTA=$'\e[95m'
BRIGHT_CYAN=$'\e[96m'

# Weekly (7-day) window: hidden until it is worth the space. Shown once
# remaining drops to WEEKLY_SHOW_AT_REMAINING percent or less — i.e. at the
# default of 80, from 20% used onward. Set to 100 to always show it.
WEEKLY_SHOW_AT_REMAINING=${WEEKLY_SHOW_AT_REMAINING:-80}
WEEKLY_BAR_WIDTH=${WEEKLY_BAR_WIDTH:-10}

# Every field comes out of ONE jq call. This used to be sixteen separate
# `echo "$data" | jq` lines — sixteen forks, each re-parsing the same small
# payload from scratch, and ~88% of that time was process startup rather than
# any actual JSON work.
#
# Read with mapfile, one value per line — NOT `IFS=$'\t' read ... <<< @tsv`.
# Tab is IFS whitespace, so bash collapses runs of it: a single empty value in
# the middle silently shifts every field after it by one, with no error.
#
# `warm` is deliberately "true" or "" rather than the raw boolean, matching the
# old `// empty` behaviour that the [[ $cache_warm == "true" ]] test expects.
mapfile -t F < <(printf '%s' "$data" | jq -r '
  (.model.display_name // "?"),
  (.context_window.used_percentage // 0 | floor),
  (.cost.total_cost_usd // 0 | "$\(. * 100 | round | . / 100)"),
  (.rate_limits.five_hour.used_percentage // 0 | floor),
  (.rate_limits.five_hour.resets_at // 0),
  (.rate_limits.seven_day.used_percentage // 0 | floor),
  (.rate_limits.seven_day.resets_at // 0),
  (.cost.total_duration_ms // 0),
  (if .prompt_cache.warm == true then "true" else "" end),
  (.prompt_cache.ttl // ""),
  (.prompt_cache.caching_observed // false),
  (.prompt_cache.expires_at // 0),
  ((.prompt_cache.hit_ratio // 0) * 100 | round),
  (.context_window.total_input_tokens // 0),
  (.cwd // ""),
  (.session_id // ""),
  (.cost.total_cost_usd // 0),
  (.version // "")' 2>/dev/null)

# Defaults mirror the // fallbacks above, so malformed JSON degrades to the
# same empty statusline it always did instead of printing raw bash.
model=${F[0]:-?}
ctx=${F[1]:-0}
cost=${F[2]:-\$0}
usage_5h=${F[3]:-0}
resets_at=${F[4]:-0}
usage_7d=${F[5]:-0}
resets_7d=${F[6]:-0}
duration_ms=${F[7]:-0}
cache_warm=${F[8]-}
cache_ttl=${F[9]-}
cache_observed=${F[10]:-false}
cache_expires_raw=${F[11]:-0}
cache_hit_pct=${F[12]:-0}
context_input_tokens=${F[13]:-0}
cwd=${F[14]-}
session_id=${F[15]-}
cost_usd=${F[16]:-0}
cc_version=${F[17]-}
project=$(basename "$cwd")

to_epoch() {
  local v=$1
  [[ -z $v || $v == null ]] && { echo 0; return; }
  [[ $v =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  date -d "$v" +%s 2>/dev/null || echo 0
}
resets_at=$(to_epoch "$resets_at")
resets_7d=$(to_epoch "$resets_7d")
cache_expires_at=$(to_epoch "$cache_expires_raw")

# XDG_CACHE_HOME is the freedesktop.org convention for "where programs keep
# regenerable data" — ~/.cache unless the user has moved it. Everything this
# script caches lives under one directory there and can be deleted at any time.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-hud"

# Measured tokens/min from the background calibration scan. Read here rather
# than with the other calibration values further down, because the burn-rate
# block below renders it and runs first.
calib_tpm=0
[[ -f "$CACHE_DIR/calib-tokens" ]] && calib_tpm=$(cat "$CACHE_DIR/calib-tokens" 2>/dev/null || echo 0)
[[ $calib_tpm =~ ^[0-9]+$ ]] || calib_tpm=0

# ── Window value (for the cold-cache reheat estimate) ─────────────────────────
# window_cents — the API-equivalent value of a 5h window, in US cents.
#
# This is in cents rather than tokens because no single token count describes a
# 5h window: Anthropic meters value, not tokens, so cache-write-heavy and
# cache-read-heavy windows cannot be compared by counting tokens. See
# docs/cold-reheat.md for the measurements behind this; do not "simplify" the
# reheat estimate back to a token budget. Burn rate and time-to-cap used to
# carry a parallel token budget and inherited exactly that error -- they are
# now derived from used_percentage and resets_at alone and need no constant.
#
# Cached for 60s — credentials rarely change and jq parsing adds latency.
budget_cache="$CACHE_DIR/window-cents"
window_cents=${CLAUDE_HUD_WINDOW_CENTS:-0}

if [[ -f $budget_cache ]]; then
  cache_age=$(( $(date +%s) - $(date -r "$budget_cache" +%s 2>/dev/null || echo 0) ))
  if (( cache_age < 60 )); then
    read -r cached_cents < "$budget_cache"
    [[ $cached_cents =~ ^[0-9]+$ ]] || cached_cents=0
    (( window_cents == 0 )) && window_cents=${cached_cents:-0}
  fi
fi

if (( window_cents == 0 )); then
  creds="${CLAUDE_HUD_CREDENTIALS:-$HOME/.claude/.credentials.json}"
  if [[ -f $creds ]]; then
    plan=$(jq -r '.claudeAiOauth.subscriptionType // ""' "$creds" 2>/dev/null)
    tier=$(jq -r '.claudeAiOauth.rateLimitTier // ""' "$creds" 2>/dev/null)
    # rateLimitTier is a decorated slug, not a bare one — a Max 5x account
    # reports "default_claude_max_5x" — so match the tier anywhere in the
    # string. 20x is checked first only for readability; the two can't collide.
    #
    # Max 5x is the measured anchor ($120/window); Pro and Max 20x are that
    # scaled by the nominal plan multipliers, which is a guess.
    case "$plan:$tier" in
      pro:*)         plan_cents=2400  ;;
      max:*max_20x*) plan_cents=48000 ;;
      max:*max_5x*)  plan_cents=12000 ;;
      *max*)         plan_cents=12000 ;;
      *)             plan_cents=2400  ;;
    esac
    mkdir -p "$CACHE_DIR"
    printf '%s\n' "$plan_cents" > "$budget_cache"
    window_cents=$plan_cents
  fi
fi

# ── Duration formatting ───────────────────────────────────────────────────────
if   (( duration_ms >= 3600000 )); then duration="$(( duration_ms / 3600000 ))h$(( (duration_ms % 3600000) / 60000 ))m"
elif (( duration_ms >= 60000 ));   then duration="$(( duration_ms / 60000 ))m"
else duration="$(( duration_ms / 1000 ))s"; fi

# ── Burn rate & time-to-cap ───────────────────────────────────────────────────
burn_label=""
ttc_label=""
now=$(date +%s)

# Compact duration: "45m", "3h20m", "2d4h". A bare "0.4d" is unreadable when
# what it means is "about nine hours".
fmt_dur() {
  local m=$1
  if   (( m < 60 ));   then printf '%dm' "$m"
  elif (( m < 1440 )); then printf '%dh%dm' $(( m / 60 )) $(( m % 60 ))
  else                      printf '%dd%dh' $(( m / 1440 )) $(( (m % 1440) / 60 ))
  fi
}

# Both windows use the same maths -- percent consumed per unit of time, and the
# time until 100% at that pace. Neither needs to know the window's size in
# tokens or dollars, only the percentage the payload already reports, so this
# works identically for the 5h and the 7d window. $4 is the rate's unit in
# seconds (3600 = per hour, 86400 = per day).
#
# Sets burn_x10 (tenths of a percent per unit) and mins_to_cap (-1 = unknown,
# 0 = already at the cap).
window_burn() {
  local used=$1 resets=$2 window=$3 per=$4 elapsed
  burn_x10=0; mins_to_cap=-1
  (( used >= 100 )) && { mins_to_cap=0; return; }
  (( resets > now && used > 0 )) || return
  elapsed=$(( now - (resets - window) ))
  (( elapsed > 60 )) || return
  burn_x10=$(( used * per * 10 / elapsed ))
  (( burn_x10 > 0 )) && mins_to_cap=$(( (100 - used) * elapsed / (used * 60) ))
}

fmt_burn() {   # tenths -> "12%/h" or "0.4%/h"
  local x=$1 unit=$2
  if (( x >= 100 )); then printf '%d%%/%s' $(( x / 10 )) "$unit"
  else printf '%d.%d%%/%s' $(( x / 10 )) $(( x % 10 )) "$unit"
  fi
}

window_burn "$usage_5h" "$resets_at" 18000 3600
burn_5h_x10=$burn_x10; ttc_5h=$mins_to_cap
window_burn "$usage_7d" "$resets_7d" 604800 86400
burn_7d_x10=$burn_x10; ttc_7d=$mins_to_cap

# Measured tokens/min sits next to the percentage rather than replacing it:
# the percentage is what the server actually meters you on, the token count is
# the physical throughput behind it. Dim, because it is a local-only estimate
# refreshed on the calibration's cadence, not a live figure.
tok_label=""
if (( calib_tpm >= 1000000 )); then
  tok_label=" ${DIM}$(( calib_tpm / 100000 / 10 )).$(( calib_tpm / 100000 % 10 ))M/m${RESET}"
elif (( calib_tpm >= 1000 )); then
  tok_label=" ${DIM}$(( calib_tpm / 1000 ))k/m${RESET}"
elif (( calib_tpm > 0 )); then
  tok_label=" ${DIM}${calib_tpm}/m${RESET}"
fi

if (( burn_5h_x10 > 0 )); then
  burn_label="🔥 ${YELLOW}$(fmt_burn "$burn_5h_x10" h)${RESET}${tok_label}"
  if (( ttc_5h > 0 )); then
    if   (( ttc_5h < 60 ));  then ttc_color=$RED
    elif (( ttc_5h < 120 )); then ttc_color=$YELLOW
    else                          ttc_color=$DIM; fi
    ttc_label=" ${ttc_color}~$(fmt_dur "$ttc_5h")${RESET}"
  fi
fi

# The weekly burn rides along with the 7d segment rather than standing alone,
# so it appears and disappears with the bar it describes instead of needing its
# own visibility rule. Thresholds are in days, not hours: a weekly window with
# two hours left is far more urgent than a 5h window in the same state.
burn_7d_label=""
if (( burn_7d_x10 > 0 )); then
  burn_7d_label=" 🔥 ${YELLOW}$(fmt_burn "$burn_7d_x10" d)${RESET}"
  if (( ttc_7d > 0 )); then
    if   (( ttc_7d < 720 ));  then ttc7_color=$RED
    elif (( ttc_7d < 2880 )); then ttc7_color=$YELLOW
    else                           ttc7_color=$DIM; fi
    burn_7d_label+=" ${ttc7_color}~$(fmt_dur "$ttc_7d")${RESET}"
  fi
fi

# ── Self-calibrated window size ───────────────────────────────────────────────
# The plan table above is a guess. This measures the real thing: sum the API-
# equivalent value of every request in the current 5h window from the local
# transcripts, then divide by the used_percentage the payload reports.
#
#   measured_window_cents = window_so_far_cents * 100 / used_percentage
#
# used_percentage is server-side and account-wide — it includes other devices
# and claude.ai. The transcript sum only sees this machine, so the numerator is
# a lower bound and the calibration reads LOW, never high. Samples are smoothed
# with an EMA across windows to blunt that.
#
# The scan takes ~1.5s, so it never runs inline: the render reads whatever the
# cache holds and forks a refresh in the background at most once per interval.
calib_cents=0
calib_file="$CACHE_DIR/calib-cents"
calib_stamp="$CACHE_DIR/calib-stamp"
calib_interval=${CLAUDE_HUD_CALIB_INTERVAL:-600}
# Below this used_percentage the reading is mostly rounding error (the payload
# reports whole percents), so neither sample nor trust it.
calib_min_pct=${CLAUDE_HUD_CALIB_MIN_PCT:-5}

[[ -f $calib_file ]] && calib_cents=$(cat "$calib_file" 2>/dev/null || echo 0)
[[ $calib_cents =~ ^[0-9]+$ ]] || calib_cents=0

if (( resets_at > now && usage_5h >= calib_min_pct )); then
  stamp_age=$calib_interval
  [[ -f $calib_stamp ]] && stamp_age=$(( now - $(date -r "$calib_stamp" +%s 2>/dev/null || echo 0) ))
  if (( stamp_age >= calib_interval )); then
    mkdir -p "$CACHE_DIR"
    # Touch before forking so concurrent renders don't each spawn a scan.
    : > "$calib_stamp"
    (
      window_start=$(( resets_at - 18000 ))
      # Prices in cents per million input tokens. Output is 5x input and cache
      # writes 2x on every current model, so one input price covers those --
      # but cache READS are not uniformly 0.1x: Fable/Mythos read at a flat
      # $0.25/MTok, not a tenth of their $10 input rate, so the read rate is
      # tracked separately. Anything unmatched falls through to Sonnet 5's $2;
      # Sonnet 4.6 is $3 and needs its own arm.
      spent=$(find "$HOME/.claude/projects" -name '*.jsonl' -newermt "@$window_start" -print0 2>/dev/null \
        | xargs -0 -r grep -h '"type":"assistant"' 2>/dev/null \
        | jq -rc --argjson start "$window_start" '
            select(.type=="assistant" and .timestamp != null and .requestId != null)
            | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t
            | select($t >= $start)
            | [ .requestId, (.message.model // ""),
                (.message.usage.input_tokens // 0),
                (.message.usage.output_tokens // 0),
                (.message.usage.cache_creation_input_tokens // 0),
                (.message.usage.cache_read_input_tokens // 0) ] | @tsv' 2>/dev/null \
        | sort -u -k1,1 \
        | awk -F'\t' '
            { if      ($2 ~ /fable|mythos/) { p = 1000; cr = 25 }
              else if ($2 ~ /opus/)         { p = 500;  cr = p/10 }
              else if ($2 ~ /haiku/)        { p = 100;  cr = p/10 }
              else if ($2 ~ /sonnet-4-6/)   { p = 300;  cr = p/10 }
              else                          { p = 200;  cr = p/10 }
              c += ($3*p + $4*p*5 + $5*p*2 + $6*cr) / 1000000
                t += $3 + $4 + $5 + $6 }
            END { printf "%d %d", c + 0, t + 0 }')
      # The scan already summed real tokens; it used to discard them. Emitting
      # measured throughput costs nothing extra here. Local machine only, so it
      # undercounts if another device shares the account.
      read -r spent scanned_tokens <<< "$spent"
      elapsed_min=$(( (now - window_start) / 60 ))
      if (( elapsed_min > 0 )) && [[ $scanned_tokens =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$(( scanned_tokens / elapsed_min ))" > "$CACHE_DIR/calib-tokens" 2>/dev/null
      fi
      [[ $spent =~ ^[0-9]+$ ]] || exit 0
      (( spent > 0 )) || exit 0
      sample=$(( spent * 100 / usage_5h ))
      prev=0
      [[ -f $calib_file ]] && prev=$(cat "$calib_file" 2>/dev/null || echo 0)
      [[ $prev =~ ^[0-9]+$ ]] || prev=0
      # EMA, alpha = 1/4. First sample seeds it outright.
      if (( prev > 0 )); then
        printf '%s\n' "$(( (prev * 3 + sample) / 4 ))" > "$calib_file"
      else
        printf '%s\n' "$sample" > "$calib_file"
      fi
    ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi
fi

# ── Per-model usage, opt-in ───────────────────────────────────────────────────
# The statusline payload carries only aggregate five_hour/seven_day windows.
# GET /api/oauth/usage additionally returns per-model weekly windows in its
# limits[] array (kind="weekly_scoped", scope.model.display_name) -- the one
# thing the payload genuinely cannot tell you. Verified against the payload:
# the aggregate numbers match to the percentage point, so this adds the
# per-model breakdown and nothing else.
#
# Off by default (CLAUDE_HUD_USAGE_API=1 to enable). It is an undocumented
# internal endpoint that a release can reshape without notice, it sends your
# OAuth token, and it is subject to an open 429 bug that depends on the exact
# User-Agent. Nothing here is load-bearing: every failure path leaves the line
# exactly as it would have been.
usage_models=""
if [[ ${CLAUDE_HUD_USAGE_API:-0} == 1 ]]; then
  usage_cache="$CACHE_DIR/usage-api.json"
  usage_lock="$CACHE_DIR/usage-api.lock"
  # The fetch is backgrounded and never blocks a render, and the lock means one
  # fetch per interval across ALL sessions, not per session -- so the interval
  # buys request volume, nothing else. Kept close to the render cadence on
  # purpose: a long interval leaves the server numbers visibly frozen while the
  # local ones tick, which reads like a bug rather than a slower sample.
  usage_interval=${CLAUDE_HUD_USAGE_INTERVAL:-30}

  usage_age=$usage_interval
  [[ -f $usage_cache ]] && usage_age=$(( now - $(date -r "$usage_cache" +%s 2>/dev/null || echo 0) ))

  # A crashed fetch would otherwise hold the lock forever.
  if [[ -d $usage_lock ]]; then
    lock_age=$(( now - $(date -r "$usage_lock" +%s 2>/dev/null || echo 0) ))
    (( lock_age > 120 )) && rmdir "$usage_lock" 2>/dev/null
  fi

  # mkdir is atomic, so exactly one of several concurrent sessions fetches.
  if (( usage_age >= usage_interval )) && mkdir -p "$CACHE_DIR" 2>/dev/null \
     && mkdir "$usage_lock" 2>/dev/null; then
    (
      trap 'rmdir "$usage_lock" 2>/dev/null' EXIT
      tok=$(jq -r '.claudeAiOauth.accessToken // empty' \
        "${CLAUDE_HUD_CREDENTIALS:-$HOME/.claude/.credentials.json}" 2>/dev/null)
      [[ -n $tok ]] || exit 0
      curl -sf --max-time 10 \
        -H "Authorization: Bearer $tok" \
        -H "User-Agent: claude-cli/${cc_version:-2.0.0} (external, cli)" \
        -H "anthropic-beta: oauth-2025-04-20" \
        https://api.anthropic.com/api/oauth/usage > "$usage_cache.tmp" 2>/dev/null \
        && mv -f "$usage_cache.tmp" "$usage_cache" 2>/dev/null
      rm -f "$usage_cache.tmp" 2>/dev/null
    ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi

  # Render from whatever the cache holds. A missing, stale, or malformed cache
  # simply produces no segment -- the percentage-based line stands on its own.
  if [[ -f $usage_cache ]]; then
    # Show the server's own aggregates next to the per-model rows, so the
    # payload-derived numbers on the left can be compared against their source
    # rather than taken on trust.
    # Aggregates and per-model rows are read separately: the aggregates have a
    # local counterpart to compare against, the per-model rows have none and so
    # are always worth showing.
    mapfile -t U < <(jq -r '
      (.five_hour.utilization // 0 | floor),
      (.seven_day.utilization // 0 | floor),
      ([ .limits[]?
         | select(.kind == "weekly_scoped")
         | select((.scope.model.display_name // "") != "")
         | "\(.scope.model.display_name) \(.percent // 0 | floor)%" ] | join(" "))
      ' "$usage_cache" 2>/dev/null)
    srv_5h=${U[0]:-}; srv_7d=${U[1]:-}; srv_models=${U[2]-}
    [[ $srv_5h =~ ^[0-9]+$ ]] || srv_5h=""
    [[ $srv_7d =~ ^[0-9]+$ ]] || srv_7d=""

    # CLAUDE_HUD_USAGE_DRIFT=N hides the server aggregates unless they disagree
    # with the payload by N points or more -- useful once the two have proven
    # they track, so the line only speaks up when they diverge. 0 (default)
    # always shows them, which is what you want while still comparing.
    usage_drift=${CLAUDE_HUD_USAGE_DRIFT:-0}
    show_aggregates=1
    if (( usage_drift > 0 )) && [[ -n $srv_5h && -n $srv_7d ]]; then
      d5=$(( srv_5h - usage_5h )); (( d5 < 0 )) && d5=$(( -d5 ))
      d7=$(( srv_7d - usage_7d )); (( d7 < 0 )) && d7=$(( -d7 ))
      (( d5 >= usage_drift || d7 >= usage_drift )) || show_aggregates=0
    fi

    usage_models=""
    if (( show_aggregates )) && [[ -n $srv_5h && -n $srv_7d ]]; then
      usage_models="5h ${srv_5h}% 7d ${srv_7d}%"
    fi
    [[ -n $srv_models ]] && usage_models="${usage_models:+$usage_models }${srv_models}"

    # Age is part of the reading, not decoration: these numbers are sampled, and
    # a stalled fetch should be obvious rather than quietly showing an old value
    # that looks live. Yellow once older than two intervals -- what a failing
    # fetch looks like.
    if [[ -n $usage_models ]]; then
      usage_data_age=$(( now - $(date -r "$usage_cache" +%s 2>/dev/null || echo "$now") ))
      (( usage_data_age < 0 )) && usage_data_age=0
      if   (( usage_data_age < 60 ));   then usage_age_str="${usage_data_age}s"
      elif (( usage_data_age < 3600 )); then usage_age_str="$(( usage_data_age / 60 ))m"
      else                                   usage_age_str="$(( usage_data_age / 3600 ))h"
      fi
      usage_age_color=$DIM
      (( usage_data_age > usage_interval * 2 )) && usage_age_color=$YELLOW
      usage_models="${usage_models} ${usage_age_color}${usage_age_str}${RESET}"
    fi
  fi
fi

# ── Git info ──────────────────────────────────────────────────────────────────
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
# Detached HEAD (rebase, checked-out tag/commit, etc.) — fall back to an
# exact tag match, then a short commit SHA, instead of showing nothing.
if [[ -z $branch ]]; then
  branch=$(git -C "$cwd" describe --tags --exact-match 2>/dev/null)
fi
if [[ -z $branch ]]; then
  branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi
dirty_count=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

ahead=0 behind=0
if [[ -n $branch ]]; then
  read -r ahead behind < <(git -C "$cwd" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null)
  ahead=${ahead:-0}; behind=${behind:-0}
fi
ahead_behind=""
(( ahead > 0 ))  && ahead_behind+="↑${ahead}"
(( behind > 0 )) && ahead_behind+="↓${behind}"

# ── Environment counts ────────────────────────────────────────────────────────
# Both counts from a single read of settings.json, same reasoning as above.
mapfile -t E < <(jq -r '((.mcpServers // {}) | length), ([.hooks // {} | to_entries[].value[]] | length)' \
  ~/.claude/settings.json 2>/dev/null)
mcps=${E[0]:-0}
hooks=${E[1]:-0}

# ── Bar colors ────────────────────────────────────────────────────────────────
if   (( ctx >= 85 )); then CTX_COLOR=$RED
elif (( ctx >= 70 )); then CTX_COLOR=$YELLOW
else CTX_COLOR=$GREEN; fi

if   (( usage_5h >= 90 )); then USAGE_COLOR=$RED
elif (( usage_5h >= 75 )); then USAGE_COLOR=$BRIGHT_MAGENTA
else USAGE_COLOR=$BRIGHT_BLUE; fi

if   (( usage_7d >= 90 )); then WEEKLY_COLOR=$RED
elif (( usage_7d >= 75 )); then WEEKLY_COLOR=$YELLOW
else WEEKLY_COLOR=$BRIGHT_CYAN; fi

# ── Reset time ────────────────────────────────────────────────────────────────
reset_label=""
if (( resets_at > now )); then
  reset_time=$(date -d "@$resets_at" "+%-I:%M%p" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/:00//')
  reset_label=" ${reset_time}"
fi

# ── Prompt cache ──────────────────────────────────────────────────────────────
# prompt_cache only appears in the statusline payload after the first API
# response of the session — cache_observed stays false until then.
cache_label=""
if [[ $cache_observed == "true" ]]; then
  if [[ $cache_warm == "true" ]]; then
    cache_status="warm"
    cache_color=$GREEN
    cache_ttl_label=""
    cache_hit_label=" ${DIM}hit ${cache_hit_pct}%${RESET}"
    if (( cache_expires_at > now )); then
      remaining=$(( cache_expires_at - now ))
      # Warn (yellow) inside the last fifth of the TTL, so the color starts
      # shifting before the segment flips to cold, not just at the cliff.
      case "$cache_ttl" in
        *5m*) ttl_secs=300  ;;
        *1h*) ttl_secs=3600 ;;
        *)    ttl_secs=3600 ;;
      esac
      (( remaining <= ttl_secs / 5 )) && cache_color=$YELLOW
      if (( remaining >= 60 )); then
        cache_ttl_label=" ${DIM}~$(( remaining / 60 ))m${RESET}"
      else
        cache_ttl_label=" ${DIM}~${remaining}s${RESET}"
      fi
    fi
  else
    cache_color=$RED
    cache_status="cold"
    cache_ttl_label=""
    cache_hit_label=""
    # Cold means the next turn re-writes the whole context into the cache
    # instead of reading it: ~2x base input price on a 1h TTL, ~1.25x on 5m,
    # vs. the ~0.1x a warm read would have cost. What that costs you is a
    # share of the 5h window, so price the rewrite in cents and divide by the
    # window's value in cents.
    #
    # The earlier version divided the token count by a token budget after
    # multiplying it by the *price* multiplier — a dollars-per-token factor
    # applied to a token count — which is what produced readings like 377%.
    if (( context_input_tokens > 0 )); then
      case "$cache_ttl" in
        *5m*) write_mult="1.25" ;;
        *)    write_mult="2"    ;;
      esac
      # Same table as the calibration scan above, matched on display name.
      # Only the input rate matters here -- a reheat is a cache *write*.
      case "$(printf '%s' "$model" | tr 'A-Z' 'a-z')" in
        *fable*|*mythos*) in_price=1000 ;;
        *opus*)           in_price=500  ;;
        *haiku*)          in_price=100  ;;
        *sonnet\ 4.6*)    in_price=300  ;;
        *)                in_price=200  ;;
      esac
      reheat_cents=$(jq -n --argjson tok "$context_input_tokens" --argjson price "$in_price" \
        --argjson mult "$write_mult" '($tok * $price * $mult / 1000000)')

      # Tokens first, because it is the one number here that is measured
      # rather than estimated.
      if (( context_input_tokens >= 1000000 )); then
        reheat_tok=$(jq -rn --argjson t "$context_input_tokens" '"\($t/1000000*10|round/10)M"')
      else
        reheat_tok=$(jq -rn --argjson t "$context_input_tokens" '"\($t/1000*10|round/10)k"')
      fi

      # Two denominators, shown side by side while the calibration proves
      # itself: the plan table (C) then the self-calibrated measurement (B).
      pct_parts=()
      (( window_cents > 0 )) && pct_parts+=("$(jq -rn --argjson c "$reheat_cents" \
        --argjson w "$window_cents" '(($c / $w) * 100) | round')")
      (( calib_cents > 0 )) && pct_parts+=("$(jq -rn --argjson c "$reheat_cents" \
        --argjson w "$calib_cents" '(($c / $w) * 100) | round')")

      if (( ${#pct_parts[@]} > 0 )); then
        # Rendered as a range ("2-3%"), low end first, so it reads as "2 to 3
        # percent" rather than as a ratio. Collapses to a single number when
        # both estimates round the same or only one denominator resolved. A
        # value that rounds to zero shows as "<1" — "0%" reads as free.
        lo=${pct_parts[0]}; hi=${pct_parts[0]}
        if (( ${#pct_parts[@]} > 1 )); then
          if (( pct_parts[1] < lo )); then lo=${pct_parts[1]}; else hi=${pct_parts[1]}; fi
        fi
        lo_s=$lo; (( lo == 0 )) && lo_s="<1"
        hi_s=$hi; (( hi == 0 )) && hi_s="<1"
        if [[ $lo_s == "$hi_s" ]]; then reheat_pct=$lo_s; else reheat_pct="${lo_s}-${hi_s}"; fi
        cache_ttl_label=" ${DIM}${reheat_tok} ${reheat_pct}% 5h${RESET}"
      else
        cache_ttl_label=" ${DIM}${reheat_tok} to reheat${RESET}"
      fi
    fi
  fi
  cache_label="${cache_color}${cache_status}${RESET}${cache_ttl_label}${cache_hit_label}"
fi

weekly_reset_label=""
if (( resets_7d > now )); then
  if (( resets_7d - now < 86400 )); then
    weekly_reset_label=" $(date -d "@$resets_7d" "+%-I:%M%p" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/:00//')"
  else
    weekly_reset_label=" $(date -d "@$resets_7d" "+%a" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  fi
fi

# ── Host stats (RAM / CPU / clock) ────────────────────────────────────────────
# Best-effort: `free` is Linux-only, so this degrades gracefully (empty
# segment) on a host that doesn't have it rather than erroring the whole
# statusline. "avail" is `free`'s own "available" column (what could
# actually be allocated before swapping), not the raw "free" column, which
# undercounts anything sitting in reclaimable page cache.
ram_label=""
if command -v free >/dev/null 2>&1; then
  # Percentage USED (total minus available), not free -- matches every
  # other number in this statusline (ctx/5h/7d are all "how much of the
  # budget is consumed", higher = closer to a limit), rather than
  # introducing a lone "higher is better" metric that reads backwards
  # next to the rest of the line.
  ram_used_pct=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d", (($2-$7)/$2)*100}')
  [[ -n $ram_used_pct ]] && ram_label=" ${DIM}ram${RESET} ${ram_used_pct}%"
fi

cpu_label=""
cpu_load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
[[ -z $cpu_load1 ]] && cpu_load1=$(uptime 2>/dev/null | grep -oE '[0-9]+\.[0-9]+,?' | head -1 | tr -d ',')
# Shown as a percentage of this host's OWN core count -- a load-average
# float means nothing on its own without knowing how many cores it's
# being spread across, so normalize against the real number rather than
# a fixed/arbitrary denominator.
if [[ -n $cpu_load1 ]]; then
  cpu_cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
  if [[ -n $cpu_cores && $cpu_cores -gt 0 ]]; then
    cpu_pct=$(awk -v l="$cpu_load1" -v c="$cpu_cores" 'BEGIN{printf "%d", (l/c)*100}')
    cpu_label=" ${DIM}cpu${RESET} ${cpu_pct}%"
  fi
fi

clock_label=" ${DIM}t${RESET} $(date '+%-I:%M%p' 2>/dev/null | tr '[:upper:]' '[:lower:]')"

host_stats_label="${ram_label}${cpu_label}${clock_label}"
host_stats_label="${host_stats_label# }"

# ── Bars ──────────────────────────────────────────────────────────────────────
make_bar() {
  local pct=$1 color=$2 width=${3:-10}
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  local filled=$(( pct * width / 100 )) empty=$(( width - pct * width / 100 ))
  # printf pads to a width, then substitution swaps the padding for the block
  # character. This used to fork `seq` twice per bar, three bars per render.
  local f='' e=''
  printf -v f '%*s' "$filled" ''
  printf -v e '%*s' "$empty" ''
  printf '%s%s%s%s%s' "$color" "${f// /█}" "$DIM" "${e// /░}" "$RESET"
}

ctx_bar=$(make_bar "$ctx" "$CTX_COLOR")
usage_bar=$(make_bar "$usage_5h" "$USAGE_COLOR")
weekly_bar=$(make_bar "$usage_7d" "$WEEKLY_COLOR" "$WEEKLY_BAR_WIDTH")

# ── Terminal width ────────────────────────────────────────────────────────────
# Claude Code passes the terminal width via COLUMNS. Falls back to 0 (no
# wrapping) if it's ever unset, e.g. running the script outside Claude Code.
cols=${COLUMNS:-0}
[[ $cols =~ ^[0-9]+$ ]] || cols=0

# Approximate on-screen width: strip ANSI color codes, then correct for the
# double-width emoji this script prints (bash counts each codepoint as 1,
# terminals render them as 2) and for the invisible U+FE0F variation selector
# (counted as 1 codepoint by bash, 0 cells on screen).
# Called once per segment inside the wrapping loop, so it ran on the order of
# 24 processes per render (sed + 2 greps + 2 wc, per segment) whenever COLUMNS
# was set -- which is always, under Claude Code. All of it is native bash:
# extglob strips the SGR sequences, and each count is a length difference after
# removing the characters in question. Character semantics (not bytes) come
# from the UTF-8 locale, exactly as the old ${#stripped} already assumed.
visible_width() {
  local s=${1//$'\e['*([0-9;])m/}
  local n=${#s}
  local no_wide=${s//[🔥🔌🪝⏱]/}
  local no_vs16=${s//$'\ufe0f'/}
  echo $(( n + (n - ${#no_wide}) - (n - ${#no_vs16}) ))
}

# ── Assemble line ─────────────────────────────────────────────────────────────
SEP="${RESET} ${DIM}│${RESET} "

segments=("${CYAN}[${model}]${RESET}")

if [[ -n $branch ]]; then
  dirty_flag=""; (( dirty_count > 0 )) && dirty_flag="*"
  segments+=("${YELLOW}${project}${RESET} ${MAGENTA}git:(${CYAN}${branch}${dirty_flag}${ahead_behind}${MAGENTA})${RESET}")
else
  segments+=("${YELLOW}${project}${RESET}")
fi

segments+=("${DIM}ctx${RESET} ${ctx_bar} ${CTX_COLOR}${ctx}%${RESET}")
[[ -n $cache_label ]] && segments+=("$cache_label")
segments+=("${DIM}5h${RESET} ${usage_bar} ${USAGE_COLOR}${usage_5h}%${reset_label}${RESET}")
(( usage_7d >= 100 - WEEKLY_SHOW_AT_REMAINING )) && \
  segments+=("${DIM}7d${RESET} ${weekly_bar} ${WEEKLY_COLOR}${usage_7d}%${weekly_reset_label}${RESET}${burn_7d_label}")
[[ -n $burn_label ]] && segments+=("${burn_label}${ttc_label}")

env=""
(( mcps > 0 ))       && env+=" 🔌${mcps}"
(( hooks > 0 ))      && env+=" 🪝${hooks}"
[[ -n $env ]] && segments+=("${env# }")
[[ -n $usage_models ]] && segments+=("${DIM}api${RESET} ${DIM}${usage_models}${RESET}")

# Cost and duration are opt-in, off by default -- burn rate/time-to-cap
# already cover "how much budget is left in this window", which is the
# number most people actually want at a glance; total-session cost and
# wall-clock session length are a different, less universally-wanted
# question, so they don't cost every user the extra width by default.
[[ ${CLAUDE_HUD_SHOW_COST:-0} == 1 ]]     && segments+=("${YELLOW}${cost}${RESET}")
[[ ${CLAUDE_HUD_SHOW_DURATION:-0} == 1 ]] && segments+=("⏱️  ${DIM}${duration}${RESET}")
[[ -n $host_stats_label ]] && segments+=("$host_stats_label")

# Pack segments onto as many lines as needed to fit COLUMNS — wraps instead of
# dropping or truncating, so nothing is lost on a narrow terminal.
lines=("${segments[0]}")
for (( i = 1; i < ${#segments[@]}; i++ )); do
  last=$(( ${#lines[@]} - 1 ))
  candidate="${lines[$last]}${SEP}${segments[i]}"
  if (( cols > 0 )) && (( $(visible_width "$candidate") > cols )); then
    lines+=("${segments[i]}")
  else
    lines[$last]="$candidate"
  fi
done

printf '%s\n' "${lines[@]}"

# ── Snapshot ──────────────────────────────────────────────────────────────────
# Also write the rendered HUD to a file, so anything that can't see the
# terminal — a monitor loop, an agent, another pane — can read the current
# status with a plain `cat` instead of re-deriving any of it. Colors are
# stripped; the file's mtime is its freshness.
#
# One file per session, deliberately with no "latest" alias: with several
# sessions running, a shared pointer just races between them and whoever reads
# it gets an arbitrary session's numbers. Readers name the session they mean.
# Set CLAUDE_HUD_SNAPSHOT_DIR=none to turn this off.
snapshot_dir=${CLAUDE_HUD_SNAPSHOT_DIR:-$CACHE_DIR/status}
if [[ $snapshot_dir != none ]] && mkdir -p "$snapshot_dir" 2>/dev/null; then
  snapshot_name=$(printf '%s' "${session_id:-unknown}" | tr -cd 'A-Za-z0-9._-')
  snapshot_file="$snapshot_dir/${snapshot_name:-unknown}.txt"
  printf '%s\n' "${lines[@]}" | sed -E 's/\x1b\[[0-9;]*m//g' > "$snapshot_file" 2>/dev/null

  # Structured sibling of the .txt. The rendered line is for humans: times are
  # local clock strings ("1:30am", with ":00" dropped on the hour), numbers are
  # embedded in bars and separators. A consumer that greps it back out has to
  # re-derive what this script already knows -- and worse, fails silently when
  # the format shifts, since a missing match just looks like "no data".
  #
  # Built with printf rather than jq: this runs on every render, and a fork
  # here would give back a chunk of what collapsing the jq calls above bought.
  # Epochs are emitted raw, so no consumer has to guess today-vs-tomorrow the
  # way a bare clock time forces.
  json_escape() { local v=${1//\\/\\\\}; printf '%s' "${v//\"/\\\"}"; }
  # A timestamp the payload didn't supply comes through as 0, and 0 is a real
  # epoch -- a consumer doing `todate` on it gets 1970-01-01 and no hint that
  # the value was simply absent. Emit JSON null instead, which every consumer
  # already has to handle and which cannot be mistaken for a date.
  epoch_or_null() { (( ${1:-0} > 0 )) && printf '%s' "$1" || printf 'null'; }
  num_or_null() { (( ${1:--1} >= 0 )) && printf '%s' "$1" || printf 'null'; }
  # Which limit actually stops you, and when. A consumer that only watches the
  # 5h window will happily keep working straight into a weekly wall, so this
  # resolves both and names the binding one rather than making every reader
  # re-derive it. blocked_now/blocked_until describe a cap already hit;
  # binding_limit/blocked_at are the prediction at the current burn.
  blocked_now=false; blocked_until=0
  (( usage_5h >= 100 )) && { blocked_now=true; blocked_until=$resets_at; }
  (( usage_7d >= 100 )) && { blocked_now=true; (( resets_7d > blocked_until )) && blocked_until=$resets_7d; }
  binding=null; blocked_at=0
  if (( ttc_5h >= 0 && ttc_7d >= 0 )); then
    if (( ttc_5h <= ttc_7d )); then binding='"five_hour"'; blocked_at=$(( now + ttc_5h * 60 ))
    else binding='"seven_day"'; blocked_at=$(( now + ttc_7d * 60 )); fi
  elif (( ttc_5h >= 0 )); then binding='"five_hour"'; blocked_at=$(( now + ttc_5h * 60 ))
  elif (( ttc_7d >= 0 )); then binding='"seven_day"'; blocked_at=$(( now + ttc_7d * 60 ))
  fi
  cache_warm_json=false; [[ $cache_warm == "true" ]] && cache_warm_json=true
  printf '{"session_id":"%s","rendered_at":%s,"model":"%s","cwd":"%s","project":"%s",' \
    "$(json_escape "$session_id")" "$now" "$(json_escape "$model")" \
    "$(json_escape "$cwd")" "$(json_escape "$project")" \
    > "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" 2>/dev/null
  printf '"ctx_pct":%s,"context_input_tokens":%s,"used_5h_pct":%s,"resets_5h":%s,' \
    "${ctx:-0}" "${context_input_tokens:-0}" "${usage_5h:-0}" "$(epoch_or_null "${resets_at:-0}")" \
    >> "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" 2>/dev/null
  printf '"used_7d_pct":%s,"resets_7d":%s,"cache_observed":%s,"cache_warm":%s,' \
    "${usage_7d:-0}" "$(epoch_or_null "${resets_7d:-0}")" "${cache_observed:-false}" "$cache_warm_json" \
    >> "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" 2>/dev/null
  printf '"cache_expires_at":%s,"cache_hit_pct":%s,"cost_usd":%s,"duration_ms":%s,' \
    "$(epoch_or_null "${cache_expires_at:-0}")" "${cache_hit_pct:-0}" "${cost_usd:-0}" "${duration_ms:-0}" \
    >> "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" 2>/dev/null
  printf '"burn_5h_pct_per_hour":%s.%s,"burn_7d_pct_per_day":%s.%s,' \
    $(( burn_5h_x10 / 10 )) $(( burn_5h_x10 % 10 )) $(( burn_7d_x10 / 10 )) $(( burn_7d_x10 % 10 )) \
    >> "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" 2>/dev/null
  printf '"mins_to_cap_5h":%s,"mins_to_cap_7d":%s,"binding_limit":%s,"blocked_at":%s,' \
    "$(num_or_null "$ttc_5h")" "$(num_or_null "$ttc_7d")" "$binding" "$(epoch_or_null "$blocked_at")" \
    >> "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" 2>/dev/null
  printf '"blocked_now":%s,"blocked_until":%s}\n' \
    "$blocked_now" "$(epoch_or_null "$blocked_until")" \
    >> "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" 2>/dev/null
  # Rename into place so a reader never catches a half-written object.
  mv -f "$snapshot_dir/${snapshot_name:-unknown}.json.tmp" \
        "$snapshot_dir/${snapshot_name:-unknown}.json" 2>/dev/null

  # Sessions come and go; prune abandoned snapshots at most once a day so this
  # doesn't accumulate one file per session forever. Cheap — one flat dir.
  prune_stamp="$snapshot_dir/.pruned"
  prune_age=86400
  [[ -f $prune_stamp ]] && prune_age=$(( now - $(date -r "$prune_stamp" +%s 2>/dev/null || echo 0) ))
  if (( prune_age >= 86400 )); then
    : > "$prune_stamp"
    find "$snapshot_dir" -maxdepth 1 \( -name '*.txt' -o -name '*.json' \) -mtime +7 -delete 2>/dev/null
  fi
fi

exit 0
