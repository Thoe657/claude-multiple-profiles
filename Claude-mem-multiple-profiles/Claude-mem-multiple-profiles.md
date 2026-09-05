# Running two claude-mem workers (one per account)

Status: both workers running and verified separate, 2026-09-05. Both profiles on
claude-mem 13.24.0. Both marketplaces are github sources. The 09-03 version-mismatch
issue is closed; see *Outage log* for what actually broke afterwards.

## How claude-mem finds its data dir

`scripts/bun-runner.js`:

```js
const dataDir = process.env.CLAUDE_MEM_DATA_DIR || join(homedir(), '.claude-mem');
```

Env var only — the `CLAUDE_MEM_DATA_DIR` key **inside** a data dir's own
`settings.json` is self-descriptive, not a bootstrap. So the link has to come from
the Claude profile's `settings.json` `env` block, which Claude Code exports to hooks.

The plugin itself resolves off `CLAUDE_CONFIG_DIR` (`$_C/plugins/cache/thedotmack/claude-mem/<ver>/`),
so the CLI half of profile separation already carries the plugin correctly.

`bun-runner.js` also reads `CLAUDE_CONFIG_DIR` in `isPluginDisabledInClaudeSettings()`
— it exits silently if that profile has `claude-mem@thedotmack: false`. Both env vars
therefore matter when running lifecycle commands by hand (see below).

## The pairing

| Profile (`CLAUDE_CONFIG_DIR`) | Memory store (`CLAUDE_MEM_DATA_DIR`) | Worker port | Server port | Redis prefix | Version |
|---|---|---|---|---|---|
| `~\.claude` (default) | `~\.claude-mem` | 37777 | 37954 | `claude_mem_37777` | 13.24.0 |
| `~\.claude-fullon` | `~\.claude-mem-fullon` | 37778 | 37955 | `claude_mem_37778` | 13.24.0 |

`~\.claude-mem-fullon` was created as a byte-for-byte copy of `~\.claude-mem`
(same `claude-mem.db`, same `installId` in `backfill.json`), so every one of these
values collided before the fix — two workers would have fought over port 37777 and,
worse, both written the same SQLite file.

## Marketplace sources

Both profiles now resolve claude-mem from the same upstream repo, independently:

| Profile | `source` | `autoUpdate` |
|---|---|---|
| `~\.claude` | `github: thedotmack/claude-mem` | `true` |
| `~\.claude-fullon` | `github: thedotmack/claude-mem` | absent (manual) |

Fullon was originally a `directory` source pointing at its own `installLocation` —
a self-referential copy taken from the default profile's checkout on 09-03. That
copy could never advance, and `/plugin update` correctly reported "latest" against
a checkout frozen at 13.21.2. Re-added as a github source on 09-05.

`autoUpdate: true` on the default profile is what silently moved it 13.15.3 → 13.24.0
and produced the broken install below. Fullon is deliberately left manual.

## Changes applied

`~\.claude-fullon\settings.json`

```json
"env": {
  "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
  "CLAUDE_MEM_DATA_DIR": "C:\\Users\\thedo\\.claude-mem-fullon"
}
```

`~\.claude-mem-fullon\settings.json`

- `CLAUDE_MEM_DATA_DIR` → `C:\Users\thedo\.claude-mem-fullon`
- `CLAUDE_MEM_TRANSCRIPTS_CONFIG_PATH` → `C:\Users\thedo\.claude-mem-fullon\transcript-watch.json`
- `CLAUDE_MEM_WORKER_PORT` → `37778`
- `CLAUDE_MEM_QUEUE_REDIS_PREFIX` → `claude_mem_37778`
- `CLAUDE_MEM_SERVER_URL` / `CLAUDE_MEM_SERVER_BETA_URL` → `http://127.0.0.1:37955`

`.bak` written beside each before the edit.

Chroma is left at `CLAUDE_MEM_CHROMA_MODE: local`, so its store lives inside each
data dir and port 8000 is unused. If either profile ever switches to `server` mode,
that port needs splitting too.

## Restarting the workers

Lifecycle commands are `start | stop | restart | status`, invoked exactly as the
SessionStart hook does:

```
node <plugin>\scripts\bun-runner.js <plugin>\scripts\worker-service.cjs <cmd>
```

**Trap:** a bare PowerShell prompt has neither `CLAUDE_CONFIG_DIR` nor
`CLAUDE_MEM_DATA_DIR` set — Claude Code only injects those into its own hooks. Run a
lifecycle command without them and it operates on the *default* store regardless of
which plugin copy's path you typed. Set both explicitly, or let a session do it.

Clean stop, default profile:

```powershell
$env:CLAUDE_CONFIG_DIR   = "$env:USERPROFILE\.claude"
$env:CLAUDE_MEM_DATA_DIR = "$env:USERPROFILE\.claude-mem"
$S = (Get-ChildItem "$env:CLAUDE_CONFIG_DIR\plugins\cache\thedotmack\claude-mem" -Directory |
      Where-Object { -not (Test-Path "$($_.FullName)\.orphaned_at") } |
      Sort-Object Name -Descending | Select-Object -First 1).FullName + "\scripts"
node "$S\bun-runner.js" "$S\worker-service.cjs" stop
Remove-Item Env:\CLAUDE_CONFIG_DIR, Env:\CLAUDE_MEM_DATA_DIR
```

Same again with `.claude-fullon` / `.claude-mem-fullon` for the other store. Clear the
env afterwards so it does not leak into the next thing you run.

Then **start each by opening a Claude Code session on that profile** (`cc-personal`,
`cc-fullon`) rather than by hand — the SessionStart hook runs `worker-service.cjs start`
with the profile's env already applied, which is the whole point of the wiring above.

## Verifying

A port listing is **not** sufficient. Both a healthy pair and a crossed pair show two
listeners; and a worker can be alive on the right port while the hook path is broken
(see *MCP lazy-spawn* below).

```powershell
Get-NetTCPConnection -LocalPort 37777,37778 -State Listen
(Get-Content "$env:USERPROFILE\.claude-mem\supervisor.json" | ConvertFrom-Json).processes.worker.pid
(Get-Content "$env:USERPROFILE\.claude-mem-fullon\supervisor.json" | ConvertFrom-Json).processes.worker.pid
```

Two listeners **and** two distinct pids. Same pid in both means the fullon session is
still writing to the default store — `CLAUDE_MEM_DATA_DIR` is not reaching the hook.
Check `logs/` in each store is advancing independently.

`supervisor.json` is written optimistically and is frequently stale — on 09-03 it
named pid 7240, dead 0.5s after the entry was written; on 09-05 it named pid 21264
with nothing listening for ten hours. Always confirm the pid resolves to a live
bun/node process running `worker-service`.

Last verified 2026-09-05: 37777 → pid 496, 37778 → pid 25488.

## Outage log

### 09-02 → 09-03: version mismatch (resolved)

`~\.claude\plugins\cache\thedotmack\claude-mem` held only 13.15.3 while the marketplace
checkout was at 13.21.2. Hooks resolve cache-first, spawned 13.15.3, version check
compared it against the marketplace and killed it within ~2s. Five start/kill cycles
on 09-02 alone (pids 5596, 11960, 23076, 9388, 7240). The respawn targeted the
marketplace path and never opened the port.

```
Worker version mismatch — killing stale worker {pluginVersion=13.21.2, workerVersion=13.15.3}
Worker exited before readiness endpoint became available
```

Fixed by updating claude-mem in the default profile so both resolutions agree.

### 09-05: missing dependency in the 13.24.0 cache (resolved)

**Different cause, identical symptom** — this is the important entry. After the update
above, `autoUpdate` carried the default profile to 13.24.0 and 37777 still would not
come up. Cache and marketplace *both* read 13.24.0, so the mismatch diagnosis no longer
applied, but the launcher logged the same line:

```
Starting worker daemon {workerScriptPath=...\13.24.0\scripts\worker-service.cjs}
Worker exited before readiness endpoint became available
```

Sixty seconds apart, with no worker-side log lines in between — the worker dies at
module load, before it can write anything, and the detached spawn discards its stderr.
Running it in the foreground is the only way to see the reason:

```powershell
node "$S\bun-runner.js" "$S\worker-service.cjs" start
```

```
error: Cannot find module 'zod/v3' from ...\13.24.0\scripts\worker-service.cjs
Bun v1.4.0 (Windows x64)
```

That cache directory had a `node_modules` but no `zod` inside it — an incomplete
extraction, not a change in 13.24.0. Every other cache on the machine (13.21.2,
13.23.1, and fullon's later 13.24.0) has zod present, so this was a one-off.

**Check first when a worker dies before readiness with an empty log:**

```powershell
$P = "$env:USERPROFILE\.claude\plugins\cache\thedotmack\claude-mem"
Get-ChildItem $P -Directory | ForEach-Object {
  [pscustomobject]@{ Ver=$_.Name; Orphaned=Test-Path "$($_.FullName)\.orphaned_at"; Zod=Test-Path "$($_.FullName)\node_modules\zod" }
}
```

Fix is `bun install` in the version directory itself (the one holding `package.json`
and `bun.lock`, not `scripts\`).

## Traps worth remembering

**`/plugin marketplace remove` can prune `enabledPlugins`.** After re-adding fullon's
marketplace as a github source, `claude-mem@thedotmack` was gone from
`~\.claude-fullon\settings.json` — so `/plugin update` had nothing to resolve and just
opened the marketplace browser. Same thing had happened on the default profile without
being noticed. Re-install rather than hand-editing, so the entry is written in whatever
shape the current version expects.

**MCP lazy-spawn keeps a worker alive while the plugin is uninstalled.** 37777 was
listening on a profile whose `enabledPlugins` had no claude-mem entry at all. The MCP
server spawns the worker on demand and does not consult that setting; the SessionStart
hook does. So the port was up, the hook path was dead, and it would have vanished at
next reboot. **A listening port is not proof the hook path works.**

**Silent fallback in `resolveDataDir()`:**

```js
if (process.env.CLAUDE_MEM_DATA_DIR) return expandHome(...);
// else read ~/.claude-mem/settings.json for CLAUDE_MEM_DATA_DIR
// else ~/.claude-mem
```

If the env var fails to reach a hook, it reads the **default** store's `settings.json`
— which names `C:\Users\thedo\.claude-mem` — and lands there with no error or warning.
This is why the pid comparison is the check that matters.

**`status` reports a version that lags `package.json`.** A worker running from the
`13.24.0` cache reports `Version: 13.23.1`, freshly restarted. That string is a
build-time constant minified into `worker-service.cjs` (four literals); 13.24.0 was
released without bumping it. Not a stale daemon, and it cannot trigger the mismatch
kill above -- that compares the running worker's reported version against the constant
in the bundle about to spawn it, so both sides read the same string and always agree.
The 09-02 outage was two *different* bundles, which is the real divergence. Cosmetic;
patching it means editing a vendored build artifact that `autoUpdate` overwrites.

## Rejected: one worker serving both accounts

**Rejected, 2026-09-03.** Both bindings are module-level constants in
`worker-service.cjs`, evaluated once at daemon start, with no per-request override:

```js
lt = ra()                                                        // DATA_DIR
pE = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude")  // config dir
```

Every path — `claude-mem.db`, `chroma/`, `logs/`, `settings.json`, `supervisor.json` —
derives from `lt`. One worker is structurally one store.

Two separate crossovers would result:

1. **Memories merge.** One SQLite DB, one chroma collection; both accounts'
   observations land together and are injected into both accounts' sessions.
2. **Quota crosses.** The vendored SDK reads credentials as
   `n?.CLAUDE_CONFIG_DIR ?? process.env.CLAUDE_CONFIG_DIR`, then
   `readFile(join(p, ".credentials.json"))`. `n` is per-call options; there are only
   three `CLAUDE_CONFIG_DIR:` occurrences in the entire 3MB bundle and all three are
   SDK internals — claude-mem never passes one. So it falls through to the daemon's
   frozen `process.env`, and every observation/summary is billed to whichever account
   started the worker.

Mechanically possible (point both profiles at one port and one data dir); it just
undoes the separation on both axes.

## Known cosmetic leftovers

In `~\.claude-mem-fullon`, inherited from the copy: `.worker-start-attempted` is stale
and `.cleanup-v12.4.3-applied` records a backup path under `~\.claude-mem`. Historical
records, rewritten or ignored on next start. `backfill.json` shares an `installId` with
the default store; local-only, no effect observed.

Orphaned caches retained as fallbacks: 13.21.2 and 13.23.1 on the default profile,
13.21.2 on fullon. Safe to delete once 13.24.0 has proven itself. Note that falling
back requires pinning the marketplace to the same version, or the mismatch kill loop
returns.
