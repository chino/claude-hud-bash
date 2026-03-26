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
duration_ms=$(echo "$data" | jq -r '.cost.total_duration_ms // 0')
cwd=$(echo "$data" | jq -r '.cwd // ""')
project=$(basename "$cwd")
transcript=$(echo "$data" | jq -r '.transcript_path // ""')

# Duration formatting
if   [ "$duration_ms" -ge 3600000 ]; then duration="$(( duration_ms / 3600000 ))h$(( (duration_ms % 3600000) / 60000 ))m"
elif [ "$duration_ms" -ge 60000 ];   then duration="$(( duration_ms / 60000 ))m"
else duration="$(( duration_ms / 1000 ))s"; fi

# Git info
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
dirty_count=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# Environment counts
claude_mds=$(find "$cwd" -name "CLAUDE.md" 2>/dev/null | wc -l | tr -d ' ')
mcps=$(jq -r '(.mcpServers // {}) | length' ~/.claude/settings.json 2>/dev/null || echo 0)
hooks=$(jq -r '[.hooks // {} | to_entries[].value[]] | length' ~/.claude/settings.json 2>/dev/null || echo 0)

# Bar colors
if   [ "$ctx" -ge 85 ]; then CTX_COLOR=$RED
elif [ "$ctx" -ge 70 ]; then CTX_COLOR=$YELLOW
else CTX_COLOR=$GREEN; fi

if   [ "$usage_5h" -ge 90 ]; then USAGE_COLOR=$RED
elif [ "$usage_5h" -ge 75 ]; then USAGE_COLOR=$BRIGHT_MAGENTA
else USAGE_COLOR=$BRIGHT_BLUE; fi

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

SEP="${RESET} ${DIM}│${RESET} "

line="${CYAN}[${model}]${RESET}"

if [ -n "$branch" ]; then
  dirty_flag=""; [ "$dirty_count" -gt 0 ] && dirty_flag="*"
  line+="${SEP}${YELLOW}${project}${RESET} ${MAGENTA}git:(${CYAN}${branch}${dirty_flag}${MAGENTA})${RESET}"
else
  line+="${SEP}${YELLOW}${project}${RESET}"
fi

line+="${SEP}${DIM}ctx${RESET} ${ctx_bar} ${CTX_COLOR}${ctx}%${RESET}"
line+="${SEP}${DIM}5h${RESET} ${usage_bar} ${USAGE_COLOR}${usage_5h}%${RESET}"
line+="${SEP}⏱️  ${DIM}${duration}${RESET}"

env=""
[ "$claude_mds" -gt 0 ] && env+=" 📋${claude_mds}"
[ "$mcps" -gt 0 ]       && env+=" 🔌${mcps}"
[ "$hooks" -gt 0 ]      && env+=" 🪝${hooks}"
[ -n "$env" ] && line+="${SEP}${env# }"

line+="${SEP}${YELLOW}${cost}${RESET}"

echo "$line"

# Todos (if any)
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
