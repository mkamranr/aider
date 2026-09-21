<#
.SYNOPSIS
    Smoke test for an air-gapped aider install.

.DESCRIPTION
    Tier A runs entirely offline and must pass with the network cable out.
    Tier B talks to the vLLM server on the LAN.

    Exits non-zero if any check fails, so it can be run unattended per machine
    and the output pasted into a rollout ticket.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 `
        -VllmUrl http://10.20.30.40:8000/v1 -ModelName Qwen/Qwen2.5-Coder-32B-Instruct
#>
[CmdletBinding()]
param(
    [string] $VllmUrl,
    [string] $ModelName,
    [string] $ApiKey = 'sk-vllm-local',
    [string] $InstallDir,
    [int]    $VersionMaxSeconds = 10,
    [int]    $StartupMaxSeconds = 20,
    [switch] $Quick,
    [switch] $SkipEdit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\aider' }
$py       = Join-Path $InstallDir 'venv\Scripts\python.exe'
$aiderCmd = Join-Path $InstallDir 'bin\aider.cmd'

$script:Failures = New-Object System.Collections.Generic.List[string]
function Pass($m) { Write-Host "[PASS] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:Failures.Add($m) }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Note($m) { Write-Host "       $m" -ForegroundColor DarkGray }

$scratchRoot = Join-Path $env:TEMP ("aider-verify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

Write-Host ""
Write-Host "aider offline verification" -ForegroundColor Cyan
Write-Host "  install dir : $InstallDir"
Write-Host ""

# --------------------------------------------------------------- environment
if (-not (Test-Path -LiteralPath $py)) {
    Fail "no interpreter at $py -- is aider installed at -InstallDir?"
    Write-Host ""
    Write-Host "1 CHECK FAILED" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------- 1. launcher present and fast
Write-Host "-- Tier A: offline --" -ForegroundColor Cyan

if (Test-Path -LiteralPath $aiderCmd) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ver = & $aiderCmd --version 2>&1
    $rc = $LASTEXITCODE
    $sw.Stop()
    if ($rc -ne 0) {
        Fail "aider --version exited $rc : $($ver -join ' ')"
    } else {
        Pass "aider --version -> $(($ver | Select-Object -Last 1))"
    }
    if ($sw.Elapsed.TotalSeconds -gt $VersionMaxSeconds) {
        Fail ("aider --version took {0:N1}s (limit {1}s) -- a network call is stalling startup" -f $sw.Elapsed.TotalSeconds, $VersionMaxSeconds)
        Note "usual causes: AIDER_CHECK_UPDATE not false, or LITELLM_LOCAL_MODEL_COST_MAP not set"
    } else {
        Pass ("aider --version returned in {0:N1}s" -f $sw.Elapsed.TotalSeconds)
    }
} else {
    Fail "launcher not found at $aiderCmd"
}

# --------------------------------------- 2. package data (broken-wheel gate)
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null
$probeAssets = Join-Path $scratchRoot 'probe_assets.py'
$assetsSrc = @'
import sys
from importlib.resources import files

need = [
    "resources/model-settings.yml",
    "resources/model-metadata.json",
    "queries/tree-sitter-language-pack/python-tags.scm",
    "queries/tree-sitter-language-pack/javascript-tags.scm",
]
root = files("aider")
missing = [p for p in need if not root.joinpath(p).is_file()]
qdir = root.joinpath("queries", "tree-sitter-language-pack")
scm = [p for p in qdir.iterdir() if p.name.endswith("-tags.scm")]
print("SCM_COUNT=%d" % len(scm))
if missing:
    print("MISSING=" + ",".join(missing))
    sys.exit(1)
if len(scm) < 20:
    print("MISSING=too-few-scm")
    sys.exit(1)
print("ASSETS_OK")
'@
[System.IO.File]::WriteAllText($probeAssets, $assetsSrc, (New-Object System.Text.UTF8Encoding($false)))
$out = & $py $probeAssets 2>&1
if ($LASTEXITCODE -eq 0) {
    Pass "package data present ($(($out | Where-Object { $_ -like 'SCM_COUNT=*' }) -join ''))"
} else {
    Fail "package data missing: $($out -join ' ')"
    Note "the wheel was probably built from a tree without .git -- rebuild the bundle"
}

# ----------------------------------------------- 3. tree-sitter really loads
$probeTs = Join-Path $scratchRoot 'probe_ts.py'
[System.IO.File]::WriteAllText($probeTs, "from grep_ast.tsl import get_parser`nprint('TS_OK' if get_parser('python') else 'TS_FAIL')`n", (New-Object System.Text.UTF8Encoding($false)))
$out = & $py $probeTs 2>&1
if ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'TS_OK') { Pass "tree-sitter loads the python grammar" }
else { Fail "tree-sitter grammar failed to load: $($out -join ' ')" }

# ---------------------------------------------- 4. config files clean + valid
$cfgs = @('.env', '.aider.conf.yml', '.aider.model.settings.yml', '.aider.model.metadata.json')
foreach ($c in $cfgs) {
    $p = Join-Path $HOME $c
    if (-not (Test-Path -LiteralPath $p)) { Fail "missing config: $p"; continue }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Fail "$c has a UTF-8 BOM -- python-dotenv does not strip it and the first key is lost"
    } elseif (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
        Fail "$c contains non-ASCII bytes -- aider reads it with the system codepage"
    } else {
        Pass "$c present, no BOM, ASCII"
    }
}

# aider splats the settings dict into ModelSettings(**d); any stray key is a
# FATAL startup error. Catch it here instead of interactively.
$probeCfg = Join-Path $scratchRoot 'probe_cfg.py'
$cfgSrc = @'
import sys, pathlib, yaml, json5
from aider.models import ModelSettings

home = pathlib.Path.home()
try:
    data = yaml.safe_load((home / ".aider.model.settings.yml").read_text())
    names = []
    for d in data:
        ModelSettings(**d)
        names.append(d["name"])
    meta = json5.loads((home / ".aider.model.metadata.json").read_text())
    print("SETTINGS=" + ",".join(names))
    print("METADATA=" + ",".join(sorted(meta.keys())))
except Exception as e:
    print("ERR=%s" % e)
    sys.exit(1)
'@
[System.IO.File]::WriteAllText($probeCfg, $cfgSrc, (New-Object System.Text.UTF8Encoding($false)))
$out = & $py $probeCfg 2>&1
$outText = $out -join "`n"
if ($LASTEXITCODE -ne 0) {
    Fail "model settings/metadata invalid: $outText"
    Note "valid ModelSettings fields are defined in aider/models.py"
} else {
    Pass "model settings and metadata parse"
    if ($ModelName) {
        $bare = $ModelName
        if ($bare -like 'openai/*') { $bare = $bare.Substring(7) }
        $full = "openai/$bare"
        if (($outText -split "`n" | Where-Object { $_ -like 'SETTINGS=*' }) -match [regex]::Escape($full)) {
            Pass "settings entry matches openai/$bare"
        } else { Fail "no model-settings entry named '$full' -- aider will fall back to edit_format whole and no repo map" }
        if (($outText -split "`n" | Where-Object { $_ -like 'METADATA=*' }) -match [regex]::Escape($full)) {
            Pass "metadata entry matches openai/$bare"
        } else { Fail "no metadata entry keyed '$full' -- expect 'Unknown context window size'" }
    }
}

# ------------------------------- 5. full startup: timing + no cache writes
$priceCache = Join-Path $HOME '.aider\caches\model_prices_and_context_window.json'
$verCache   = Join-Path $HOME '.aider\caches\versioncheck'
function StampOf($p) { if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p).LastWriteTimeUtc } else { return $null } }
$p0 = StampOf $priceCache
$v0 = StampOf $verCache

$probeDir = Join-Path $scratchRoot 'startup'
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
Push-Location $probeDir
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$startup = & $aiderCmd --exit --no-git --yes-always --verbose 2>&1
$sw.Stop()
Pop-Location

if ($sw.Elapsed.TotalSeconds -gt $StartupMaxSeconds) {
    Fail ("full startup took {0:N1}s (limit {1}s)" -f $sw.Elapsed.TotalSeconds, $StartupMaxSeconds)
} else {
    Pass ("full startup in {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
$joined = $startup -join "`n"
if ($joined -match 'Unknown context window size') {
    Fail "startup says 'Unknown context window size' -- the metadata key does not match the model name"
} else {
    Pass "model metadata resolved (no unknown-context warning)"
}
if ($joined -match 'expects these environment variables') { Fail "aider reports a missing API key environment variable" }

if ($p0 -ne (StampOf $priceCache)) {
    Fail "the litellm price cache was written -- LITELLM_LOCAL_MODEL_COST_MAP is not taking effect"
} else { Pass "no litellm cost-map fetch" }
if ($v0 -ne (StampOf $verCache)) {
    Fail "the versioncheck cache was written -- AIDER_CHECK_UPDATE is not taking effect"
} else { Pass "no PyPI version check" }

# ------------------------------------------- 6. stray repo config shadowing
$gitRoot = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $gitRoot) {
    foreach ($f in @('.env', '.aider.conf.yml', '.aider.model.settings.yml')) {
        $p = Join-Path ($gitRoot -replace '/', '\') $f
        if (Test-Path -LiteralPath $p) { Warn "$p exists and OVERRIDES your home config in this repo" }
    }
}

if ($Quick) {
    Remove-Item -Recurse -Force -LiteralPath $scratchRoot -ErrorAction SilentlyContinue
    Write-Host ""
    if ($script:Failures.Count -eq 0) { Write-Host "TIER A PASSED (-Quick)" -ForegroundColor Green; exit 0 }
    Write-Host ("{0} CHECK(S) FAILED:" -f $script:Failures.Count) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

# ------------------------------------------------------ Tier B: LAN to vLLM
if (-not $VllmUrl) {
    Warn "no -VllmUrl given; skipping the vLLM checks"
} else {
    Write-Host ""
    Write-Host "-- Tier B: LAN to vLLM --" -ForegroundColor Cyan

    $base = $VllmUrl.TrimEnd('/')
    if ($base -notmatch '/v1$') { $base = "$base/v1" }
    $headers = @{ Authorization = "Bearer $ApiKey" }

    $served = $null
    try {
        $models = Invoke-RestMethod -Uri "$base/models" -Headers $headers -TimeoutSec 10 -Method Get
        $served = @($models.data | ForEach-Object { $_.id })
        if ($ModelName) {
            $bare = $ModelName
            if ($bare -like 'openai/*') { $bare = $bare.Substring(7) }
            if ($served -contains $bare) { Pass "vLLM serves '$bare'" }
            else { Fail ("vLLM does NOT serve '{0}'. It serves: {1}" -f $bare, ($served -join ', ')) }
        } else {
            Pass ("vLLM reachable; serves: {0}" -f ($served -join ', '))
        }
    } catch {
        Fail "cannot reach $base/models : $($_.Exception.Message)"
    }

    if ($served) {
        $target = $ModelName
        if ($target -like 'openai/*') { $target = $target.Substring(7) }
        if (-not $target) { $target = $served[0] }
        $payload = @{
            model       = $target
            messages    = @(@{ role = 'user'; content = 'Reply with exactly one word: pong' })
            max_tokens  = 16
            temperature = 0
        } | ConvertTo-Json -Depth 6
        # PowerShell 5.1 sends a string body as ISO-8859-1; send bytes instead.
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        try {
            $resp = Invoke-RestMethod -Method Post -Uri "$base/chat/completions" -Headers $headers `
                -ContentType 'application/json' -Body $bodyBytes -TimeoutSec 120
            Pass "chat/completions responded: '$(($resp.choices[0].message.content).Trim())'"
        } catch {
            Fail "chat/completions failed: $($_.Exception.Message)"
        }
    }

    # ------------------------------------------- 9/10. real edit and repo map
    if (-not $SkipEdit) {
        $repo = Join-Path $scratchRoot 'repo'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        Push-Location $repo
        $enc = New-Object System.Text.UTF8Encoding($false)
        & git init -q
        & git config user.email 'smoke@local'
        & git config user.name  'Aider Smoke Test'
        [System.IO.File]::WriteAllText((Join-Path $repo 'hello.py'), "def greet():`n    pass`n", $enc)
        [System.IO.File]::WriteAllText((Join-Path $repo 'util.py'),  "def helper_alpha(x):`n    return x + 1`n`n`nclass ThingDoer:`n    def do_the_thing(self):`n        return 42`n", $enc)
        & git add .
        & git commit -q -m init

        $before = [System.IO.File]::ReadAllText((Join-Path $repo 'hello.py'))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $aiderCmd --message "In hello.py, change greet() so it returns the string 'hello world'. Do not change anything else." `
            --yes-always --no-auto-commits --no-check-update --no-analytics --no-detect-urls hello.py 2>&1 | Out-Null
        $rc = $LASTEXITCODE
        $sw.Stop()
        $after = [System.IO.File]::ReadAllText((Join-Path $repo 'hello.py'))

        if ($rc -ne 0) { Fail "aider --message exited $rc" }
        elseif ($after -eq $before) { Fail "aider did not modify hello.py (edit format or connectivity problem)" }
        elseif ($after -notmatch 'hello world') { Fail "hello.py changed but does not contain 'hello world'" }
        else { Pass ("one-shot edit applied in {0:N1}s" -f $sw.Elapsed.TotalSeconds) }

        $map = & $aiderCmd --show-repo-map --yes-always --no-check-update --no-analytics 2>&1
        $mapText = $map -join "`n"
        if ($mapText -match 'helper_alpha' -and $mapText -match 'ThingDoer') {
            Pass "repo map generated with symbols (tree-sitter + use_repo_map active)"
        } else {
            Fail "repo map empty or missing symbols -- check use_repo_map: true and the .scm query files"
        }
        Pop-Location
    }
}

Remove-Item -Recurse -Force -LiteralPath $scratchRoot -ErrorAction SilentlyContinue

Write-Host ""
if ($script:Failures.Count -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("{0} CHECK(S) FAILED:" -f $script:Failures.Count) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
