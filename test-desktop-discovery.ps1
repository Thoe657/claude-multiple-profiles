$ErrorActionPreference = 'Stop'
$originalEnv = @{}
foreach ($name in 'APPDATA', 'LOCALAPPDATA', 'CLAUDE_DESKTOP_DIR_WORK', 'CLAUDE_CONFIG_DIR') {
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}
# Switch-ClaudeDesktop writes this at user scope; put the real one back after.
$originalUserConfigDir = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-discovery-' + [guid]::NewGuid())
$live = Join-Path $testRoot 'Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude'
try {
    $env:APPDATA = Join-Path $testRoot 'Roaming'
    $env:LOCALAPPDATA = Join-Path $testRoot 'Local'
    $env:CLAUDE_DESKTOP_DIR_WORK = Join-Path $env:LOCALAPPDATA 'Claude-profiles\fullon'
    New-Item -ItemType Directory -Path $env:APPDATA, $env:CLAUDE_DESKTOP_DIR_WORK -Force | Out-Null
    Set-Content (Join-Path $env:CLAUDE_DESKTOP_DIR_WORK 'claude_desktop_config.json') '{}'
    . "$PSScriptRoot\claude-profiles.ps1"
    if ($script:ClaudeDesktopLive) { throw 'Discovery selected saved profile data as the live directory.' }

    New-Item -ItemType Directory -Path (Split-Path $live) -Force | Out-Null
    $missingTarget = Join-Path $env:LOCALAPPDATA 'Claude-profiles\work'
    New-Item -ItemType Directory -Path $missingTarget | Out-Null
    New-Item -ItemType Junction -Path $live -Target $missingTarget | Out-Null
    [IO.Directory]::Delete($missingTarget, $false)
    . "$PSScriptRoot\claude-profiles.ps1"
    if ($script:ClaudeDesktopLive -ne $live -or -not $script:ClaudeDesktopIsMsix) {
        throw 'Discovery missed the broken MSIX junction.'
    }
    function Test-ClaudeDesktopRunning { return $false }
    function Start-ClaudeMemWorker { }   # would stop and start the real workers
    foreach ($name in 'work', 'personal', 'work') {
        Switch-ClaudeDesktop $name -IAcceptTheRisk
        if ((Get-JunctionTarget $live) -ne (Get-ClaudeDesktopProfilePath $name)) {
            throw "Switch to $name failed."
        }
    }
    if (-not (Test-Path (Join-Path $env:CLAUDE_DESKTOP_DIR_WORK 'claude_desktop_config.json'))) {
        throw 'Saved profile data was lost.'
    }
    Write-Host 'PASS: saved profiles excluded; broken MSIX junction discovered; both profiles switch.'
} finally {
    if (Get-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue) {
        [IO.Directory]::Delete($live, $false)
    }
    foreach ($name in $originalEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $originalEnv[$name]) }
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $originalUserConfigDir, 'User')
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
