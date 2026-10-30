<#
.SYNOPSIS
  Upload the sagit port to GitHub through the REST API (no git, no github.com
  HTTPS needed) and run the XNU macOS workflow.

.DESCRIPTION
  This PC can reach api.github.com but not github.com, so a normal `git push`
  fails. This script creates the repository, uploads every source file as Git
  blobs, creates one commit on `main`, dispatches `.github/workflows/xnu.yml`
  and downloads the resulting kernel artifact.

  You need a classic GitHub PAT with `repo` and `workflow` scopes. The token is
  only kept in memory by this process; revoke it when the build is done.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\upload-to-github.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoName = "ios16_on_sagit_mi6",
    [ValidateSet("public", "private")]
    [string]$Visibility = "public",
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$KernelConfig = "DEVELOPMENT",
    [string]$MachineConfig = "SWEET",
    [switch]$NoRun
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail($msg) { Write-Host "[x] $msg" -ForegroundColor Red; exit 1 }
function Info($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }

$user = Read-Host "GitHub username"
if (-not $user) { Fail "username required" }
$sec = Read-Host "Paste the PAT (input hidden)" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
if (-not $token) { Fail "token required" }

$headers = @{
    Authorization          = "Bearer $token"
    "User-Agent"           = "sagit-port-uploader"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Api {
    param([string]$Method, [string]$Path, $Body = $null)
    $p = @{ Uri = "https://api.github.com$Path"; Method = $Method; Headers = $headers; TimeoutSec = 120 }
    if ($null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $p.ContentType = "application/json"
    }
    return Invoke-RestMethod @p
}

try { $me = Api GET "/user" } catch { Fail "token rejected: $($_.Exception.Message)" }
Info "authenticated as $($me.login)"

# --- repository -----------------------------------------------------------
$repoPath = "/repos/$user/$RepoName"
try {
    $repo = Api POST "/user/repos" @{
        name        = $RepoName
        private     = ($Visibility -eq "private")
        auto_init   = $false
        description = "iOS 16 / XNU port for Xiaomi Mi 6 (sagit, MSM8998)"
        has_issues  = $true
    }
    Info "created $($repo.full_name) ($Visibility)"
} catch {
    try { $repo = Api GET $repoPath; Info "using existing $($repo.full_name)" }
    catch { Fail "cannot create or open ${user}/${RepoName}: $($_.Exception.Message)" }
}

# --- blobs ----------------------------------------------------------------
$rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$skip = '^(\.git|out|dist|xnu/out|xnu/out-|__pycache__)(/|$)'
$files = Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
    ($rel -notmatch $skip) -and ($rel -notmatch '(^|/)__pycache__(/|$)') -and
    ($_.Extension -notin @('.pyc', '.log')) -and ($rel -ne 'scripts')
}
Info "uploading $($files.Count) files ($([math]::Round((($files | Measure-Object Length -Sum).Sum)/1MB,1)) MB)"

$entries = New-Object System.Collections.ArrayList
$n = 0
foreach ($f in $files) {
    $rel = $f.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
    try {
        $blob = Api POST "/repos/$user/$RepoName/git/blobs" @{ content = $b64; encoding = "base64" }
    } catch {
        Fail "blob upload failed for ${rel}: $($_.Exception.Message)"
    }
    $mode = if ($f.Extension -in @('.sh', '.py')) { "100755" } else { "100644" }
    [void]$entries.Add(@{ path = $rel; mode = $mode; type = "blob"; sha = $blob.sha })
    $n++
    if ($n % 20 -eq 0) { Write-Host "    $n/$($files.Count)" }
    if ($n % 10 -eq 0) { Start-Sleep -Milliseconds 80 }
}

# --- tree, commit, branch -------------------------------------------------
Info "creating tree/commit"
try {
    $tree = Api POST "/repos/$user/$RepoName/git/trees" @{ tree = $entries.ToArray() }
} catch {
    Fail "tree creation failed (token needs 'repo' + 'workflow' for .github/workflows): $($_.Exception.Message)"
}
$parents = @()
try {
    $oldRef = Api GET "/repos/$user/$RepoName/git/ref/heads/main"
    $parents = @($oldRef.object.sha)
    Info "reusing existing main ($($oldRef.object.sha.Substring(0,12))) as parent"
} catch { }
try {
    $commit = Api POST "/repos/$user/$RepoName/git/commits" @{
        message = "sagit: iOS 16/XNU port for Xiaomi Mi 6 (MSM8998)"
        tree    = $tree.sha
        parents = $parents
    }
} catch {
    Fail "commit failed (classic PAT must have BOTH 'repo' and 'workflow' scopes): $($_.Exception.Message)"
}
if ($parents.Count -eq 0) {
    Api POST "/repos/$user/$RepoName/git/refs" @{ ref = "refs/heads/main"; sha = $commit.sha } | Out-Null
} else {
    Api PATCH "/repos/$user/$RepoName/git/refs/heads/main" @{ sha = $commit.sha; force = $true } | Out-Null
}
Api PATCH $repoPath @{ default_branch = "main" } | Out-Null
Info "pushed commit $($commit.sha.Substring(0,12)) to main"

if ($NoRun) { Write-Host "repo ready: https://github.com/$user/$RepoName"; exit 0 }

# --- dispatch + wait ------------------------------------------------------
Info "dispatching xnu workflow (machine=$MachineConfig, config=$KernelConfig)"
$dispatched = $false
for ($try = 1; $try -le 8 -and -not $dispatched; $try++) {
    try {
        Api POST "/repos/$user/$RepoName/actions/workflows/xnu.yml/dispatches" @{
            ref    = "main"
            inputs = @{
                macos_version  = "13.5"
                kernel_config  = $KernelConfig
                machine_config = $MachineConfig
                keep_going     = "true"
            }
        } | Out-Null
        $dispatched = $true
    } catch {
        Write-Host "    dispatch attempt $try failed: $($_.Exception.Message)"
        Start-Sleep -Seconds 10
    }
}
if (-not $dispatched) {
    Fail @"
workflow dispatch failed. Check:
  - repository Settings -> Actions -> General -> 'Allow all actions' is selected
  - the token has the 'workflow' scope
  - open https://github.com/$user/$RepoName/actions manually
"@
}

$run = $null
for ($i = 0; $i -lt 20 -and -not $run; $i++) {
    Start-Sleep -Seconds 6
    try {
        $runs = Api GET "/repos/$user/$RepoName/actions/runs?event=workflow_dispatch&per_page=5"
        $run = $runs.workflow_runs | Where-Object { $_.head_sha -eq $commit.sha } | Select-Object -First 1
    } catch { }
}
if (-not $run) { Fail "workflow did not appear; open https://github.com/$user/$RepoName/actions" }
Info "run: $($run.html_url)"

$deadline = (Get-Date).AddMinutes(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    $run = Api GET "/repos/$user/$RepoName/actions/runs/$($run.id)"
    Write-Host ("    {0}  {1}  {2}" -f $run.status, $run.conclusion, (Get-Date -Format HH:mm:ss))
    if ($run.status -eq "completed") { break }
}
if ($run.status -ne "completed") { Fail "timed out; see $($run.html_url)" }
if ($run.conclusion -ne "success") { Fail "build $($run.conclusion); logs: $($run.html_url)" }

# --- download artifact ----------------------------------------------------
Info "downloading xnu-kernel artifact"
$arts = Api GET "/repos/$user/$RepoName/actions/runs/$($run.id)/artifacts"
$art = $arts.artifacts | Where-Object { $_.name -eq "xnu-kernel" } | Select-Object -First 1
if (-not $art) { Fail "no xnu-kernel artifact; inspect $($run.html_url)" }

$zip = Join-Path $env:TEMP "xnu-kernel-$($run.id).zip"
Invoke-WebRequest -Uri $art.archive_download_url -Headers $headers -OutFile $zip -UseBasicParsing -TimeoutSec 600
$dst = Join-Path $rootFull "xnu\out"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
$tmp = Join-Path $env:TEMP "xnu-kernel-$($run.id)"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
$kernel = Get-ChildItem $tmp -Recurse -File | Where-Object { $_.Name -like "kernel.*" } | Select-Object -First 1
if (-not $kernel) { Fail "artifact has no kernel.* file" }
Copy-Item $kernel.FullName (Join-Path $dst $kernel.Name) -Force
Write-Host ""
Info "kernel saved: $dst\$($kernel.Name)"
Get-FileHash (Join-Path $dst $kernel.Name) -Algorithm SHA256 | Format-List
Write-Host "Next: run tools/build-sagit-boot.sh from Linux, or tell the agent." -ForegroundColor Green
