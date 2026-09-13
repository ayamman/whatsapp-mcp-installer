<#
  Local WhatsApp MCP - PREFLIGHT GATE
  READ ONLY. This script changes nothing on the machine. Ever.

  Exit 0  = every MUST requirement met, installation may proceed
  Exit 2  = one or more MUST requirements missing, installation MUST NOT proceed
  Exit 3  = the gate itself could not run

  -Simulate accepts a comma-separated list of conditions to fake, for dry runs.
  Every simulated run is labelled on screen and recorded in the report, so a
  simulated verdict can never be mistaken for a real one.

    failures : no-gcc, no-go, old-go, no-git, no-python, no-git-remote,
               port-busy, arch-mismatch, tls-intercept, no-network,
               sac-enforced, onedrive, low-disk, cfa-on, no-admin, cgo-fail
    passes   : tls-ok   - pretend the four required hosts present public-CA
                          certificates. Lets you rehearse a full PROCEED on a
                          network that inspects TLS, where C11 would otherwise
                          block. Never consulted by install.ps1.
#>
[CmdletBinding()]
param(
  [string]$Simulate = '',
  [string]$InstallRoot = "$env:USERPROFILE\Dev\whatsapp-mcp-go",
  [int]$Port = 8080,
  # The repository Stage 2 clones. install.ps1 passes its own value; the default
  # here only matters when the gate is run by hand.
  [string]$Origin = 'https://github.com/vimigo-lee/whatsapp-mcp-go.git',
  # Defaults to the installer's own work folder, so a gate run by hand leaves
  # its report in the same place as one run by the installer.
  [string]$ReportPath = "$env:USERPROFILE\Dev\wa-mcp\preflight-report.json",
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$SIM = @($Simulate -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$script:Checks = @()

function Sim([string]$n){ return $SIM -contains $n }

function Add-Check {
  param(
    [string]$Id, [string]$Req, [string]$Name,
    [ValidateSet('PASS','FAIL','WARN','INFO')][string]$Status,
    [string]$Detail, [string]$Remedy = '',
    [ValidateSet('MUST','SHOULD','INFO')][string]$Priority = 'MUST'
  )
  $script:Checks += [pscustomobject]@{
    id=$Id; requirement=$Req; name=$Name; status=$Status
    detail=$Detail; remedy=$Remedy; priority=$Priority
  }
}

function Get-CertIssuer([string]$h) {
  try {
    $tcp = New-Object Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect($h, 443, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(8000)) { $tcp.Close(); return $null }
    $tcp.EndConnect($iar)
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({$true} -as [Net.Security.RemoteCertificateValidationCallback]))
    $ssl.AuthenticateAsClient($h)
    $iss = $ssl.RemoteCertificate.Issuer
    $ssl.Dispose(); $tcp.Close()
    return $iss
  } catch { return $null }
}

# ---------------------------------------------------------------- C1 platform
$os = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
$osName = if ($os) { "$($os.Caption) build $($os.BuildNumber)" } else { 'unknown' }
Add-Check -Id 'C1' -Req 'R5' -Name 'Operating system' -Status 'INFO' -Priority 'INFO' -Detail $osName

$arch = $env:PROCESSOR_ARCHITECTURE
if (Sim 'arch-mismatch') { $arch = 'ARM64' }
Add-Check -Id 'C2' -Req 'R5' -Name 'CPU architecture' -Status 'INFO' -Priority 'INFO' -Detail $arch

$ps = $PSVersionTable.PSVersion
if ($ps.Major -ge 5) { Add-Check -Id 'C3' -Req 'R5' -Name 'PowerShell version' -Status 'PASS' -Detail "$ps" }
else { Add-Check -Id 'C3' -Req 'R5' -Name 'PowerShell version' -Status 'FAIL' -Detail "$ps" -Remedy 'PowerShell 5.1 or newer is required.' }

$inAdmin = [bool]((whoami /groups) -match 'S-1-5-32-544')
if (Sim 'no-admin') { $inAdmin = $false }
Add-Check -Id 'C4' -Req 'R5' -Name 'Local administrator group' -Status $(if($inAdmin){'PASS'}else{'WARN'}) -Priority 'SHOULD' `
  -Detail $(if($inAdmin){'member'}else{'not a member'}) `
  -Remedy 'Not required for install. Needed only to tighten the session-store permissions afterwards.'

# ---------------------------------------------------------------- C5 disk
$free = if (Sim 'low-disk') { 0.4 } else { [math]::Round((Get-PSDrive C -EA SilentlyContinue).Free/1GB, 1) }
if ($free -ge 3) { Add-Check -Id 'C5' -Req 'R5' -Name 'Free disk space' -Status 'PASS' -Detail "$free GB free on C:" }
else { Add-Check -Id 'C5' -Req 'R5' -Name 'Free disk space' -Status 'FAIL' -Detail "$free GB free on C:" -Remedy 'At least 3 GB is needed for the Go module cache and the two binaries.' }

# ---------------------------------------------------------------- C6-C9 toolchain
$gitCmd = if (Sim 'no-git') { $null } else { Get-Command git -EA SilentlyContinue }
if ($gitCmd) { Add-Check -Id 'C6' -Req 'R5' -Name 'git' -Status 'PASS' -Detail $gitCmd.Source }
else { Add-Check -Id 'C6' -Req 'R5' -Name 'git' -Status 'FAIL' -Detail 'not found' -Remedy 'winget install --id Git.Git --scope user' }

# Go, with the same filesystem fallback the C compiler already has. winget
# writes the new PATH to the registry, so a freshly installed Go is invisible to
# Get-Command in this process - which made -AutoFix unable to recover a laptop
# with no Go at all: it installed it, then reported it missing.
$goPaths = @("$env:LOCALAPPDATA\Programs\Go\bin\go.exe",
  "$env:ProgramFiles\Go\bin\go.exe", 'C:\Program Files\Go\bin\go.exe')
$goCmd = if (Sim 'no-go') { $null } else { Get-Command go -EA SilentlyContinue }
if (-not $goCmd -and -not (Sim 'no-go')) {
  $goFile = $goPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($goFile) {
    $env:PATH = "$(Split-Path $goFile);$env:PATH"
    $goCmd = Get-Command go -EA SilentlyContinue
  }
}
if ($goCmd) {
  $goVer = if (Sim 'old-go') { 'go1.19.0' } else { (& go env GOVERSION 2>$null) }
  $m = [regex]::Match($goVer, 'go(\d+)\.(\d+)')
  $okGo = $m.Success -and ([int]$m.Groups[1].Value -gt 1 -or ([int]$m.Groups[1].Value -eq 1 -and [int]$m.Groups[2].Value -ge 25))
  if ($okGo) { Add-Check -Id 'C7' -Req 'R5' -Name 'Go toolchain' -Status 'PASS' -Detail "$goVer at $($goCmd.Source)" }
  else { Add-Check -Id 'C7' -Req 'R5' -Name 'Go toolchain' -Status 'FAIL' -Detail "$goVer is older than the go.mod directive (go 1.25.0)" -Remedy 'winget install --id GoLang.Go' }
} else {
  Add-Check -Id 'C7' -Req 'R5' -Name 'Go toolchain' -Status 'FAIL' -Detail 'not found' -Remedy 'winget install --id GoLang.Go'
}

$gccPaths = @('C:\msys64\ucrt64\bin\gcc.exe','C:\msys64\mingw64\bin\gcc.exe',
  "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin\gcc.exe")
$gccCmd = if (Sim 'no-gcc') { $null } else { Get-Command gcc -EA SilentlyContinue }
$gccFile = if (Sim 'no-gcc') { $null } else { $gccPaths | Where-Object { Test-Path $_ } | Select-Object -First 1 }
$gccWhere = if ($gccCmd) { $gccCmd.Source } elseif ($gccFile) { $gccFile } else { $null }
if ($gccWhere) { Add-Check -Id 'C8' -Req 'R5' -Name 'C compiler (CGO)' -Status 'PASS' -Detail $gccWhere }
else {
  Add-Check -Id 'C8' -Req 'R5' -Name 'C compiler (CGO)' -Status 'FAIL' -Detail 'gcc not found' `
    -Remedy 'winget install --id BrechtSanders.WinLibs.POSIX.UCRT --scope user   (261 MB, no admin needed). Then open a NEW terminal.'
}

# Real CGO compile probe, in TEMP, removed afterwards.
if ($gccWhere -and $goCmd -and -not (Sim 'no-go')) {
  if (Sim 'cgo-fail') {
    Add-Check -Id 'C9' -Req 'R5' -Name 'CGO compile probe' -Status 'FAIL' -Detail 'probe build failed' -Remedy 'The C compiler is present but cannot produce a binary. Reinstall the toolchain.'
  } else {
    # Build in a scratch directory passed to Go with -C, not by changing the
    # shell's location: a native process does not necessarily inherit
    # Push-Location, so the probe would otherwise build in whatever directory
    # the gate happened to be started from. TEMP is resolved defensively for
    # the same reason - an empty TEMP made the path relative.
    $tempBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { [System.IO.Path]::GetTempPath() }
    $t = Join-Path $tempBase ("cgoprobe-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $t -Force | Out-Null
    @'
package main
/*
#include <stdio.h>
*/
import "C"
func main() { println("ok") }
'@ | Set-Content -Path (Join-Path $t 'main.go') -Encoding ASCII
    $env:PATH = "$(Split-Path $gccWhere);$env:PATH"; $env:CGO_ENABLED = '1'
    & go -C $t mod init probe 2>&1 | Out-Null
    $probeOut = & go -C $t build -o probe.exe . 2>&1
    $rc = $LASTEXITCODE
    Remove-Item $t -Recurse -Force -EA SilentlyContinue
    if ($rc -eq 0) { Add-Check -Id 'C9' -Req 'R5' -Name 'CGO compile probe' -Status 'PASS' -Detail 'compiled a CGO test binary successfully' }
    else { Add-Check -Id 'C9' -Req 'R5' -Name 'CGO compile probe' -Status 'FAIL' -Detail (($probeOut | Select-Object -First 3) -join ' / ') -Remedy 'Go and gcc are both present but cannot build together. Check CGO_ENABLED and the compiler on PATH.' }
  }
} else {
  Add-Check -Id 'C9' -Req 'R5' -Name 'CGO compile probe' -Status 'FAIL' -Detail 'skipped - Go or C compiler missing' -Remedy 'Resolve C7 and C8 first.'
}

# ---------------------------------------------------------------- C19 python
# The installer applies its security patches with Python. Nothing checked for it
# before, so a laptop without it passed the gate, got as far as cloning the repo,
# and then died at stage 3 blaming the patch script.
$pyCmd = if (Sim 'no-python') { $null } else { Get-Command python -EA SilentlyContinue }
$pyStub = $false
if ($pyCmd) {
  # A bare Microsoft Store alias is a zero-byte reparse point under WindowsApps.
  # It answers Get-Command and then fails to run, so it must not count as Python.
  $pyInfo = Get-Item $pyCmd.Source -Force -EA SilentlyContinue
  $pyStub = ($pyCmd.Source -like '*\WindowsApps\python*') -or ($pyInfo -and $pyInfo.Length -eq 0)
}
$pyVer = ''
if ($pyCmd -and -not $pyStub) { $pyVer = (& $pyCmd.Source --version 2>&1 | Select-Object -First 1) }
if ("$pyVer" -match 'Python\s+3\.') {
  Add-Check -Id 'C19' -Req 'R5' -Name 'Python 3' -Status 'PASS' -Detail "$pyVer at $($pyCmd.Source)"
} else {
  $d = if ($pyStub) { 'only the Microsoft Store alias stub is present' } elseif ($pyCmd) { "unusable: $pyVer" } else { 'not found' }
  Add-Check -Id 'C19' -Req 'R5' -Name 'Python 3' -Status 'FAIL' -Detail $d `
    -Remedy 'The installer applies its security patches with Python. winget install --id Python.Python.3.12 --scope user   (no admin needed). Then open a NEW terminal.'
}

# ---------------------------------------------------------------- C10-C12 network
$hosts = 'github.com','proxy.golang.org','sum.golang.org','web.whatsapp.com'
$netFail = @(); $intercepted = @()
foreach ($h in $hosts) {
  if (Sim 'no-network') { $netFail += $h; continue }
  $iss = if (Sim 'tls-intercept') { 'CN=Corporate-Inspection-CA, O=Example Corp' }
         elseif (Sim 'tls-ok')        { 'CN=DigiCert Global Root G2, O=DigiCert Inc' }
         else                         { Get-CertIssuer $h }
  if (-not $iss) { $netFail += $h; continue }
  if ($iss -notmatch 'DigiCert|Google Trust|Sectigo|Let''s Encrypt|Amazon|GlobalSign|Microsoft|ISRG') { $intercepted += "$h -> $iss" }
}
if ($netFail.Count -eq 0) { Add-Check -Id 'C10' -Req 'R5' -Name 'Network reachability' -Status 'PASS' -Detail 'all 4 required hosts reachable over TLS' }
else { Add-Check -Id 'C10' -Req 'R5' -Name 'Network reachability' -Status 'FAIL' -Detail ("unreachable: " + ($netFail -join ', ')) -Remedy 'The build needs github.com, proxy.golang.org and sum.golang.org. The bridge needs web.whatsapp.com.' }

if ($intercepted.Count -eq 0) { Add-Check -Id 'C11' -Req 'R5' -Name 'TLS interception' -Status 'PASS' -Detail 'certificates issued by public CAs' }
else { Add-Check -Id 'C11' -Req 'R5' -Name 'TLS interception' -Status 'FAIL' -Detail ($intercepted -join '; ') -Remedy 'A firewall is re-signing HTTPS. Go module downloads and the WhatsApp websocket will both fail. Exempt these hosts or install from a network without inspection.' }

# ---------------------------------------------------------------- C20 git reachability
# C10 proves a TLS handshake to github.com from .NET. It does NOT prove that *git*
# can get there. Chrome and PowerShell may resolve through their own DoH while git
# uses the Windows resolver, so a laptop can pass every other check and then die at
# Stage 2 on "Could not resolve host" - after -AutoFix has already installed ~1 GB of
# toolchain. This runs the same operation Stage 2 depends on, before anything changes.
if (Sim 'no-git-remote') {
  Add-Check -Id 'C20' -Req 'R5' -Name 'git can reach the source' -Status 'FAIL' `
    -Detail 'simulated: fatal: unable to access - Could not resolve host: github.com' `
    -Remedy 'Stage 2 clones from this URL, so the install cannot proceed. The reason git gives is shown above - read that first. The usual cause on Windows is the DNS resolver not answering while the browser resolves through its own secure DNS; test with: nslookup github.com   If that fails, set the adapter DNS (1.1.1.1 or 8.8.8.8) or install from another network such as a phone hotspot. If a proxy or firewall is in the way, git has to be able to use it too.'
} elseif (-not $gitCmd) {
  Add-Check -Id 'C20' -Req 'R5' -Name 'git can reach the source' -Status 'FAIL' `
    -Detail 'skipped - git not found' -Remedy 'Resolve C6 first.'
} else {
  $env:GIT_TERMINAL_PROMPT = '0'   # never sit waiting for credentials on a public repo
  # Call git directly rather than through cmd: one less shell in the way, and the
  # exit code is trustworthy.
  $lsr = (& git ls-remote --heads $Origin 2>&1) | Out-String
  $lsrOk = ($LASTEXITCODE -eq 0) -and ($lsr -match 'refs/heads/')
  if ($lsrOk) {
    Add-Check -Id 'C20' -Req 'R5' -Name 'git can reach the source' -Status 'PASS' -Detail 'git ls-remote succeeded'
  } else {
    $why = ($lsr.Trim() -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $why) { $why = "git ls-remote failed with exit code $LASTEXITCODE and no output" }
    Add-Check -Id 'C20' -Req 'R5' -Name 'git can reach the source' -Status 'FAIL' -Detail "$why" `
      -Remedy 'Stage 2 clones from this URL, so the install cannot proceed. The reason git gives is shown above - read that first. The usual cause on Windows is the DNS resolver not answering while the browser resolves through its own secure DNS; test with: nslookup github.com   If that fails, set the adapter DNS (1.1.1.1 or 8.8.8.8) or install from another network such as a phone hotspot. If a proxy or firewall is in the way, git has to be able to use it too.'
  }
}

$ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -EA SilentlyContinue
$proxyOn = ($ie.ProxyEnable -eq 1) -or $env:HTTPS_PROXY
Add-Check -Id 'C12' -Req 'R5' -Name 'HTTP proxy' -Status $(if($proxyOn){'WARN'}else{'PASS'}) -Priority 'SHOULD' `
  -Detail $(if($proxyOn){"proxy configured: $($ie.ProxyServer)$env:HTTPS_PROXY"}else{'none'}) `
  -Remedy 'A proxy is not fatal but the Go toolchain and the bridge must both be able to use it.'

# ---------------------------------------------------------------- C13-C14 local networking
$busy = if (Sim 'port-busy') { $true } else { [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue) }
if (-not $busy) { Add-Check -Id 'C13' -Req 'R20' -Name "Port $Port available" -Status 'PASS' -Detail 'free' }
else {
  $own  = (Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue | Select-Object -First 1)
  $op   = if ($own) { Get-Process -Id $own.OwningProcess -EA SilentlyContinue } else { $null }
  $pn   = if ($op) { $op.ProcessName } else { 'simulated' }
  # A port held by THIS installation's own bridge is a reinstall, not a conflict (R8 idempotency).
  $isOurs = $op -and $op.Path -and ($op.Path -like "$InstallRoot*")
  if ($isOurs -and -not (Sim 'port-busy')) {
    Add-Check -Id 'C13' -Req 'R20' -Name "Port $Port available" -Status 'PASS' `
      -Detail "held by this installation's own bridge (pid $($op.Id)) - reinstall, will be restarted"
  } else {
    Add-Check -Id 'C13' -Req 'R20' -Name "Port $Port available" -Status 'FAIL' -Detail "in use by $pn" `
      -Remedy "Another program owns this port. Stop it, or install with -Port on a free port."
  }
}

$lh = Resolve-DnsName localhost -EA SilentlyContinue
$v6first = $lh -and (($lh | Select-Object -First 1).Type -eq 'AAAA')
Add-Check -Id 'C14' -Req 'R19' -Name 'localhost resolution order' -Status $(if($v6first){'WARN'}else{'PASS'}) -Priority 'SHOULD' `
  -Detail $(if($v6first){'resolves to ::1 (IPv6) first'}else{'resolves to 127.0.0.1 first'}) `
  -Remedy 'Handled: the installer writes 127.0.0.1 literally everywhere, never the name localhost.'

# ---------------------------------------------------------------- C15-C17 platform policy
$sacRaw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -EA SilentlyContinue).VerifiedAndReputablePolicyState
$sac = if (Sim 'sac-enforced') { 1 } else { $sacRaw }
switch ($sac) {
  1 { Add-Check -Id 'C15' -Req 'R5' -Name 'Smart App Control' -Status 'FAIL' -Detail 'ENFORCEMENT - unsigned binaries are blocked' -Remedy 'The bridge is an unsigned binary and will not run. Turn Smart App Control off, sign the binaries, or run the bridge under WSL.' }
  2 { Add-Check -Id 'C15' -Req 'R5' -Name 'Smart App Control' -Status 'WARN' -Priority 'SHOULD' -Detail 'Evaluation mode' -Remedy 'Unsigned binaries run today, but Windows may switch to Enforcement without warning and the bridge will stop. Decide this before relying on it.' }
  default { Add-Check -Id 'C15' -Req 'R5' -Name 'Smart App Control' -Status 'PASS' -Detail "off or not applicable (state=$sac)" }
}

$cfa = if (Sim 'cfa-on') { 1 } else { (Get-MpPreference -EA SilentlyContinue).EnableControlledFolderAccess }
Add-Check -Id 'C16' -Req 'R5' -Name 'Controlled folder access' -Status $(if($cfa -and $cfa -ne 0){'FAIL'}else{'PASS'}) `
  -Detail $(if($cfa -and $cfa -ne 0){"enabled (state=$cfa)"}else{'disabled'}) `
  -Remedy 'Blocks writing to Documents and Desktop. Add the install folder as an allowed app or choose a different location.'

$myDocs = [Environment]::GetFolderPath('MyDocuments')
$od = if (Sim 'onedrive') { $true } else { ($InstallRoot -like '*OneDrive*') -or (($myDocs -like '*OneDrive*') -and ($InstallRoot -like "$myDocs*")) }
Add-Check -Id 'C17' -Req 'R7' -Name 'Install path not cloud-synced' -Status $(if($od){'FAIL'}else{'PASS'}) `
  -Detail $(if($od){"$InstallRoot is inside a synced folder"}else{$InstallRoot}) `
  -Remedy 'Cloud sync locks and corrupts the SQLite session store. Install outside OneDrive, for example %USERPROFILE%\Dev.'

# ---------------------------------------------------------------- C18 existing state
$existing = Test-Path $InstallRoot
$store = Join-Path $InstallRoot 'whatsapp-bridge\store\whatsapp.db'
$hasSession = Test-Path $store
Add-Check -Id 'C18' -Req 'R8' -Name 'Existing installation' -Status 'INFO' -Priority 'INFO' `
  -Detail $(if(-not $existing){'none - clean install'} elseif($hasSession){'present WITH a linked session - will be preserved'} else{'present, no session yet'})

# ---------------------------------------------------------------- verdict
$must   = $script:Checks | Where-Object { $_.priority -eq 'MUST' }
$failed = @($must | Where-Object { $_.status -eq 'FAIL' })
$warned = @($script:Checks | Where-Object { $_.status -eq 'WARN' })

$report = [pscustomobject]@{
  generated   = (Get-Date).ToString('s')
  machine     = $env:COMPUTERNAME
  user        = $env:USERNAME
  os          = $osName
  arch        = $arch
  installRoot = $InstallRoot
  port        = $Port
  simulated   = $SIM
  verdict     = $(if ($failed.Count -eq 0) { 'PROCEED' } else { 'BLOCKED' })
  blockers    = @($failed | ForEach-Object { $_.id })
  checks      = $script:Checks
}

$rd = Split-Path $ReportPath -Parent
if ($rd -and -not (Test-Path $rd)) { New-Item -ItemType Directory -Path $rd -Force | Out-Null }
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8

if (-not $Quiet) {
  Write-Host ''
  Write-Host '  Local WhatsApp MCP - preflight gate' -ForegroundColor Cyan
  Write-Host "  $osName | $arch | $env:COMPUTERNAME\$env:USERNAME"
  if ($SIM.Count) {
    Write-Host "  SIMULATED CONDITIONS: $($SIM -join ', ')" -ForegroundColor Magenta
    Write-Host '  This verdict is a rehearsal, not a measurement of this machine.' -ForegroundColor Magenta
  }
  Write-Host ''
  foreach ($c in $script:Checks) {
    $col = switch ($c.status) { 'PASS'{'Green'} 'FAIL'{'Red'} 'WARN'{'Yellow'} default{'DarkGray'} }
    $mark = switch ($c.status) { 'PASS'{'[ OK ]'} 'FAIL'{'[FAIL]'} 'WARN'{'[WARN]'} default{'[ -- ]'} }
    Write-Host ("  {0} {1,-4} {2,-30} {3}" -f $mark, $c.requirement, $c.name, $c.detail) -ForegroundColor $col
  }
  Write-Host ''
  $simTag = if ($SIM.Count) { ' (SIMULATED)' } else { '' }
  if ($failed.Count -eq 0) {
    Write-Host "  VERDICT: PROCEED$simTag - every mandatory requirement is met." -ForegroundColor Green
    if ($warned.Count) { Write-Host "  ($($warned.Count) warning(s) - see the report)" -ForegroundColor Yellow }
  } else {
    Write-Host "  VERDICT: BLOCKED$simTag - $($failed.Count) mandatory requirement(s) not met." -ForegroundColor Red
    Write-Host '  NOTHING HAS BEEN CHANGED ON THIS MACHINE.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  What is missing:' -ForegroundColor Red
    foreach ($f in $failed) {
      Write-Host ("   - {0} ({1}): {2}" -f $f.name, $f.requirement, $f.detail) -ForegroundColor Red
      if ($f.remedy) { Write-Host ("     fix: {0}" -f $f.remedy) -ForegroundColor Gray }
    }
  }
  Write-Host ''
  Write-Host "  Report: $ReportPath" -ForegroundColor DarkGray
  Write-Host ''
}

if ($failed.Count -gt 0) { exit 2 } else { exit 0 }
