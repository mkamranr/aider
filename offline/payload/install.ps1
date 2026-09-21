<#
.SYNOPSIS
    Installs aider from an offline bundle onto an air-gapped Windows x64 machine.

.DESCRIPTION
    Run this from inside the unzipped bundle directory. It verifies the
    transfer, installs aider into a private venv from the bundled wheelhouse,
    writes the vLLM configuration, and puts an `aider` launcher on your PATH.

    Nothing in this script reaches the network.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
        -VllmUrl http://10.20.30.40:8000/v1 `
        -ModelName Qwen/Qwen2.5-Coder-32B-Instruct `
        -MaxModelLen 32768
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $VllmUrl,
    [Parameter(Mandatory = $true)][string] $ModelName,
    [int]    $MaxModelLen = 32768,
    [string] $ApiKey = 'sk-vllm-local',
    [ValidateSet('diff', 'diff-fenced', 'whole')]
    [string] $EditFormat = 'diff',
    [string] $ReasoningTag = '',
    [string] $UseTemperature = 'true',
    [string] $InstallDir,
    [switch] $UseSystemPython,
    [switch] $Force,
    [switch] $NoConfig,
    [switch] $NoPathUpdate,
    [switch] $SkipIntegrity
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$bundleRoot = $PSScriptRoot
. (Join-Path $bundleRoot 'Common.ps1')

if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\aider' }

$logFile = Join-Path $env:TEMP ("aider-install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $logFile | Out-Null

try {

Write-Step "aider offline installer"

# ------------------------------------------------------------- 1. preflight
Write-Step "1/8  Preflight"

if (-not [Environment]::Is64BitOperatingSystem) { throw "This bundle is win_amd64; this machine is not 64-bit." }

# Files copied from removable media carry a Mark-of-the-Web that blocks
# execution and can trip AV. Strip it before touching anything.
Get-ChildItem -LiteralPath $bundleRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

$manifestPath = Join-Path $bundleRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json not found. Run this from inside the unzipped bundle." }
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

if ($manifest.bundleFormat -ne 1) {
    throw "Bundle format $($manifest.bundleFormat) is not understood by this installer (expected 1)."
}
Write-Info "aider  : $($manifest.aiderVersion)  ($($manifest.aiderGitCommit.Substring(0,12)))"
Write-Info "python : $($manifest.pythonVersion) $($manifest.pythonTag) $($manifest.targetPlatform)"
Write-Info "built  : $($manifest.createdUtc)"
Write-Info "log    : $logFile"

# Transfer verification. This is the step a security reviewer cares about.
if ($SkipIntegrity) {
    Write-Warn "-SkipIntegrity: the transfer was NOT verified."
} else {
    Write-Info "verifying SHA256SUMS.txt ..."
    $res = Test-Checksums -Root $bundleRoot -ChecksumFile (Join-Path $bundleRoot 'SHA256SUMS.txt')
    if ($res.Bad.Count -gt 0) {
        throw ("Transfer verification FAILED for {0} of {1} files:`n{2}" -f $res.Bad.Count, $res.Total, ($res.Bad -join "`n"))
    }
    Write-Info "$($res.Total)/$($res.Total) files verified"
}

# Aider without git silently drops the repo map and auto-commits, so make the
# missing-git case loud here rather than confusing later.
$gitCmd = Get-Command 'git.exe' -ErrorAction SilentlyContinue
if (-not $gitCmd) { $gitCmd = Get-Command 'git' -ErrorAction SilentlyContinue }
if (-not $gitCmd) {
    throw ("git was not found on PATH.`n" +
           "Aider needs git for the repo map, auto-commits, /undo and /diff; without it`n" +
           "aider silently runs in a degraded mode. Install Git for Windows, reopen the`n" +
           "terminal, and re-run this installer.")
}
Write-Info "git    : $($gitCmd.Source)"

# ----------------------------------------------------- 2. pick an interpreter
Write-Step "2/8  Selecting the Python interpreter"

$wantMinor = ($manifest.pythonVersion -split '\.')[0..1] -join '.'
$basePython = $null

# Returns "3.12|64" or $null. Uses a temp script file rather than -c because
# PowerShell 5.1 mangles native arguments containing both quotes and spaces.
$versionProbe = @'
import sys, struct
print("%d.%d|%d" % (sys.version_info[0], sys.version_info[1], struct.calcsize("P") * 8))
'@
function Test-Candidate {
    param([string]$Exe)
    try {
        $r = Invoke-PyScript -Python $Exe -Source $versionProbe -Soft
        if ($r.ExitCode -ne 0) { return $null }
        return $r.Output
    } catch { return $null }
}

if ($UseSystemPython) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $pyLauncher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $p = & py.exe "-$wantMinor" -c "import sys;print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $p) { $candidates.Add(("$p").Trim()) }
    }
    foreach ($c in (Get-Command 'python.exe' -All -ErrorAction SilentlyContinue)) { $candidates.Add($c.Source) }

    $rejected = New-Object System.Collections.Generic.List[string]
    foreach ($c in $candidates) {
        $v = Test-Candidate $c
        if ($v -eq "$wantMinor|64") { $basePython = $c; break }
        if ($v) { $rejected.Add("  $c  ->  Python $($v.Split('|')[0]), $($v.Split('|')[1])-bit") }
    }
    if (-not $basePython) {
        $msg = "No system Python $wantMinor (64-bit) found.`n"
        if ($rejected.Count -gt 0) { $msg += "Rejected candidates:`n" + ($rejected -join "`n") + "`n" }
        $msg += ("The wheelhouse contains $($manifest.pythonTag) $($manifest.targetPlatform) binary wheels for numpy,`n" +
                 "scipy, tokenizers and pydantic-core, and no sdists, so no other minor version`n" +
                 "can be installed from it. Drop -UseSystemPython to use the bundled Python.")
        throw $msg
    }
    Write-Info "using system Python: $basePython"
} else {
    $bundledPy = Join-Path $bundleRoot 'python\python.exe'
    if (-not (Test-Path -LiteralPath $bundledPy)) { throw "Bundled Python not found at $bundledPy" }
    $basePython = $bundledPy
    Write-Info "using bundled Python: $basePython"
}

# --------------------------------------------------- 3. materialise InstallDir
Write-Step "3/8  Preparing $InstallDir"

$venvDir = Join-Path $InstallDir 'venv'
if ($Force -and (Test-Path -LiteralPath $venvDir)) {
    Write-Info "-Force: removing existing venv"
    Remove-Item -Recurse -Force -LiteralPath $venvDir
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# The bundled interpreter MUST be copied out of the bundle before the venv is
# created: pyvenv.cfg records the absolute path of the base interpreter, so a
# venv built against the USB/extraction directory dies the moment that
# directory goes away.
if (-not $UseSystemPython) {
    $localPy = Join-Path $InstallDir 'python'
    if ($Force -and (Test-Path -LiteralPath $localPy)) { Remove-Item -Recurse -Force -LiteralPath $localPy }
    if (-not (Test-Path -LiteralPath $localPy)) {
        Write-Info "copying portable Python into the install directory"
        Copy-Item -Path (Join-Path $bundleRoot 'python') -Destination $InstallDir -Recurse -Force
    }
    $basePython = Join-Path $localPy 'python.exe'
}

# The wheelhouse stays with the install so repairs and extras do not need the
# original media again.
$localWheelhouse = Join-Path $InstallDir 'wheelhouse'
if (-not (Test-Path -LiteralPath $localWheelhouse)) { New-Item -ItemType Directory -Force -Path $localWheelhouse | Out-Null }
Write-Info "copying wheelhouse ($($manifest.wheelCount) wheels)"
Copy-Item -Path (Join-Path $bundleRoot 'wheelhouse\*.whl') -Destination $localWheelhouse -Force

Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $InstallDir 'bundle-manifest.json') -Force

# --------------------------------------------------------------- 4. the venv
Write-Step "4/8  Creating the virtual environment"

# python -m venv bootstraps pip from ensurepip's bundled wheel, with no
# network. Never use --upgrade-deps, which does fetch from PyPI.
if (-not (Test-Path -LiteralPath (Join-Path $venvDir 'Scripts\python.exe'))) {
    Invoke-Native $basePython @('-m', 'venv', $venvDir)
}
$py = Join-Path $venvDir 'Scripts\python.exe'

# PIP_RETRIES/PIP_TIMEOUT matter more than they look: on an air-gapped LAN
# packets are usually dropped rather than refused, so pip's default 5 retries
# with backoff turn a mistake into a ~15 minute silent hang.
$env:PIP_NO_INDEX                  = '1'
$env:PIP_FIND_LINKS                = $localWheelhouse
$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
$env:PIP_NO_BUILD_ISOLATION        = '1'
$env:PIP_NO_CACHE_DIR              = '1'
$env:PIP_RETRIES                   = '0'
$env:PIP_TIMEOUT                   = '5'
$env:PYTHONNOUSERSITE              = '1'

Copy-Item -LiteralPath (Join-Path $bundleRoot 'templates\pip.ini') -Destination (Join-Path $venvDir 'pip.ini') -Force

# -------------------------------------------------------------- 5. install
Write-Step "5/8  Installing aider $($manifest.aiderVersion)"

Invoke-Native $py @('-m', 'pip', 'install', '--no-index', '--find-links', $localWheelhouse, '--upgrade', 'pip', 'setuptools', 'wheel')
Invoke-Native $py @('-m', 'pip', 'install', '--no-index', '--find-links', $localWheelhouse, "aider-chat==$($manifest.aiderVersion)")
Invoke-Native $py @('-m', 'pip', 'check')

$reported = (Invoke-PyScript -Python $py -Source 'import aider;print(aider.__version__)').Output
if ($reported -match '\+(import|type|less|parse)$') {
    throw "Installed aider reports a degraded version '$reported'. The bundle's wheel is incomplete."
}
Write-Info "aider $reported installed"

# --------------------------------------------------------------- 6. config
Write-Step "6/8  Writing configuration"

if ($NoConfig) {
    Write-Info "skipped (-NoConfig)"
} else {
    # --- normalise inputs ---
    $base = $VllmUrl.TrimEnd('/')
    if ($base -notmatch '^https?://') { throw "-VllmUrl must start with http:// or https:// (got '$VllmUrl')" }
    if ($base -notmatch '/v1$') { $base = "$base/v1" }

    $bare = $ModelName
    if ($bare -like 'openai/*') { $bare = $bare.Substring(7) }
    $full = "openai/$bare"

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "-ApiKey must be non-empty. vLLM rejects an empty Bearer token."
    }

    if ($bare.ToLower() -match 'llama-2|llama-3|replicate') {
        Write-Warn ("The model name '$bare' contains a substring that makes litellm try to fetch a`n" +
                    "    tokenizer from HuggingFace. HF_HUB_OFFLINE=1 makes that fail fast, but the clean`n" +
                    "    fix is on the vLLM side: restart it with e.g.`n" +
                    "      --served-model-name $($bare -replace '[Ll]lama-([23])', 'Llama$1')-local")
    }

    # vLLM rejects prompt_tokens + max_tokens > --max-model-len with a 400.
    # Aider counts with tiktoken, which under-counts a Qwen/Llama BPE on code
    # by 10-25%, so the input budget needs real headroom, not just arithmetic.
    $maxOutput = [int][math]::Min(8192, [math]::Floor([double]$MaxModelLen / 4))
    $maxInput  = [int][math]::Floor(([double]$MaxModelLen - $maxOutput) * 0.90)
    $maxInput  = $maxInput - ($maxInput % 256)
    if ($maxInput -lt 2048) { throw "-MaxModelLen $MaxModelLen is too small to run aider (input budget would be $maxInput tokens)." }
    Write-Info "context: max_model_len=$MaxModelLen -> max_input=$maxInput, max_output=$maxOutput"

    $reasoningBlock = ''
    if ($ReasoningTag) { $reasoningBlock = "  reasoning_tag: $ReasoningTag`n" }

    $editorEditFormat = "editor-$EditFormat"
    if ($EditFormat -eq 'whole') { $editorEditFormat = 'editor-whole' }

    $subs = @{
        '__VLLM_BASE__'          = $base
        '__API_KEY__'            = $ApiKey
        '__FULL_MODEL__'         = $full
        '__BARE_MODEL__'         = $bare
        '__MAX_OUTPUT__'         = "$maxOutput"
        '__MAX_INPUT__'          = "$maxInput"
        '__EDIT_FORMAT__'        = $EditFormat
        '__EDITOR_EDIT_FORMAT__' = $editorEditFormat
        '__USE_TEMPERATURE__'    = $UseTemperature
        '__REASONING_BLOCK__'    = $reasoningBlock
    }

    $targets = @(
        @{ Tmpl = 'env.tmpl';                       Out = '.env' },
        @{ Tmpl = 'aider.conf.yml.tmpl';            Out = '.aider.conf.yml' },
        @{ Tmpl = 'aider.model.settings.yml.tmpl';  Out = '.aider.model.settings.yml' },
        @{ Tmpl = 'aider.model.metadata.json.tmpl'; Out = '.aider.model.metadata.json' }
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($t in $targets) {
        $src = Join-Path $bundleRoot ('templates\' + $t.Tmpl)
        $dst = Join-Path $HOME $t.Out
        $content = [System.IO.File]::ReadAllText($src)
        foreach ($k in $subs.Keys) { $content = $content.Replace($k, $subs[$k]) }

        if (Test-Path -LiteralPath $dst) {
            $bak = "$dst.bak.$stamp"
            Copy-Item -LiteralPath $dst -Destination $bak -Force
            Write-Info "backed up existing $($t.Out) -> $(Split-Path -Leaf $bak)"
        }
        # UTF-8 WITHOUT BOM: python-dotenv does not strip a BOM and aider reads
        # the yaml/json5 files with the locale codepage.
        Write-TextNoBom -Path $dst -Content $content
        $enc = Test-AsciiNoBom $dst
        if ($enc -ne 'OK') { throw "Generated $dst is not clean ASCII-no-BOM (got $enc)." }
        Write-Info "wrote $dst"
    }
}

# ------------------------------------------------------ 7. launcher and PATH
Write-Step "7/8  Launcher and PATH"

$binDir = Join-Path $InstallDir 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$launcher = [System.IO.File]::ReadAllText((Join-Path $bundleRoot 'templates\aider.cmd.tmpl'))
$launcher = $launcher.Replace('__INSTALL_DIR__', $InstallDir)
Write-TextNoBom -Path (Join-Path $binDir 'aider.cmd') -Content $launcher
Write-Info "wrote $binDir\aider.cmd"

if ($NoPathUpdate) {
    Write-Info "PATH not modified (-NoPathUpdate). Add $binDir yourself."
} else {
    # Write the registry value directly with type ExpandString.
    # [Environment]::SetEnvironmentVariable(...,'User') rewrites the value as
    # REG_SZ, permanently flattening any %USERPROFILE%-style entries already in
    # the user's PATH.
    $key = 'HKCU:\Environment'
    $cur = ''
    $prop = Get-ItemProperty -Path $key -Name Path -ErrorAction SilentlyContinue
    if ($prop) { $cur = [string]$prop.Path }

    if ($cur -split ';' -contains $binDir) {
        Write-Info "PATH already contains $binDir"
    } elseif (($cur.Length + $binDir.Length + 1) -gt 1900) {
        Write-Warn "User PATH is near the 2047-character truncation limit; not modifying it. Add $binDir manually."
    } else {
        $new = $binDir
        if ($cur) { $new = ($cur.TrimEnd(';') + ';' + $binDir) }
        Set-ItemProperty -Path $key -Name Path -Value $new -Type ExpandString
        Write-Info "added $binDir to the user PATH (open a NEW terminal to pick it up)"
    }
}

# ------------------------------------------------------------ 8. one-shots
Write-Step "8/8  First-run settling"

$aiderExe = Join-Path $venvDir 'Scripts\aider.exe'

# One combined invocation, and --exit is REQUIRED here. Without it,
# --analytics-disable does its work and then drops into the interactive chat
# loop; run from an installer with no console and no stdin, that hits EOF and
# exits 1, so the opt-out never persists.
#
# This both persists the analytics opt-out (so no later run prints "Analytics
# have been permanently disabled") and, for a release build, records the
# first-run marker in ~/.aider/installs.json so the user's first real run
# loads imports in a background thread rather than synchronously. Note that
# aider/main.py returns early from is_first_run_of_new_version() when the
# version contains ".dev", so the marker is a no-op for dev builds.
$probe = Join-Path $env:TEMP ("aider-firstrun-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $probe | Out-Null
Push-Location $probe
$rc = Invoke-NativeSoft $aiderExe @('--analytics-disable', '--exit', '--no-git', '--yes-always')
Pop-Location
Remove-Item -Recurse -Force -LiteralPath $probe -ErrorAction SilentlyContinue
if ($rc -ne 0) {
    Write-Warn "aider first-run settling returned $rc (continuing; run verify.ps1 for detail)"
} else {
    Write-Info "analytics opt-out persisted"
}

Write-Host ""
Write-Host "INSTALL COMPLETE" -ForegroundColor Green
Write-Host ("  install dir : {0}" -f $InstallDir)
Write-Host ("  launcher    : {0}\aider.cmd" -f $binDir)
Write-Host ("  config      : {0}\.aider.conf.yml (+ .env, .aider.model.settings.yml, .aider.model.metadata.json)" -f $HOME)
Write-Host ("  log         : {0}" -f $logFile)
Write-Host ""
Write-Host "Next: open a NEW terminal, then run the smoke test:" -ForegroundColor Cyan
Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"{0}\verify.ps1`" -VllmUrl {1} -ModelName {2}" -f $bundleRoot, $VllmUrl, $ModelName)

} finally {
    Stop-Transcript | Out-Null
}
