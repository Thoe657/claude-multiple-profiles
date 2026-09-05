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
and quota aren't crossing; a port listing alone isn't. The check reports only --
a `down` line is fixed by opening a session on that profile, since the worker is
started by claude-mem's SessionStart hook. See
[Claude-mem-multiple-profiles.md](Claude-mem-multiple-profiles/Claude-mem-multiple-profiles.md)
for the wiring each profile needs.

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
