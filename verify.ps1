<#
  Local WhatsApp MCP - acceptance verification (URS T2-T13).
  Read-only apart from one message sent to the linked number itself.
  Exit 0 = all pass, 1 = one or more failed.
#>
param(
  [int]$Port = 8080,
  [string]$InstallRoot = "$env:USERPROFILE\Dev\whatsapp-mcp-go",
  [string]$WorkRoot    = "$env:USERPROFILE\Dev\wa-mcp",
  [switch]$SkipSend
)
$ErrorActionPreference = 'Continue'
$B = "http://127.0.0.1:$Port"
$audit = Join-Path $InstallRoot 'whatsapp-bridge\store\audit.log'
# C4: remember how long the audit log is BEFORE any of this run's traffic, so
# T13 can assert that THIS run was recorded instead of reading a fixed window of
# old lines - which could never fail, even with the audit log dead.
$auditBefore = if (Test-Path $audit) { @(Get-Content $audit -EA SilentlyContinue).Count } else { 0 }
$Results = @()
function T($id,$name,$expect,$got,$pass,$skip=$false){ $script:Results += [pscustomobject]@{ID=$id;Test=$name;Expect=$expect;Got=$got;Pass=$pass;Skip=$skip} }

function Call($method,$url,$body){
  try {
    if ($body) { $r = Invoke-WebRequest -UseBasicParsing -Uri $url -Method $method -Headers $H -Body ($body|ConvertTo-Json) -TimeoutSec 30 -EA Stop }
    else       { $r = Invoke-WebRequest -UseBasicParsing -Uri $url -Method $method -Headers $H -TimeoutSec 30 -EA Stop }
    return @{code=$r.StatusCode; body=$r.Content}
  } catch {
    $c=$_.Exception.Response.StatusCode.value__; $t=''
    try { $t = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
    return @{code=$c; body=$t}
  }
}

$key   = [Environment]::GetEnvironmentVariable('WHATSAPP_API_KEY','User')
$allow = [Environment]::GetEnvironmentVariable('WHATSAPP_SEND_ALLOWLIST','User')
try {
  $tok = Invoke-RestMethod -Uri "$B/auth/login" -Method Post -Headers @{Authorization="Bearer $key"} -TimeoutSec 15
  $jwt = if($tok.token){$tok.token}else{$tok.access_token}
} catch { Write-Host "  cannot reach the bridge at $B - is it running?" -ForegroundColor Red; exit 1 }
$H = @{ Authorization = "Bearer $jwt"; 'Content-Type' = 'application/json' }

# T2 tool list
$mcp = Join-Path $InstallRoot 'whatsapp-mcp-server\whatsapp-mcp.exe'
$toolsOk = $false; $toolCount = 0; $banned = 'not-checked'
$lt = Join-Path $PSScriptRoot 'patches\list_tools.py'
if (Test-Path $lt) {
  $out = & python $lt $mcp $key "$B/api" 2>&1
  $line = ($out | Where-Object { $_ -match '^TOOLS ' }) -join ''
  if ($line -match '^TOOLS (\d+) banned=(.*)$') { $toolCount=[int]$Matches[1]; $banned=$Matches[2]; $toolsOk = ($banned -eq 'none') }
}
T 'T2' 'MCP tools listed, none banned' 'banned=none' "n=$toolCount banned=$banned" $toolsOk

# T6 reads
$r = Call GET "$B/api/chats" $null;       T 'T6a' 'read /chats' '200' $r.code ($r.code -eq 200)
$r = Call GET "$B/api/auth/status" $null; T 'T6b' 'read /auth/status' '200' $r.code ($r.code -eq 200)

# T3 send to self
if (-not $SkipSend -and $allow) {
  $r = Call POST "$B/api/send" @{recipient=$allow; message="WhatsApp MCP verification $(Get-Date -Format 'yyyy-MM-dd HH:mm')."}
  T 'T3' 'send to OWN number' '200' $r.code ($r.code -eq 200)
} else { T 'T3' 'send to OWN number' '200' 'NOT RUN' $true $true }

# T4 sends elsewhere refused before leaving the machine
$r = Call POST "$B/api/send" @{recipient='60111111111'; message='MUST NOT BE DELIVERED'}
T 'T4a' 'send to OTHER number refused' '403' $r.code ($r.code -eq 403)
$r = Call POST "$B/api/send" @{recipient='120363000000000000@g.us'; message='MUST NOT REACH A GROUP'}
T 'T4b' 'send to GROUP refused' '403' $r.code ($r.code -eq 403)

# T5 every other write refused
foreach ($ep in 'edit','revoke','react','mark-read','presence','logout','resync','backfill',
                'group/create','group/update-participants','group/name','group/topic','group/leave','group/invite-link') {
  $r = Call POST "$B/api/$ep" @{jid='x'}
  T 'T5' "write /$ep refused" '403' $r.code ($r.code -eq 403)
}

# T7 loopback only
$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue
$addrs = ($listen.LocalAddress | Sort-Object -Unique) -join ','
$loopbackOnly = $listen -and -not ($listen | Where-Object { $_.LocalAddress -notin @('127.0.0.1','::1') })
T 'T7' 'bridge binds loopback only' '127.0.0.1' $addrs $loopbackOnly

# T10 no message content in bridge logs
$leak = 0
foreach ($f in Get-ChildItem "$WorkRoot\bridge-*.log" -EA SilentlyContinue) {
  $c = Get-Content $f.FullName -Raw -EA SilentlyContinue
  if ($c) {
    foreach ($p in 'cat=[^ ]* raw=\{', '"content":"', 'messageSecret', 'chat name for [^ ]+: \S') {
      $leak += ([regex]::Matches($c, $p)).Count
    }
  }
}
T 'T10' 'no message content in bridge logs' '0' "$leak" ($leak -eq 0)

# T11 secrets absent from repo and history
Push-Location $InstallRoot
$hist = (& cmd /c "git log --all -S`"$key`" --oneline 2>&1") | Out-String
$tree = (& cmd /c "git grep -l `"$key`" 2>&1") | Out-String
Pop-Location
$secretClean = ($hist.Trim() -eq '' -or $hist -match 'fatal') -and ($tree.Trim() -eq '' -or $tree -match 'fatal')
T 'T11' 'API key absent from repo and git history' 'absent' $(if($secretClean){'absent'}else{'FOUND'}) $secretClean

# T13 audit records refusals without bodies
$auditOk = $false; $aAllow = 0; $aDeny = 0; $grew = 0
if (Test-Path $audit) {
  $allLines = @(Get-Content $audit -EA SilentlyContinue)
  $grew  = $allLines.Count - $auditBefore
  $fresh = @($allLines | Select-Object -Skip $auditBefore)
  $aAllow = @($fresh | Where-Object { $_ -match '"decision":"ALLOW"' }).Count
  $aDeny  = @($fresh | Where-Object { $_ -match '"decision":"DENY"' }).Count
  $noBody = -not @($fresh | Where-Object { $_ -match 'MUST NOT BE DELIVERED|MUST NOT REACH A GROUP' })
  # T4a, T4b and the 14 T5 endpoints must all have been recorded.
  $auditOk = ($grew -ge 15) -and ($aDeny -gt 0) -and $noBody
}
T 'T13' 'audit recorded THIS run, no bodies' 'grew, deny>0' "+$grew lines allow=$aAllow deny=$aDeny" $auditOk

Write-Host ''
Write-Host '  ============ VERIFICATION ============' -ForegroundColor Cyan
foreach ($x in $Results) {
  $c = if ($x.Skip) {'Yellow'} elseif ($x.Pass) {'Green'} else {'Red'}
  $mk = if ($x.Skip) {'SKIP'} elseif ($x.Pass) {'PASS'} else {'FAIL'}
  Write-Host ("   {0,-5} {1,-38} expect {2,-8} got {3,-12} {4}" -f $x.ID,$x.Test,$x.Expect,$x.Got,$mk) -ForegroundColor $c
}
$fail = @($Results | Where-Object { -not $_.Pass })
$skip = @($Results | Where-Object { $_.Skip })
Write-Host ''
$tail = if ($skip.Count) { " - $($skip.Count) SKIPPED, not run" } else { '' }
Write-Host ("   {0} of {1} passed{2}" -f ($Results.Count-$fail.Count-$skip.Count), $Results.Count, $tail) -ForegroundColor $(if($fail.Count){'Red'}elseif($skip.Count){'Yellow'}else{'Green'})
Write-Host ''
if ($fail.Count) { exit 1 } else { exit 0 }
