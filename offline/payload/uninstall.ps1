<#
.SYNOPSIS
    Removes an offline aider install.

.DESCRIPTION
    Deletes the install directory and the user PATH entry. Config files in your
    home directory are left alone unless -RemoveConfig is given, and per-repo
    artifacts are always left alone.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $InstallDir,
    [switch] $RemoveConfig,
    [switch] $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\aider' }
$binDir = Join-Path $InstallDir 'bin'

Write-Step "aider offline uninstaller"
Write-Info "install dir : $InstallDir"

if (-not (Test-Path -LiteralPath $InstallDir)) {
    Write-Warn "nothing found at $InstallDir"
} else {
    if (-not $Force) {
        $ans = Read-Host "Delete $InstallDir ? [y/N]"
        if ($ans -notmatch '^[Yy]') { Write-Info "aborted"; return }
    }
    if ($PSCmdlet.ShouldProcess($InstallDir, 'Remove')) {
        Remove-Item -Recurse -Force -LiteralPath $InstallDir
        Write-Info "removed $InstallDir"
    }
}

# Rewrite the user PATH, preserving REG_EXPAND_SZ so %VAR% entries survive.
$key = 'HKCU:\Environment'
$prop = Get-ItemProperty -Path $key -Name Path -ErrorAction SilentlyContinue
if ($prop) {
    $cur = [string]$prop.Path
    $parts = @($cur -split ';' | Where-Object { $_ -and ($_ -ne $binDir) })
    $new = ($parts -join ';')
    if ($new -ne $cur) {
        Set-ItemProperty -Path $key -Name Path -Value $new -Type ExpandString
        Write-Info "removed $binDir from the user PATH"
    } else {
        Write-Info "user PATH did not reference $binDir"
    }
}

$cfgs = @('.env', '.aider.conf.yml', '.aider.model.settings.yml', '.aider.model.metadata.json')
if ($RemoveConfig) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($c in $cfgs) {
        $p = Join-Path $HOME $c
        if (Test-Path -LiteralPath $p) {
            Copy-Item -LiteralPath $p -Destination "$p.removed.$stamp" -Force
            Remove-Item -Force -LiteralPath $p
            Write-Info "removed $p (backup kept as $c.removed.$stamp)"
        }
    }
} else {
    Write-Info "config files left in place (pass -RemoveConfig to delete them):"
    foreach ($c in $cfgs) {
        $p = Join-Path $HOME $c
        if (Test-Path -LiteralPath $p) { Write-Info "  $p" }
    }
}

Write-Info "per-repo artifacts (.aider.chat.history.md, .aider.input.history, .aider.tags.cache.v*) are left in your repos on purpose"
Write-Host ""
Write-Host "UNINSTALL COMPLETE" -ForegroundColor Green
