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

compactions=0
[[ -n $transcript && -f $transcript ]] && compactions=$(grep -c '"subtype":"compact_boundary"' "$transcript" 2>/dev/null || echo 0)

# ── Plan token budget ─────────────────────────────────────────────────────────
# Cached for 60s — credentials rarely change and jq parsing adds latency.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-hud"
budget_cache="$CACHE_DIR/token-budget"
token_budget=0

if [[ -f $budget_cache ]]; then
  cache_age=$(( $(date +%s) - $(date -r "$budget_cache" +%s 2>/dev/null || echo 0) ))
  (( cache_age < 60 )) && token_budget=$(cat "$budget_cache")
fi

if (( token_budget == 0 )); then
  creds="$HOME/.claude/.credentials.json"
  if [[ -f $creds ]]; then
    plan=$(jq -r '.claudeAiOauth.subscriptionType // ""' "$creds" 2>/dev/null)
    tier=$(jq -r '.claudeAiOauth.rateLimitTier // ""' "$creds" 2>/dev/null)
    case "$plan:$tier" in
      pro:*)        token_budget=88000   ;;
      max:max_5x*)  token_budget=440000  ;;
      max:max_20x*) token_budget=1760000 ;;
      *max*)        token_budget=440000  ;;
      *)            token_budget=88000   ;;
    esac
    mkdir -p "$CACHE_DIR"
    echo "$token_budget" > "$budget_cache"
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
