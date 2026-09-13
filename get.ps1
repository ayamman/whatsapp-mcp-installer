<#
  Local WhatsApp MCP - one-line bootstrap.

      irm https://raw.githubusercontent.com/ayamman/whatsapp-mcp-installer/main/get.ps1 | iex

  Downloads the newest RELEASED version of this package, prints exactly which
  commit it got, and runs the installer. The installer's own Stage 1 still
  gates the machine: if this laptop does not qualify, it lists what is missing
  and stops without changing anything.

  To pass options, use the script-block form instead of the pipe:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ayamman/whatsapp-mcp-installer/main/get.ps1))) -DryRun
      & ([scriptblock]::Create((irm .../get.ps1))) -Ref v1.0.0
      & ([scriptblock]::Create((irm .../get.ps1))) -NoAutoFix
#>
[CmdletBinding()]
param(
  # 'latest' resolves to the newest tag. Pass a tag (v1.0.0), a branch, or a
  # full commit SHA to pin this laptop to an exact version.
  [string]$Ref        = 'latest',
  [string]$Repo       = 'ayamman/whatsapp-mcp-installer',
  # NOT the same folder the README tells you to clone into: this bootstrap
  # REPLACES its destination, and a clone there would be destroyed.
  [string]$Dest       = "$env:USERPROFILE\Dev\wa-mcp-pkg",
  [int]$Port          = 8080,
  # AutoFix is ON by default: a fresh laptop needs git, Go, Python and a C
  # compiler, and installing them by hand is the step people get wrong.
  [switch]$NoAutoFix,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($m,$c='Gray'){ Write-Host "  $m" -ForegroundColor $c }

Write-Host ''
Write-Host '  Local WhatsApp MCP - bootstrap' -ForegroundColor Cyan
Write-Host ''
Say 'This links ONE WhatsApp account to Claude on THIS laptop.' 'Gray'
Say 'It can read your chats and send messages to your own number only.' 'Gray'
Write-Host ''
Say 'Before you continue, two things you should know:' 'Yellow'
Say '  - It uses an unofficial WhatsApp connection. That is against' 'Yellow'
Say '    WhatsApp terms of service and the number can be banned.' 'Yellow'
Say '  - Pairing uses one of the four linked-device slots on that number.' 'Yellow'
Write-Host ''

$UA = @{ 'User-Agent' = 'wa-mcp-bootstrap' }

# ---------------------------------------------------------------- resolve ref
if ($Ref -eq 'latest') {
  try {
    $tags = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/tags?per_page=1" -Headers $UA -TimeoutSec 30
    if ($tags -and $tags.Count -gt 0) {
      $Ref = $tags[0].name
      Say "newest released version: $Ref" 'Green'
    } else {
      $Ref = 'main'
      Say 'no tagged release found - falling back to the main branch.' 'Yellow'
      Say 'That is unreviewed code. Ctrl+C now if you were expecting a release.' 'Yellow'
      Start-Sleep -Seconds 5
    }
  } catch {
    throw "could not reach the GitHub API to find the newest version: $($_.Exception.Message)"
  }
}

# ---------------------------------------------------------------- download
$tmp = Join-Path $env:TEMP ("wa-mcp-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'pkg.zip'

$urls = @(
  "https://codeload.github.com/$Repo/zip/refs/tags/$Ref",
  "https://codeload.github.com/$Repo/zip/refs/heads/$Ref",
  "https://codeload.github.com/$Repo/zip/$Ref"
)
$got = $false
foreach ($u in $urls) {
  try { Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $zip -Headers $UA -TimeoutSec 120; $got = $true; break }
  catch { }
}
if (-not $got) { throw "could not download $Repo at ref '$Ref'. Check the version name." }

$zipSha = (Get-FileHash $zip -Algorithm SHA256).Hash
Say "downloaded $([math]::Round((Get-Item $zip).Length/1KB,1)) KB" 'Gray'
Say "ref    : $Ref" 'Gray'
Say "sha256 : $zipSha" 'Gray'

# ---------------------------------------------------------------- extract
$ex = Join-Path $tmp 'x'
Expand-Archive -Path $zip -DestinationPath $ex -Force
$root = @(Get-ChildItem $ex -Directory)
if ($root.Count -ne 1) { throw "unexpected archive layout ($($root.Count) top-level folders)" }
$src = $root[0].FullName

# Installing REPLACES $Dest. Refuse to do that to anything that is not obviously a
# previous copy of this package - a git clone above all. SECURITY.md tells people to
# clone and read the code before running it, and that clone has to survive this.
if (Test-Path $Dest) {
  if (Test-Path (Join-Path $Dest '.git')) {
    throw "$Dest is a git repository. This bootstrap replaces its destination folder, which would destroy that clone and any local changes in it. Either re-run with -Dest pointing at a different folder, or just run .\install.ps1 from inside the clone."
  }
  $looksLikeOurs = (Test-Path (Join-Path $Dest 'install.ps1')) -or
                   (Test-Path (Join-Path $Dest 'bootstrap-provenance.json'))
  $isEmpty = @(Get-ChildItem $Dest -Force -EA SilentlyContinue).Count -eq 0
  if (-not $looksLikeOurs -and -not $isEmpty) {
    throw "$Dest already exists and does not look like a previous copy of this package. Refusing to delete it. Re-run with -Dest pointing at a new or empty folder."
  }
  Remove-Item $Dest -Recurse -Force
}
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item (Join-Path $src '*') $Dest -Recurse -Force

# Files that came out of a downloaded zip carry the mark of the web, which makes
# Windows refuse to run them even under -ExecutionPolicy Bypass. Not fatal if it
# fails - the package is already staged, and -File still runs an unblocked copy.
try { Get-ChildItem $Dest -Recurse -File | Unblock-File -EA SilentlyContinue }
catch { Say "note: could not clear the mark of the web ($($_.Exception.Message))" 'DarkGray' }

# Record what was installed, next to the package, before anything runs.
[pscustomobject]@{
  fetchedAt = (Get-Date).ToString('s')
  repo      = $Repo
  ref       = $Ref
  zipSha256 = $zipSha
  dest      = $Dest
} | ConvertTo-Json | Set-Content (Join-Path $Dest 'bootstrap-provenance.json') -Encoding UTF8

Say "package ready at $Dest" 'Green'
Write-Host ''

# ---------------------------------------------------------------- run
$inst = Join-Path $Dest 'install.ps1'
if (-not (Test-Path $inst)) { throw "install.ps1 is missing from the downloaded package" }

$argv = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $inst, '-Port', "$Port")
if (-not $NoAutoFix) { $argv += '-AutoFix' }
if ($DryRun)         { $argv += '-DryRun' }

Say "running: install.ps1 $(if(-not $NoAutoFix){'-AutoFix '})$(if($DryRun){'-DryRun'})" 'Cyan'
Write-Host ''
& powershell.exe @argv
$rc = $LASTEXITCODE

Remove-Item $tmp -Recurse -Force -EA SilentlyContinue

# Deliberately NOT 'exit $rc'. In the script-block form -
#   & ([scriptblock]::Create((irm .../get.ps1))) -DryRun
# - exit terminates the CALLER's session, so anything after the call never runs.
# Surface the installer's result instead and let the caller decide.
$global:LASTEXITCODE = $rc
if ($rc -ne 0) { Say "the installer exited with code $rc" 'Yellow' }
