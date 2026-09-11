# claude-multiple-profiles

Run two (or more) Claude accounts side by side on one Windows machine - a personal
account and a work one - without signing in and out, and without doing work under
the wrong identity by accident.

PowerShell, no dependencies, no admin rights.

---

## Why this exists

Claude has no built-in account switcher. Usage limits are per-account and never
pool between them, so the risk isn't billing crossover - it's *context* crossover:
burning work quota on personal tasks, or worse, doing work in a personal account
whose conversations live outside your employer's organisation.

Two surfaces need separating, and they behave differently:

| Surface | Mechanism | Support |
|---|---|---|
| Claude Code CLI | `CLAUDE_CONFIG_DIR` relocates the whole `~/.claude` tree - settings, `CLAUDE.md`, skills, agents, plugins, sessions **and auth** | Documented and supported |
| Desktop app | No equivalent env var. The live data directory is replaced with a junction pointing at one of several profile directories | Unsupported; works, with caveats |

---

## Requirements

- Windows, PowerShell 5.1 or later
- Claude Code CLI on `PATH` (for the CLI half)
- Two Claude accounts on **different email addresses** - one address can't hold
  both a personal subscription and a Team/Enterprise seat

---

## Install

Save `claude-profiles.ps1` somewhere stable and load it from your PowerShell profile:

```powershell
Copy-Item .\claude-profiles.ps1 "$env:USERPROFILE\.claude-profiles.ps1"

if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
Add-Content $PROFILE '. "$env:USERPROFILE\.claude-profiles.ps1"'
```

If your profile directories are named something other than `.claude` and
`.claude-work`, point the script at them from `$PROFILE` *above* the dot-source
line, so a reinstall can't undo it:

```powershell
$env:CLAUDE_PROFILE_DIR_WORK = "$env:USERPROFILE\.claude-acme"
```

`CLAUDE_DESKTOP_DIR_<PROFILE>` does the same for that profile's desktop data
directory, which otherwise defaults to `%LOCALAPPDATA%\Claude-profiles\<name>`:

```powershell
$env:CLAUDE_DESKTOP_DIR_WORK = "$env:LOCALAPPDATA\Claude-profilescme"
```

Open a new terminal and check it loaded:

```powershell
Get-ClaudeProfileStatus
```

If PowerShell refuses to run it:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

---

## Configure your profiles

Open `%USERPROFILE%\.claude-profiles.ps1` and edit the map near the top. This is
the only part you need to change:

```powershell
$script:ClaudeCliProfiles = [ordered]@{
    'personal' = Join-Path $env:USERPROFILE '.claude'
    'work'     = Join-Path $env:USERPROFILE '.claude-work'
}
```

Rules of thumb:

- **Keep one profile pointed at `%USERPROFILE%\.claude`.** That's what plain
  `claude` uses when no profile is active, and it's where your existing config
  already lives.
- Name profiles whatever you like - `personal`, `work`, `client-a`. A `cc-<name>`
  shortcut is generated automatically for each one.
- Add as many as you want; nothing is limited to two.

If your existing config lives somewhere unusual, point the entry straight at it:

```powershell
'personal' = 'D:\configs\.claude'
```

---

## First-time setup

Close the Claude desktop app completely - system tray included - then:

```powershell
Initialize-ClaudeProfiles
```

This creates each profile directory, and moves the desktop app's existing data
into a profile slot so the live path can become a junction. By default the
existing data is adopted as `personal`; use `-AdoptDesktopDataAs work` if it
belongs to the other account.

Then check what it found:

```powershell
Get-ClaudeProfileStatus
```

You should see each profile, the email signed in on it, and how your desktop app
is installed. **That status output is your ground truth** - it reads each
profile's `.claude.json` directly, so it can't be wrong about who is where.

### Signing in the second profile

A new profile starts empty. Run the CLI on it once and log in:

```powershell
cc-work        # then /login inside the session
```

For the desktop app, switch to the profile and sign in when it opens:

```powershell
Switch-ClaudeDesktop work -Launch
```

---

## Daily use

**The launcher** (no command line)

Double-click `Claude-Launcher.cmd`. Pick a profile and it closes every Claude
instance, repoints the desktop data junction, sets `CLAUDE_CONFIG_DIR` at user
scope, stops the other profile's claude-mem worker, starts this one's and
relaunches the app. The rest of the menu is troubleshooting: full status, start
or restart the active profile's worker, force-close Claude, update that
profile's plugins.

It is dot-sourced rather than run as a child script, because PowerShell resolves
`$script:` against the *calling* script's scope -- a nested `.ps1` would see an
empty profile map. Keep the `.` in the `.cmd` if you edit it.

To pin it to the taskbar, make a shortcut whose target is `powershell.exe` with
the same arguments as the `.cmd` -- Windows won't pin a shortcut to a `.cmd`.
`claude-launcher.ico` is its icon: Clawd Thinking by
[Icons8](https://icons8.com).

**Claude Code CLI**

```powershell
cc-personal              # one session as personal
cc-work                  # one session as work
cc-work --continue       # arguments pass straight through
```

Those set `CLAUDE_CONFIG_DIR` for that invocation only and restore it afterwards.

To pin an entire terminal instead, so plain `claude` uses one profile:

```powershell
Use-ClaudeProfile work
Clear-ClaudeProfile      # back to the default ~/.claude
```

The pin lasts for that window only.

**Desktop app**

```powershell
Switch-ClaudeDesktop personal -Launch
Switch-ClaudeDesktop work -Launch
```

**Close the app fully before switching.** The script refuses while it's running,
because swapping the data directory underneath a live process corrupts whichever
profile it's holding open. `-Force` closes it for you.

Switching also sets `CLAUDE_CONFIG_DIR` at **user** scope, and that is the part
that keeps the accounts apart. The junction only moves the desktop app's own
data. Claude Code running *inside* the app is a separate thing that reads
`CLAUDE_CONFIG_DIR` exactly like the CLI does and inherits it from the app's
process -- so without it, a Code tab writes its sessions, projects and refreshed
OAuth tokens into `~/.claude` no matter which account the app is signed into.
Terminals already open keep their old value; reopen them.

**Check state at any time**

```powershell
Get-ClaudeProfileStatus
```

If you run [claude-mem](https://github.com/thedotmack/claude-mem), that status --
and `Switch-ClaudeDesktop ... -Launch` -- ends with one worker line per profile:

```
claude-mem workers
  personal   ok    port 37777  pid 496
             store: C:\Users\thedo\.claude-mem
  work       ok    port 37778  pid 25488
             store: C:\Users\thedo\.claude-mem-work
```

Two distinct stores and two distinct live pids is the only proof that memories
and quota aren't crossing; a port listing alone isn't. The check reports only.
Fix a `down` line with `Start-ClaudeMemWorker <profile>`, which stops every
other profile's worker first -- one worker at a time, the active profile's.
Switching does the same. A CLI session on the *other* profile still starts its
own worker through claude-mem's SessionStart hook; that's needed for the
session to have memory, and the next switch or `Start-ClaudeMemWorker` stops it
again. If the plugin is disabled in a profile's `enabledPlugins`, the worker
exits silently on start, and `Start-ClaudeMemWorker` says so. See
[Claude-mem-multiple-profiles.md](Claude-mem-multiple-profiles/Claude-mem-multiple-profiles.md)
for the wiring each profile needs.

**Local models (Ollama)**

Launcher `[l]` lists the installed [Ollama](https://ollama.com) models that can
call tools, then offers context sizes (64k/128k/256k, or type one like `96k`)
and a project folder (the last five used, `b` for a folder picker, or a pasted
path), and runs Claude Code in that window. `/exit` returns to the menu. From a terminal:

```powershell
Start-ClaudeLocal qwen3.5:9b -Path C:\src\app
Start-ClaudeLocal qwen3.5:9b -Context 98304 -- --continue   # Claude's flags go after --
```

It uses Ollama's built-in Anthropic endpoint, so no router or proxy is needed.
Sessions live in `~/.claude-local`, which has no account, plugins, hooks or
`CLAUDE.md`. Each of those would spend context a small model can't spare, and
local sessions would fill an account's history and claude-mem store. The desktop
profile and its worker are left alone.

**Terminal only.** The desktop app can't do this. It forces Anthropic's API
address into every Code tab. Its third-party inference mode (Developer →
Configure Third-Party Inference) accepts a gateway URL, but it drops model names
it recognises as non-Claude (`qwen`, `llama`, `gemma` and so on).

What `Start-ClaudeLocal` sets, and why:

- **Context size, on both sides.** Ollama loads a model at its full trained
  window unless told otherwise. Its Anthropic endpoint ignores per-request
  options, so the function creates `cc-local`, a derived model with `num_ctx`
  pinned. It shares the original's weights, so it takes no extra disk. Claude
  Code assumes 200k for a model it doesn't know, so
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` makes it auto-compact before Ollama truncates.
- **Every model slot points at `cc-local`,** so background calls and subagents
  stay local too.
- **The reply reservation is capped at 8k** (`CLAUDE_CODE_MAX_OUTPUT_TOKENS`).
  The default takes most of a 64k window.
- **Only Bash, Read, Edit, Write, Glob and Grep are offered.** `-AllTools`
  restores the rest.

Measured on 2026-09-11 (RTX 3060 Ti 8 GB, 32 GB RAM, Ollama 0.23, Claude Code
2.1.268):

| | |
|---|---|
| Claude Code's per-turn overhead | ~7k tokens with the default tools, ~17k with `-AllTools` |
| 32k context | fails: "Prompt is too long", or auto-compact thrashes |
| 64k context | works |
| Qwen3.5-4B at 64k | 8.1 GB, 24% on CPU; edited a file correctly in 8 turns |
| Same model with no context cap | Ollama loads 256k: 15 GB, 67% on CPU |
| Qwen3.5-4B with `-AllTools` | lost track and asked for file permission it already had |
| `qwen2.5-coder:7b` | writes tool calls as plain text instead of making them. It advertises tool support, so it still appears in the list, but it can't drive Claude Code |

---

## Porting your conventions to a new profile

A fresh profile has none of your `CLAUDE.md`, skills, agents or commands. See
what's missing:

```powershell
Compare-ClaudeProfiles
```

Dry run, then copy:

```powershell
Copy-ClaudeConventions -WhatIf
Copy-ClaudeConventions
```

By default this copies `personal` → the next profile in your map. Name both ends
explicitly if you have more than two:

```powershell
Copy-ClaudeConventions -From personal -To client-a
```

### What gets copied

`CLAUDE.md`, `settings.json`, `skills/`, `agents/`, `commands/`, `hooks/`,
`rules/`, `output-styles/`, `workflows/`.

### What never gets copied, and why

**Identity and session state** - `.claude.json`, `.credentials.json`, `sessions/`,
`projects/`, `history/`, `todos/`, and friends. Copying these would drag one
account's login into the other profile, which is the exact failure this tool
exists to prevent. The copy function refuses them even if you ask by name.

**Plugin enablement** - `settings.json` is *merged key by key* rather than
replaced, and `enabledPlugins` / `extraKnownMarketplaces` are always left alone.
This matters: plugin caches are per-profile, so copying those keys makes the new
profile auto-install plugins it has no cache for. Plugins with hooks then fire
against a half-installed copy and block your prompts. Enable plugins per profile
from inside a session with `/plugin` instead.

Existing keys aren't overwritten unless you pass `-Overwrite`. A `.bak` is written
before any settings merge.

---

## Verifying the separation actually holds

```powershell
Get-ClaudeProfileStatus                     # two different emails
cc-work                                     # then /status inside the session
```

If both profiles report the same account, `CLAUDE_CONFIG_DIR` isn't taking effect.
Try the belt-and-braces mode, which also repoints `USERPROFILE`/`HOME`:

```powershell
Invoke-ClaudeProfile -Name work -IsolateHome
```

Be aware that git, ssh and anything else reading `~` will then look inside the
profile directory.

---

## Windows install types

The desktop app ships in two shapes and they behave very differently. The script
detects which you have by finding `claude_desktop_config.json` rather than
assuming a path.

### Standalone install

Data lives at `%APPDATA%\Claude`. Junction swapping works straightforwardly:

```powershell
Initialize-ClaudeProfiles
Switch-ClaudeDesktop work -Launch
```

### MSIX / Store install

Data is virtualised into the package container, at a path like:

```
%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude
```

`%APPDATA%\Claude` never exists. Swapping is opt-in:

```powershell
Initialize-ClaudeProfiles -IncludeMsixDesktop
Switch-ClaudeDesktop work -Launch -IAcceptTheRisk
```

**This does work** - verified on Claude desktop 1.40609.0. The container follows
a junction that points out of its sandbox. Two caveats:

- Windows can clear `LocalCache` on a package reset. Profile data lives in
  `%LOCALAPPDATA%\Claude-profiles\`, **outside** the container, so a reset
  destroys the link and not your profiles. Re-run `Switch-ClaudeDesktop`.
- If a future build tightens the sandbox, the link may be refused or writes
  silently redirected. The script detects both: it creates the junction, writes a
  probe file through it, confirms the probe lands in the target, and reverts your
  data if not.

MSIX apps also have no launchable `.exe`. `-Launch` resolves them through
`shell:AppsFolder\<PackageFamilyName>!<AppId>`, falling back to the package
manifest and then to classic install paths.

---

## Troubleshooting

**`Get-ClaudeProfileStatus` isn't recognised** - the profile line didn't load.
Check `Test-Path $PROFILE` and your execution policy, then open a new terminal.

**"The live data folder is real, not a junction"** - run `Initialize-ClaudeProfiles`
first, so the existing data is moved somewhere safe before a link replaces it.

**Desktop switch appears to do nothing** - the app was still running, or the
sandbox refused the link. Check `Get-ClaudeProfileStatus` for `active:`.

**`-Launch` can't find the app**:

```powershell
Get-ClaudeDesktopLaunchTarget          # what it resolved
Get-StartApps | Where-Object Name -like '*Claude*'
```

**A plugin hook blocks prompts on a new profile** - you copied `enabledPlugins`
from an older version of this script, or by hand. Set the plugin to `false` in
that profile's `settings.json`, and delete its stale cache under
`<profile>\plugins\cache\`.

**Something else looks wrong** - nothing here writes outside your profile
directories, `%LOCALAPPDATA%\Claude-profiles\`, and the app's own data path. See
Rollback.

---

## Rollback

```powershell
# desktop app closed
[System.IO.Directory]::Delete($LiveDataPath, $false)     # removes the link only
Move-Item "$env:LOCALAPPDATA\Claude-profiles\personal" $LiveDataPath
```

Get `$LiveDataPath` from `Get-ClaudeProfileStatus`. Then remove the
`. "$env:USERPROFILE\.claude-profiles.ps1"` line from `$PROFILE`. CLI profiles are
just directories - delete the ones you don't want.

---

## Design notes

Everything here follows two rules:

1. **Never delete a real directory.** Only reparse points are removed, and only
   after confirming they are reparse points.
2. **Never claim success without checking.** Junctions are verified by writing a
   probe through them; a failed link reverts your data rather than leaving the app
   pointing at nothing.

Profile stores deliberately live outside any application sandbox so that OS-level
cleanup destroys links rather than data.

---

## Notes for Anthropic

Collected while building this, in case they're useful upstream:

- `CLAUDE_CONFIG_DIR` cleanly separates CLI profiles **including authentication**,
  which makes it the supported answer for multi-account CLI use - but it isn't
  documented as such.
- The desktop app has no equivalent. A `CLAUDE_DATA_DIR` (or a native profile
  picker) would remove the need for this entire script.
- On MSIX builds, the user data path is undocumented, and `%APPDATA%\Claude`
  - the path most guides cite - does not exist.
- A junction inside the MSIX `LocalCache` pointing outside the container **is
  followed correctly** by the app. Desktop profile separation is therefore
  achievable on current builds.

Related issues: [#30565](https://github.com/anthropics/claude-code/issues/30565),
[#36821](https://github.com/anthropics/claude-code/issues/36821),
[#18435](https://github.com/anthropics/claude-code/issues/18435),
[#57998](https://github.com/anthropics/claude-code/issues/57998),
[#33430](https://github.com/anthropics/claude-code/issues/33430).

---

## Licence

MIT - see [LICENSE](LICENSE).

Not affiliated with or endorsed by Anthropic. Relies on undocumented behaviour of
the Claude desktop app that may change at any time.
