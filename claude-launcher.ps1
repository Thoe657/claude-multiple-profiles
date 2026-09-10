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
    Write-Host "   [q] quit                 [u] update plugins on active profile" -ForegroundColor DarkGray
    Write-Host ""
}

function Wait-Key { Write-Host ""; Read-Host "enter to continue" | Out-Null }

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
        'q' { return }
        default { }
    }
}
