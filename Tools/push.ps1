#
# push.ps1
# For every project folder under <RootPath>:
#   1. Initialises a git repo if needed
#   2. Commits any local changes
#   3. Creates the GitHub repo if it doesn't exist
#   4. Pulls remote changes (rebase), then pushes
#   5. If the project has a releases\<version>\ folder, creates / updates
#      a GitHub Release for each valid SEMVER folder and uploads its assets
#
# Prerequisites:
#   - Git installed  (git.exe on PATH or at default location)
#   - gh CLI installed and authenticated  (gh auth login)
#
# Usage:
#   .\push.ps1
#   .\push.ps1 -RootPath D:\Gorstak
#   .\push.ps1 -ProjectFilter GIDE,GEdr
#   .\push.ps1 -SkipCode          # skip git push, only upload releases
#   .\push.ps1 -SkipReleases      # skip release upload, only git push
#   .\push.ps1 -LatestOnly        # only upload the highest version release per project
#   .\push.ps1 -DryRun            # print what would happen, no changes
#
# Automatic conflict resolution:
#   - Local ahead of remote  -> push
#   - Remote ahead of local  -> reset to remote, then push
#   - Both diverged          -> force-with-lease (local wins)
#

param(
    # Repo root when this script lives under Tools\; else script directory
    [string]$RootPath        = $(if ($PSScriptRoot -and ((Split-Path $PSScriptRoot -Leaf) -eq 'Tools')) { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }),
    [string[]]$ProjectFilter = @(),
    [switch]$SkipCode,
    [switch]$SkipReleases,
    [switch]$LatestOnly,
    [switch]$DryRun,
    # Process at most this many projects, starting at -StartAt (0-based).
    # Lets you run the set in chunks so a single invocation never runs too long.
    [int]$StartAt = 0,
    [int]$Take    = 0
)

$ErrorActionPreference = "Continue"

# Never let git/gh block on an interactive credential or editor prompt.
# A blocked child process is the usual cause of the loop appearing to "hang"
# or being killed mid-run. Fail fast instead of waiting on a GUI popup.
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE     = "never"
$env:GIT_PAGER           = "cat"
$env:GIT_EDITOR          = "true"

$SkipFolders = @("releases", ".vscode", ".kiro", ".git", "node_modules")
$Visibility  = "--public"

# GitHub hard file size limit (for git-tracked files only; releases allow 2GB)
$GitHubFileSizeLimit = 2GB

# Only treat a folder under releases\ as a release tag if its name matches semver.
# Examples accepted: 1.0, 1.0.0, 0.5.0, 1.2.3.4, v1.0.0
# Examples rejected: scripts, src, foo, dist
$SemverRegex = '^v?\d+(\.\d+){1,3}([-+][\w.]+)?$'

# ---------------------------------------------------------------------------
# Locate tools
# ---------------------------------------------------------------------------

function Find-Exe([string]$defaultPath, [string]$name) {
    if (Test-Path $defaultPath) { return $defaultPath }
    $found = Get-Command $name -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    return $null
}

$gitPath = Find-Exe "C:\Program Files\Git\cmd\git.exe" "git"
$ghPath  = Find-Exe "C:\Program Files\GitHub CLI\gh.exe" "gh"

if (-not $gitPath) { Write-Host "[ERROR] git not found." -ForegroundColor Red; exit 1 }
if (-not $ghPath)  { Write-Host "[ERROR] gh not found. Run: gh auth login" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

& $gitPath config --global --add safe.directory "*" 2>$null | Out-Null

if (-not (& $gitPath config user.name 2>$null)) {
    & $gitPath config --global user.name "Gorstak"
}
if (-not (& $gitPath config user.email 2>$null)) {
    & $gitPath config --global user.email "gorstak@users.noreply.github.com"
}

$GitHubUser = (& $ghPath api user --jq ".login" 2>$null).Trim()
if (-not $GitHubUser) {
    Write-Host "[ERROR] Not authenticated with gh. Run: gh auth login" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Push (Gorstak) ===" -ForegroundColor Cyan
Write-Host "  User   : $GitHubUser"
Write-Host "  Root   : $RootPath"
if ($SkipCode)     { Write-Host "  Mode   : Releases only (skipping git push)" -ForegroundColor Yellow }
if ($SkipReleases) { Write-Host "  Mode   : Code only (skipping release upload)" -ForegroundColor Yellow }
if ($LatestOnly)   { Write-Host "  Mode   : Latest release only" -ForegroundColor Yellow }
if ($DryRun)       { Write-Host "  Mode   : DRY RUN" -ForegroundColor Yellow }
Write-Host ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Ensure-RepoExists([string]$repoFullName) {
    & $ghPath repo view $repoFullName 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [REPO] Creating $repoFullName ..." -ForegroundColor Yellow
        if (-not $DryRun) {
            & $ghPath repo create $repoFullName $Visibility --confirm 2>$null | Out-Null
        }
    }
}

function Get-RemoteDefaultBranch([string]$repoFullName) {
    $branch = & $ghPath repo view $repoFullName --json defaultBranchRef --jq ".defaultBranchRef.name" 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) { return $branch.Trim() }
    return "main"
}

# Normalise a raw string into a valid GitHub topic:
# lowercase, only [a-z0-9-], collapsed dashes, trimmed, <=35 chars.
function ConvertTo-GhTopic([string]$raw) {
    $t = "$raw".Trim().ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-+', '-'
    $t = $t.Trim('-')
    if ($t.Length -gt 35) { $t = $t.Substring(0, 35).Trim('-') }
    return $t
}

# Curated description + topics per project, keyed by folder/repo name.
# This is the same hand-written metadata the standalone apply script used:
# polished one-line descriptions and 4-7 relevant topics each. Projects not
# listed here fall back to a minimal auto-derive (README first line + name).
# To tweak a repo's description or tags, edit its entry here.
$script:CuratedMeta = @{
    "Sentinel"            = @{ d = "Userland EDR for Windows. ETW telemetry, behavioral correlation, MITRE ATT&CK."; t = @("edr","windows","security","etw","mitre-attack","csharp","threat-detection") }
    "FTTS"                = @{ d = "2D in-browser football tactics previewer."; t = @("football","tactics","simulation","javascript","github-pages","sports") }
    "gorstakssite"        = @{ d = "Static portfolio site for Gorstak's GitHub projects."; t = @("portfolio","static-site","github-pages","html","javascript") }
    "GorstaksAI"          = @{ d = "In-browser LLM chat via WebGPU. No cloud, no API keys."; t = @("webllm","webgpu","llm","in-browser","react","vite","ai") }
    "Notes"               = @{ d = "Personal knowledge base: writings, guides, and documentation."; t = @("notes","knowledge-base","documentation","guides","writing") }
    "DriversGet"          = @{ d = "Windows tray app to fetch the latest official NVIDIA, AMD, and Intel drivers."; t = @("windows","drivers","winforms","csharp","tray-app","dotnet") }
    "SentinelTwo"         = @{ d = "Experimental second line of the Sentinel userland EDR."; t = @("edr","windows","security","experimental") }
    "Guardian"            = @{ d = "Auto-evicts remote intruders on a single-user Windows PC."; t = @("windows","security","intrusion-detection","remote-access","csharp","hardening") }
    "Registry"            = @{ d = "Windows registry packs for security, privacy, and performance."; t = @("windows","registry","security","privacy","hardening","performance") }
    "INF"                 = @{ d = "Windows INF setup scripts and security templates."; t = @("windows","inf","security","scripts","hardening") }
    "Hrvatski"            = @{ d = "Croatian keyboard layout installer for Windows."; t = @("windows","keyboard-layout","croatian","localization") }
    "GTalk"               = @{ d = "Serverless P2P messenger over the BitTorrent DHT. Flutter, all platforms."; t = @("p2p","messenger","bittorrent","dht","flutter","dart","serverless") }
    "GSecurity"           = @{ d = "Windows OEM hardening and first-boot toolkit built on autounattend.xml."; t = @("windows","oem","hardening","security","autounattend","deployment") }
    "GBrowser"            = @{ d = "Privacy-first Python/PyQt6 web browser."; t = @("browser","privacy","python","pyqt6","chromium","qtwebengine") }
    "Ceprkac"             = @{ d = "Chrome-style WebView2 browser for Windows, with ad-block and codecs."; t = @("browser","windows","webview2","csharp","winforms","chromium") }
    "Benchmark"           = @{ d = "Windows system benchmark with health analysis and bottleneck detection."; t = @("benchmark","windows","winforms","csharp","performance","diagnostics") }
    "TrimKit"             = @{ d = "Windows image customizer and debloater. Open-source NTLite alternative."; t = @("windows","wim","iso","debloat","dism","wpf","csharp") }
    "Rainmeter"           = @{ d = "Custom Rainmeter skins for desktop widgets and system monitoring."; t = @("rainmeter","skins","desktop-customization","windows","widgets") }
    "Provisioning"        = @{ d = "Windows provisioning scripts for automated system setup."; t = @("windows","provisioning","scripts","automation") }
    "Infinity"            = @{ d = "Party AI script for Infinity Engine games."; t = @("infinity-engine","baldurs-gate","scripting","game-mod","ai") }
    "Harmony"             = @{ d = "Background binaural/solfeggio tone generator for Windows."; t = @("windows","audio","binaural","tone-generator","csharp","winforms") }
    "GSecurity-Ad-Shield" = @{ d = "Chrome extension for ad-blocking and privacy."; t = @("chrome-extension","adblock","privacy","tracker-blocking","javascript") }
    "GIDE"                = @{ d = "Fully local AI coding assistant for Windows. llama.cpp + Qwen3, no cloud."; t = @("ai","coding-assistant","local-llm","llama-cpp","qwen","csharp","windows") }
    "Troll"               = @{ d = "Detects and removes unauthorized network bridges on Windows."; t = @("windows","network","security","csharp","bridge-removal") }
    "RamCleaner"          = @{ d = "Lightweight Windows memory optimizer using EmptyStandbyList."; t = @("windows","memory","ram","optimization","batch") }
    "Python"              = @{ d = "Windows-focused Python utilities: antivirus, VPN, backup, and more."; t = @("python","windows","utilities","scripts","security") }
    "Powershell"          = @{ d = "PowerShell packs for security, EDR, detection, and hardening."; t = @("powershell","windows","security","edr","detection","hardening") }
    "Policies"            = @{ d = "Windows security baseline via LGPO and Policy Plus."; t = @("windows","group-policy","lgpo","security","baseline","hardening") }
    "PiHole"              = @{ d = "System-wide ad and tracker blocking for Windows via permanent routes."; t = @("windows","adblock","pihole","powershell","networking","privacy") }
    "Pac"                 = @{ d = "PAC-based ad-blocking and GeoBlock proxy configs."; t = @("pac","proxy","adblock","userscript","privacy") }
    "Love4Free"           = @{ d = "Free open-source PHP/MySQL dating platform."; t = @("php","mysql","dating","web","messaging") }
    "Html"                = @{ d = "Small standalone HTML tools and pages."; t = @("html","tools","web","standalone") }
    "Behavedr"            = @{ d = "Behavioral EDR agent with real-time detection and configurable response."; t = @("edr","security","behavioral-detection","threat-detection","cross-platform") }
    "GS"                  = @{ d = "Minimal Windows security baseline installer (GSecurity core)."; t = @("windows","security","lgpo","hardening","baseline","batch") }
    "GPrep"               = @{ d = "Windows post-install optimizer and bulk app installer via Winget."; t = @("windows","powershell","winget","provisioning","optimization","setup") }
    "Debloat"             = @{ d = "NTLite and WinReducer presets for debloating Windows 11 images."; t = @("windows","debloat","ntlite","winreducer","windows-11","deployment") }
    "C"                   = @{ d = "C-based security and ML utilities."; t = @("c","security","machine-learning","antivirus","utilities") }
    "Batch"               = @{ d = "Windows batch scripts for hardening, firewall, and tweaks."; t = @("windows","batch","scripts","hardening","networking","security") }
    "AutoHotkey"          = @{ d = "AutoHotkey script that auto-mutes Discord when it's focused."; t = @("autohotkey","discord","automation","windows","script") }
}

# Minimal fallback for projects not in the curated table: first meaningful
# README line as the description, plus language topics from file extensions.
# Returns @{ description = <string>; topics = <string[]> }.
function Get-DerivedMetadata {
    param([string]$ProjectPath)

    $description = ""
    $readmeFile = Get-ChildItem -Path $ProjectPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^README(\.md|\.txt|\.rst)?$' } |
        Select-Object -First 1

    if ($readmeFile) {
        $lines = Get-Content $readmeFile.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            $l = $line.Trim()
            if (-not $l) { continue }
            if ($l -match '^#{1,6}\s' -or $l -match '^<' -or $l -match '^\|') { continue }
            if ($l -match '^-{3,}$' -or $l -match '^\!\[' -or $l -match '^\[!\[') { continue }
            $l = ($l -replace '^>\s*', '') -replace '\[([^\]]+)\]\([^)]+\)', '$1' -replace '[*_`]', ''
            $l = $l.Trim()
            if ($l) { $description = $l; break }
        }
    }
    if (-not $description) { $description = Split-Path $ProjectPath -Leaf }
    if ($description.Length -gt 250) { $description = $description.Substring(0, 247).TrimEnd() + "..." }

    $topics  = New-Object System.Collections.Generic.List[string]
    $extMap  = @{
        ".cs" = "csharp"; ".csproj" = "dotnet"; ".py" = "python"; ".ps1" = "powershell";
        ".bat" = "batch"; ".cmd" = "batch"; ".dart" = "dart"; ".php" = "php";
        ".js" = "javascript"; ".ts" = "typescript"; ".html" = "html"; ".c" = "c";
        ".cpp" = "cpp"; ".ahk" = "autohotkey"; ".reg" = "registry"; ".inf" = "inf"
    }
    $exts = Get-ChildItem -Path $ProjectPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(\.git|\.github|\.kiro|bin|obj|node_modules)\\' } |
        ForEach-Object { $_.Extension.ToLowerInvariant() } | Select-Object -Unique
    foreach ($e in $exts) {
        if ($extMap.ContainsKey($e)) {
            $tp = ConvertTo-GhTopic $extMap[$e]
            if ($tp -and -not $topics.Contains($tp)) { $topics.Add($tp) | Out-Null }
        }
    }
    return @{ description = $description; topics = @($topics | Select-Object -First 8) }
}

# Applies description + topics to the GitHub repo via `gh repo edit`.
# Source of metadata, in order of precedence:
#   1. Curated table ($script:CuratedMeta), keyed by project name.
#   2. Minimal auto-derive from local contents (for unlisted projects).
# A failed `gh` call logs a warning without aborting the push.
function Set-RepoMetadata {
    param(
        [string]$RepoFullName,
        [string]$ProjectPath
    )

    $projName = Split-Path $ProjectPath -Leaf
    $description = ""
    $topics      = @()
    $source      = ""

    if ($script:CuratedMeta.ContainsKey($projName)) {
        $description = $script:CuratedMeta[$projName].d
        $topics      = @($script:CuratedMeta[$projName].t)
        $source      = "curated"
    } else {
        $derived     = Get-DerivedMetadata -ProjectPath $ProjectPath
        $description  = $derived.description
        $topics       = $derived.topics
        $source       = "auto"
    }

    $editArgs = @("repo", "edit", $RepoFullName)
    $applied  = @()

    if ($description) {
        $editArgs += "--description"; $editArgs += $description
        $applied  += "description"
    }

    $topicCount = 0
    foreach ($raw in $topics) {
        $topic = ConvertTo-GhTopic $raw
        if ($topic) { $editArgs += "--add-topic"; $editArgs += $topic; $topicCount++ }
    }
    if ($topicCount -gt 0) { $applied += "$topicCount topic(s)" }

    if ($applied.Count -eq 0) { return }

    Write-Host "  [META] ($source) $($applied -join ', ')" -ForegroundColor Cyan
    Write-Host "         desc: $description" -ForegroundColor DarkGray
    if ($topicCount -gt 0) {
        $shown = @($topics | ForEach-Object { ConvertTo-GhTopic $_ } | Where-Object { $_ })
        Write-Host "         tags: $($shown -join ', ')" -ForegroundColor DarkGray
    }

    if ($DryRun) {
        Write-Host "  [DRY ] Would run: gh repo edit $RepoFullName ..." -ForegroundColor Yellow
        return
    }

    & $ghPath @editArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK  ] Metadata applied" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] gh repo edit failed (exit $LASTEXITCODE)" -ForegroundColor Yellow
    }
}

function Test-LargeFiles {
    param([string[]]$Files)
    $large = @()
    $ok    = @()
    foreach ($file in $Files) {
        try {
            $size = (Get-Item $file).Length
            if ($size -gt $GitHubFileSizeLimit) {
                $sizeMB = [math]::Round($size / 1MB, 2)
                Write-Host "  [WARN] File exceeds 2GB limit: $(Split-Path $file -Leaf) ($sizeMB MB)" -ForegroundColor Red
                $large += $file
            } else {
                $ok += $file
            }
        } catch {
            $ok += $file
        }
    }
    return @{ Large = $large; Ok = $ok }
}

function Upload-Release {
    param(
        [string]$RepoFullName,
        [string]$Tag,
        [string]$Title,
        [string[]]$Files
    )

    if ($Files.Count -eq 0) {
        Write-Host "  [SKIP] No files for tag $Tag" -ForegroundColor DarkGray
        return
    }

    $check = Test-LargeFiles $Files
    $Files = $check.Ok
    if ($check.Large.Count -gt 0) {
        Write-Host "  [SKIP] $($check.Large.Count) file(s) skipped due to 100MB limit" -ForegroundColor Yellow
    }
    if ($Files.Count -eq 0) {
        Write-Host "  [SKIP] No valid files remaining for tag $Tag" -ForegroundColor DarkGray
        return
    }

    Write-Host "  [TAG ] $Tag  ($($Files.Count) file(s))" -ForegroundColor Cyan
    $Files | ForEach-Object { Write-Host "         + $(Split-Path $_ -Leaf)" -ForegroundColor DarkGray }

    if ($DryRun) {
        Write-Host "  [DRY ] Would upload to $RepoFullName @ $Tag" -ForegroundColor Yellow
        return
    }

    & $ghPath release view $Tag --repo $RepoFullName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [UPD ] Release $Tag exists - replacing assets" -ForegroundColor Yellow
        foreach ($file in $Files) {
            $assetName = Split-Path $file -Leaf
            & $ghPath release upload $Tag $file --repo $RepoFullName --clobber 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK  ] $assetName" -ForegroundColor Green
            } else {
                Write-Host "  [FAIL] $assetName" -ForegroundColor Red
            }
        }
    } else {
        $createArgs = @("release", "create", $Tag) + $Files + @("--repo", $RepoFullName, "--title", $Title, "--notes", "Release $Tag")
        & $ghPath @createArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK  ] Created release $Tag" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Could not create release $Tag" -ForegroundColor Red
        }
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

$projects = Get-ChildItem -Path $RootPath -Directory |
    Where-Object { $_.Name -notin $SkipFolders }

if ($ProjectFilter.Count -gt 0) {
    $projects = $projects | Where-Object { $_.Name -in $ProjectFilter }
    Write-Host "[FILTER] Processing only: $($ProjectFilter -join ', ')" -ForegroundColor Yellow
    Write-Host ""
}

$codeOk    = 0
$codeFail  = 0
$releaseOk = 0

foreach ($project in $projects) {
    $name  = $project.Name
    $fpath = $project.FullName

    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan

    $repoFullName = "$GitHubUser/$name"
    $branch       = "main"

  try {
    # ---- 1. Git push -------------------------------------------------------
    if (-not $SkipCode) {
        Push-Location $fpath
        try {
            $divergenceHandled = $false

            if (-not (Test-Path ".git")) {
                Write-Host "  [INIT] Initialising git repo" -ForegroundColor Yellow
                if (-not $DryRun) { & $gitPath init -b main | Out-Null }
            }

            # Make sure releases/ is never tracked - only published via GitHub Releases
            if (Test-Path "releases") {
                $releasesTracked = & $gitPath ls-files "releases/" 2>$null
                if ($releasesTracked) {
                    Write-Host "  [CLEAN] Untracking releases/ folder..." -ForegroundColor Yellow
                    if (-not $DryRun) {
                        & $gitPath rm -r --cached "releases/" 2>$null | Out-Null
                        & $gitPath commit -m "chore: stop tracking releases/" 2>$null | Out-Null
                    }
                }
            }

            Write-Host "  [ADD ] Staging files..." -ForegroundColor Yellow
            if (-not $DryRun) {
                & $gitPath add . 2>$null | Out-Null
                if (Test-Path "releases") {
                    & $gitPath reset HEAD "releases/" 2>$null | Out-Null
                }
            }

            $status = & $gitPath status --porcelain 2>$null
            if ($status) {
                Write-Host "  [COMMIT] Committing changes" -ForegroundColor Green
                if (-not $DryRun) {
                    & $gitPath commit -m "chore: update" 2>$null | Out-Null
                }
            } else {
                Write-Host "  [INFO] Nothing to commit" -ForegroundColor DarkGray
            }

            # Remote URL
            $expected = "https://github.com/$GitHubUser/$name.git"
            $current  = (& $gitPath remote get-url origin 2>$null)
            if (-not $current) {
                if (-not $DryRun) { & $gitPath remote add origin $expected 2>$null | Out-Null }
            } elseif ($current.Trim() -ne $expected) {
                if (-not $DryRun) { & $gitPath remote set-url origin $expected 2>$null | Out-Null }
            }

            Ensure-RepoExists $repoFullName
            $branch = Get-RemoteDefaultBranch $repoFullName

            # Fetch + rebase pull
            Write-Host "  [FETCH] Fetching origin/$branch..." -ForegroundColor Yellow
            if (-not $DryRun) {
                & $gitPath fetch origin 2>&1 | Out-Null

                $local  = (& $gitPath rev-parse HEAD 2>$null).Trim()
                $remote = (& $gitPath rev-parse "origin/$branch" 2>$null).Trim()

                # If remote branch doesn't exist yet (fresh empty repo), just push directly
                if (-not $remote -or $LASTEXITCODE -ne 0) {
                    Write-Host "  [NEW  ] Remote branch doesn't exist yet - pushing..." -ForegroundColor Yellow
                    & $gitPath push -u origin $branch 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  [OK  ] Pushed $name" -ForegroundColor Green
                        $codeOk++
                    } else {
                        Write-Host "  [FAIL] Push failed for $name" -ForegroundColor Red
                        $codeFail++
                    }
                    $divergenceHandled = $true
                }

                if (-not $divergenceHandled -and $local -ne $remote) {
                    Write-Host "  [PULL ] Rebasing onto origin/$branch..." -ForegroundColor Yellow
                    & $gitPath pull --rebase origin $branch 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        & $gitPath rebase --abort 2>$null | Out-Null

                        $aheadBehind = & $gitPath rev-list --left-right --count "HEAD...origin/$branch" 2>$null
                        $ahead  = 0
                        $behind = 0
                        if ($aheadBehind -match "^(\d+)\s+(\d+)") {
                            $ahead  = [int]$matches[1]
                            $behind = [int]$matches[2]
                        }
                        Write-Host "  [DIVERGED] Local +$ahead, Remote +$behind" -ForegroundColor Yellow

                        if ($ahead -gt 0 -and $behind -eq 0) {
                            Write-Host "  [AUTO ] Local ahead - pushing..." -ForegroundColor Magenta
                            & $gitPath push -u origin $branch 2>&1 | Out-Null
                        } elseif ($behind -gt 0 -and $ahead -eq 0) {
                            Write-Host "  [AUTO ] Remote ahead - resetting to origin/$branch..." -ForegroundColor Yellow
                            & $gitPath reset --hard "origin/$branch" 2>&1 | Out-Null
                            & $gitPath push -u origin $branch 2>&1 | Out-Null
                        } elseif ($ahead -gt 0 -and $behind -gt 0) {
                            Write-Host "  [AUTO ] Both diverged - force-with-lease (local wins)..." -ForegroundColor Magenta
                            & $gitPath push -u origin $branch --force-with-lease 2>&1 | Out-Null
                        } else {
                            Write-Host "  [AUTO ] Unrelated histories - force pushing (local wins)..." -ForegroundColor Magenta
                            & $gitPath push -u origin $branch --force-with-lease 2>&1 | Out-Null
                        }

                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  [OK  ] Pushed $name" -ForegroundColor Green
                            $codeOk++
                        } else {
                            Write-Host "  [FAIL] Push failed for $name" -ForegroundColor Red
                            $codeFail++
                        }
                        # Divergence resolved - skip normal push, but let finally Pop-Location
                        # and fall through to release upload
                        $divergenceHandled = $true
                    }
                }
            }

            if (-not $divergenceHandled) {
                Write-Host "  [PUSH ] Pushing to origin/$branch..." -ForegroundColor Green
                if (-not $DryRun) {
                    & $gitPath push -u origin $branch 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  [OK  ] Pushed $name" -ForegroundColor Green
                        $codeOk++
                    } else {
                        Write-Host "  [FAIL] Push failed: $name" -ForegroundColor Red
                        $codeFail++
                    }
                } else {
                    Write-Host "  [DRY ] Would push $name" -ForegroundColor Yellow
                    $codeOk++
                }
            }
        }
        catch {
            Write-Host "  [ERR ] $_" -ForegroundColor Red
            $codeFail++
        }
        finally {
            Pop-Location
        }

        # ---- 1b. Repo metadata (description + topics) ----------------------
        # Applies the curated description + topics for this project (or a
        # minimal auto-derive for unlisted ones) via `gh repo edit`, after the
        # repo is guaranteed to exist.
        Set-RepoMetadata -RepoFullName $repoFullName -ProjectPath $fpath
    }

    # ---- 2. GitHub Releases ------------------------------------------------
    if (-not $SkipReleases) {
        $releasesDir = Join-Path $fpath "releases"
        if (-not (Test-Path $releasesDir)) { continue }

        $versionDirs = Get-ChildItem -Path $releasesDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $SemverRegex }

        if (-not $versionDirs -or $versionDirs.Count -eq 0) {
            $bad = Get-ChildItem -Path $releasesDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch $SemverRegex }
            if ($bad) {
                Write-Host "  [SKIP] Found non-semver folders in releases/ (ignored): $($bad.Name -join ', ')" -ForegroundColor DarkGray
            }
            continue
        }

        if ($LatestOnly) {
            $versionDirs = $versionDirs |
                Sort-Object { [version]($_.Name -replace '^v', '') } -Descending |
                Select-Object -First 1
            Write-Host "  [LATEST] Only uploading: $($versionDirs.Name)" -ForegroundColor Yellow
        }

        Ensure-RepoExists $repoFullName

        foreach ($versionDir in $versionDirs) {
            $version = $versionDir.Name -replace '^v', ''
            $tag     = "v$version"
            $title   = "$name $version"
            $files   = Get-ChildItem -Path $versionDir.FullName -File -Recurse |
                       Select-Object -ExpandProperty FullName

            Upload-Release -RepoFullName $repoFullName -Tag $tag -Title $title -Files $files
        }
        $releaseOk++
    }
  }
  catch {
      Write-Host "  [ERR ] $name failed: $_" -ForegroundColor Red
      $codeFail++
  }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
if (-not $SkipCode) {
    Write-Host "  Code pushed OK   : $codeOk" -ForegroundColor Green
    if ($codeFail -gt 0) {
        Write-Host "  Code push failed : $codeFail" -ForegroundColor Red
    }
}
if (-not $SkipReleases) {
    Write-Host "  Releases uploaded: $releaseOk project(s)"
}
Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
