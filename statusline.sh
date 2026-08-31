#!/usr/bin/env bash
# Claude Code statusLine script — claude-hud style
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

model=$(echo "$data" | jq -r '.model.display_name // "?"')
ctx=$(echo "$data" | jq -r '.context_window.used_percentage // 0 | floor')
cost=$(echo "$data" | jq -r '.cost.total_cost_usd // 0 | "$\(. * 100 | round | . / 100)"')
usage_5h=$(echo "$data" | jq -r '.rate_limits.five_hour.used_percentage // 0 | floor')
resets_at=$(echo "$data" | jq -r '.rate_limits.five_hour.resets_at // 0')
usage_7d=$(echo "$data" | jq -r '.rate_limits.seven_day.used_percentage // 0 | floor')
resets_7d=$(echo "$data" | jq -r '.rate_limits.seven_day.resets_at // 0')
duration_ms=$(echo "$data" | jq -r '.cost.total_duration_ms // 0')
cache_warm=$(echo "$data" | jq -r '.prompt_cache.warm // empty')
cache_ttl=$(echo "$data" | jq -r '.prompt_cache.ttl // ""')
cache_observed=$(echo "$data" | jq -r '.prompt_cache.caching_observed // false')
cache_expires_raw=$(echo "$data" | jq -r '.prompt_cache.expires_at // 0')
cache_hit_pct=$(echo "$data" | jq -r '((.prompt_cache.hit_ratio // 0) * 100) | round')
context_input_tokens=$(echo "$data" | jq -r '.context_window.total_input_tokens // 0')
cwd=$(echo "$data" | jq -r '.cwd // ""')
project=$(basename "$cwd")
transcript=$(echo "$data" | jq -r '.transcript_path // ""')

to_epoch() {
  local v=$1
  [[ -z $v || $v == null ]] && { echo 0; return; }
  [[ $v =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  date -d "$v" +%s 2>/dev/null || echo 0
}
resets_at=$(to_epoch "$resets_at")
resets_7d=$(to_epoch "$resets_7d")
cache_expires_at=$(to_epoch "$cache_expires_raw")

compactions=0
[[ -n $transcript && -f $transcript ]] && compactions=$(grep -c '"subtype":"compact_boundary"' "$transcript" 2>/dev/null || echo 0)

# ── Plan budgets ──────────────────────────────────────────────────────────────
# Two budgets are derived from the plan, in different units:
#
#   token_budget  — tokens per 5h window. Used by burn rate / time-to-cap.
#   window_cents  — API-equivalent value of a 5h window, in US cents. Used by
#                   the cold-cache reheat estimate.
#
# The second exists because no single token count describes a 5h window --
# Anthropic meters value, not tokens, so cache-write-heavy and cache-read-heavy
# windows cannot be compared by counting tokens. See docs/cold-reheat.md for
# the measurements behind this; do not "simplify" the reheat estimate back to
# a token budget.
#
# Cached for 60s — credentials rarely change and jq parsing adds latency.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-hud"
budget_cache="$CACHE_DIR/token-budget"
token_budget=${CLAUDE_HUD_TOKEN_BUDGET:-0}
window_cents=${CLAUDE_HUD_WINDOW_CENTS:-0}

if [[ -f $budget_cache ]]; then
  cache_age=$(( $(date +%s) - $(date -r "$budget_cache" +%s 2>/dev/null || echo 0) ))
  if (( cache_age < 60 )); then
    read -r cached_tokens cached_cents < "$budget_cache"
    (( token_budget == 0 )) && token_budget=${cached_tokens:-0}
    (( window_cents == 0 )) && window_cents=${cached_cents:-0}
  fi
fi

if (( token_budget == 0 || window_cents == 0 )); then
  creds="${CLAUDE_HUD_CREDENTIALS:-$HOME/.claude/.credentials.json}"
  if [[ -f $creds ]]; then
    plan=$(jq -r '.claudeAiOauth.subscriptionType // ""' "$creds" 2>/dev/null)
    tier=$(jq -r '.claudeAiOauth.rateLimitTier // ""' "$creds" 2>/dev/null)
    # rateLimitTier is a decorated slug, not a bare one — a Max 5x account
    # reports "default_claude_max_5x" — so match the tier anywhere in the
    # string. 20x is checked first only for readability; the two can't collide.
    case "$plan:$tier" in
      pro:*)         plan_tokens=88000   ;;
      max:*max_20x*) plan_tokens=1760000 ;;
      max:*max_5x*)  plan_tokens=440000  ;;
      *max*)         plan_tokens=440000  ;;
      *)             plan_tokens=88000   ;;
    esac
    # Max 5x is the measured anchor ($120/window, see above); Pro and Max 20x
    # are that scaled by the nominal plan multipliers, which is a guess.
    case "$plan:$tier" in
      pro:*)         plan_cents=2400  ;;
      max:*max_20x*) plan_cents=48000 ;;
      max:*max_5x*)  plan_cents=12000 ;;
      *max*)         plan_cents=12000 ;;
      *)             plan_cents=2400  ;;
    esac
    mkdir -p "$CACHE_DIR"
    printf '%s %s\n' "$plan_tokens" "$plan_cents" > "$budget_cache"
    (( token_budget == 0 )) && token_budget=$plan_tokens
    (( window_cents == 0 )) && window_cents=$plan_cents
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

if (( resets_at > now && usage_5h > 0 )); then
  window_start=$(( resets_at - 18000 ))
  elapsed_secs=$(( now - window_start ))

  if (( elapsed_secs > 60 && token_budget > 0 )); then
    tokens_used=$(( token_budget * usage_5h / 100 ))
    tokens_per_min=$(( tokens_used * 60 / elapsed_secs ))

    if (( tokens_per_min >= 1000 )); then
      burn_label="🔥 ${YELLOW}$(( tokens_per_min / 1000 ))k/m${RESET}"
    elif (( tokens_per_min > 0 )); then
      burn_label="🔥 ${YELLOW}${tokens_per_min}/m${RESET}"
    fi

    if (( tokens_per_min > 0 && usage_5h < 100 )); then
      tokens_remaining=$(( token_budget - tokens_used ))
      mins_to_cap=$(( tokens_remaining / tokens_per_min ))
      if   (( mins_to_cap < 60 ));  then ttc_color=$RED
      elif (( mins_to_cap < 120 )); then ttc_color=$YELLOW
      else                               ttc_color=$DIM; fi

      if (( mins_to_cap < 60 )); then
        ttc_label=" ${ttc_color}~${mins_to_cap}m${RESET}"
      else
        ttc_label=" ${ttc_color}~$(( mins_to_cap / 60 ))h$(( mins_to_cap % 60 ))m${RESET}"
      fi
    fi
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
      # Output prices are 5x input, cache writes 2x (1h) and reads 0.1x, for
      # every current model — so one input price per model covers all four.
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
            { p = ($2 ~ /opus/) ? 500 : ($2 ~ /haiku/) ? 100 : 200
              c += ($3*p + $4*p*5 + $5*p*2 + $6*p/10) / 1000000 }
            END { printf "%d", c + 0 }')
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
claude_mds=$(find "$cwd" -name "CLAUDE.md" 2>/dev/null | wc -l | tr -d ' ')
mcps=$(jq -r '(.mcpServers // {}) | length' ~/.claude/settings.json 2>/dev/null || echo 0)
hooks=$(jq -r '[.hooks // {} | to_entries[].value[]] | length' ~/.claude/settings.json 2>/dev/null || echo 0)

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
      case "$(printf '%s' "$model" | tr 'A-Z' 'a-z')" in
        *opus*)  in_price=500 ;;
        *haiku*) in_price=100 ;;
        *)       in_price=200 ;;
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

# ── Bars ──────────────────────────────────────────────────────────────────────
make_bar() {
  local pct=$1 color=$2 width=${3:-10}
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  local filled=$(( pct * width / 100 )) empty=$(( width - pct * width / 100 ))
  local bar="${color}"
  for _ in $(seq 1 $filled 2>/dev/null); do bar="${bar}█"; done
  bar="${bar}${DIM}"
  for _ in $(seq 1 $empty 2>/dev/null); do bar="${bar}░"; done
  printf '%s%s' "$bar" "$RESET"
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
visible_width() {
  local stripped wide vs16
  stripped=$(sed -E 's/\x1b\[[0-9;]*m//g' <<< "$1")
  wide=$(grep -oE '🔥|📋|🔌|🪝|⏱' <<< "$stripped" | wc -l)
  vs16=$(grep -oE $'\xef\xb8\x8f' <<< "$stripped" | wc -l)
  echo $(( ${#stripped} + wide - vs16 ))
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

compact_label=""
(( compactions > 0 )) && compact_label=" ${DIM}↻ ${compactions}${RESET}"
segments+=("${DIM}ctx${RESET} ${ctx_bar} ${CTX_COLOR}${ctx}%${RESET}${compact_label}")
[[ -n $cache_label ]] && segments+=("$cache_label")
segments+=("${DIM}5h${RESET} ${usage_bar} ${USAGE_COLOR}${usage_5h}%${reset_label}${RESET}")
(( usage_7d >= 100 - WEEKLY_SHOW_AT_REMAINING )) && \
  segments+=("${DIM}7d${RESET} ${weekly_bar} ${WEEKLY_COLOR}${usage_7d}%${weekly_reset_label}${RESET}")
[[ -n $burn_label ]] && segments+=("${burn_label}${ttc_label}")

env=""
(( claude_mds > 0 )) && env+=" 📋${claude_mds}"
(( mcps > 0 ))       && env+=" 🔌${mcps}"
(( hooks > 0 ))      && env+=" 🪝${hooks}"
[[ -n $env ]] && segments+=("${env# }")

segments+=("${YELLOW}${cost}${RESET}")
segments+=("⏱️  ${DIM}${duration}${RESET}")

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

exit 0
