@echo off
rem Double-click this. The launcher is dot-sourced, not run as a child script:
rem see the comment at the top of claude-launcher.ps1 for why that matters.
rem The profile is loaded on purpose -- CLAUDE_PROFILE_DIR_* overrides live there.
powershell.exe -ExecutionPolicy Bypass -NoLogo -Command ". '%~dp0claude-launcher.ps1'"
