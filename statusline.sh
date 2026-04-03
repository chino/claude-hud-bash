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

model=$(echo "$data" | jq -r '.model.display_name // "?"')
ctx=$(echo "$data" | jq -r '.context_window.used_percentage // 0 | floor')
cost=$(echo "$data" | jq -r '.cost.total_cost_usd // 0 | "$\(. * 100 | round | . / 100)"')
usage_5h=$(echo "$data" | jq -r '.rate_limits.five_hour.used_percentage // 0 | floor')
resets_at=$(echo "$data" | jq -r '.rate_limits.five_hour.resets_at // 0')
duration_ms=$(echo "$data" | jq -r '.cost.total_duration_ms // 0')
total_tokens=$(echo "$data" | jq -r '(.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0)')
cwd=$(echo "$data" | jq -r '.cwd // ""')
project=$(basename "$cwd")
transcript=$(echo "$data" | jq -r '.transcript_path // ""')

# ── Plan token budget ─────────────────────────────────────────────────────────
# Cached for 60s — credentials rarely change and jq parsing adds latency.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-hud"
budget_cache="$CACHE_DIR/token-budget"
token_budget=0

if [ -f "$budget_cache" ]; then
  cache_age=$(( $(date +%s) - $(date -r "$budget_cache" +%s 2>/dev/null || echo 0) ))
  [ "$cache_age" -lt 60 ] && token_budget=$(cat "$budget_cache")
fi

if [ "$token_budget" -eq 0 ]; then
  creds="$HOME/.claude/.credentials.json"
  if [ -f "$creds" ]; then
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
if   [ "$duration_ms" -ge 3600000 ]; then duration="$(( duration_ms / 3600000 ))h$(( (duration_ms % 3600000) / 60000 ))m"
elif [ "$duration_ms" -ge 60000 ];   then duration="$(( duration_ms / 60000 ))m"
else duration="$(( duration_ms / 1000 ))s"; fi

# ── Burn rate & time-to-cap ───────────────────────────────────────────────────
# Use 5h window elapsed time as denominator (wall-clock, not API latency)
# Window started at: resets_at - 18000
burn_label=""
ttc_label=""
now=$(date +%s)

if [ "$resets_at" -gt "$now" ] 2>/dev/null && [ "$usage_5h" -gt 0 ]; then
  window_start=$(( resets_at - 18000 ))
  elapsed_secs=$(( now - window_start ))

  if [ "$elapsed_secs" -gt 60 ] && [ "$token_budget" -gt 0 ]; then
    tokens_used=$(( token_budget * usage_5h / 100 ))
    tokens_per_min=$(( tokens_used * 60 / elapsed_secs ))

    if [ "$tokens_per_min" -ge 1000 ]; then
      burn_label="🔥 ${YELLOW}$(( tokens_per_min / 1000 ))k/m${RESET}"
    elif [ "$tokens_per_min" -gt 0 ]; then
      burn_label="🔥 ${YELLOW}${tokens_per_min}/m${RESET}"
    fi

    # Time to cap: remaining tokens / burn rate (in minutes)
    if [ "$tokens_per_min" -gt 0 ] && [ "$usage_5h" -lt 100 ]; then
      tokens_remaining=$(( token_budget - tokens_used ))
      mins_to_cap=$(( tokens_remaining / tokens_per_min ))
      if   [ "$mins_to_cap" -lt 60 ];  then ttc_color=$RED
      elif [ "$mins_to_cap" -lt 120 ]; then ttc_color=$YELLOW
      else                                  ttc_color=$DIM; fi

      if [ "$mins_to_cap" -lt 60 ]; then
        ttc_label=" ${ttc_color}~${mins_to_cap}m${RESET}"
      else
        ttc_label=" ${ttc_color}~$(( mins_to_cap / 60 ))h$(( mins_to_cap % 60 ))m${RESET}"
      fi
    fi
  fi
fi

# ── Git info ──────────────────────────────────────────────────────────────────
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
dirty_count=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# ── Environment counts ────────────────────────────────────────────────────────
claude_mds=$(find "$cwd" -name "CLAUDE.md" 2>/dev/null | wc -l | tr -d ' ')
mcps=$(jq -r '(.mcpServers // {}) | length' ~/.claude/settings.json 2>/dev/null || echo 0)
hooks=$(jq -r '[.hooks // {} | to_entries[].value[]] | length' ~/.claude/settings.json 2>/dev/null || echo 0)

# ── Bar colors ────────────────────────────────────────────────────────────────
if   [ "$ctx" -ge 85 ]; then CTX_COLOR=$RED
elif [ "$ctx" -ge 70 ]; then CTX_COLOR=$YELLOW
else CTX_COLOR=$GREEN; fi

if   [ "$usage_5h" -ge 90 ]; then USAGE_COLOR=$RED
elif [ "$usage_5h" -ge 75 ]; then USAGE_COLOR=$BRIGHT_MAGENTA
else USAGE_COLOR=$BRIGHT_BLUE; fi

# ── Reset time ────────────────────────────────────────────────────────────────
reset_label=""

if [ "$resets_at" -gt "$now" ] 2>/dev/null; then
  reset_time=$(date -d "@$resets_at" "+%-I:%M%p" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/:00//')
  reset_label=" ${reset_time}"
fi

# ── Bars ──────────────────────────────────────────────────────────────────────
make_bar() {
  local pct=$1 color=$2
  local filled=$(( pct / 10 )) empty=$(( 10 - pct / 10 ))
  local bar="${color}"
  for _ in $(seq 1 $filled 2>/dev/null); do bar="${bar}█"; done
  bar="${bar}${DIM}"
  for _ in $(seq 1 $empty 2>/dev/null); do bar="${bar}░"; done
  printf '%s%s' "$bar" "$RESET"
}

ctx_bar=$(make_bar "$ctx" "$CTX_COLOR")
usage_bar=$(make_bar "$usage_5h" "$USAGE_COLOR")

# ── Assemble line ─────────────────────────────────────────────────────────────
SEP="${RESET} ${DIM}│${RESET} "

line="${CYAN}[${model}]${RESET}"

if [ -n "$branch" ]; then
  dirty_flag=""; [ "$dirty_count" -gt 0 ] && dirty_flag="*"
  line+="${SEP}${YELLOW}${project}${RESET} ${MAGENTA}git:(${CYAN}${branch}${dirty_flag}${MAGENTA})${RESET}"
else
  line+="${SEP}${YELLOW}${project}${RESET}"
fi

line+="${SEP}${DIM}ctx${RESET} ${ctx_bar} ${CTX_COLOR}${ctx}%${RESET}"
line+="${SEP}${DIM}5h${RESET} ${usage_bar} ${USAGE_COLOR}${usage_5h}%${reset_label}${RESET}"
[ -n "$burn_label" ] && line+="${SEP}${burn_label}${ttc_label}"

env=""
[ "$claude_mds" -gt 0 ] && env+=" 📋${claude_mds}"
[ "$mcps" -gt 0 ]       && env+=" 🔌${mcps}"
[ "$hooks" -gt 0 ]      && env+=" 🪝${hooks}"
[ -n "$env" ] && line+="${SEP}${env# }"

line+="${SEP}${YELLOW}${cost}${RESET}"
line+="${SEP}⏱️  ${DIM}${duration}${RESET}"

echo "$line"

# ── Todos ─────────────────────────────────────────────────────────────────────
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  todos=$(grep '"TodoWrite"' "$transcript" 2>/dev/null | tail -1 | jq -r '
    .message.content[]? | select(.name=="TodoWrite") | .input.todos[]? |
    if .status == "completed" then "✓ \(.content)"
    elif .status == "in_progress" then "▶ \(.content)"
    else "○ \(.content)"
    end' 2>/dev/null)
  [ -n "$todos" ] && echo "$todos"
fi

exit 0
