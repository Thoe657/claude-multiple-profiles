<#
.SYNOPSIS
    Menu front-end for claude-profiles.ps1. Double-click Claude-Launcher.cmd.

.DESCRIPTION
    Picking a profile closes every Claude instance, repoints the desktop data
    junction, sets CLAUDE_CONFIG_DIR at user scope so Code tabs inside the app
    write to the right profile, stops the other profile's claude-mem worker and
    relaunches the app. The rest of the menu is troubleshooting.
#>

# Dot-sourced by Claude-Launcher.cmd, never run as a child script: the helper
# functions read $script:-scoped state, and PowerShell resolves $script: against
# the *calling* script's scope, so a nested .ps1 sees an empty profile map.
if (-not (Get-Command Get-ClaudeProfileNames -ErrorAction SilentlyContinue)) {
    # Sibling copy first, so running from a clone beats a stale installed one.
    $source = @(
        (Join-Path $PSScriptRoot 'claude-profiles.ps1'),
        (Join-Path $env:USERPROFILE '.claude-profiles.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $source) {
        Write-Host "claude-profiles.ps1 not found. Install it first (see README)." -ForegroundColor Red
        Read-Host "enter to close"; return
    }
    . $source
}

function Update-ClaudePlugins {
    param([Parameter(Mandatory)][string]$Name)

    $dir = Get-ClaudeCliProfilePath $Name
    $saved = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = $dir
        $plugins = & claude plugin list --json 2>$null | ConvertFrom-Json
        if (-not $plugins) { Write-Host "no plugins installed on '$Name'" -ForegroundColor DarkGray; return }
        foreach ($p in $plugins) {
            Write-Host "  updating $($p.id)" -ForegroundColor DarkGray
            & claude plugin update $p.id 2>&1 | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        Write-Host "done -- updates apply on the next session" -ForegroundColor Green
    } finally {
        $env:CLAUDE_CONFIG_DIR = $saved
    }
}

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  Claude profile launcher" -ForegroundColor White
    Write-Host "  =======================" -ForegroundColor DarkGray
    Write-Host ""

    $active = Get-ActiveClaudeDesktopProfile
    $userScope = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')

    $i = 0
    foreach ($n in (Get-ClaudeProfileNames)) {
        $i++
        $mark = if ($n -eq $active) { '*' } else { ' ' }
        $acct = Get-ClaudeAccountFromConfig (Get-ClaudeCliProfilePath $n)
        $who  = if ($acct -and $acct.Email) { $acct.Email } else { '(not signed in)' }
        $col  = if ($n -eq $active) { 'Cyan' } else { 'Gray' }
        Write-Host ("   [{0}] {1} {2,-10} {3}" -f $i, $mark, $n, $who) -ForegroundColor $col
    }

    Write-Host ""
    if (-not $active) {
        Write-Host "   desktop is not on a managed profile" -ForegroundColor DarkYellow
    }
    if ($userScope) {
        Write-Host ("   Code tabs write to: {0}" -f $userScope) -ForegroundColor DarkGray
    } else {
        Write-Host "   Code tabs write to ~/.claude whatever account is signed in -- switch to fix" -ForegroundColor Red
    }
    Write-Host ("   desktop running: {0}" -f $(if (Test-ClaudeDesktopRunning) { 'yes' } else { 'no' })) -ForegroundColor DarkGray

    Write-Host ""
    Write-Host "   [s] full status          [r] start active profile's claude-mem worker" -ForegroundColor DarkGray
    Write-Host "   [k] force-close Claude   [w] restart claude-mem worker" -ForegroundColor DarkGray
    Write-Host "   [l] local model (Ollama) [u] update plugins on active profile" -ForegroundColor DarkGray
    Write-Host "   [q] quit" -ForegroundColor DarkGray
    Write-Host ""
}

function Wait-Key { Write-Host ""; Read-Host "enter to continue" | Out-Null }

function Read-LocalContext {
    # Numbered window sizes up to what the model was trained on; enter takes 64k.
    # Returns $null when the answer is not a size.
    param([int]$Max)
    $sizes = @(@(65536, 131072, 262144) | Where-Object { -not $Max -or $_ -le $Max })
    if (-not $sizes) { $sizes = @($Max) }   # trained on less than 64k: offer all it has
    $notes = @{ 65536 = 'default, fastest'; 131072 = 'bigger tickets, slower'
                262144 = 'slowest -- more of the model spills onto the CPU' }
    Write-Host ""
    Write-Host "  context window (below 64k Claude Code runs out of room and keeps compacting)" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        Write-Host ("   [{0}] {1,4}k  {2}" -f ($i + 1), ($sizes[$i] / 1024), $notes[$sizes[$i]])
    }
    $a = (Read-Host "  context [1], or a size like 96k").Trim().ToLower()
    if (-not $a) { return $sizes[0] }
    if ($a -match '^\d$' -and [int]$a -ge 1 -and [int]$a -le $sizes.Count) { return $sizes[[int]$a - 1] }
    if ($a -match '^(\d+)k$') { return [int]$Matches[1] * 1024 }
    if ($a -match '^\d{4,}$') { return [int]$a }
}

function Read-LocalProject {
    # Recent folders first (enter takes the newest), [b] opens a folder picker,
    # anything else is a pasted path -- Explorer's "Copy as path" quotes included.
    param([string[]]$Recent)
    Write-Host ""
    Write-Host "  project folder" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Recent.Count; $i++) { Write-Host ("   [{0}] {1}" -f ($i + 1), $Recent[$i]) }
    Write-Host "   [b] browse..."
    $hint = if ($Recent) { '[1], b, or paste a path' } else { 'b, or paste a path' }
    $a = (Read-Host "  project $hint").Trim().Trim('"')
    if (-not $a -and $Recent) { return $Recent[0] }
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Recent.Count) { return $Recent[[int]$a - 1] }
    if ($a -eq 'b') {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Project folder for the local model'
        if ($Recent) { $dlg.SelectedPath = $Recent[0] }
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }   # else it can open behind the console
        try { if ($dlg.ShowDialog($owner) -eq 'OK') { return $dlg.SelectedPath } }
        finally { $owner.Dispose(); $dlg.Dispose() }
        return
    }
    $a
}

while ($true) {
    Show-Menu
    $choice = Read-Host "  select"
    $names = Get-ClaudeProfileNames

    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $names.Count) {
        $target = $names[[int]$choice - 1]
        Switch-ClaudeDesktop $target -Launch -Force -IAcceptTheRisk
        Wait-Key
        continue
    }

    switch ($choice.ToLower()) {
        's' { Get-ClaudeProfileStatus; Wait-Key }
        { $_ -in 'r', 'w' } {
            $active = Get-ActiveClaudeDesktopProfile
            if (-not $active) { Write-Host "no active profile" -ForegroundColor DarkYellow; Wait-Key; break }
            if ($_ -eq 'w') { foreach ($n in $names) { Stop-ClaudeMemWorker $n } }
            Start-ClaudeMemWorker $active
            Write-Host ""; Get-ClaudeMemWorkerStatus
            Wait-Key
        }
        'k' {
            Get-ClaudeDesktopProcess | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Host "closed all Claude processes" -ForegroundColor Green
            Wait-Key
        }
        'u' {
            $active = Get-ActiveClaudeDesktopProfile
            if ($active) { Update-ClaudePlugins $active }
            else { Write-Host "no active profile to update" -ForegroundColor DarkYellow }
            Wait-Key
        }
        'l' {
            # Runs in this window and leaves the desktop profile, and its
            # claude-mem worker, alone. /exit returns to the menu.
            try { $models = @(Get-ClaudeLocalModels) }
            catch { Write-Host "Ollama is not answering -- start it first" -ForegroundColor DarkYellow; Wait-Key; break }
            if (-not $models) { Write-Host "no installed Ollama model can call tools -- ollama pull one" -ForegroundColor DarkYellow; Wait-Key; break }
            Write-Host ""
            for ($i = 0; $i -lt $models.Count; $i++) {
                Write-Host ("   [{0}] {1,-48} trained on {2:n0} tokens" -f ($i + 1), $models[$i].Name, $models[$i].Context)
            }
            $pick = Read-Host "  model"
            if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $models.Count) { break }
            $model = $models[[int]$pick - 1]

            $ctx = Read-LocalContext $model.Context
            if (-not $ctx) { Write-Host "not a context size" -ForegroundColor DarkYellow; Wait-Key; break }

            $recentFile = Join-Path $env:USERPROFILE '.claude-local\recent-projects.txt'
            $recent = @(Get-Content -LiteralPath $recentFile -ErrorAction SilentlyContinue |
                        Where-Object { Test-Path -LiteralPath $_ -PathType Container })
            $path = Read-LocalProject $recent
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
                Write-Host "no such folder: $path" -ForegroundColor DarkYellow; Wait-Key; break
            }
            $path = (Resolve-Path -LiteralPath $path).Path
            # Save before the session: closing the window mid-session skips anything after it.
            New-Item -ItemType Directory -Force -Path (Split-Path $recentFile) | Out-Null
            @($path) + ($recent | Where-Object { $_ -ne $path }) | Select-Object -First 5 |
                Set-Content -LiteralPath $recentFile -ErrorAction SilentlyContinue
            Start-ClaudeLocal $model.Name -Context $ctx -Path $path
        }
        'q' { return }
        default { }
    }
}
