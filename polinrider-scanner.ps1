<#
.SYNOPSIS
    PolinRider Malware Scanner v1.2
    https://opensourcemalware.com

.DESCRIPTION
    Scans the filesystem for evidence of PolinRider malware infection.
    PolinRider appends obfuscated JS payloads to config files and uses
    temp_auto_push.bat to amend commits and force-push to GitHub.

    Phase 1 — config file signature scan (both original and rotated Apr 2026 variant)
    Phase 2 — git repository artifact checks (temp_auto_push.bat, config.bat, .gitignore)
    Phase 3 — .vscode/tasks.json TasksJacker check (C2 domains, StakingGame UUID)
    Phase 4 — package.json malicious npm dependency check

.PARAMETER ScanDir
    Directory to scan. Defaults to the current directory.

.PARAMETER Verbose
    Show detailed output for each file checked.

.PARAMETER JsAll
    Scan all .js files, not just known config filenames.

.EXAMPLE
    .\polinrider-scanner.ps1
    .\polinrider-scanner.ps1 C:\Projects
    .\polinrider-scanner.ps1 -Verbose C:\Projects
    .\polinrider-scanner.ps1 -JsAll C:\Projects

.NOTES
    Exit codes:
      0 - No infections found
      1 - Infections found
      2 - Error (invalid path, etc.)
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [string]$ScanDir = "",

    [switch]$JsAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$VERSION = "1.2"

# PolinRider signatures — original variant (Mar 2026)
# In PS double-quoted strings: \ is always literal, `$ is an escaped literal $
$PRIMARY_SIG   = '("rmcej%otb%",2857687)'
$SECONDARY_SIG = "global['!']='8-270-2';var _\`$_1e42="

# PolinRider signatures — rotated variant (Apr 2026, Cot%3t=shtP)
# Architecture identical; all unique fingerprints rotated as an evasion response to the
# published rmcej_otb_payload YARA rule. Both variants are currently active in the wild.
$PRIMARY_SIG_V2   = '("Cot%3t=shtP",1111436)'
$SECONDARY_SIG_V2 = "global['_V']='8-"

# Known config file glob patterns
# Note: App.js (capital A) and app.js are different files on case-sensitive (Linux) filesystems
$CONFIG_PATTERNS = @(
    "*.config.ts"
    "*.config.js"
    "*.config.mjs"
    "*.woff2"
    "App.js"
    "app.js"
    "index.js"
    "truffle.js"
)

# TasksJacker / PolinRider merged cluster — known Vercel-hosted C2 subdomains
# Used in .vscode/tasks.json curl|bash payloads with runOn:folderOpen
$C2_DOMAINS = @(
    "260120.vercel.app"
    "default-configuration.vercel.app"
    "vscode-settings-bootstrap.vercel.app"
    "vscode-settings-config.vercel.app"
    "vscode-bootstrapper.vercel.app"
    "vscode-load-config.vercel.app"
)
$STAKINGAME_UUID = "e9b53a7c-2342-4b15-b02d-bd8b8f6a03f9"

# Known malicious npm packages published by the PolinRider threat actor
$MALICIOUS_PACKAGES = @(
    "tailwindcss-style-animate"
    "tailwind-mainanimation"
    "tailwind-autoanimation"
    "tailwind-animationbased"
    "tailwindcss-typography-style"
    "tailwindcss-style-modify"
    "tailwindcss-animate-style"
)

# Counters — kept separate so files and repo artifacts aren't summed into a meaningless total
$script:InfectedFiles = 0   # files with malware signatures (phase 1)
$script:InfectedRepos = 0   # git repos with malicious artifacts (phase 2)
$script:TotalRepos    = 0

#region Helpers

function Write-Banner {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor White
    Write-Host "  PolinRider Malware Scanner v$VERSION"  -ForegroundColor White
    Write-Host "  https://opensourcemalware.com"         -ForegroundColor White
    Write-Host "========================================" -ForegroundColor White
    Write-Host ""
}

function Test-Signature ([string]$FilePath) {
    # Returns a space-separated string of matched variant labels, or $null if clean.
    # A file can carry both variants simultaneously (re-infection case documented Apr 2026).
    try {
        $content = [System.IO.File]::ReadAllText($FilePath)
        $variants = @()
        if ($content.Contains($PRIMARY_SIG))      { $variants += "v1-primary" }
        if ($content.Contains($SECONDARY_SIG))    { $variants += "v1-secondary" }
        if ($content.Contains($PRIMARY_SIG_V2))   { $variants += "v2-primary" }
        if ($content.Contains($SECONDARY_SIG_V2)) { $variants += "v2-secondary" }
        if ($variants.Count -gt 0) { return ($variants -join " ") }
    } catch {
        # Unreadable file — skip silently
    }
    return $null
}

#endregion

#region Phase 1 — Signature scan

function Invoke-SignatureScan ([string]$ScanPath, [bool]$AllJs) {
    $findingCount = 0

    Write-Verbose "Scanning for signatures under: $ScanPath"

    # Build the set of files to check
    $patterns = $CONFIG_PATTERNS
    if ($AllJs) {
        $patterns = $patterns + "*.js"
    }

    # Collect unique file paths matching any pattern, excluding node_modules/.git
    # Use Ordinal (case-sensitive) on Linux/macOS where the FS is case-sensitive;
    # OrdinalIgnoreCase only on Windows to avoid deduplicating different files
    $comparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } `
                else            { [System.StringComparer]::Ordinal }
    $files = [System.Collections.Generic.HashSet[string]]::new($comparer)

    foreach ($pattern in $patterns) {
        Get-ChildItem -Path $ScanPath -Filter $pattern -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + "node_modules" + [IO.Path]::DirectorySeparatorChar) -and
                $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + ".git"         + [IO.Path]::DirectorySeparatorChar)
            } |
            ForEach-Object { [void]$files.Add($_.FullName) }
    }

    foreach ($file in $files) {
        Write-Verbose "Checking $file"
        $match = Test-Signature $file
        if ($match) {
            Write-Host "  " -NoNewline
            Write-Host "-" -ForegroundColor Red -NoNewline
            Write-Host " $file" -NoNewline
            Write-Host ": PolinRider payload detected ($match)" -ForegroundColor Red
            $findingCount++
            $script:InfectedFiles++
        }
    }

    if ($findingCount -gt 0) {
        Write-Host ""
        Write-Host "[INFECTED]" -ForegroundColor Red -NoNewline
        Write-Host " $findingCount file(s) with malware signatures found"
    } else {
        Write-Verbose "No signature matches found"
    }
}

#endregion

#region Phase 2 — Git artifact checks

function Invoke-GitArtifactCheck ([string]$RepoDir) {
    $findings  = @()

    Write-Verbose "Checking git artifacts: $RepoDir"

    if (Test-Path (Join-Path $RepoDir "temp_auto_push.bat")) {
        $findings += "  - temp_auto_push.bat: Propagation script found"
    }

    if (Test-Path (Join-Path $RepoDir "config.bat")) {
        $findings += "  - config.bat: Hidden orchestrator found"
    }

    $gitignorePath = Join-Path $RepoDir ".gitignore"
    if (Test-Path $gitignorePath) {
        # Use -cmatch (case-sensitive) — .gitignore is case-sensitive on Linux
        $injected = Get-Content $gitignorePath -ErrorAction SilentlyContinue |
            Where-Object { $_ -cmatch '^(config|temp-auto)\.bat$' }
        foreach ($entry in $injected) {
            $findings += "  - .gitignore: '$entry' entry injected"
        }
    }

    # Check git reflog for amend activity (only flag if combined with other findings)
    $gitDir = Join-Path $RepoDir ".git"
    if ((Test-Path $gitDir) -and ($findings.Count -gt 0)) {
        try {
            $reflog = & git -C "$RepoDir" reflog 2>$null
            if ($reflog -match "amend") {
                $findings += "  - git reflog: Amended commits found (consistent with PolinRider behavior)"
            }
        } catch { }
    }

    if ($findings.Count -gt 0) {
        Write-Host ""
        Write-Host "[INFECTED] " -ForegroundColor Red -NoNewline
        Write-Host $RepoDir
        foreach ($line in $findings) {
            Write-Host $line -ForegroundColor Red
        }
        $script:InfectedRepos++
        return $true
    }

    Write-Verbose "Clean: $RepoDir"
    return $false
}

#endregion

#region Phase 3 — tasks.json scan (TasksJacker / PolinRider merged cluster)

function Invoke-TasksJsonScan ([string]$ScanPath) {
    $findingCount = 0

    Write-Verbose "Scanning for malicious tasks.json files under: $ScanPath"

    $taskFiles = Get-ChildItem -Path $ScanPath -Filter "tasks.json" -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            # Only care about .vscode/tasks.json — cross-platform via Directory.Name
            $_.Directory.Name -eq ".vscode" -and
            $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + "node_modules" + [IO.Path]::DirectorySeparatorChar)
        }

    foreach ($taskFile in $taskFiles) {
        Write-Verbose "Checking $($taskFile.FullName)"
        $fileFindings = @()

        try {
            $content = [System.IO.File]::ReadAllText($taskFile.FullName)

            foreach ($domain in $C2_DOMAINS) {
                if ($content.Contains($domain)) {
                    $fileFindings += "C2:$domain"
                }
            }

            if ($content.Contains($STAKINGAME_UUID)) {
                $fileFindings += "StakingGame-UUID"
            }

            # Heuristic: task auto-executes curl/wget when folder is opened
            if (($content -cmatch "folderOpen") -and ($content -cmatch "curl|wget")) {
                $fileFindings += "runOn:folderOpen+curl/wget"
            }
        } catch { }

        if ($fileFindings.Count -gt 0) {
            Write-Host "  " -NoNewline
            Write-Host "-" -ForegroundColor Red -NoNewline
            Write-Host " $($taskFile.FullName)" -NoNewline
            Write-Host ": Malicious tasks.json ($($fileFindings -join ', '))" -ForegroundColor Red
            $findingCount++
            $script:InfectedFiles++
        }
    }

    if ($findingCount -gt 0) {
        Write-Host ""
        Write-Host "[INFECTED]" -ForegroundColor Red -NoNewline
        Write-Host " $findingCount tasks.json file(s) with TasksJacker payload found"
    } else {
        Write-Verbose "No malicious tasks.json found"
    }
}

#endregion

#region Phase 4 — package.json malicious dependency check

function Invoke-PackageJsonScan ([string]$ScanPath) {
    $findingCount = 0

    Write-Verbose "Scanning for malicious npm packages under: $ScanPath"

    $pkgFiles = Get-ChildItem -Path $ScanPath -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + "node_modules" + [IO.Path]::DirectorySeparatorChar) -and
            $_.FullName -notmatch [regex]::Escape([IO.Path]::DirectorySeparatorChar + ".git"         + [IO.Path]::DirectorySeparatorChar)
        }

    foreach ($pkgFile in $pkgFiles) {
        Write-Verbose "Checking $($pkgFile.FullName)"
        $fileFindings = @()

        try {
            $content = [System.IO.File]::ReadAllText($pkgFile.FullName)
            foreach ($pkg in $MALICIOUS_PACKAGES) {
                if ($content.Contains('"' + $pkg + '"')) {
                    $fileFindings += $pkg
                }
            }
        } catch { }

        if ($fileFindings.Count -gt 0) {
            Write-Host "  " -NoNewline
            Write-Host "-" -ForegroundColor Red -NoNewline
            Write-Host " $($pkgFile.FullName)" -NoNewline
            Write-Host ": Malicious npm package(s): $($fileFindings -join ', ')" -ForegroundColor Red
            $findingCount++
            $script:InfectedFiles++
        }
    }

    if ($findingCount -gt 0) {
        Write-Host ""
        Write-Host "[INFECTED]" -ForegroundColor Red -NoNewline
        Write-Host " $findingCount package.json file(s) with malicious npm dependency found"
    } else {
        Write-Verbose "No malicious npm packages found"
    }
}

#endregion

#region Entry point

# Resolve scan directory to an absolute string path
if ([string]::IsNullOrEmpty($ScanDir)) {
    $ScanDir = (Get-Location).Path
}

try {
    # Convert-Path always returns a [string], avoiding PathInfo.Path access entirely
    $ScanDir = Convert-Path $ScanDir
} catch {
    Write-Error "Directory not found or not accessible: $ScanDir"
    exit 2
}

if (-not (Test-Path $ScanDir -PathType Container)) {
    Write-Error "Path exists but is not a directory: $ScanDir"
    exit 2
}

Write-Banner
Write-Host "Scanning: " -NoNewline
Write-Host $ScanDir -ForegroundColor White
Write-Host ""

# Phase 1: config file signature scan (filesystem-wide, not limited to git repos)
Write-Host "Checking config files for malware signatures..."
Invoke-SignatureScan -ScanPath $ScanDir -AllJs $JsAll.IsPresent | Out-Null

# Phase 2: git repository artifact checks
$gitDirs = Get-ChildItem -Path $ScanDir -Filter ".git" -Recurse -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq ".git" }

$script:TotalRepos = ($gitDirs | Measure-Object).Count

if ($script:TotalRepos -gt 0) {
    Write-Host ""
    Write-Host "Checking $($script:TotalRepos) git repositories for artifacts..."
    foreach ($gitDir in $gitDirs) {
        Invoke-GitArtifactCheck -RepoDir $gitDir.Parent.FullName | Out-Null
    }
}

# Phase 3: .vscode/tasks.json TasksJacker check (PolinRider merged cluster)
Write-Host ""
Write-Host "Checking .vscode/tasks.json files for TasksJacker payloads..."
Invoke-TasksJsonScan -ScanPath $ScanDir | Out-Null

# Phase 4: package.json malicious npm dependency check
Write-Host ""
Write-Host "Checking package.json for malicious npm packages..."
Invoke-PackageJsonScan -ScanPath $ScanDir | Out-Null

# Summary
Write-Host ""
Write-Host "========================================"
if ($script:InfectedFiles -gt 0 -or $script:InfectedRepos -gt 0) {
    Write-Host "  RESULTS:" -ForegroundColor Red
    if ($script:InfectedFiles -gt 0) {
        Write-Host "    $($script:InfectedFiles) file(s) with malware signatures" -ForegroundColor Red
    }
    if ($script:InfectedRepos -gt 0) {
        Write-Host "    $($script:InfectedRepos) git repo(s) with malicious artifacts" -ForegroundColor Red
    }
} else {
    Write-Host "  RESULTS: No infections found" -ForegroundColor Green
}
Write-Host "========================================"

if ($script:InfectedFiles -gt 0 -or $script:InfectedRepos -gt 0) {
    Write-Host ""
    Write-Host "REMEDIATION STEPS:"
    Write-Host "1. Remove the obfuscated payload from the end of infected config files"
    Write-Host "   (anything after the legitimate config beginning with global['!'] or global['_V'])"
    Write-Host "   Covers both variants: rmcej%otb% (original) and Cot%3t=shtP (rotated Apr 2026)"
    Write-Host "2. Delete temp_auto_push.bat and config.bat if present"
    Write-Host "3. Remove 'config.bat' from .gitignore"
    Write-Host "4. Remove any malicious .vscode/tasks.json files referencing known C2 subdomains"
    Write-Host "5. Remove malicious npm packages from package.json, then: npm install --package-lock-only"
    Write-Host "6. Check npm global packages and VS Code extensions for the initial dropper"
    Write-Host "7. Rotate all secrets/tokens in scope during any compromised build"
    Write-Host "8. Force-push clean versions to GitHub"
    Write-Host "9. Re-scan periodically — the actor re-infects previously-cleaned repos"
    Write-Host "10. Report to https://opensourcemalware.com"
    Write-Host ""
    exit 1
}

Write-Host ""
exit 0

#endregion
