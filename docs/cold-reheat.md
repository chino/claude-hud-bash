# Cold reheat cost & window calibration

How the `cold 829.5k 2-3% 5h` part of the prompt-cache segment works, and why
the 5-hour window is modelled in cents rather than tokens.

Read this before changing the reheat or budget code in `statusline.sh`.

## Cold reheat cost

> **Read this before touching the reheat or budget code.**
>
> **What renders:** `cold 829.5k 2-3% 5h`
>
> | Part | Meaning | Source |
> |------|---------|--------|
> | `829.5k` | Tokens the next turn re-writes into the cache | `context_window.total_input_tokens` — measured, not estimated |
> | `2-3` | That cost as a % of the 5h window — a range spanning both estimates, low end first: the **self-calibrated** window (B, 2%) and the **plan table** (C, 3%) | live scan ÷ `used_percentage`; `~/.claude/.credentials.json` → cents table |
> | `5h` | Which window the % refers to | — |
>
> **The range is one numerator over two different denominators.** Both are shown on purpose, so the guessed constant can be eyeballed against the measurement. The range collapses to a single number when they round the same, or when only one denominator resolves, and either end shows as `<1` rather than `0` when it rounds below a percent — so the possible forms are `2-3%`, `3%`, `<1-2%` and `<1%`. If neither does, the segment degrades to `cold 829.5k to reheat` — it never invents a denominator.
>
> **The window is priced in cents, not tokens.** This is the single most important design fact here and the fix for a bug that once rendered `~377%`. Do not "simplify" it back to a token budget — the [evidence section](#why-the-window-is-measured-in-cents-not-tokens) shows token counts for a fixed window varying by 48×. Cents never appear on screen; they are the internal unit only.
>
> **The old bug, so it isn't reintroduced:** the previous formula was `tokens × write_multiplier ÷ token_budget`. `write_multiplier` is a *price* factor (dollars per token). Applying it to a token count and dividing by a token budget is a unit error — it inflated every reading by 2×, on top of a token budget that was itself ~10× too small.


A cold turn pays the cache-**write** premium on the whole context instead of the cache-**read** discount a warm turn would have gotten:

```
reheat_cents  = tokens × input_price_cents_per_mtok × write_multiplier / 1e6
reheat_pct    = reheat_cents / window_cents × 100
```

`write_multiplier` is `1.25` for a 5-minute TTL and `2` for a 1-hour TTL (Claude Code subscriptions default to 1h), from `prompt_cache.ttl`. `input_price_cents_per_mtok` comes from the model in the payload: 500 for Opus, 200 for Sonnet, 100 for Haiku.

If no budget can be resolved at all — no credentials file and no override — the segment degrades to `cold 829.5k to reheat` rather than inventing a denominator.

## Why the window is measured in cents, not tokens

Because no single token count describes a 5-hour window.

Every `rate_limit` rejection Claude Code records lands in the transcript as a `quotaLimits` entry with `rateLimitType: "five_hour"`. Each one marks a window that was consumed to exactly 100%, which makes it free calibration data. Summing the local transcripts over twelve such windows on one Max 5× account:

| Unit | min | median | max | spread |
|------|-----|--------|-----|--------|
| `input + output` | 32,347 | 184,171 | 616,227 | **19×** |
| `input + output + cache_write` | 579,596 | 5,998,260 | 27,917,697 | **48×** |
| API-equivalent value | $5.57 | $35.57 | $154.16 | 28× |

No token unit is stable — a subagent-heavy window that writes cache constantly and a long-context window that reads it constantly cannot be reconciled by counting tokens. Anthropic meters **value**, not tokens, which is also why a four-figure session cost can show up as only half a weekly limit.

The dollar column looks just as spread out, but it isn't: `used_percentage` is *server-side and account-wide*, covering every device and claude.ai, while a local transcript sum only sees one machine. So each row is a **lower bound**, and the windows where most of the work happened elsewhere are the small ones. Take the four largest — the least contaminated — and add an independent reading taken by sampling a live window against its reported `used_percentage`:

```
cap hit       $154.16
cap hit       $132.66
cap hit       $120.39
cap hit       $102.13
live sample   $138.46   measured against a known used_percentage
```

Five estimates, $102–154. The same windows in tokens disagree by 6×. Hence cents.

**You never see dollars in the statusline.** They are the internal unit of account only; the display stays a percentage of your 5-hour window.

### The plan table (C)

The budget is detected from `subscriptionType` and `rateLimitTier` in `~/.claude/.credentials.json`:

| Plan | `rateLimitTier` | 5h window value |
|------|-----------------|-----------------|
| Pro | `default_claude_pro` | ~$24 |
| Max 5× | `default_claude_max_5x` | ~$120 |
| Max 20× | `default_claude_max_20x` | ~$480 |

Only the Max 5× row is measured. Pro and Max 20× are that number scaled by the nominal plan multipliers, which is a guess — the community's own reverse-engineered figures suggest the real ratios are closer to 1:2:5 than 1:5:20. If you are on Pro or Max 20×, the self-calibration below will be more accurate than this row, and a calibrated reading from either would be a welcome issue.

The tier is matched as a substring, since Anthropic reports it as a decorated slug (`default_claude_max_5x`, not `max_5x`). A `max` plan with an unrecognized tier falls back to the 5× row; anything else falls back to Pro. Upgrades are picked up automatically on the next render — the budget is re-read from the credentials file, not baked in — though the credentials file itself only refreshes when Claude Code renews its token, so a fresh upgrade may need a session restart (or `claude auth logout && claude auth login`) to show up. The result is cached for 60s to keep `jq` off the render path.

Only `subscriptionType` and `rateLimitTier` are ever read from that file. The adjacent OAuth tokens are never touched.

Set `CLAUDE_HUD_WINDOW_CENTS` to override the table entirely — e.g. `CLAUDE_HUD_WINDOW_CENTS=15000` for a $150 window.

### Self-calibration (B)

The plan table is a guess. This measures the real thing:

```
measured_window_cents = value_spent_so_far_in_window × 100 / used_percentage
```

The numerator is computed by scanning `~/.claude/projects/*/*.jsonl` for every assistant response inside the current window (`resets_at - 5h` to now), deduplicating by `requestId` — resumed and forked sessions duplicate records — and pricing each one at API rates. The denominator is `rate_limits.five_hour.used_percentage` from the payload.

That percentage is the crucial part: it is computed server-side across your **entire account**, so it already includes other machines, other sessions, and claude.ai. There is no public API for subscription usage, and this is why none is needed — the number such an API would return is already in the statusline payload.

The known bias runs one way. The transcript sum only sees this machine, so if you use claude.ai or a second laptop, the numerator is short while the denominator is complete, and the calibration reads **low** — it will understate the window, never overstate it. Samples are smoothed across windows with an exponential moving average (α = ¼) to blunt this, and a reading is only taken above `used_percentage` 5, below which the payload's whole-number rounding dominates.

The scan takes roughly half a second, so it never runs on the render path. Each render reads the cached value and, at most once per interval, forks a background refresh.

| Variable | Default | Effect |
|----------|---------|--------|
| `CLAUDE_HUD_CALIB_INTERVAL` | `600` | Seconds between background calibration scans |
| `CLAUDE_HUD_CALIB_MIN_PCT` | `5` | Minimum `used_percentage` before a sample is taken; set above 100 to disable calibration entirely |

The cache lives in `${XDG_CACHE_HOME:-~/.cache}/claude-hud/`. Delete `calib-cents` to reset the calibration.
