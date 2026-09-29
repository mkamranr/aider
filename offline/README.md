# Air-gapped aider bundle (Windows x64 + vLLM)

Build a single `.zip` on an internet-connected machine, carry it across the air
gap, and install aider on a Windows x64 machine that has **no internet and no
package mirror**. Aider then talks to a **vLLM OpenAI-compatible server on the
LAN** and makes no other outbound calls.

**Prebuilt bundles are published on the
[releases page](https://github.com/mkamranr/aider/releases/latest)** — if one
matches the aider version you want, skip straight to
[section 2, Transfer](#2-transfer). Build your own when you need a newer aider,
a different Python minor version, or an extra.

> **About this directory.** `aider` is developed by Paul Gauthier and the Aider
> contributors at <https://github.com/Aider-AI/aider> (Apache 2.0), with
> documentation at <https://aider.chat>. This `offline/` directory is an
> addition in this fork; it packages upstream aider for air-gapped use and
> changes nothing in the `aider/` package itself. Bugs in aider belong
> upstream; bugs in the bundling belong here.
>
> The line numbers and behaviours cited below were verified against the
> upstream commit this fork is based on. They can drift — re-check them after
> pulling a newer upstream.

| | |
|---|---|
| Target | Windows x64, air-gapped, files-only transfer |
| Python | **Bundled** (portable CPython 3.12) — nothing preinstalled needed |
| Git | **Must already be installed** — the installer fails loudly if not |
| Features | Core: edit, repo map, git, lint. No `/help` RAG, no `/web`, no `--browser` |
| Bundle size | roughly 250–330 MB |

---

## 1. Build (internet-connected Windows x64 machine)

You need a git checkout of this repo **with its `.git` directory and tags**.

```powershell
git fetch --tags --force
powershell -NoProfile -ExecutionPolicy Bypass -File offline\build-bundle.ps1
```

Output lands in `offline\dist\`:

```
aider-offline-<ver>-win_amd64-py312-<date>.zip
aider-offline-<ver>-win_amd64-py312-<date>.zip.sha256
```

### Why the build must see `.git`

Aider ships `aider/coders/`, `aider/queries/**/*.scm` and `aider/resources/`
as **package data**, and `MANIFEST.in` contains only *excludes* — the positive
file list comes from setuptools_scm's git file-finder. Build from an export
with no `.git` and you get a wheel that imports fine but has **no coders, no
repo-map grammars and no model settings**. `build-bundle.ps1` refuses to
proceed without tags, refuses uncommitted changes under `aider\` (they would
be silently omitted), and then unzips the finished wheel and asserts the files
are actually in it.

### Why the build downloads Python before the wheels

`requirements.txt` was compiled by `uv` **on Linux**, so click's Windows-only
dependency `colorama` was dropped from it (it survives only in
`requirements/common-constraints.txt`). A cross-platform
`pip download --platform win_amd64 --no-deps` therefore produces a wheelhouse
that `ImportError`s on the target, where you cannot fix it.

So the builder fetches the portable CPython 3.12 first, hash-verifies it, and
uses **that interpreter** to resolve the wheelhouse natively — correct ABI,
correct Windows environment markers, full dependency closure. It then proves
the result by installing into a throwaway venv with `PIP_NO_INDEX=1` and
running `pip check` plus the real import graph.

### Build options

| Flag | Effect |
|---|---|
| `-PretendVersion 0.86.3` | Use when tags are unreachable. Must be **≥** the floor in `aider/__init__.py`, or aider reports a degraded `…+less` version. |
| `-AllowDirty` | Build with uncommitted changes under `aider\`, accepting that they will be missing from the wheel. |
| `-KeepStaging` | Leave `offline\build\` in place for inspection. |
| `-IncludeGit` | Creates `stage\git\` for you to drop `PortableGit-*-64-bit.7z.exe` into. Not needed here — targets already have git. |

---

## 2. Transfer

Move both the `.zip` and the `.sha256` across. On the target, before
extracting:

```powershell
Get-FileHash -Algorithm SHA256 .\aider-offline-*.zip | Format-List
```

Compare against the `.sha256` file. After extraction, `install.ps1`
independently re-verifies **every file** against the bundle's
`SHA256SUMS.txt`.

---

## 3. Install (air-gapped machine)

Extract the zip, open PowerShell in that folder, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
    -VllmUrl     http://10.20.30.40:8000/v1 `
    -ModelName   Qwen/Qwen2.5-Coder-32B-Instruct `
    -MaxModelLen 32768
```

`-ModelName` is vLLM's `--served-model-name`. Confirm it with:

```powershell
curl.exe -sS -H "Authorization: Bearer sk-vllm-local" http://10.20.30.40:8000/v1/models
```

Then **open a new terminal** (for the PATH change) and run the smoke test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 `
    -VllmUrl http://10.20.30.40:8000/v1 -ModelName Qwen/Qwen2.5-Coder-32B-Instruct
```

### Install options

| Flag | Default | Notes |
|---|---|---|
| `-MaxModelLen` | `32768` | Must match vLLM's `--max-model-len`. Drives the token budget. |
| `-ApiKey` | `sk-vllm-local` | Must be non-empty — vLLM rejects an empty `Bearer`. Match vLLM's `--api-key` if it has one. |
| `-EditFormat` | `diff` | `whole` for models under roughly 14B. |
| `-ReasoningTag` | *(none)* | Set to `think` **only** if vLLM runs *without* `--reasoning-parser`. |
| `-UseTemperature` | `true` | Means temperature 0. Use `0.6` for reasoning models (QwQ, R1 distills, Qwen3 thinking) — temperature 0 sends those into repetition loops. |
| `-InstallDir` | `%LOCALAPPDATA%\Programs\aider` | Keep it short; deep paths plus site-packages can exceed 260 characters. |
| `-UseSystemPython` | off | Requires an existing **3.12 64-bit**. Any other minor version is refused, because the wheelhouse holds `cp312` binary wheels and no sdists. |
| `-Force` | off | Rebuild the venv. Config files are backed up, never clobbered. |
| `-NoConfig`, `-NoPathUpdate`, `-SkipIntegrity` | off | Escape hatches. |

Re-running without `-Force` is safe and idempotent.

---

## 4. What gets written

| Path | Purpose |
|---|---|
| `<InstallDir>\python\` | Portable CPython, copied **out of the bundle** before the venv is made — `pyvenv.cfg` records an absolute base path, so a venv built against the USB drive would die when it is removed |
| `<InstallDir>\venv\` | The aider install |
| `<InstallDir>\wheelhouse\` | Kept for repairs and extras without the original media |
| `<InstallDir>\bin\aider.cmd` | Launcher, added to the **user** PATH |
| `%USERPROFILE%\.env` | Network hardening + endpoint |
| `%USERPROFILE%\.aider.conf.yml` | Model and flag defaults |
| `%USERPROFILE%\.aider.model.settings.yml` | Edit format, repo map, authoritative `api_base` |
| `%USERPROFILE%\.aider.model.metadata.json` | Context window — keeps startup fully offline |

All four config files are written **UTF-8 without BOM, 7-bit ASCII**.
`python-dotenv` has no BOM handling and aider reads the YAML/JSON5 files with
the locale codepage, so a BOM silently destroys the first entry. PowerShell's
`Set-Content -Encoding utf8` writes one — do not hand-edit these with it.

The config lives in your **home directory**, which is the lowest-precedence
location aider searches (home → git root → cwd, last wins), so an individual
repo can still override any of it.

---

## 5. What the hardening actually stops

| Setting | Stops |
|---|---|
| `AIDER_CHECK_UPDATE=false` | `versioncheck.py`'s `requests.get("https://pypi.org/pypi/aider-chat/json")` — **no timeout**, so it blocks for the full OS TCP/DNS timeout. The single worst hang. |
| `LITELLM_LOCAL_MODEL_COST_MAP=True` | `import litellm` fetching its cost map over httpx (5 s each run, synchronous on the first run of a new version). |
| `AIDER_ANALYTICS=false` | The PostHog opt-in prompt (10 % of user IDs get it) and the client. |
| `AIDER_DETECT_URLS=false` | A URL in a prompt offering `/web`, which calls `pypandoc.download_pandoc()` **without asking**. |
| `AIDER_SHOW_RELEASE_NOTES=false` | The first-run release-notes prompt. Not optional: `--yes-always` auto-answers it and launches a browser. |
| `HF_HUB_OFFLINE=1`, `HF_ENDPOINT=http://127.0.0.1:1` | litellm substring-matching `llama-2`/`llama-3` in the model name and reaching for a HuggingFace tokenizer. |
| `NO_PROXY=*` and blanked proxy vars | A stale corporate `HTTPS_PROXY` routing your LAN vLLM traffic at an unreachable proxy. |
| `.aider.model.metadata.json` entry | `ModelInfoManager` falling through to `raw.githubusercontent.com`, plus the 1024-token history/repo-map collapse. |

tiktoken needs nothing: litellm ships the BPE blobs inside its own package and
points `TIKTOKEN_CACHE_DIR` at them. The builder asserts this is still true.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Startup hangs 30–120 s | `versioncheck.py`, no timeout | `AIDER_CHECK_UPDATE=false` in `~/.env`; check no repo `.env` re-enables it |
| Exactly ~5 s pause each run | litellm cost-map fetch | `LITELLM_LOCAL_MODEL_COST_MAP=True` |
| `Unknown context window size and costs` | metadata key ≠ `Model.name` | key must be `openai/<served-model-name>` verbatim; there is no partial match for three-segment names |
| `401` / empty `Bearer` | empty API key | any non-empty `-ApiKey`; match vLLM's `--api-key` if set |
| `404 The model ... does not exist` | name ≠ `--served-model-name` | copy the exact `id` from `/v1/models` |
| `400 maximum context length ... you requested` | `prompt + max_tokens > --max-model-len` | lower `-MaxModelLen`, or drop the `0.90` headroom factor |
| `didn't return a valid edit block` | `diff` too hard, or reasoning text leaking | set `-ReasoningTag think`; check `use_temperature`; then fall back to `-EditFormat whole` |
| Repo map empty | broken wheel, or `use_repo_map` false | `verify.ps1` checks 2 and 10 |
| `ModuleNotFoundError: aider.coders` | wheel built without `.git` | rebuild the bundle |
| First config key ignored | UTF-8 BOM | rewrite without BOM; `verify.ps1` check 4 detects it |
| Works in one repo, hits api.openai.com in another | that repo's `.env` sets `OPENAI_API_BASE` and loads with `override=True` | this is what `extra_params.api_base` immunises against; `verify.ps1` check 6 flags the stray file |
| Scripts blocked | execution policy or Mark-of-the-Web | `-ExecutionPolicy Bypass`; the installer runs `Unblock-File` itself |

---

## 7. Known residual behaviour

- **`aider/report.py`** installs a crash handler that offers to open a GitHub
  issue in a browser. There is no opt-out flag. Offline it simply opens an
  unreachable page — cosmetic, and it auto-accepts under `--yes-always`.
- **litellm's `llama-2`/`llama-3` substring match** has no environment
  variable in this version. `HF_HUB_OFFLINE=1` makes it fail fast and the
  result is `lru_cache`d, so it costs one swallowed exception. The clean fix is
  on the vLLM side: pick a `--served-model-name` without those substrings. The
  installer warns when it sees one.
- Nothing here patches aider. Every high-severity touchpoint has a supported
  off switch, and a fork would need re-validating on every upgrade with no CI.
  Two changes are worth proposing **upstream** instead: a `timeout=` on
  `versioncheck.py`'s `requests.get`, and an opt-out for the crash handler.

---

## 8. Maintenance

```powershell
git fetch --tags --force
git checkout v<new>
powershell -NoProfile -ExecutionPolicy Bypass -File offline\build-bundle.ps1
```

Diff the new `locks\requirements.locked.txt` against the previous bundle's —
anything appearing or disappearing there is the change-log for a security
review. Keep the old `.zip`: installing it with `-Force` is a complete
rollback.

`numpy` and `scipy` are range-pinned rather than `==` pinned in
`requirements.txt`, so two builds on different days can differ. The locked file
is the reproducibility record.

Adding an extra later means a second `pip download -r
requirements/requirements-<extra>.txt` in step 5. Be aware that `help` pulls
`torch` from a separate index (`download.pytorch.org/whl/cpu`) and adds roughly
2.5–3 GB, and `playwright` needs a separate browser-binary transfer.
