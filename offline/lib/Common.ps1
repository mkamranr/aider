# Common helpers shared by build-bundle.ps1 and the payload scripts.
# Windows PowerShell 5.1 compatible: no &&, no ||, no ternary, no ??.

Set-StrictMode -Version 2.0

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ("==> " + $Message) -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host ("    " + $Message)
}

function Write-Warn {
    param([string]$Message)
    Write-Host ("    WARNING: " + $Message) -ForegroundColor Yellow
}

# PowerShell 5.1 does not throw on a non-zero native exit code and has no &&.
# Every external process call must go through this.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkDir = $null,
        [switch]$PassThru
    )
    if ($WorkDir) { Push-Location $WorkDir }
    try {
        if ($PassThru) {
            $out = & $Exe @Arguments 2>&1
            $code = $LASTEXITCODE
        } else {
            & $Exe @Arguments
            $code = $LASTEXITCODE
            $out = $null
        }
    } finally {
        if ($WorkDir) { Pop-Location }
    }
    if ($code -ne 0) {
        throw ("Command failed (exit {0}): {1} {2}" -f $code, $Exe, ($Arguments -join ' '))
    }
    if ($PassThru) { return $out }
}

# Same as Invoke-Native but returns the exit code instead of throwing.
function Invoke-NativeSoft {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkDir = $null
    )
    if ($WorkDir) { Push-Location $WorkDir }
    try {
        & $Exe @Arguments | Out-Null
        $code = $LASTEXITCODE
    } catch {
        $code = 1
    } finally {
        if ($WorkDir) { Pop-Location }
    }
    return $code
}

function Get-Sha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

# PowerShell 5.1 mangles a native-command argument that contains both double
# quotes and spaces, so `python -c "print(\"a b\")"` arrives at Python cut in
# half. Write the source to a temp file and run that instead.
function Invoke-PyScript {
    param(
        [Parameter(Mandatory = $true)][string]$Python,
        [Parameter(Mandatory = $true)][string]$Source,
        [switch]$Soft
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aiderprobe-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".py")
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, ($Source -replace "`r`n", "`n"), $enc)
    try {
        $out = & $Python $tmp
        $code = $LASTEXITCODE
    } finally {
        Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    if ($code -ne 0 -and -not $Soft) {
        throw ("Python probe failed (exit {0}):`n{1}`n--- source ---`n{2}" -f $code, ($out -join "`n"), $Source)
    }
    return [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n").Trim() }
}

# aider/models.py reads config files with the locale codepage and python-dotenv
# does not strip a BOM, so every generated file must be UTF-8 without BOM.
# Set-Content -Encoding utf8 and Out-File both emit a BOM on PowerShell 5.1.
function Write-TextNoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $normalized = $Content -replace "`r`n", "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $enc)
}

function Test-AsciiNoBom {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return "BOM"
    }
    foreach ($b in $bytes) {
        if ($b -gt 127) { return "NONASCII" }
    }
    return "OK"
}

# Turn an absolute path into a root-relative, forward-slash path.
# [char]92 is backslash and [char]47 is forward slash, spelled numerically so
# the source survives any quoting layer and never reaches the regex engine.
function ConvertTo-RelativePosixPath {
    param(
        [Parameter(Mandatory = $true)][string]$RootFull,
        [Parameter(Mandatory = $true)][string]$FullPath
    )
    if ($FullPath.StartsWith($RootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $FullPath.Substring($RootFull.Length)
    } else {
        # Short-name / long-name or junction mismatch: fall back to URI math.
        $rootUri = New-Object System.Uri (($RootFull.TrimEnd([char]92, [char]47)) + [char]92)
        $rel = [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri((New-Object System.Uri $FullPath)).ToString())
    }
    return $rel.TrimStart([char]92, [char]47).Replace([char]92, [char]47)
}

# sha256sum -c compatible: "<lowercase hex><two spaces><forward/slash/path>"
function New-ChecksumFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string[]]$ExcludeLeaf = @()
    )
    # Get-Item, NOT Resolve-Path: Resolve-Path preserves 8.3 short names
    # (C:\Users\MUHAMM~1.RAF\...) while Get-ChildItem returns children under
    # the expanded long name, and the length skew corrupts every relative path.
    $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd([char]92, [char]47)
    $lines = New-Object System.Collections.Generic.List[string]
    $files = Get-ChildItem -LiteralPath $rootFull -Recurse -File | Sort-Object FullName
    foreach ($f in $files) {
        if ($ExcludeLeaf -contains $f.Name) { continue }
        $rel = ConvertTo-RelativePosixPath -RootFull $rootFull -FullPath $f.FullName
        $lines.Add(("{0}  {1}" -f (Get-Sha256Lower $f.FullName), $rel))
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($OutFile, $lines, $enc)
    return $lines.Count
}

function Test-Checksums {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ChecksumFile
    )
    $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd([char]92, [char]47)
    $bad = New-Object System.Collections.Generic.List[string]
    $count = 0
    foreach ($line in [System.IO.File]::ReadAllLines($ChecksumFile)) {
        if (-not $line.Trim()) { continue }
        $idx = $line.IndexOf('  ')
        if ($idx -lt 1) { continue }
        $expected = $line.Substring(0, $idx).Trim().ToLower()
        $rel = $line.Substring($idx + 2).Trim()
        $full = Join-Path $rootFull ($rel.Replace([char]47, [char]92))
        $count = $count + 1
        if (-not (Test-Path -LiteralPath $full)) {
            $bad.Add("MISSING  $rel")
            continue
        }
        $actual = Get-Sha256Lower $full
        if ($actual -ne $expected) { $bad.Add("MISMATCH $rel") }
    }
    return [pscustomobject]@{ Total = $count; Bad = $bad }
}
