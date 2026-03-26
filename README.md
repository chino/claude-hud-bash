# claude-hud-bash

A simple low dependency bash implementation inspired by [claude-hud](https://github.com/jarrodwatts/claude-hud) for Claude Code.

## What it shows

```
[Sonnet 4.6] │ my-project git:(main*) │ ctx ████░░░░░░ 23% │ 5h ██░░░░░░░░ 22% │ ⏱️ 5m │ 📋1 │ $0.04
✓ Fix the crash bug
▶ Write tests
○ Update docs
```

| Element       | Example                    | Description                                                                                          |
|---------------|----------------------------|------------------------------------------------------------------------------------------------------|
| **Model**     | `[Sonnet 4.6]`             | The Claude model currently in use                                                                    |
| **Project**   | `my-project git:(main*)`   | Current directory name and git branch. `*` means uncommitted changes                                |
| **Context**   | `ctx ████░░░░░░ 23%`       | How much of the context window is used. Turns yellow at 70%, red at 85%                             |
| **5h usage**  | `5h ██░░░░░░░░ 22%`        | Your rolling 5-hour API rate limit consumption. Turns magenta at 75%, red at 90%                    |
| **Duration**  | `⏱️ 5m`                   | How long the current Claude Code session has been running                                            |
| **Env**       | `📋1 🔌2 🪝3`              | Count of CLAUDE.md files (📋), MCP servers (🔌), and hooks (🪝) configured. Only shown when non-zero |
| **Cost**      | `$0.04`                    | Total API cost for the current session                                                               |

**Todos:** If Claude has used TodoWrite during the session, the current task list is shown below the status line with status indicators: `✓` completed, `▶` in progress, `○` pending.

## Requirements

- `jq`
- `git`

## Install

1. Download `statusline.sh` to `~/.claude/statusline.sh` and make it executable:
   ```bash
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

## Known limitation

Claude Code truncates statusLine output at terminal width and does not pass `COLUMNS` to the subprocess, so the script cannot know the terminal width or reflow on resize. Tracked in [anthropics/claude-code#22115](https://github.com/anthropics/claude-code/issues/22115) — upvote if this affects you.

## Customization

`statusline.sh` is ~70 lines of straightforward bash — edit it directly. Or just ask Claude to update it for you in real time: describe what you want to add, remove, or change and it will edit the script live.
