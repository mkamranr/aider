<#
.SYNOPSIS
    Builds a self-contained, air-gapped aider bundle for Windows x64.

.DESCRIPTION
    Run this on an INTERNET-CONNECTED Windows x64 machine that has a git
    checkout of this repo WITH ITS .git DIRECTORY AND TAGS.

    It produces offline\dist\aider-offline-<ver>-win_amd64-py312-<date>.zip,
    which is copied to the air-gapped target and installed with install.ps1.

    The build deliberately downloads a portable CPython 3.12 FIRST and then
    uses that interpreter to resolve and download the wheelhouse. That is not
    a convenience: requirements.txt was compiled by uv on Linux and is missing
    the Windows-only dependency `colorama` that click declares (it is present
    in requirements/common-constraints.txt but not in requirements.txt). Only a
    genuine Windows resolution at the target ABI pulls it in, so a
    cross-platform `pip download --platform win_amd64 --no-deps` silently
    produces a wheelhouse that ImportErrors on the target with no way to fix
    it there.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File offline\build-bundle.ps1
#>
[CmdletBinding()]
param(
    [string]   $RepoRoot,
    [string]   $OutDir,
    [string]   $PretendVersion,
    [switch]   $AllowDirty,
    [switch]   $IncludeGit,
    [switch]   $KeepStaging
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $OutDir)   { $OutDir   = Join-Path $PSScriptRoot 'dist' }

$spec     = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'bundle-spec.psd1')
$buildDir = Join-Path $PSScriptRoot 'build'
$stage    = Join-Path $buildDir 'stage'
$pyMinor  = ($spec.PythonVersion -split '\.')[0..1] -join '.'

Write-Step "aider air-gapped bundle builder"
Write-Info "repo        : $RepoRoot"
Write-Info "target      : Python $($spec.PythonVersion) / $($spec.PythonTag) / $($spec.Platform)"
Write-Info "staging     : $stage"
Write-Info "output      : $OutDir"

# ---------------------------------------------------------------- 1. preflight
Write-Step "1/9  Preflight"

if (-not [Environment]::Is64BitOperatingSystem) { throw "This builder must run on 64-bit Windows." }
foreach ($exe in @('git', 'tar', 'curl')) {
    $c = Get-Command "$exe.exe" -ErrorAction SilentlyContinue
    if (-not $c) { $c = Get-Command $exe -ErrorAction SilentlyContinue }
    if (-not $c) { throw "Required tool not found on PATH: $exe" }
    Write-Info "found $exe -> $($c.Source)"
}

Invoke-Native 'git' @('-C', $RepoRoot, 'rev-parse', '--is-inside-work-tree') | Out-Null

# setuptools_scm derives the version from tags, and the sdist file list from
# `git ls-files`. Both must work or the wheel is silently broken.
& git -C $RepoRoot fetch --tags --force 2>&1 | Out-Null
$describe = & git -C $RepoRoot describe --tags --dirty 2>&1
if ($LASTEXITCODE -ne 0) {
    if (-not $PretendVersion) {
        throw ("No reachable git tags (git describe failed). setuptools_scm cannot derive a version.`n" +
               "Fix with: git fetch --tags --force   (or re-clone without --depth)`n" +
               "Or pass -PretendVersion 0.86.3")
    }
    Write-Warn "No tags reachable; using -PretendVersion $PretendVersion"
    $env:SETUPTOOLS_SCM_PRETEND_VERSION = $PretendVersion
    $describe = "(pretend:$PretendVersion)"
} else {
    if ($PretendVersion) { $env:SETUPTOOLS_SCM_PRETEND_VERSION = $PretendVersion }
    Write-Info "git describe: $describe"
}

# Untracked/modified files under aider\ will be MISSING from the wheel, because
# the package-data file list comes from setuptools_scm's git file-finder.
$dirty = & git -C $RepoRoot status --porcelain -- aider
if ($dirty -and -not $AllowDirty) {
    throw ("Uncommitted changes under aider\ will be OMITTED from the built wheel`n" +
           "(package data is enumerated by the setuptools_scm git file-finder).`n" +
           "Commit them, or re-run with -AllowDirty if you accept that.`n`n" + ($dirty -join "`n"))
}
$commit = (& git -C $RepoRoot rev-parse HEAD).Trim()
Write-Info "commit      : $commit"

if (Test-Path -LiteralPath $buildDir) { Remove-Item -Recurse -Force -LiteralPath $buildDir }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --------------------------------------------------- 2. portable CPython 3.12
Write-Step "2/9  Portable CPython $($spec.PythonVersion)"

$pbsName = "cpython-$($spec.PythonVersion)+$($spec.PbsTag)-x86_64-pc-windows-msvc-install_only.tar.gz"
$pbsUrl  = "https://github.com/astral-sh/python-build-standalone/releases/download/$($spec.PbsTag)/$pbsName"
$pbsTgz  = Join-Path $buildDir $pbsName

Write-Info "downloading $pbsName"
Invoke-Native 'curl.exe' @('-fsSL', '--retry', '3', '-o', $pbsTgz, $pbsUrl)

$actualSha = Get-Sha256Lower $pbsTgz
if ($actualSha -ne $spec.PbsSha256.ToLower()) {
    throw ("Portable Python hash mismatch (supply-chain check FAILED).`n" +
           "  expected $($spec.PbsSha256)`n  actual   $actualSha")
}
Write-Info "sha256 verified against bundle-spec.psd1"

Invoke-Native 'tar.exe' @('-xzf', $pbsTgz, '-C', $stage)
$bpy = Join-Path $stage 'python\python.exe'
if (-not (Test-Path -LiteralPath $bpy)) { throw "Extraction did not yield $bpy" }

# Fail now, not on the target, if stdlib we depend on is absent.
# sqlite3 backs diskcache (aider/repomap.py); lzma/ctypes/ssl are needed by deps.
$stdlibProbe = @'
import sys, sqlite3, ssl, ctypes, lzma, venv, struct
print("%d.%d|%d" % (sys.version_info[0], sys.version_info[1], struct.calcsize("P") * 8))
'@
$r = Invoke-PyScript -Python $bpy -Source $stdlibProbe
$parts = $r.Output.Split('|')
if ($parts[0] -ne $pyMinor) { throw "Portable Python reports $($parts[0]), expected $pyMinor" }
if ($parts[1] -ne '64')     { throw "Portable Python is $($parts[1])-bit, expected 64-bit" }
Write-Info "portable Python $($parts[0]) $($parts[1])-bit, required stdlib modules present"

# ---------------------------------------------------- 3. build the aider wheel
Write-Step "3/9  Building the aider wheel"

$venvBuild = Join-Path $buildDir 'venv-build'
Invoke-Native $bpy @('-m', 'venv', $venvBuild)
$vbPy = Join-Path $venvBuild 'Scripts\python.exe'

$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
Invoke-Native $vbPy @('-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel', 'build', 'setuptools_scm[toml]')

$distDir = Join-Path $buildDir 'dist'
# Plain `python -m build` (not --wheel): it builds the sdist from the git tree,
# then builds the wheel FROM THE UNPACKED SDIST. setuptools_scm resolves the
# version there from PKG-INFO and the file list is already baked in. This is
# why the repo's own release recipe works where `pip wheel .` on an export does not.
Invoke-Native $vbPy @('-m', 'build', '--outdir', $distDir) $RepoRoot

$wheel = Get-ChildItem -LiteralPath $distDir -Filter 'aider_chat-*-py3-none-any.whl' | Select-Object -First 1
if (-not $wheel) { throw "No aider wheel produced in $distDir" }
$aiderVersion = ($wheel.Name -replace '^aider_chat-', '') -replace '-py3-none-any\.whl$', ''
Write-Info "built aider-chat $aiderVersion"

# `python -m build` leaves its sdist staging tree (aider_chat-<version>\) in the
# repo root, and it is not covered by .gitignore. Clean it up so a build does
# not leave the working tree dirty for the next one.
foreach ($leftover in (Get-ChildItem -LiteralPath $RepoRoot -Directory -Filter 'aider_chat-*' -ErrorAction SilentlyContinue)) {
    Remove-Item -Recurse -Force -LiteralPath $leftover.FullName -ErrorAction SilentlyContinue
    Write-Info "cleaned build leftover $($leftover.Name)"
}

# ------------------------------------------------------- 4. wheel-content gate
Write-Step "4/9  Verifying wheel contents"

$zip   = [System.IO.Compression.ZipFile]::OpenRead($wheel.FullName)
$names = @($zip.Entries | ForEach-Object { $_.FullName })
$zip.Dispose()

$must = @(
    'aider/_version.py',
    'aider/coders/__init__.py',
    'aider/coders/base_coder.py',
    'aider/coders/editblock_coder.py',
    'aider/resources/model-settings.yml',
    'aider/resources/model-metadata.json',
    'aider/queries/tree-sitter-language-pack/python-tags.scm'
)
foreach ($m in $must) {
    if ($names -notcontains $m) {
        throw ("BROKEN WHEEL: missing $m`n" +
               "This is the classic symptom of building without .git present. aider ships its`n" +
               "coders, queries and resources as package data enumerated by setuptools_scm.")
    }
}
$scmCount   = @($names | Where-Object { $_ -like 'aider/queries/*.scm' }).Count
$coderCount = @($names | Where-Object { $_ -like 'aider/coders/*.py' }).Count
if ($scmCount   -lt $spec.MinScmQueries) { throw "BROKEN WHEEL: only $scmCount .scm query files (expected at least $($spec.MinScmQueries))" }
if ($coderCount -lt $spec.MinCoderFiles) { throw "BROKEN WHEEL: only $coderCount coder modules (expected at least $($spec.MinCoderFiles))" }
Write-Info "OK: $scmCount tree-sitter query files, $coderCount coder modules"

# ----------------------------------------------------------- 5. wheelhouse
Write-Step "5/9  Downloading the wheelhouse (native Windows resolution)"

$wh = Join-Path $stage 'wheelhouse'
New-Item -ItemType Directory -Force -Path $wh | Out-Null

# NOTE: no --platform / --python-version / --abi, and no --no-deps.
# We are already running the exact target interpreter, so pip resolves the
# correct ABI and, crucially, evaluates Windows environment markers for real.
# That is what pulls in colorama, which click needs on Windows and which is
# absent from the Linux-compiled requirements.txt.
Write-Info "resolving dependencies of the built wheel"
Invoke-Native $vbPy @('-m', 'pip', 'download', '--only-binary=:all:', '--dest', $wh, $wheel.FullName)

Write-Info "cross-checking against pinned requirements.txt"
Invoke-Native $vbPy @('-m', 'pip', 'download', '--only-binary=:all:', '--dest', $wh, '-r', (Join-Path $RepoRoot 'requirements.txt'))

Write-Info "adding bootstrap wheels (pip / setuptools / wheel)"
Invoke-Native $vbPy @('-m', 'pip', 'download', '--only-binary=:all:', '--dest', $wh, 'pip', 'setuptools', 'wheel')

Copy-Item -LiteralPath $wheel.FullName -Destination $wh -Force

$wheelFiles = @(Get-ChildItem -LiteralPath $wh -Filter '*.whl')
Write-Info ("{0} wheels, {1:N1} MB" -f $wheelFiles.Count, (($wheelFiles | Measure-Object Length -Sum).Sum / 1MB))

if (-not ($wheelFiles | Where-Object { $_.Name -like 'colorama-*' })) {
    Write-Warn "colorama is not in the wheelhouse. click needs it on Windows; the target may ImportError."
}

# ------------------------------------ 6. prove the wheelhouse is self-sufficient
Write-Step "6/9  Offline install rehearsal"

$venvVerify = Join-Path $buildDir 'venv-verify'
Invoke-Native $bpy @('-m', 'venv', $venvVerify)
$vvPy = Join-Path $venvVerify 'Scripts\python.exe'

# Hard guard: even though this machine has internet, the rehearsal must succeed
# with the index disabled, or the bundle is not actually self-contained.
$env:PIP_NO_INDEX = '1'
try {
    Invoke-Native $vvPy @('-m', 'pip', 'install', '--no-index', '--find-links', $wh, "aider-chat==$aiderVersion")
    Invoke-Native $vvPy @('-m', 'pip', 'check')

    $importProbe = @'
import aider, aider.main, aider.commands, aider.repomap, aider.linter
from aider.coders import Coder, EditBlockCoder
from grep_ast.tsl import get_parser
assert get_parser("python") is not None, "tree-sitter python grammar failed to load"
print("import graph OK")
'@
    $r = Invoke-PyScript -Python $vvPy -Source $importProbe
    Write-Info $r.Output

    # aider/__init__.py appends +import / +type / +less / +parse when _version.py
    # is missing or older than the hardcoded floor. A free canary for a half-built wheel.
    $reported = (Invoke-PyScript -Python $vvPy -Source 'import aider;print(aider.__version__)').Output
    if ($reported -match '\+(import|type|less|parse)$') {
        throw "Installed aider reports a degraded version '$reported'. aider/_version.py did not survive the build."
    }
    Write-Info "aider reports version $reported"

    Invoke-Native (Join-Path $venvVerify 'Scripts\aider.exe') @('--version')

    # litellm ships the tiktoken BPE blobs and points TIKTOKEN_CACHE_DIR at its
    # own package dir, so no encoding is fetched from openaipublic at runtime.
    # Assert that is still true for the version we just vendored.
    $tkProbe = @'
import os
import litellm
from importlib import resources
d = str(resources.files(litellm).joinpath("litellm_core_utils/tokenizers"))
# cl100k_base is the encoding litellm falls back to for unknown model names.
print(os.path.isfile(os.path.join(d, "9b5ad71b2ce5302211f9c61530b329a4922fc6a4")))
'@
    $tk = (Invoke-PyScript -Python $vvPy -Source $tkProbe -Soft).Output
    if ($tk -ne 'True') {
        Write-Warn "litellm did not ship the cl100k_base tiktoken blob. The first chat turn may try to reach openaipublic.blob.core.windows.net."
    } else {
        Write-Info "litellm ships the pre-seeded tiktoken cache (no BPE download at runtime)"
    }

    $locks = Join-Path $stage 'locks'
    New-Item -ItemType Directory -Force -Path $locks | Out-Null
    $frozen = & $vvPy -m pip freeze
    Write-TextNoBom -Path (Join-Path $locks 'requirements.locked.txt') -Content ($frozen -join "`n")
    Write-Info "wrote locks\requirements.locked.txt ($($frozen.Count) packages)"
} finally {
    Remove-Item Env:\PIP_NO_INDEX -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- 7. optional git
Write-Step "7/9  Git for Windows"
if ($IncludeGit) {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'git') | Out-Null
    Write-Warn "-IncludeGit only creates the folder. Place PortableGit-*-64-bit.7z.exe in $stage\git\ and re-run with -KeepStaging to include it."
} else {
    Write-Info "skipped (targets already have git; install.ps1 verifies and fails loudly if not)"
}

# --------------------------------------------------- 8. payload, manifest, sums
Write-Step "8/9  Staging payload and manifest"

Copy-Item -Path (Join-Path $PSScriptRoot 'payload\*') -Destination $stage -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lib\Common.ps1') -Destination (Join-Path $stage 'Common.ps1') -Force

# The config templates become files that python-dotenv and aider read with the
# locale codepage, so a BOM or a stray non-ASCII character silently corrupts
# the first entry. install.ps1 refuses such a file; catch it here instead.
foreach ($t in (Get-ChildItem -LiteralPath (Join-Path $stage 'templates') -File)) {
    $enc = Test-AsciiNoBom $t.FullName
    if ($enc -ne 'OK') { throw "Template $($t.Name) is not clean ASCII-without-BOM (got $enc)." }
}
Write-Info "templates are clean ASCII without BOM"

$manifest = [ordered]@{
    bundleFormat     = $spec.BundleFormat
    createdUtc       = (Get-Date).ToUniversalTime().ToString('o')
    builtOnHost      = $env:COMPUTERNAME
    aiderVersion     = $aiderVersion
    aiderGitCommit   = $commit
    aiderGitDescribe = "$describe"
    pythonVersion    = $spec.PythonVersion
    pythonTag        = $spec.PythonTag
    targetPlatform   = $spec.Platform
    pbsTag           = $spec.PbsTag
    pbsSha256        = $spec.PbsSha256
    wheelCount       = $wheelFiles.Count
    wheelhouseBytes  = (($wheelFiles | Measure-Object Length -Sum).Sum)
    scmQueryCount    = $scmCount
    coderModuleCount = $coderCount
    extras           = @($spec.Extras)
    gitIncluded      = [bool]$IncludeGit
}
Write-TextNoBom -Path (Join-Path $stage 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 5)

$sumFile = Join-Path $stage 'SHA256SUMS.txt'
$n = New-ChecksumFile -Root $stage -OutFile $sumFile -ExcludeLeaf @('SHA256SUMS.txt')
Write-Info "SHA256SUMS.txt covers $n files"

# ------------------------------------------------------------------- 9. zip
Write-Step "9/9  Packaging"

$stamp   = Get-Date -Format 'yyyyMMdd'
$zipName = "aider-offline-$aiderVersion-win_amd64-py312-$stamp.zip"
$zipPath = Join-Path $OutDir $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -Force -LiteralPath $zipPath }

[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stage, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

$zipSha = Get-Sha256Lower $zipPath
Write-TextNoBom -Path "$zipPath.sha256" -Content ("{0}  {1}" -f $zipSha, $zipName)

if (-not $KeepStaging) {
    Remove-Item -Recurse -Force -LiteralPath $venvBuild  -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $venvVerify -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath $pbsTgz -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "BUNDLE READY" -ForegroundColor Green
Write-Host ("  file   : {0}" -f $zipPath)
Write-Host ("  size   : {0:N1} MB" -f ((Get-Item $zipPath).Length / 1MB))
Write-Host ("  sha256 : {0}" -f $zipSha)
Write-Host ("  aider  : {0}  ({1})" -f $aiderVersion, $commit.Substring(0, 12))
Write-Host ""
Write-Host "Transfer the .zip and the .sha256 to the air-gapped machine, then run:" -ForegroundColor Cyan
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -VllmUrl http://HOST:8000/v1 -ModelName <served-model-name>"
