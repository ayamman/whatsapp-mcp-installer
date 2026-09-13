<#
  Local WhatsApp MCP - installer
  Run on the laptop:
      powershell -ExecutionPolicy Bypass -File .\install.ps1

  Stage 1 is a read-only requirement gate. If anything mandatory is missing the
  installer prints what is missing and STOPS WITHOUT CHANGING THE MACHINE.

  -AutoFix   install a missing compiler / Go / git / Python via winget, then re-gate
  -DryRun    run the gate and print the plan, change nothing
#>
[CmdletBinding()]
param(
  [string]$InstallRoot = "$env:USERPROFILE\Dev\whatsapp-mcp-go",
  [string]$WorkRoot    = "$env:USERPROFILE\Dev\wa-mcp",
  [int]$Port           = 8080,
  [switch]$AutoFix,
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$PKG   = Split-Path -Parent $MyInvocation.MyCommand.Path
$PIN   = '9cbea3194af316ba49b263f6a58139eee91b7471'
$ORIGIN= 'https://github.com/vimigo-lee/whatsapp-mcp-go.git'
$GCCPKG= 'BrechtSanders.WinLibs.POSIX.UCRT'
$TASK  = 'WhatsAppBridge (local)'
# Any other logon task whose name starts with this belongs to an earlier build
# of this package. Matched by pattern rather than by a hard-coded old name, so
# the cleanup keeps working however the task has been called in the past.
$TASKPREFIX = 'WhatsAppBridge'

if (-not (Test-Path $WorkRoot)) { New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null }
$LOG   = Join-Path $WorkRoot 'install.log'
$MAN   = Join-Path $WorkRoot 'install-manifest.json'

function L($m){ $s="[{0}] {1}" -f (Get-Date -Format s),$m; Write-Host $s; Add-Content -Path $LOG -Value $s }
function Head($m){ Write-Host ''; Write-Host "  == $m" -ForegroundColor Cyan; Add-Content -Path $LOG -Value "== $m" }
function Die($m){ L "STOPPED: $m"; Write-Host ''; Write-Host "  INSTALLATION STOPPED: $m" -ForegroundColor Red; exit 2 }
function Run($cmdline){ (& cmd /c "$cmdline 2>&1") | ForEach-Object { L "  | $_" } }

$MACHINE = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
L "================ Local WhatsApp MCP installer ================"
L "machine=$MACHINE user=$env:USERNAME"
L "installRoot=$InstallRoot port=$Port pin=$PIN"

# ---------------------------------------------------------------- 1. GATE
Head "Stage 1 of 8 - checking this laptop meets the requirements"
$gate = Join-Path $PKG 'lib\preflight.ps1'
if (-not (Test-Path $gate)) { Die "preflight gate not found at $gate" }
$rep = Join-Path $WorkRoot 'preflight-report.json'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gate -InstallRoot $InstallRoot -Port $Port -ReportPath $rep -Origin $ORIGIN
$gateCode = $LASTEXITCODE

if ($gateCode -ne 0 -and $AutoFix) {
  $r = Get-Content $rep -Raw | ConvertFrom-Json
  $fixable = @($r.checks | Where-Object { $_.status -eq 'FAIL' -and $_.id -in @('C6','C7','C8','C9','C19') })
  if ($fixable.Count -gt 0) {
    Head "AutoFix - installing missing build tools (no admin required)"
    foreach ($f in $fixable) {
      switch ($f.id) {
        'C6' { L "installing Git"; Run "winget install --id Git.Git --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity" }
        'C7' { L "installing Go (machine scope - Windows may prompt for administrator)"; Run "winget install --id GoLang.Go --accept-package-agreements --accept-source-agreements --disable-interactivity" }
        'C8' { L "installing C compiler ($GCCPKG, ~261 MB)"; Run "winget install --id $GCCPKG --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity" }
        'C19'{ L "installing Python"; Run "winget install --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity" }
      }
    }
    # B2: winget writes the new PATH to the registry. This process - and every
    # child it spawns, including the re-gate below - still holds the old one.
    # Rebuild it, or the gate reports what we just installed as missing.
    $mp = [Environment]::GetEnvironmentVariable('PATH','Machine')
    $up = [Environment]::GetEnvironmentVariable('PATH','User')
    $env:PATH = (@($mp, $up, $env:PATH) | Where-Object { $_ }) -join ';'
    L "PATH refreshed from the registry after AutoFix"
    Head "re-running the gate after AutoFix"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gate -InstallRoot $InstallRoot -Port $Port -ReportPath $rep -Origin $ORIGIN
    $gateCode = $LASTEXITCODE
  }
}

if ($gateCode -ne 0) {
  L "gate verdict BLOCKED (exit $gateCode) - see the list above and $rep"
  Write-Host ''
  Write-Host '  Nothing on this laptop has been changed.' -ForegroundColor Red
  Write-Host '  Fix the items listed above and run this installer again.' -ForegroundColor Red
  Write-Host '  Tip: -AutoFix will install a missing compiler, Go, Python or git for you.' -ForegroundColor Gray
  exit 2
}
L "gate verdict PROCEED"

if ($DryRun) {
  Head "DRY RUN - the gate passed; stopping before any change"
  L "Would: clone/pin -> patch -> build -> configure -> pair -> register -> verify"
  exit 0
}

# ---------------------------------------------------------------- 2. SOURCE
Head "Stage 2 of 8 - fetching the reviewed source"
$gccbin = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\${GCCPKG}_Microsoft.Winget.Source_8wekyb3d8bbwe\mingw64\bin"
if (Test-Path $gccbin) { $env:PATH = "$gccbin;$env:PATH" }
$env:CGO_ENABLED = '1'

if (-not (Test-Path (Join-Path $InstallRoot '.git'))) {
  L "cloning $ORIGIN"
  Run "git clone $ORIGIN `"$InstallRoot`""
} else {
  L "existing checkout found; fetching"
  Set-Location $InstallRoot
  Run "git stash push -u -m installer-checkpoint"
  Run "git fetch origin --tags"
}
Set-Location $InstallRoot
$actualOrigin = (git remote get-url origin).Trim()
if ($actualOrigin -ne $ORIGIN -and $actualOrigin -ne ($ORIGIN -replace '\.git$','')) {
  Die "origin is '$actualOrigin', expected '$ORIGIN'. Refusing to build from an unexpected source."
}
Run "git checkout -B pinned $PIN"
$head = (git rev-parse HEAD).Trim()
if ($head -ne $PIN) { Die "could not check out the pinned commit (HEAD=$head)" }
L "pinned at $head"

# ---------------------------------------------------------------- 3. PATCH
Head "Stage 3 of 8 - applying the security patches"
$o = & python (Join-Path $PKG 'patches\remove_group_tools.py') (Join-Path $InstallRoot 'whatsapp-mcp-server\helpers\mcp_tool.go') 2>&1
if ($LASTEXITCODE -ne 0) { $o | ForEach-Object { L "  $_" }; Die "group-tool removal failed" }
$o | ForEach-Object { L "  $_" }
$o = & python (Join-Path $PKG 'patches\apply_write_gate.py') $InstallRoot (Join-Path $PKG 'patches\policy.go') 2>&1
if ($LASTEXITCODE -ne 0) { $o | ForEach-Object { L "  $_" }; Die "write-gate patch failed" }
$o | ForEach-Object { L "  $_" }
$o = & python (Join-Path $PKG 'patches\harden_mcp_client.py') $InstallRoot 2>&1
if ($LASTEXITCODE -ne 0) { $o | ForEach-Object { L "  $_" }; Die "MCP client hardening failed" }
$o | ForEach-Object { L "  $_" }

# ---------------------------------------------------------------- 4. BUILD
Head "Stage 4 of 8 - building (a few minutes on first run)"
foreach ($m in @(@{d='whatsapp-bridge';e='whatsapp-bridge.exe'}, @{d='whatsapp-mcp-server';e='whatsapp-mcp.exe'})) {
  Set-Location (Join-Path $InstallRoot $m.d)
  L "$($m.d): downloading modules"
  Run "go mod download"
  if ($LASTEXITCODE -ne 0) { Die "go mod download failed in $($m.d)" }
  L "$($m.d): compiling"
  Run "go build -o $($m.e) ."
  if ($LASTEXITCODE -ne 0) { Die "build failed in $($m.d)" }
  $f = Get-Item (Join-Path $InstallRoot "$($m.d)\$($m.e)")
  L "  built $($f.Name) $([math]::Round($f.Length/1MB,1)) MB"
}

# ---------------------------------------------------------------- 5. CONFIG
Head "Stage 5 of 8 - secrets and configuration"

# Retire any logon task left by an earlier build of this package FIRST. Two
# tasks would start two bridges at the next logon and they would fight over the
# port; the second one to start simply dies, silently, hours later - so this is
# a correctness fix, not tidiness.
try {
  $stale = @(Get-ScheduledTask -EA SilentlyContinue |
             Where-Object { $_.TaskName -like "$TASKPREFIX*" -and $_.TaskName -ne $TASK })
  foreach ($lt in $stale) {
    try { Unregister-ScheduledTask -TaskName $lt.TaskName -Confirm:$false; L "removed the superseded logon task '$($lt.TaskName)'" }
    catch { L "WARNING: could not remove the superseded task '$($lt.TaskName)': $($_.Exception.Message)" }
  }
} catch { L "WARNING: could not enumerate scheduled tasks: $($_.Exception.Message)" }

function EnvU($n){ [Environment]::GetEnvironmentVariable($n,'User') }
function SetEnvU($n,$v){ [Environment]::SetEnvironmentVariable($n,$v,'User'); Set-Item -Path "env:$n" -Value $v }

if ((EnvU 'WHATSAPP_API_KEY').Length -eq 64 -and (EnvU 'WHATSAPP_JWT_SECRET').Length -eq 64) {
  L "existing secrets found and kept"
} else {
  # PowerShell 5.1 is .NET Framework: no RandomNumberGenerator.Fill, no Convert.ToHexString.
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  $a = New-Object byte[] 32; $j = New-Object byte[] 32
  $rng.GetBytes($a); $rng.GetBytes($j); $rng.Dispose()
  $apiKey    = ($a | ForEach-Object { $_.ToString('x2') }) -join ''
  $jwtSecret = ($j | ForEach-Object { $_.ToString('x2') }) -join ''
  if ($apiKey.Length -ne 64 -or $jwtSecret.Length -ne 64 -or $apiKey -eq $jwtSecret) { Die "secret generation failed" }
  SetEnvU 'WHATSAPP_API_KEY' $apiKey
  SetEnvU 'WHATSAPP_JWT_SECRET' $jwtSecret
  L "generated a new API key and JWT secret (values never logged)"
}
SetEnvU 'IS_POSTGRES' 'false'
SetEnvU 'HOST' '127.0.0.1'
SetEnvU 'PORT' "$Port"
SetEnvU 'LOG_LEVEL' 'info'
SetEnvU 'BRIDGE_TZ' 'Asia/Kuala_Lumpur'
SetEnvU 'AUTH_LOGIN_RATE' '5/1m'
L "HOST=127.0.0.1 PORT=$Port - the bridge binds loopback only"

# launcher (no secrets inside it; it reads them from the user environment)
$launcher = Join-Path $WorkRoot 'start-wa-bridge.ps1'
@"
`$bridge = '$InstallRoot\whatsapp-bridge'
`$dir    = '$WorkRoot'
if (Get-Process whatsapp-bridge -ErrorAction SilentlyContinue) { exit 0 }
foreach (`$v in 'WHATSAPP_API_KEY','WHATSAPP_JWT_SECRET','WHATSAPP_SEND_ALLOWLIST','IS_POSTGRES','HOST','PORT','LOG_LEVEL','BRIDGE_TZ','AUTH_LOGIN_RATE') {
  `$val = [Environment]::GetEnvironmentVariable(`$v,'User')
  if (`$val) { Set-Item -Path "env:`$v" -Value `$val }
}
`$stamp = Get-Date -Format 'yyyyMMdd'
Start-Process -FilePath "`$bridge\whatsapp-bridge.exe" -WorkingDirectory `$bridge -WindowStyle Hidden ``
  -RedirectStandardOutput "`$dir\bridge-stdout-`$stamp.log" -RedirectStandardError "`$dir\bridge-stderr-`$stamp.log"
"@ | Set-Content -Path $launcher -Encoding UTF8
L "wrote launcher $launcher"

# ---------------------------------------------------------------- 6. START + PAIR
Head "Stage 6 of 8 - starting the bridge and linking WhatsApp"
Get-Process whatsapp-bridge -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher
Start-Sleep -Seconds 10
if (-not (Get-Process whatsapp-bridge -EA SilentlyContinue)) { Die "the bridge did not start - see $WorkRoot\bridge-stderr-*.log" }
L "bridge running"

$B = "http://127.0.0.1:$Port"
function Jwt { $t = Invoke-RestMethod -Uri "$B/auth/login" -Method Post -Headers @{Authorization="Bearer $(EnvU 'WHATSAPP_API_KEY')"} -TimeoutSec 15
               if ($t.token) { $t.token } else { $t.access_token } }
$jwt = Jwt
$st  = Invoke-RestMethod -Uri "$B/api/auth/status" -Headers @{Authorization="Bearer $jwt"} -TimeoutSec 15
L "status connected=$($st.connected) logged_in=$($st.logged_in)"

if (-not $st.logged_in) {
  Write-Host ''
  Write-Host '  A browser tab will open with a QR code.' -ForegroundColor Yellow
  Write-Host '  On your phone: WhatsApp > Linked Devices > Link a Device, then scan it.' -ForegroundColor Yellow
  Write-Host '  The square refreshes itself - scan whichever one is on screen.' -ForegroundColor Yellow
  Write-Host ''
  $qrPng  = Join-Path $WorkRoot 'pairing-qr.png'
  $qrHtml = Join-Path $WorkRoot 'scan-me.html'
  $deadline = (Get-Date).AddMinutes(10); $opened = $false; $restarts = 0; $lastChange = Get-Date; $lastHash = ''
  while ((Get-Date) -lt $deadline) {
    try { $st = Invoke-RestMethod -Uri "$B/api/auth/status" -Headers @{Authorization="Bearer $jwt"} -TimeoutSec 10 }
    catch { $jwt = Jwt; continue }
    if ($st.logged_in) { break }
    try {
      Invoke-WebRequest -UseBasicParsing -Uri "$B/api/auth/pairing-qr" -Headers @{Authorization="Bearer $jwt"} -OutFile $qrPng -TimeoutSec 15 -EA Stop
      $h = (Get-FileHash $qrPng -Algorithm SHA256).Hash
      if ($h -ne $lastHash) { $lastHash = $h; $lastChange = Get-Date }
    } catch { }
    # A code unchanged for ~90s is dead; only restarting the bridge clears it.
    if (((Get-Date) - $lastChange).TotalSeconds -gt 90 -and $restarts -lt 4) {
      $restarts++
      L "pairing code went stale - restarting the bridge (attempt $restarts of 4)"
      Get-Process whatsapp-bridge -EA SilentlyContinue | Stop-Process -Force
      Start-Sleep -Seconds 4
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher
      Start-Sleep -Seconds 10
      $jwt = Jwt; $lastChange = Get-Date; $lastHash = ''
    }
    $stamp = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    @"
<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="3">
<title>Scan to link WhatsApp</title></head>
<body style="font-family:Segoe UI,sans-serif;text-align:center;padding:24px;background:#111;color:#eee">
<h2>Scan this with WhatsApp</h2><p style="color:#aaa">Phone: WhatsApp &rarr; Linked Devices &rarr; Link a Device</p>
<img src="pairing-qr.png?t=$stamp" style="width:360px;height:360px;background:#fff;padding:12px;border-radius:8px">
<p style="color:#888;font-size:13px">This square refreshes by itself. Scan whichever one is on screen.</p></body></html>
"@ | Set-Content -Path $qrHtml -Encoding UTF8
    if (-not $opened) { Start-Process $qrHtml; $opened = $true }
    Start-Sleep -Seconds 3
  }
  if (-not $st.logged_in) { Die "WhatsApp was not linked within 10 minutes. Re-run the installer when you are ready to scan." }
}
L "WhatsApp linked: jid=$($st.jid)"

# ---------------------------------------------------------------- 7. ALLOWLIST + REGISTER
Head "Stage 7 of 8 - locking sends to this phone, and registering with Claude"

# The allowlist is derived from the number that actually paired, so "send only
# to yourself" is true by construction and cannot be mistyped per laptop.
$own = ($st.jid -split '[:@]')[0] -replace '\D',''
if ($own.Length -lt 8) { Die "could not determine the linked number from jid '$($st.jid)'" }
SetEnvU 'WHATSAPP_SEND_ALLOWLIST' $own
L "send allowlist set to the linked number only (****$($own.Substring($own.Length-4)))"

L "restarting the bridge so it loads the allowlist"
Get-Process whatsapp-bridge -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 4
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher
Start-Sleep -Seconds 10
if (-not (Get-Process whatsapp-bridge -EA SilentlyContinue)) { Die "the bridge did not restart" }

$taskName = $TASK
try {
  if (Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`""
  $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
         -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  $prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Settings $set -Principal $prn `
    -Description 'Starts the local WhatsApp MCP bridge at logon (loopback only, no elevation).' | Out-Null
  L "auto-start task registered"
} catch { L "WARNING: could not register the auto-start task: $($_.Exception.Message)" }

# S5: the key goes to the registrar on stdin. It used to be written to
# .apikey.tmp and deleted afterwards, which left it on disk in cleartext for the
# duration - and permanently if anything failed in between.
$o = ((EnvU 'WHATSAPP_API_KEY') | & python (Join-Path $PKG 'patches\register_clients.py') $InstallRoot '-' "$Port" 2>&1)
$rc = $LASTEXITCODE
$o | ForEach-Object { L "  $_" }
if ($rc -ne 0) { L "WARNING: client registration reported a problem - see above" }

# ---------------------------------------------------------------- 8. MANIFEST + VERIFY
Head "Stage 8 of 8 - recording what was installed, then verifying it"
$bridgeExe = Join-Path $InstallRoot 'whatsapp-bridge\whatsapp-bridge.exe'
$mcpExe    = Join-Path $InstallRoot 'whatsapp-mcp-server\whatsapp-mcp.exe'
[pscustomobject]@{
  installedAt  = (Get-Date).ToString('s')
  machine      = $MACHINE
  user         = $env:USERNAME
  installRoot  = $InstallRoot
  workRoot     = $WorkRoot
  origin       = $ORIGIN
  commit       = $PIN
  branch       = 'pinned'
  port         = $Port
  bindAddress  = '127.0.0.1'
  linkedJid    = $st.jid
  allowlist    = @($own)
  bridgeExe    = $bridgeExe
  bridgeSha256 = (Get-FileHash $bridgeExe -Algorithm SHA256).Hash
  mcpExe       = $mcpExe
  mcpSha256    = (Get-FileHash $mcpExe -Algorithm SHA256).Hash
  scheduledTask= $taskName
  # Recorded so the fleet can be audited later without visiting each laptop.
  # 0=off 1=enforcement 2=evaluation. Enforcement stops this unsigned bridge;
  # evaluation means Windows has not decided yet and may move either way.
  smartAppControl = $(
    $sacv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -EA SilentlyContinue).VerifiedAndReputablePolicyState
    switch ($sacv) { 0 {'off'} 1 {'enforcement'} 2 {'evaluation'} default {'not-applicable'} })
  enterpriseManaged = $((Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue).PartOfDomain -eq $true)
  storePath    = Join-Path $InstallRoot 'whatsapp-bridge\store'
  auditLog     = Join-Path $InstallRoot 'whatsapp-bridge\store\audit.log'
  envVars      = @('WHATSAPP_API_KEY','WHATSAPP_JWT_SECRET','WHATSAPP_SEND_ALLOWLIST','IS_POSTGRES','HOST','PORT','LOG_LEVEL','BRIDGE_TZ','AUTH_LOGIN_RATE')
  clientConfigs= @("$env:APPDATA\Claude\claude_desktop_config.json", "$env:USERPROFILE\.claude.json")
} | ConvertTo-Json -Depth 5 | Set-Content -Path $MAN -Encoding UTF8
L "manifest written to $MAN"

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PKG 'verify.ps1') -Port $Port -InstallRoot $InstallRoot -WorkRoot $WorkRoot
$vrc = $LASTEXITCODE

# An earlier build kept its logs and launcher somewhere else. Point it out
# rather than deleting it - the old install log may still be wanted.
$oldWork = @(Get-ChildItem (Split-Path $WorkRoot -Parent) -Directory -EA SilentlyContinue |
             Where-Object { $_.FullName -ne $WorkRoot -and (Test-Path (Join-Path $_.FullName 'start-wa-bridge.ps1')) })
foreach ($lw in $oldWork) {
  Write-Host ''
  Write-Host "  Note: an older work folder is still on this laptop: $($lw.FullName)" -ForegroundColor Gray
  Write-Host '  Its logon task has been removed. Keep it for the old logs, or delete it.' -ForegroundColor Gray
}

Write-Host ''
if ($vrc -eq 0) {
  Write-Host '  INSTALLED AND VERIFIED.' -ForegroundColor Green
  Write-Host ''
  Write-Host '  Now quit Claude completely and open it again -' -ForegroundColor Yellow
  Write-Host '  check the arrow near the clock in case it is still running.' -ForegroundColor Yellow
  Write-Host '  Your WhatsApp tools will be there when it restarts.' -ForegroundColor Yellow
} else {
  Write-Host '  INSTALLED, BUT VERIFICATION FAILED - see the results above.' -ForegroundColor Red
  Write-Host "  Full log: $LOG" -ForegroundColor Gray
}
Write-Host ''
L "================ installer finished (verify exit $vrc) ================"
exit $vrc
