<#
.SYNOPSIS
    Run two (or more) Claude accounts side by side on one Windows machine.

.DESCRIPTION
    Claude has no built-in account switcher. Usage limits are per-account and never
    pool, so the real risk is not billing crossover -- it is doing work under the
    wrong identity without noticing.

    This script separates two things:

      Claude Code CLI   CLAUDE_CONFIG_DIR relocates the whole ~/.claude tree
                        (settings, CLAUDE.md, skills, agents, plugins, sessions
                        and auth) per profile. Officially supported.

      Desktop app       No equivalent env var exists, so the live data directory
                        is replaced with a junction pointing at one of several
                        profile directories. Works on standalone installs, and
                        on MSIX/Store installs too -- see README.

.NOTES
    Requires PowerShell 5.1+. No administrator rights (junctions need none).
    MIT licensed. See README.md for the full walkthrough.
#>

# ============================================================== configuration

# Add, rename or remove profiles here. The key is the profile name you type;
# the value is its config directory.
#
# 'personal' maps to %USERPROFILE%\.claude, which is also what plain `claude`
# uses when no profile is active -- keep one profile pointed there.
#
# If your directories are named differently, set CLAUDE_PROFILE_DIR_PERSONAL /
# CLAUDE_PROFILE_DIR_WORK in your PowerShell profile before dot-sourcing this
# file. Editing the map below works too, but is lost the next time you reinstall.
$script:ClaudeCliProfiles = [ordered]@{
    'personal' = if ($env:CLAUDE_PROFILE_DIR_PERSONAL) { $env:CLAUDE_PROFILE_DIR_PERSONAL }
                 else { Join-Path $env:USERPROFILE '.claude' }
    'work'     = if ($env:CLAUDE_PROFILE_DIR_WORK) { $env:CLAUDE_PROFILE_DIR_WORK }
                 else { Join-Path $env:USERPROFILE '.claude-work' }
}

# Where each profile's desktop-app data is kept. Deliberately outside any app
# sandbox, so a package reset destroys links rather than data.
$script:ClaudeDesktopStore = Join-Path $env:LOCALAPPDATA 'Claude-profiles'

# Config you author and want identical across profiles.
$script:ClaudePortableItems = @(
    'CLAUDE.md'
    'settings.json'
    'skills'
    'agents'
    'commands'
    'hooks'
    'rules'
    'output-styles'
    'workflows'
)

# Identity and per-account state. Copying any of these defeats the purpose.
$script:ClaudeNeverCopy = @(
    '.claude.json'
    '.credentials.json'
    'sessions'
    'projects'
    'history'
    'todos'
    'shell-snapshots'
    'statsig'
    'cache'
    'backups'
    'file-history'
    'ide'
)

# settings.json keys that must NOT be copied between profiles. Plugin caches are
# per-profile, so copying these makes a profile install plugins it has no cache
# for -- which is how you get hooks firing for plugins that are not really there.
$script:ClaudeSettingsNeverMerge = @(
    'enabledPlugins'
    'extraKnownMarketplaces'
)

# ============================================================== discovery

function Find-ClaudeDesktopDataDir {
    <#
      The live user-data directory is whichever folder holds
      claude_desktop_config.json. Do not assume %APPDATA%\Claude -- Store (MSIX)
      installs virtualise it into the package container.
    #>
    [CmdletBinding()]
    param()

    $candidates = @(
        (Join-Path $env:APPDATA 'Claude'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c 'claude_desktop_config.json')) { return $c }
    }
    $hit = Get-ChildItem $env:APPDATA, $env:LOCALAPPDATA -Filter 'claude_desktop_config.json' `
             -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
    return $null
}

$script:ClaudeDesktopLive   = Find-ClaudeDesktopDataDir
$script:ClaudeDesktopIsMsix = [bool]($script:ClaudeDesktopLive -and
                                     $script:ClaudeDesktopLive -match '[\\/]Packages[\\/]')

# ============================================================== helpers

function Resolve-ClaudeProfileName {
    param([Parameter(Mandatory)][string]$Name)
    $match = $script:ClaudeCliProfiles.Keys | Where-Object { $_ -eq $Name }
    if (-not $match) {
        throw "Unknown Claude profile '$Name'. Known: $($script:ClaudeCliProfiles.Keys -join ', ')"
    }
    return [string]$match
}

function Get-ClaudeCliProfilePath {
    param([Parameter(Mandatory)][string]$Name)
    return $script:ClaudeCliProfiles[(Resolve-ClaudeProfileName $Name)]
}

function Get-ClaudeProfileNames {
    # Public accessor: $script:ClaudeCliProfiles is private to this file's scope,
    # so anything dot-sourcing it separately (the launcher) cannot read it.
    return @($script:ClaudeCliProfiles.Keys)
}

function Get-ActiveClaudeDesktopProfile {
    # Which profile the desktop data junction currently points at, or $null.
    if (-not $script:ClaudeDesktopLive) { return $null }
    if (-not (Test-IsJunction $script:ClaudeDesktopLive)) { return $null }
    $t = Get-JunctionTarget $script:ClaudeDesktopLive
    if (-not $t) { return $null }
    foreach ($n in $script:ClaudeCliProfiles.Keys) {
        if ($t.TrimEnd('\') -eq (Get-ClaudeDesktopProfilePath $n).TrimEnd('\')) { return $n }
    }
    return $null
}

function Get-ClaudeDesktopProfilePath {
    # CLAUDE_DESKTOP_DIR_<PROFILE> overrides where a profile's desktop data
    # lives, for directories that already exist under a different name. Set it
    # in $PROFILE, same as CLAUDE_PROFILE_DIR_<PROFILE> for the CLI side.
    param([Parameter(Mandatory)][string]$Name)
    $n = Resolve-ClaudeProfileName $Name
    $override = [Environment]::GetEnvironmentVariable("CLAUDE_DESKTOP_DIR_$($n.ToUpper())")
    if ($override) { return $override }
    return Join-Path $script:ClaudeDesktopStore $n
}

function Test-IsJunction {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band
                  [System.IO.FileAttributes]::ReparsePoint)
}

function Get-JunctionTarget {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-IsJunction $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSObject.Properties.Name -contains 'Target' -and $item.Target) {
        return @($item.Target)[0]
    }
    return $null
}

function Remove-JunctionOnly {
    # Deletes the link only, never what it points at.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-IsJunction $Path)) {
        throw "Refusing to remove '$Path': it is a real directory, not a junction."
    }
    [System.IO.Directory]::Delete($Path, $false)
}

function New-VerifiedJunction {
    <#
      Creates the link and proves it resolves. An app sandbox may refuse a
      reparse point that leaves its container, so this must fail loudly.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    if (-not (Test-IsJunction $Path)) {
        throw "Created '$Path' but it is not a reparse point -- the sandbox refused the link. Data is safe at $Target."
    }
    $probe = Join-Path $Path '.__linkprobe'
    try {
        Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
        $seen = Test-Path -LiteralPath (Join-Path $Target '.__linkprobe')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        if (-not $seen) {
            throw "Writes through '$Path' are not reaching '$Target' -- the sandbox is redirecting them."
        }
    } catch [System.UnauthorizedAccessException] {
        throw "Cannot write through '$Path' -- the sandbox blocked it. Data is safe at $Target."
    }
}

function Get-ClaudeAccountFromConfig {
    param([Parameter(Mandatory)][string]$ProfileDir)
    $file = Join-Path $ProfileDir '.claude.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $json = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Email = '(unreadable)'; Organization = $null }
    }
    $email = $null; $org = $null
    if ($json.PSObject.Properties.Name -contains 'oauthAccount' -and $json.oauthAccount) {
        $acct = $json.oauthAccount
        foreach ($p in 'emailAddress','email') {
            if ($acct.PSObject.Properties.Name -contains $p -and $acct.$p) { $email = $acct.$p; break }
        }
        if ($acct.PSObject.Properties.Name -contains 'organizationName') { $org = $acct.organizationName }
    }
    return [pscustomobject]@{ Email = $email; Organization = $org }
}

# ============================================================== desktop app

function Get-ClaudeDesktopLaunchTarget {
    <#
      Returns something Start-Process can launch, or $null. MSIX apps have no
      plain exe path -- they are addressed as shell:AppsFolder\<family>!<AppId>
    #>
    [CmdletBinding()]
    param()

    try {
        if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
            $app = Get-StartApps -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like '*Claude*' } | Select-Object -First 1
            if ($app) { return "shell:AppsFolder\$($app.AppID)" }
        }
    } catch { }

    try {
        $pkg = if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
                   Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
               } else { $null }
        if ($pkg) {
            $id = ($pkg | Get-AppxPackageManifest).Package.Applications.Application.Id |
                    Select-Object -First 1
            if ($id) { return "shell:AppsFolder\$($pkg.PackageFamilyName)!$id" }
        }
    } catch { }

    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Claude\Claude.exe'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Claude.lnk')
    )) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Start-ClaudeDesktopApp {
    [CmdletBinding()]
    param()
    $target = Get-ClaudeDesktopLaunchTarget
    if (-not $target) {
        Write-Warning "Could not resolve a way to launch Claude desktop. Open it from the Start menu."
        Write-Warning "Diagnose with:  Get-StartApps | Where-Object Name -like '*Claude*'"
        return
    }
    Write-Host "launching: $target" -ForegroundColor DarkGray
    try { Start-Process $target -ErrorAction Stop }
    catch { Write-Warning "Launch failed: $($_.Exception.Message)" }
}

function Get-ClaudeDesktopProcess {
    # Match on executable path, not a guessed process name. Excludes the CLI.
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like '*Claude*' -and $_.Path -notlike '*\.local\bin\*' }
}

function Test-ClaudeDesktopRunning {
    return [bool](Get-ClaudeDesktopProcess)
}

# ============================================================== setup

function Initialize-ClaudeProfiles {
    <#
    .SYNOPSIS
        One-time setup. Creates profile directories and puts the desktop app's
        current data into a profile slot.
    .PARAMETER AdoptDesktopDataAs
        Which profile the desktop app's existing data belongs to.
    .PARAMETER IncludeMsixDesktop
        Set up desktop swapping even on a Store (MSIX) install.
    #>
    [CmdletBinding()]
    param(
        [string]$AdoptDesktopDataAs = 'personal',
        [switch]$IncludeMsixDesktop
    )

    foreach ($entry in $script:ClaudeCliProfiles.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value)) {
            New-Item -ItemType Directory -Path $entry.Value -Force | Out-Null
            Write-Host "created CLI profile '$($entry.Key)' at $($entry.Value)" -ForegroundColor Green
        }
    }

    if (-not (Test-Path -LiteralPath $script:ClaudeDesktopStore)) {
        New-Item -ItemType Directory -Path $script:ClaudeDesktopStore -Force | Out-Null
    }
    $adopt = Resolve-ClaudeProfileName $AdoptDesktopDataAs
    foreach ($name in $script:ClaudeCliProfiles.Keys) {
        $dir = Get-ClaudeDesktopProfilePath $name
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    if (-not $script:ClaudeDesktopLive) {
        Write-Warning "Desktop data directory not found. Launch the desktop app once, then re-run."
    }
    elseif ($script:ClaudeDesktopIsMsix -and -not $IncludeMsixDesktop) {
        Write-Warning "Claude desktop is a Store (MSIX) install; its data is at"
        Write-Warning "  $script:ClaudeDesktopLive"
        Write-Warning "Desktop migration skipped. Re-run with -IncludeMsixDesktop to set it up anyway"
        Write-Warning "(profile data is stored outside the container, so this is reversible)."
    }
    elseif ((Test-Path -LiteralPath $script:ClaudeDesktopLive) -and
            -not (Test-IsJunction $script:ClaudeDesktopLive)) {
        if (Test-ClaudeDesktopRunning) {
            Write-Warning "Claude desktop is running. Close it fully, then run this again."
        } else {
            $target = Get-ClaudeDesktopProfilePath $adopt
            if (Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue) {
                Write-Warning "$target is not empty; leaving the live folder alone."
            } else {
                Write-Host "moving existing desktop data into profile '$adopt'..." -ForegroundColor Yellow
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $script:ClaudeDesktopLive -Destination $target -Force
                try {
                    New-VerifiedJunction -Path $script:ClaudeDesktopLive -Target $target
                    Write-Host "desktop profile '$adopt' is now active" -ForegroundColor Green
                } catch {
                    Write-Error $_.Exception.Message
                    Write-Warning "Restoring the original folder so the app keeps working..."
                    Move-Item -LiteralPath $target -Destination $script:ClaudeDesktopLive -Force
                    Write-Warning "Reverted. Use a separate Windows user account for the second desktop identity."
                }
            }
        }
    }

    Write-Host ""
    Get-ClaudeProfileStatus
}

# ============================================================== CLI switching

function Invoke-ClaudeProfile {
    <#
    .SYNOPSIS
        Runs the Claude Code CLI against one profile, for this invocation only.
    .PARAMETER IsolateHome
        Also repoint USERPROFILE/HOME. Only needed if auth ever leaks between
        profiles; note git/ssh will then look for configs inside the profile dir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$IsolateHome,
        [Parameter(ValueFromRemainingArguments)]$Arguments
    )

    $profileName = Resolve-ClaudeProfileName $Name
    $dir = Get-ClaudeCliProfilePath $profileName
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $saved = @{
        CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR
        USERPROFILE       = $env:USERPROFILE
        HOME              = $env:HOME
    }
    try {
        $env:CLAUDE_CONFIG_DIR = $dir
        if ($IsolateHome) { $env:USERPROFILE = $dir; $env:HOME = $dir }
        Write-Host "[$profileName] $dir" -ForegroundColor Cyan
        & claude @Arguments
    } finally {
        $env:CLAUDE_CONFIG_DIR = $saved.CLAUDE_CONFIG_DIR
        $env:USERPROFILE       = $saved.USERPROFILE
        $env:HOME              = $saved.HOME
    }
}

function Use-ClaudeProfile {
    <#
    .SYNOPSIS
        Pins the current terminal session to a profile.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $profileName = Resolve-ClaudeProfileName $Name
    $dir = Get-ClaudeCliProfilePath $profileName
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $env:CLAUDE_CONFIG_DIR = $dir
    Write-Host "this session now uses Claude profile '$profileName' ($dir)" -ForegroundColor Cyan
}

function Clear-ClaudeProfile {
    Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    Write-Host "CLAUDE_CONFIG_DIR cleared; plain 'claude' uses ~/.claude" -ForegroundColor DarkGray
}

# One cc-<name> shortcut per configured profile, generated from the map above.
foreach ($_ccName in $script:ClaudeCliProfiles.Keys) {
    Set-Item -Path "function:global:cc-$_ccName" `
             -Value ([scriptblock]::Create("Invoke-ClaudeProfile -Name '$_ccName' @args"))
}
Remove-Variable _ccName -ErrorAction SilentlyContinue

# ============================================================== desktop switching

function Switch-ClaudeDesktop {
    <#
    .SYNOPSIS
        Repoints the desktop app's data directory at one profile.
    .DESCRIPTION
        The app must be closed: it holds its data files open and caches the
        signed-in account in memory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$Launch,
        [switch]$Force,
        [switch]$IAcceptTheRisk
    )

    $profileName = Resolve-ClaudeProfileName $Name
    $target = Get-ClaudeDesktopProfilePath $profileName

    if (-not $script:ClaudeDesktopLive) {
        Write-Error "Could not locate the desktop app's data directory (no claude_desktop_config.json found)."
        return
    }

    if ($script:ClaudeDesktopIsMsix -and -not $IAcceptTheRisk) {
        Write-Error @"
This is a Store (MSIX) install. Its data lives in the package container at
  $script:ClaudeDesktopLive
Swapping places a junction there pointing out to
  $script:ClaudeDesktopStore
which is OUTSIDE the container, so profile data is not at risk. Two caveats:
  - Windows may clear LocalCache on a package reset. That destroys the junction,
    not the profiles. Re-run Switch-ClaudeDesktop to restore it.
  - The container may refuse to follow a junction out of its sandbox. If the app
    launches signed-out or ignores the swap, that is what happened -- fall back
    to a separate Windows user account for the second identity.
Re-run with -IAcceptTheRisk to proceed.
"@
        return
    }

    if (Test-ClaudeDesktopRunning) {
        if (-not $Force) { Write-Error "Claude desktop is running. Close it fully, or re-run with -Force."; return }
        Write-Host "closing Claude desktop..." -ForegroundColor Yellow
        Get-ClaudeDesktopProcess | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Write-Host "created empty desktop profile '$profileName' -- you will need to sign in" -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $script:ClaudeDesktopLive) {
        if (Test-IsJunction $script:ClaudeDesktopLive) {
            Remove-JunctionOnly $script:ClaudeDesktopLive
        } else {
            Write-Error "The live data folder is real, not a junction. Run Initialize-ClaudeProfiles first so its data is preserved."
            return
        }
    }

    try { New-VerifiedJunction -Path $script:ClaudeDesktopLive -Target $target }
    catch { Write-Error $_.Exception.Message; return }

    # The junction only moves the desktop app's own data. Claude Code running
    # inside the app is a separate thing that reads CLAUDE_CONFIG_DIR exactly
    # like the CLI does, and inherits it from the app's process. Nothing else
    # points it at a profile, so without this a Code tab writes its sessions,
    # projects and refreshed OAuth tokens into ~/.claude no matter which account
    # the app is signed into. User scope so Start-menu launches get it too;
    # process scope so the -Launch below gets it without waiting for a refresh.
    $cliDir = Get-ClaudeCliProfilePath $profileName
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $cliDir, 'User')
    $env:CLAUDE_CONFIG_DIR = $cliDir
    Write-Host "CLAUDE_CONFIG_DIR -> $cliDir" -ForegroundColor DarkGray
    Write-Host "  (terminals already open keep the old value -- reopen them)" -ForegroundColor DarkGray

    Start-ClaudeMemWorker $profileName

    Write-Host "desktop profile '$profileName' is now active" -ForegroundColor Green
    if ($Launch) {
        Start-ClaudeDesktopApp
        Write-Host ""
        Get-ClaudeMemWorkerStatus
    }
}

# ============================================================== claude-mem

# claude-mem keys its entire store off CLAUDE_MEM_DATA_DIR, which Claude Code
# exports to hooks from the profile's settings.json 'env' block. When that fails
# to reach a hook it falls back to ~/.claude-mem silently, so two profiles
# sharing one store looks exactly like a healthy pair on a port listing. The
# check that matters is distinct stores with distinct live pids.

function Get-ClaudeMemDataDir {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$ConfigDir)

    $file = Join-Path $ConfigDir 'settings.json'
    $dir = $null
    if (Test-Path -LiteralPath $file) {
        try { $dir = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).env.CLAUDE_MEM_DATA_DIR } catch { }
    }
    if (-not $dir) { $dir = Join-Path $env:USERPROFILE '.claude-mem' }
    return ([Environment]::ExpandEnvironmentVariables($dir)).TrimEnd('\')
}

function Get-ClaudeMemPort {
    param([Parameter(Mandatory, Position = 0)][string]$DataDir)

    try {
        $p = (Get-Content -LiteralPath (Join-Path $DataDir 'settings.json') -Raw |
              ConvertFrom-Json).CLAUDE_MEM_WORKER_PORT
        if ($p) { return [int]$p }
    } catch { }
    return 37777
}

function Get-ClaudeMemWorkerStatus {
    <#
    .SYNOPSIS
        One line per profile: memory store, worker port, live worker pid.
    .DESCRIPTION
        Reports only. The fix for a 'down' line is Start-ClaudeMemWorker.
    #>
    [CmdletBinding()]
    param()

    Write-Host "claude-mem workers" -ForegroundColor White
    $seenDir = @{}; $seenPid = @{}

    foreach ($entry in $script:ClaudeCliProfiles.GetEnumerator()) {
        # No profile dir means no settings.json to read, and Get-ClaudeMemDataDir
        # would fall back to the default store -- which looks exactly like two
        # profiles sharing one worker. Say what is actually wrong instead.
        if (-not (Test-Path -LiteralPath $entry.Value)) {
            Write-Host ("  {0,-10} no profile directory ({1})" -f $entry.Key, $entry.Value) -ForegroundColor DarkYellow
            continue
        }
        $data = Get-ClaudeMemDataDir $entry.Value
        if (-not (Test-Path -LiteralPath $data)) {
            Write-Host ("  {0,-10} no memory store ({1})" -f $entry.Key, $data) -ForegroundColor DarkGray
            continue
        }

        $port = Get-ClaudeMemPort $data

        $workerPid = $null
        try {
            $workerPid = (Get-Content -LiteralPath (Join-Path $data 'supervisor.json') -Raw |
                          ConvertFrom-Json).processes.worker.pid
        } catch { }

        # supervisor.json is written optimistically and goes stale; trust the process.
        $alive     = [bool]($workerPid -and (Get-Process -Id $workerPid -ErrorAction SilentlyContinue))
        $listening = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)

        $state  = if ($alive -and $listening) { 'ok  ' } else { 'down' }
        $colour = if ($alive -and $listening) { 'Green' } else { 'DarkYellow' }
        $pidTxt = if ($alive) { "pid $workerPid" } elseif ($workerPid) { "pid $workerPid (dead)" } else { 'no pid' }
        Write-Host ("  {0,-10} {1}  port {2}  {3}" -f $entry.Key, $state, $port, $pidTxt) -ForegroundColor $colour
        Write-Host ("             store: {0}" -f $data) -ForegroundColor DarkGray

        if ($seenDir.ContainsKey($data)) {
            Write-Host ("             shares its store with '{0}' -- memories and quota will cross" -f $seenDir[$data]) -ForegroundColor Red
        } else { $seenDir[$data] = $entry.Key }

        if ($alive) {
            if ($seenPid.ContainsKey($workerPid)) {
                Write-Host ("             same worker as '{0}' -- CLAUDE_MEM_DATA_DIR is not reaching the hook" -f $seenPid[$workerPid]) -ForegroundColor Red
            } else { $seenPid[$workerPid] = $entry.Key }
        }
    }
}

function Stop-ClaudeMemWorker {
    <#
    .SYNOPSIS
        Stops one profile's claude-mem worker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $profileName = Resolve-ClaudeProfileName $Name
    $dir = Get-ClaudeCliProfilePath $profileName
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $data = Get-ClaudeMemDataDir $dir

    $workerPid = $null
    try {
        $workerPid = (Get-Content -LiteralPath (Join-Path $data 'supervisor.json') -Raw |
                      ConvertFrom-Json).processes.worker.pid
    } catch { }

    # supervisor.json goes stale, so also take whatever holds the profile's port.
    $pids = @($workerPid) + @(Get-NetTCPConnection -LocalPort (Get-ClaudeMemPort $data) -State Listen -ErrorAction SilentlyContinue |
                              Select-Object -ExpandProperty OwningProcess) |
            Where-Object { $_ } | Select-Object -Unique
    foreach ($p in $pids) {
        if (Get-Process -Id $p -ErrorAction SilentlyContinue) {
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
            Write-Host "stopped claude-mem worker for '$profileName' (pid $p)" -ForegroundColor DarkGray
        }
    }
}

function Start-ClaudeMemWorker {
    <#
    .SYNOPSIS
        Starts one profile's claude-mem worker if it is down, after stopping
        every other profile's -- one worker at a time.
    .DESCRIPTION
        Normally the plugin's SessionStart hook does this, so the worker is
        down until a session opens -- and a desktop Code tab without
        CLAUDE_CONFIG_DIR runs the hooks of ~/.claude, whatever account is
        signed in. This runs the hook's own command ('worker-service.cjs
        start', a no-op when the worker is healthy) with the environment the
        hook would have had, independent of any session.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $profileName = Resolve-ClaudeProfileName $Name
    foreach ($other in $script:ClaudeCliProfiles.Keys) {
        if ($other -ne $profileName) { Stop-ClaudeMemWorker $other }
    }

    $dir = Get-ClaudeCliProfilePath $profileName
    # The hook's fallback when CLAUDE_PLUGIN_ROOT is unset: the newest cached
    # version not marked orphaned.
    $root = Get-ChildItem -LiteralPath (Join-Path $dir 'plugins\cache\thedotmack\claude-mem') -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName '.orphaned_at')) -and
                           (Test-Path -LiteralPath (Join-Path $_.FullName 'scripts\worker-service.cjs')) } |
            Sort-Object { [version]($_.Name -replace '-.*') } -Descending |
            Select-Object -First 1
    if (-not $root) {
        Write-Host "claude-mem is not installed on '$profileName'" -ForegroundColor DarkYellow
        return
    }

    $settings = $null
    try { $settings = Get-Content -LiteralPath (Join-Path $dir 'settings.json') -Raw | ConvertFrom-Json } catch { }
    # The worker checks this itself and exits 0 without a word, so say it here.
    if ($settings -and $settings.enabledPlugins.'claude-mem@thedotmack' -eq $false) {
        Write-Host "claude-mem is disabled on '$profileName' (enabledPlugins in settings.json) -- its worker will not start" -ForegroundColor DarkYellow
        return
    }

    # Hooks see CLAUDE_CONFIG_DIR plus the settings.json 'env' block, which is
    # where CLAUDE_MEM_DATA_DIR -- the store, and through it the port -- lives.
    $vars = @{ CLAUDE_CONFIG_DIR = $dir; CLAUDE_PLUGIN_ROOT = $root.FullName }
    if ($settings.env) { foreach ($p in $settings.env.PSObject.Properties) { $vars[$p.Name] = [string]$p.Value } }

    $saved = @{}
    foreach ($k in $vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $vars[$k])
    }
    try {
        $scripts = Join-Path $root.FullName 'scripts'
        & node (Join-Path $scripts 'bun-runner.js') (Join-Path $scripts 'worker-service.cjs') start 2>&1 |
            ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# ============================================================== porting config

function Merge-ClaudeSettings {
    <#
      Merges source settings.json into the target, key by key, skipping keys in
      $script:ClaudeSettingsNeverMerge. Writes a .bak first.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$TargetFile,
        [switch]$Overwrite
    )

    if (-not (Test-Path -LiteralPath $SourceFile)) { return }
    try { $src = Get-Content -LiteralPath $SourceFile -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Write-Warning "Source settings.json is not valid JSON; skipping."; return }

    $dst = $null
    if (Test-Path -LiteralPath $TargetFile) {
        try { $dst = Get-Content -LiteralPath $TargetFile -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Warning "Target settings.json is not valid JSON; skipping."; return }
    }
    if (-not $dst) { $dst = [pscustomobject]@{} }

    $changed = @(); $skipped = @()
    foreach ($prop in $src.PSObject.Properties) {
        if ($script:ClaudeSettingsNeverMerge -contains $prop.Name) { $skipped += $prop.Name; continue }
        $exists = $dst.PSObject.Properties.Name -contains $prop.Name
        if ($exists -and -not $Overwrite) { continue }
        if ($exists) { $dst.PSObject.Properties.Remove($prop.Name) }
        $dst | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        $changed += $prop.Name
    }

    if (-not $changed) {
        Write-Host "  settings.json  no changes" -ForegroundColor DarkGray
    } elseif ($PSCmdlet.ShouldProcess($TargetFile, "merge keys: $($changed -join ', ')")) {
        if (Test-Path -LiteralPath $TargetFile) {
            Copy-Item -LiteralPath $TargetFile -Destination "$TargetFile.bak" -Force
        }
        $dst | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $TargetFile -Encoding UTF8
        Write-Host ("  settings.json  merged: {0}" -f ($changed -join ', ')) -ForegroundColor Green
    }
    if ($skipped) {
        Write-Host ("  settings.json  left alone (profile-specific): {0}" -f ($skipped -join ', ')) -ForegroundColor DarkYellow
    }
}

function Compare-ClaudeProfiles {
    <#
    .SYNOPSIS
        Lists authored config present in one profile but missing from another.
    #>
    [CmdletBinding()]
    param(
        [string]$From = 'personal',
        [string]$To,
        [string]$FromPath,
        [string]$ToPath
    )

    if (-not $To -and -not $ToPath) {
        $To = ($script:ClaudeCliProfiles.Keys | Where-Object { $_ -ne $From } | Select-Object -First 1)
    }
    $src = if ($FromPath) { $FromPath } else { Get-ClaudeCliProfilePath $From }
    $dst = if ($ToPath)   { $ToPath }   else { Get-ClaudeCliProfilePath $To }

    if (-not (Test-Path -LiteralPath $src)) { Write-Error "Source profile not found: $src"; return }
    if (-not (Test-Path -LiteralPath $dst)) { Write-Error "Target profile not found: $dst"; return }

    Write-Host ("{0}  ->  {1}" -f $src, $dst) -ForegroundColor White
    Write-Host ""

    foreach ($rel in $script:ClaudePortableItems) {
        $s = Join-Path $src ($rel -replace '/', '\')
        $d = Join-Path $dst ($rel -replace '/', '\')
        $inSrc = Test-Path -LiteralPath $s
        $inDst = Test-Path -LiteralPath $d
        if (-not $inSrc -and -not $inDst) { continue }

        $detail = ''
        if ($inSrc -and (Get-Item -LiteralPath $s -Force).PSIsContainer) {
            $n = @(Get-ChildItem -LiteralPath $s -Force -ErrorAction SilentlyContinue).Count
            $detail = " ($n item$(if ($n -ne 1) { 's' }))"
        }

        if ($inSrc -and -not $inDst) {
            Write-Host ("  MISSING     {0}{1}" -f $rel, $detail) -ForegroundColor Yellow
        } elseif ($inSrc -and $inDst) {
            $sh = Get-FileHash -LiteralPath $s -ErrorAction SilentlyContinue
            $dh = Get-FileHash -LiteralPath $d -ErrorAction SilentlyContinue
            if ($sh -and $dh -and $sh.Hash -ne $dh.Hash) {
                Write-Host ("  DIFFERS     {0}" -f $rel) -ForegroundColor DarkYellow
            } else {
                Write-Host ("  present     {0}{1}" -f $rel, $detail) -ForegroundColor DarkGray
            }
        } else {
            Write-Host ("  target-only {0}" -f $rel) -ForegroundColor DarkCyan
        }
    }

    Write-Host ""
    Write-Host "never compared or copied (identity / per-account state):" -ForegroundColor DarkGray
    Write-Host ("  {0}" -f ($script:ClaudeNeverCopy -join ', ')) -ForegroundColor DarkGray
    Write-Host ("  settings.json keys: {0}" -f ($script:ClaudeSettingsNeverMerge -join ', ')) -ForegroundColor DarkGray
}

function Copy-ClaudeConventions {
    <#
    .SYNOPSIS
        Copies authored config between profiles. Never touches auth or sessions.
    .DESCRIPTION
        settings.json is merged key-by-key rather than replaced, and plugin
        enablement keys are always left alone -- plugin caches are per-profile.
        Run with -WhatIf first.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string]$From = 'personal',
        [string]$To,
        [string]$FromPath,
        [string]$ToPath,
        [switch]$Overwrite,
        [string[]]$Only
    )

    if (-not $To -and -not $ToPath) {
        $To = ($script:ClaudeCliProfiles.Keys | Where-Object { $_ -ne $From } | Select-Object -First 1)
    }
    $src = if ($FromPath) { $FromPath } else { Get-ClaudeCliProfilePath $From }
    $dst = if ($ToPath)   { $ToPath }   else { Get-ClaudeCliProfilePath $To }

    if (-not (Test-Path -LiteralPath $src)) { Write-Error "Source profile not found: $src"; return }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }

    $items = if ($Only) { $Only } else { $script:ClaudePortableItems }

    foreach ($rel in $items) {
        if ($script:ClaudeNeverCopy -contains $rel) {
            Write-Warning "refusing to copy '$rel' -- identity or session state"
            continue
        }
        $s = Join-Path $src ($rel -replace '/', '\')
        $d = Join-Path $dst ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $s)) { continue }

        if ($rel -eq 'settings.json') {
            Merge-ClaudeSettings -SourceFile $s -TargetFile $d -Overwrite:$Overwrite
            continue
        }
        if ((Test-Path -LiteralPath $d) -and -not $Overwrite) {
            Write-Host ("  skip (exists)  {0}" -f $rel) -ForegroundColor DarkGray
            continue
        }
        if ($PSCmdlet.ShouldProcess($d, "copy from $s")) {
            $parent = Split-Path -Parent $d
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $s -Destination $d -Recurse -Force
            Write-Host ("  copied         {0}" -f $rel) -ForegroundColor Green
        }
    }
}

# ============================================================== status

function Get-ClaudeProfileStatus {
    [CmdletBinding()]
    param()

    Write-Host "Claude Code CLI" -ForegroundColor White
    $active = $env:CLAUDE_CONFIG_DIR
    foreach ($entry in $script:ClaudeCliProfiles.GetEnumerator()) {
        $dir = $entry.Value
        $isActive = $false
        if ($active) {
            $a = Resolve-Path -LiteralPath $active -ErrorAction SilentlyContinue
            $b = Resolve-Path -LiteralPath $dir    -ErrorAction SilentlyContinue
            $isActive = ($a -and $b -and $a.Path -eq $b.Path)
        }
        $marker = if ($isActive) { '*' } else { ' ' }
        $exists = if (Test-Path -LiteralPath $dir) { '' } else { '  (missing)' }
        Write-Host ("  {0} {1,-10} {2}{3}" -f $marker, $entry.Key, $dir, $exists)

        $acct = Get-ClaudeAccountFromConfig $dir
        if ($acct -and $acct.Email) {
            $orgPart = if ($acct.Organization) { " ($($acct.Organization))" } else { '' }
            Write-Host ("       signed in as {0}{1}" -f $acct.Email, $orgPart) -ForegroundColor DarkGray
        } elseif (Test-Path -LiteralPath $dir) {
            Write-Host "       not signed in on this profile yet" -ForegroundColor DarkYellow
        }
    }
    if (-not $active) {
        Write-Host "  (CLAUDE_CONFIG_DIR unset here -- plain 'claude' uses ~/.claude)" -ForegroundColor DarkGray
    }
    # The user-scope value is what the desktop app inherits, and so what a Code
    # tab writes to. A blank one means every Code tab lands in ~/.claude.
    $userScope = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
    if ($userScope) {
        Write-Host ("  desktop Code tabs will use: {0}" -f $userScope) -ForegroundColor DarkGray
    } else {
        Write-Host "  desktop Code tabs will use ~/.claude regardless of the account signed in" -ForegroundColor Red
        Write-Host "  -- run Switch-ClaudeDesktop to set CLAUDE_CONFIG_DIR at user scope" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "Claude desktop" -ForegroundColor White
    if (-not $script:ClaudeDesktopLive) {
        Write-Host "  data directory not found (app never launched?)" -ForegroundColor DarkYellow
    } else {
        $kind = if ($script:ClaudeDesktopIsMsix) { 'Store / MSIX install' } else { 'standalone install' }
        Write-Host ("  {0}" -f $kind) -ForegroundColor DarkGray
        Write-Host ("  data: {0}" -f $script:ClaudeDesktopLive) -ForegroundColor DarkGray
        if (Test-IsJunction $script:ClaudeDesktopLive) {
            $activeName = Get-ActiveClaudeDesktopProfile
            if (-not $activeName) { $activeName = '(unrecognised target)' }
            Write-Host ("  active: {0}" -f $activeName) -ForegroundColor Cyan
        } elseif ($script:ClaudeDesktopIsMsix) {
            Write-Host "  swapping needs -IncludeMsixDesktop / -IAcceptTheRisk (see README)" -ForegroundColor DarkYellow
        } else {
            Write-Host "  not managed yet -- run Initialize-ClaudeProfiles" -ForegroundColor DarkYellow
        }
    }
    Write-Host ("  running: {0}" -f $(if (Test-ClaudeDesktopRunning) { 'yes' } else { 'no' })) -ForegroundColor DarkGray

    Write-Host ""
    Get-ClaudeMemWorkerStatus

    Write-Host ""
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host ("claude resolves to: {0}" -f $cmd.Source) -ForegroundColor DarkGray }
    else { Write-Host "claude is not on PATH in this session" -ForegroundColor DarkYellow }
}

# ============================================================== completion

$script:ClaudeProfileCompleter = {
    param($commandName, $parameterName, $wordToComplete)
    $script:ClaudeCliProfiles.Keys |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
Register-ArgumentCompleter -CommandName Invoke-ClaudeProfile, Use-ClaudeProfile, Switch-ClaudeDesktop, Initialize-ClaudeProfiles `
    -ParameterName Name -ScriptBlock $script:ClaudeProfileCompleter
Register-ArgumentCompleter -CommandName Compare-ClaudeProfiles, Copy-ClaudeConventions `
    -ParameterName From -ScriptBlock $script:ClaudeProfileCompleter
Register-ArgumentCompleter -CommandName Compare-ClaudeProfiles, Copy-ClaudeConventions `
    -ParameterName To -ScriptBlock $script:ClaudeProfileCompleter
