# claude-hud-bash

A simple low-dependency bash implementation inspired by [claude-hud](https://github.com/jarrodwatts/claude-hud) for Claude Code.

<img width="1049" height="24" alt="image" src="https://github.com/user-attachments/assets/d16c5fde-6cb0-49b9-b221-ebece3f358e5" />


## What it shows

```
[Opus 4.6] │ my-project git:(main*↑2↓1) │ ctx ████░░░░░░ 23% ↻ 1 │ 5h ██░░░░░░░░ 22% 7pm │ 🔥 12k/m ~1h20m │ 🔌2 🪝3 │ $0.04 │ ⏱️ 5m
```

| Element | Example | Description |
|---------|---------|-------------|
| **Model** | `[Opus 4.6]` | The Claude model currently in use |
| **Project** | `my-project git:(main*↑2↓1)` | Current directory name and git branch. `*` means uncommitted changes; `↑N`/`↓N` show commits ahead/behind the upstream (only when tracking a remote and diverged). On detached HEAD, falls back to an exact tag match, then a short commit SHA, instead of showing nothing |
| **Context** | `ctx ████░░░░░░ 23% ↻ 1` | Context window usage. Turns yellow at 70%, red at 85%. The dim `↻ N` (shown only when non-zero) counts compactions in the transcript, so a sudden drop in usage isn't confusing |
| **5h usage** | `5h ██░░░░░░░░ 22% 7pm` | Rolling 5-hour rate limit consumption + estimated reset time. Turns magenta at 75%, red at 90% |
| **Burn rate** | `🔥 12k/m ~1h20m` | Tokens/min consumed in this window, plus estimated time until you hit the cap at the current rate |
| **Env** | `📋1 🔌2 🪝3` | Count of CLAUDE.md files (📋), MCP servers (🔌), and hooks (🪝). Only shown when non-zero |
| **Cost** | `$0.04` | Total API cost for the current session |
| **Duration** | `⏱️ 5m` | How long the current Claude Code session has been running |

### Reset time

The reset clock time (`7pm`) next to the 5h bar comes from `resets_at` in the Claude Code statusline data — always accurate, no estimation.

### Burn rate & time-to-cap

> **Note:** These are rough estimates. The statusline data exposes `used_percentage` (token consumption) and `resets_at` (window close time) but not `window_started_at` or absolute token counts. Until Claude Code exposes that data, the burn rate and time-to-cap use approximations that will improve over time.
>
> Relevant upstream issues: [#9617](https://github.com/anthropics/claude-code/issues/9617) (`window_started_at`), [#11535](https://github.com/anthropics/claude-code/issues/11535) / [#36056](https://github.com/anthropics/claude-code/issues/36056) (absolute token counts).

Burn rate is computed as `tokens_used_in_window ÷ elapsed_window_minutes`, where token budget is read from `~/.claude/.credentials.json` based on your plan:

| Plan | Token budget (5h) |
|------|-------------------|
| Pro | ~88,000 |
| Max 5× | ~440,000 |
| Max 20× | ~1,760,000 |

The time-to-cap estimate (`~1h20m`) is `remaining_tokens ÷ burn_rate`. Color indicates urgency: dim when >2h, yellow 1–2h, red <1h. It disappears at 100% usage. The budget is cached for 60s to avoid parsing latency on every render.

## Requirements

- `jq`
- `git`

## Install

1. Download `statusline.sh` to `~/.claude/statusline.sh` and make it executable:
   ```bash
   curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/YOUR_USERNAME/claude-hud-bash/main/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

2. Add to `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "refreshInterval": 5
     }
   }
   ```

   `refreshInterval` (seconds, minimum `1`) re-runs the script on a timer, in addition to Claude Code's normal event-driven updates (new message, `/compact`, permission mode change, vim mode toggle). Without it, time-based fields like the reset clock, burn rate, time-to-cap, and ahead/behind counts only refresh when you interact — they'll sit stale during a long tool call or while a subagent runs. Omit it if you'd rather avoid the extra background runs.

3. Reload your Claude Code session.

## Testing

```bash
bash test.sh
```

## Width

The status line wraps across as many lines as needed to fit `COLUMNS` (passed in by Claude Code) — segments reflow instead of being dropped or truncated.

### When it redraws

Claude Code only re-runs the script on specific triggers: a new assistant message, `/compact` finishing, a permission-mode change, a vim-mode toggle, or the `refreshInterval` timer if you've set one. **Terminal resize is not one of them** — if you resize the window or a pane, the status line keeps rendering at the old width until the next trigger fires. This is a known upstream gap, not a bug in this script: [anthropics/claude-code#76988](https://github.com/anthropics/claude-code/issues/76988). Setting `refreshInterval` (see [Install](#install)) bounds how long a resize stays stale, at the cost of a script run every N seconds.

## Customization

`statusline.sh` is straightforward bash — edit it directly, or ask Claude to update it for you in real time.
