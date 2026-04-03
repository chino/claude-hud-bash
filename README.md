# claude-hud-bash

A simple low-dependency bash implementation inspired by [claude-hud](https://github.com/jarrodwatts/claude-hud) for Claude Code.

<img width="663" height="23" alt="image" src="https://github.com/user-attachments/assets/f3187a1e-26dd-4c2d-ba90-be9e55f54e81" />

## What it shows

```
[Opus 4.6] │ my-project git:(main*) │ ctx ████░░░░░░ 23% │ 5h ██░░░░░░░░ 22% 7pm │ 🔥 12k/m ~1h20m │ 🔌2 🪝3 │ $0.04 │ ⏱️ 5m
✓ Fix the crash bug
▶ Write tests
○ Update docs
```

| Element | Example | Description |
|---------|---------|-------------|
| **Model** | `[Opus 4.6]` | The Claude model currently in use |
| **Project** | `my-project git:(main*)` | Current directory name and git branch. `*` means uncommitted changes |
| **Context** | `ctx ████░░░░░░ 23%` | Context window usage. Turns yellow at 70%, red at 85% |
| **5h usage** | `5h ██░░░░░░░░ 22% 7pm` | Rolling 5-hour rate limit consumption + estimated reset time. Turns magenta at 75%, red at 90% |
| **Burn rate** | `🔥 12k/m ~1h20m` | Tokens/min consumed in this window, plus estimated time until you hit the cap at the current rate |
| **Env** | `📋1 🔌2 🪝3` | Count of CLAUDE.md files (📋), MCP servers (🔌), and hooks (🪝). Only shown when non-zero |
| **Cost** | `$0.04` | Total API cost for the current session |
| **Duration** | `⏱️ 5m` | How long the current Claude Code session has been running |

**Todos:** If Claude has used TodoWrite during the session, the current task list is shown below the status line: `✓` completed, `▶` in progress, `○` pending.

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
       "command": "~/.claude/statusline.sh"
     }
   }
   ```

3. Reload your Claude Code session.

## Testing

```bash
bash test.sh
```

## Known limitation

Claude Code truncates statusLine output at terminal width and does not pass `COLUMNS` to the subprocess, so the script cannot know the terminal width or reflow on resize. Tracked in [anthropics/claude-code#22115](https://github.com/anthropics/claude-code/issues/22115) — upvote if this affects you.

## Customization

`statusline.sh` is straightforward bash — edit it directly, or ask Claude to update it for you in real time.
