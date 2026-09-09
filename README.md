# claude-hud-bash

A simple low-dependency bash implementation inspired by [claude-hud](https://github.com/jarrodwatts/claude-hud) for Claude Code.


## What it shows
| Element | Example | Description |
|---------|---------|-------------|
| **Model** | `[Opus 4.6]` | The Claude model currently in use |
| **Project** | `my-project git:(main*↑2↓1)` | Current directory name and git branch. `*` means uncommitted changes; `↑N`/`↓N` show commits ahead/behind the upstream (only when tracking a remote and diverged). On detached HEAD, falls back to an exact tag match, then a short commit SHA, instead of showing nothing |
| **Context** | `ctx ████░░░░░░ 23%` | Context window usage. Turns yellow at 70%, red at 85% |
| **Prompt cache** | `warm ~54m hit 87%` / `cold 829.5k 2-3% 5h` | Whether the main conversation's prompt cache is warm or cold, from `prompt_cache.warm`. Green while warm, shifting to yellow inside the last 20% of the TTL, red once cold. **Warm**: a countdown to `expires_at`, plus `hit N%` — the cache hit ratio. **Cold**: the tokens the next turn re-writes into the cache, then what that costs as a share of your 5-hour window under two independent estimates (see [Cold reheat cost](#cold-reheat-cost) and [docs/cold-reheat.md](docs/cold-reheat.md)); the hit ratio is dropped here since it's a backward-looking stat, not something that changes what the next turn costs. Hidden until the first API response of the session, since `prompt_cache` isn't in the payload before then |
| **5h usage** | `5h ██░░░░░░░░ 22% 7pm` | Rolling 5-hour rate limit consumption + estimated reset time. Turns magenta at 75%, red at 90% |
| **7d usage** | `7d ████░░░░░░ 41% sat` | Rolling 7-day rate limit consumption + reset. Hidden until it is worth the space — see [Weekly window](#weekly-window). Cyan by default, yellow at 75%, red at 90% |
| **Burn rate** | `🔥 12k/m ~1h20m` | Tokens/min consumed in this window, plus estimated time until you hit the cap at the current rate |
| **Env** | `🔌2 🪝3` | Count of MCP servers (🔌) and hooks (🪝). Only shown when non-zero |
| **Cost** | `$0.04` | Total API cost for the current session |
| **Duration** | `⏱️ 5m` | How long the current Claude Code session has been running |
| **Host stats** | `ram 24% cpu 6% t 7pm` | Free RAM (percentage used) and 1-minute CPU load (percentage of this host's own core count), plus the current wall-clock time. Linux-only (needs `free`) — the whole segment is omitted on hosts without it, e.g. macOS |
| **Cost** | `$0.04` | Total API cost for the current session. Off by default; set `CLAUDE_HUD_SHOW_COST=1` |
| **Duration** | `⏱️ 5m` | How long the current session has been running. Off by default; set `CLAUDE_HUD_SHOW_DURATION=1` |
| **Host stats** | `ram 24% cpu 6% t 7pm` | Free RAM (percentage used) and 1-minute CPU load (percentage of this host's own core count via `nproc`), plus the current wall-clock time. Linux-only (needs `free`) — the whole segment is omitted on hosts without it, e.g. macOS |

### Reset time

The reset clock time (`7pm`) next to the 5h bar comes from `resets_at` in the Claude Code statusline data — always accurate, no estimation.

### Weekly window

The `7d` segment sits immediately right of the 5h one and reads
`rate_limits.seven_day` from the statusline data. It is **hidden until remaining
drops to 80%** — i.e. from 20% used onward — so it costs nothing on the status
line early in the week and appears once it is worth watching.

Its reset label is the weekday (`sat`) while the reset is more than 24h out, and
switches to a clock time (`9:15pm`) on the day itself.

Two knobs, both overridable from the environment:

| Variable | Default | Effect |
|----------|---------|--------|
| `WEEKLY_SHOW_AT_REMAINING` | `80` | Show the segment once remaining is at or below this percent. `100` always shows it, `0` holds it back until the window is fully consumed |
| `WEEKLY_BAR_WIDTH` | `10` | Bar width in cells, matching the other bars |

The colour ramp is deliberately a different hue from the 5h bar's blue/magenta
so the two are never confused at a glance.

### Burn rate & time-to-cap

> **Note:** These are rough estimates. The statusline data exposes `used_percentage` (token consumption) and `resets_at` (window close time) but not `window_started_at` or absolute token counts. Until Claude Code exposes that data, the burn rate and time-to-cap use approximations that will improve over time.

Burn rate is computed as `tokens_used_in_window ÷ elapsed_window_minutes`, where token budget is detected from your plan, using `subscriptionType` and `rateLimitTier` in `~/.claude/.credentials.json`:

| Plan | `rateLimitTier` | Token budget (5h) |
|------|-----------------|-------------------|
| Pro | `default_claude_pro` | ~88,000 |
| Max 5× | `default_claude_max_5x` | ~440,000 |
| Max 20× | `default_claude_max_20x` | ~1,760,000 |

The tier is matched as a substring, since Anthropic reports it as a decorated slug (`default_claude_max_5x`, not `max_5x`). A `max` plan with an unrecognized tier falls back to the 5× budget; anything else falls back to the Pro budget. Upgrades are picked up automatically on the next render — the budget is re-read from the credentials file, not baked in — though the credentials file itself only refreshes when Claude Code renews its token, so a fresh upgrade may need a session restart (or `claude auth logout && claude auth login`) to show up.

Set `CLAUDE_HUD_TOKEN_BUDGET` to override the table entirely if your plan isn't covered or you'd rather calibrate the number yourself.

> **Known limitation:** these token figures are the *old* plan constants, and the calibration described in [docs/cold-reheat.md](docs/cold-reheat.md) shows that no single token count describes a 5-hour window — so burn rate and time-to-cap inherit that error. The cold reheat cost no longer uses them. Converting these two to the same cents-based budget (or to a constant-free `%/h`, since `used_percentage` and `resets_at` are enough on their own) is the next thing to fix.

The time-to-cap estimate (`~1h20m`) is `remaining_tokens ÷ burn_rate`. Color indicates urgency: dim when >2h, yellow 1–2h, red <1h. It disappears at 100% usage. The budget is cached for 60s to avoid parsing latency on every render.

### Cold reheat cost

While the cache is cold the segment shows what the next turn costs to re-cache:
the token count from the payload, then that priced as a share of the 5-hour
window under two independent estimates, rendered as a range with the low end
first.

```
cold 829.5k 2-3% 5h     both estimates
cold 829.5k 3% 5h       they round the same, or only one resolved
cold 100k <1-2% 5h      low end rounds below a percent
cold 60k <1% 5h         both round below a percent
cold 1.2M to reheat     no budget available — never invents one
```

The window is measured in API-equivalent cents, not tokens, and the second
estimate is self-calibrated from your own usage. Cents never reach the display.
See **[docs/cold-reheat.md](docs/cold-reheat.md)** for the formula, the
measurements behind it, and the `CLAUDE_HUD_*` overrides.

### No 7-day equivalent

The weekly window only exposes `used_percentage`, and weekly limits are subject
to promotions that shift the denominator without notice. The reported
percentage already accounts for them, so it is shown as-is and nothing is
divided by a guessed weekly cap.


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
       "refreshInterval": 15
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

Claude Code only re-runs the script on specific triggers: a new assistant message, `/compact` finishing, a permission-mode change, a vim-mode toggle, a warm prompt cache reaching its `expires_at` (so the cache segment above flips to cold right on schedule, even mid-tool-call), the 5-hour rate-limit window hitting its own `resets_at`, or the `refreshInterval` timer if you've set one. **Terminal resize is not one of them** — if you resize the window or a pane, the status line keeps rendering at the old width until the next trigger fires. This is a known upstream gap, not a bug in this script: [anthropics/claude-code#76988](https://github.com/anthropics/claude-code/issues/76988). Setting `refreshInterval` (see [Install](#install)) bounds how long a resize stays stale, at the cost of a script run every N seconds.

## Caching

Regenerable state lives in `~/.cache/claude-hud/` (or `$XDG_CACHE_HOME/claude-hud/`)
and is safe to delete at any point:

| File | Holds |
| --- | --- |
| `token-budget` | Plan detection, re-read at most once a minute |
| `calib-cents` / `calib-stamp` | Self-calibrated window size, refreshed at most once per `CLAUDE_HUD_CALIB_INTERVAL` |
| `status/<session-id>.json` | The same values in machine-readable form — see below |
| `status/<session-id>.txt` | A plain-text copy of the current status line (colors stripped) — lets anything without a terminal (`cat`) read your current usage. Pruned after 7 days. Set `CLAUDE_HUD_SNAPSHOT_DIR=none` to disable |

### Reading the status line from outside the terminal

Every render also writes the line to a plain-text file, so anything that can't
see your terminal can read your current usage with `cat` — a monitor loop, an
agent checking its own budget before starting expensive work, a second pane:

```bash
cat ~/.cache/claude-hud/status/<session-id>.txt
```

A `<session-id>.json` sidecar carries the same values structurally, so scripts
never have to scrape the rendered line:

```bash
jq -r .resets_5h ~/.cache/claude-hud/status/<session-id>.json   # epoch, not "1:30am"
```

```json
{"session_id":"...","rendered_at":1788920840,"model":"Opus 5","cwd":"/home/dan/projects",
 "project":"projects","ctx_pct":69,"context_input_tokens":900000,"used_5h_pct":41,
 "resets_5h":1788928040,"used_7d_pct":87,"resets_7d":1789220840,"cache_observed":true,
 "cache_warm":true,"cache_expires_at":1788928040,"cache_hit_pct":99,"cost_usd":2.53,
 "duration_ms":300000}
```

Times are raw epochs, so no consumer has to parse a local clock string or guess
whether `1:30am` means today or tomorrow. It is written to a `.tmp` and renamed,
so a reader never catches a partial object.

Each session writes its own file, named for its session id. There is
deliberately no "latest" alias: with several sessions running it would just
race between them and a reader could not tell whose numbers it got. The file's
mtime is its freshness: nothing rewrites it once a session ends, so
check it before trusting a number.

## Customization

`statusline.sh` is straightforward bash — edit it directly, or ask Claude to update it for you in real time.
