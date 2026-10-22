<#
.SYNOPSIS
    PolinRider Malware Cleaner v2.0 (PowerShell)

.DESCRIPTION
    Finds the latest GitHub force-push activity for an actor and offers to
    restore each affected branch to the commit immediately before that push.

    This script is intentionally interactive before every destructive action.
    It clones the repository into a temporary directory and never changes the
    user's working copy.

.PARAMETER Branches
    Comma-separated branch names to process. If omitted, the latest affected
    branch for each force-push activity result is processed.

.PARAMETER Actor
    GitHub login whose force-push activity should be examined. Defaults to the
    currently authenticated GitHub CLI user.

.PARAMETER Repo
    Repository in owner/repo format. Defaults to the origin of the current
    directory.

.PARAMETER TimePeriod
    GitHub activity window: day, week, month, quarter, or year.

.PARAMETER Since
    Include activity on or after this date (YYYY-MM-DD).

.PARAMETER Until
    Include activity on or before this date (YYYY-MM-DD).

.EXAMPLE
    .\polinrider-cleanup.ps1
    .\polinrider-cleanup.ps1 -Repo theeurbanlegend/polinRiderScanner -Actor octocat
    .\polinrider-cleanup.ps1 -Branches "main,release" -Since 2026-04-01 -Until 2026-04-30

.NOTES
    Exit codes:
      0 - Completed or no restoration was confirmed
      1 - Invalid command-line arguments or missing dependency
      2 - GitHub, Git, or repository operation failed
      3 - Invalid repository or branch input

    Requires PowerShell 7+, Git, and GitHub CLI (gh). Authenticate first with:
      gh auth login
#>
[CmdletBinding()]
param (
    [Alias('b')]
    [string]$Branches = '',

    [Alias('a')]
    [string]$Actor = '',

    [Alias('r')]
    [string]$Repo = '',

    [Alias('t')]
    [ValidateSet('day', 'week', 'month', 'quarter', 'year')]
    [string]$TimePeriod = '',

    [Alias('s')]
    [string]$Since = '',

    [Alias('u')]
    [string]$Until = '',

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Version = '2.0'
$GitHubApiVersion = '2026-03-10'
$TempDirectory = $null

# Keep colors readable in redirected output and in terminals that do not
# support ANSI escape sequences.
$UseColor = $Host.UI.RawUI -and $Host.Name -notmatch 'ServerRemoteHost'

function Write-ErrorMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Red
}

function Write-SuccessMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-WarningMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Confirm-Action {
    param([Parameter(Mandatory)][string]$Prompt)

    # A blank answer is deliberately treated as "no".
    do {
        $answer = Read-Host "$Prompt [y/N]"
    } while ($answer -notmatch '^(?i:y(?:es)?|n(?:o)?)?$')

    return $answer -match '^(?i:y(?:es)?)$'
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    # Passing an argument array avoids shell interpretation of branch names
    # and repository values.
    $output = & $FilePath @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Out-String).Trim()
        throw "'$FilePath' failed with exit code $LASTEXITCODE. $details"
    }

    return $output
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [string]$JqQuery = ''
    )

    $arguments = @(
        'api',
        '--header', 'Accept: application/vnd.github+json',
        '--header', "X-GitHub-Api-Version: $GitHubApiVersion",
        $Endpoint
    )
    if ($JqQuery) {
        $arguments += @('--jq', $JqQuery)
    }

    try {
        return (Invoke-NativeCommand -FilePath 'gh' -ArgumentList $arguments | Out-String).Trim()
    } catch {
        throw "GitHub CLI request failed: $($_.Exception.Message)"
    }
}

function Get-RepositoryFromOrigin {
    $remote = (Invoke-NativeCommand -FilePath 'git' -ArgumentList @('remote', 'get-url', 'origin') |
        Out-String).Trim()

    # Accept HTTPS and SSH GitHub remotes, while rejecting non-GitHub remotes.
    if ($remote -match 'github\.com[/:](?<repository>[^/]+/[^/#?]+?)(?:\.git)?$') {
        return $Matches.repository
    }

    throw "The origin remote is not a GitHub repository: $remote"
}

function Convert-DateFilter {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [switch]$EndOfDay
    )

    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}$') {
        throw "$Name must use YYYY-MM-DD format: $Value"
    }

    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $Value,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$parsed)) {
        throw "$Name is not a valid calendar date: $Value"
    }

    if ($EndOfDay) {
        $parsed = $parsed.Date.AddDays(1).AddTicks(-1)
    }

    return [DateTimeOffset]$parsed
}

function Get-RepoActivity {
    param([string]$Branch = '')

    $query = "/repos/$script:CurrentRepo/activity?activity_type=force_push&actor=$script:ForcePushActor&per_page=100"
    if ($Branch) { $query += "&ref=$([uri]::EscapeDataString($Branch))" }
    if ($script:TimePeriod) { $query += "&time_period=$script:TimePeriod" }

    $events = @(Invoke-GitHubApi -Endpoint $query | ConvertFrom-Json)
    $filtered = foreach ($event in $events) {
        $timestamp = [DateTimeOffset]::Parse($event.timestamp)
        if ($script:FromDate -and $timestamp -lt $script:FromDate) { continue }
        if ($script:ToDate -and $timestamp -gt $script:ToDate) { continue }

        [pscustomobject]@{
            before    = [string]$event.before
            after     = [string]$event.after
            ref       = ([string]$event.ref) -replace '^refs/heads/', ''
            timestamp = $timestamp
        }
    }

    # GitHub activity can contain multiple events for one branch. Preserve the
    # Bash script's behavior by retaining the newest event for each branch.
    $latestByBranch = @($filtered | Group-Object ref | ForEach-Object {
        $_.Group | Sort-Object timestamp -Descending | Select-Object -First 1
    })

    return $latestByBranch
}

function Restore-ForcePushedBranch {
    param(
        [Parameter(Mandatory)][string]$RepositoryDirectory,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$BeforeCommit,
        [Parameter(Mandatory)][string]$AfterCommit
    )

    if (-not (Test-Path $RepositoryDirectory -PathType Container)) {
        throw "The temporary Git directory is invalid: $RepositoryDirectory"
    }

    $comparison = Invoke-GitHubApi -Endpoint "/repos/$script:CurrentRepo/compare/$AfterCommit...$Branch" -JqQuery '.status'
    if ($comparison -eq 'identical') {
        Write-SuccessMessage "Branch $Branch is unchanged since the force push."
    } else {
        Write-WarningMessage "Branch $Branch has drifted since the force push; reviewing changes:"
        Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $RepositoryDirectory, 'fetch', 'origin', $Branch) | Out-Null
        Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $RepositoryDirectory, 'fetch', 'origin', $AfterCommit) | Out-Null
        Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $RepositoryDirectory, 'diff', '--stat', "$AfterCommit..origin/$Branch") |
            ForEach-Object { Write-Host $_ }
    }

    if (-not (Confirm-Action -Prompt "Restore '$Branch' to $BeforeCommit and force-push it? This is destructive")) {
        Write-WarningMessage "Skipped branch $Branch."
        return
    }

    Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $RepositoryDirectory, 'fetch', 'origin', $BeforeCommit) | Out-Null
    Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $RepositoryDirectory, 'checkout', '-B', $Branch, "origin/$Branch") | Out-Null
    Invoke-NativeCommand -FilePath 'git' -ArgumentList @('-C', $RepositoryDirectory, 'reset', '--hard', $BeforeCommit) | Out-Null

    # The user has explicitly confirmed the restoration, so use the same
    # unconditional force-push behavior as the Bash implementation.
    Invoke-NativeCommand -FilePath 'git' -ArgumentList @(
        '-C', $RepositoryDirectory, 'push', '-f', 'origin', "HEAD:$Branch"
    ) | Out-Null

    Write-SuccessMessage "Branch $Branch restored successfully."
}

function Show-Help {
    Get-Help -Detailed $PSCommandPath
}

function Write-Banner {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor White
    Write-Host "  PolinRider Malware Cleaner v$Version" -ForegroundColor White
    Write-Host '  https://opensourcemalware.com' -ForegroundColor White
    Write-Host '========================================' -ForegroundColor White
    Write-Host ''
}

try {
    if ($Help) {
        Show-Help
        exit 0
    }

    if ($Repo -and $Repo -notmatch '^[^/]+/[^/]+$') {
        throw "Repo must use owner/repo format: $Repo"
    }
    if ($Branches -and $Branches -match '(^,|,$|,,)') {
        throw 'Branches must be a comma-separated list without empty entries.'
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required. Install it from https://cli.github.com/ and run gh auth login.'
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is required. Install Git for Windows from https://git-scm.com/download/win.'
    }

    $script:CurrentRepo = if ($Repo) { $Repo.Trim() } else { Get-RepositoryFromOrigin }
    $script:ForcePushActor = if ($Actor) { $Actor.Trim() } else { Invoke-GitHubApi -Endpoint '/user' -JqQuery '.login' }
    if (-not $script:ForcePushActor) { throw 'The GitHub actor cannot be empty.' }
    $script:FromDate = if ($Since) { Convert-DateFilter -Value $Since.Trim() -Name 'Since' } else { $null }
    $script:ToDate = if ($Until) { Convert-DateFilter -Value $Until.Trim() -Name 'Until' -EndOfDay } else { $null }
    if ($script:FromDate -and $script:ToDate -and $script:FromDate -gt $script:ToDate) {
        throw 'Since cannot be later than Until.'
    }

    $branchesToProcess = @()
    if ($Branches) {
        $branchesToProcess = @($Branches.Split(',') | ForEach-Object {
            $branch = $_.Trim()
            if (-not $branch) { throw 'Branches cannot contain empty names.' }
            $branch
        })
    }

    Write-Banner
    Write-Host "Repository: $script:CurrentRepo"
    Write-Host "Actor:      $script:ForcePushActor"
    if ($script:FromDate) { Write-Host "Since:      $script:FromDate" }
    if ($script:ToDate) { Write-Host "Until:      $script:ToDate" }
    Write-Host ''

    $TempDirectory = Join-Path ([IO.Path]::GetTempPath()) "polinrider-cleanup-$([Guid]::NewGuid().ToString('N'))"
    New-Item -Path $TempDirectory -ItemType Directory -Force | Out-Null
    Write-Host "Cloning repository into temporary directory..."
    Invoke-NativeCommand -FilePath 'git' -ArgumentList @('clone', "https://github.com/$script:CurrentRepo.git", $TempDirectory) | Out-Null

    $events = if ($branchesToProcess.Count -gt 0) {
        foreach ($branch in $branchesToProcess) {
            Get-RepoActivity -Branch $branch
        }
    } else {
        Get-RepoActivity
    }

    Write-Host "Latest affected activities found: $(@($events).Count)"
    for ($index = 0; $index -lt @($events).Count; $index++) {
        $event = @($events)[$index]
        Write-Host ''
        Write-Host "$($index + 1): Looking into branch $($event.ref)..."
        Restore-ForcePushedBranch -RepositoryDirectory $TempDirectory -Branch $event.ref `
            -BeforeCommit $event.before -AfterCommit $event.after
    }
} catch {
    Write-ErrorMessage $_.Exception.Message
    exit 2
} finally {
    if ($TempDirectory -and (Test-Path $TempDirectory)) {
        Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Write-SuccessMessage 'Cleaned up temporary repository resources.'
    }
}
