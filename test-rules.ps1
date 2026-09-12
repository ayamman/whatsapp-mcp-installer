<#
  Local WhatsApp MCP - three-message rule test (R2).

  1  own number, international  60xxxxxxxxx   expect 200  delivered
  2  some other number                        expect 403  refused at the bridge
  3  own number, LOCAL format   0xxxxxxxxx    expect 200  delivered (canonicalised to 60...)

  Your own number is never hardcoded: it comes from WHATSAPP_SEND_ALLOWLIST,
  which the installer derived from the number that actually paired.

  -Other defaults to an unassigned number, so test 2 proves the refusal without
  involving anybody. Pass a real number ONLY if that person has agreed to be
  probed - the message is refused at the bridge and should never arrive, and the
  point of using a real number is to have them confirm that it did not.

  Run as yourself, NOT elevated:
    powershell -ExecutionPolicy Bypass -File .\test-rules.ps1
#>
param(
  [int]$Port = 8080,
  [string]$Other = '60111111111',
  [string]$InstallRoot = "$env:USERPROFILE\Dev\whatsapp-mcp-go"
)
$ErrorActionPreference = 'Continue'
$B     = "http://127.0.0.1:$Port"
$audit = Join-Path $InstallRoot 'whatsapp-bridge\store\audit.log'

$key   = [Environment]::GetEnvironmentVariable('WHATSAPP_API_KEY','User')
$allow = [Environment]::GetEnvironmentVariable('WHATSAPP_SEND_ALLOWLIST','User')

if (-not $key)   { Write-Host "  WHATSAPP_API_KEY is not set for this user. Are you running elevated as someone else?" -ForegroundColor Red; exit 1 }
if (-not $allow) { Write-Host "  WHATSAPP_SEND_ALLOWLIST is not set. The bridge would refuse every send." -ForegroundColor Red; exit 1 }

# own number in both shapes: 60xxxxxxxxx  <->  0xxxxxxxxx
$intl  = $allow.Split(',')[0].Trim()
$local = if ($intl -match '^60(\d+)$') { '0' + $Matches[1] } else { $intl }

try {
  $tok = Invoke-RestMethod -Uri "$B/auth/login" -Method Post -Headers @{Authorization="Bearer $key"} -TimeoutSec 15
  $jwt = if ($tok.token) { $tok.token } else { $tok.access_token }
} catch { Write-Host "  cannot log in to the bridge at $B - is it running?" -ForegroundColor Red; exit 1 }
$H = @{ Authorization = "Bearer $jwt"; 'Content-Type' = 'application/json' }

$before = if (Test-Path $audit) { (Get-Content $audit).Count } else { 0 }

function Send-Probe($to,$text) {
  try {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "$B/api/send" -Method POST -Headers $H `
              -Body (@{recipient=$to; message=$text} | ConvertTo-Json) -TimeoutSec 45 -EA Stop
    return $resp.StatusCode
  } catch {
    $c = $_.Exception.Response.StatusCode.value__
    # A hung send has no HTTP status. Say so, rather than showing a blank that
    # then gets scored as a refusal.
    if ($c) { return $c } else { return 'TIMEOUT' }
  }
}

$Cases = @(
  @{ N='1'; To=$intl;   Expect=200; What="own number, international ($intl)"
     Msg="Rules test 1 of 3 - allowed recipient. Expected: delivered." },
  @{ N='2'; To=$Other;  Expect=403; What="another number ($Other)"
     Msg="Automated policy test. This message should have been blocked at source and must NOT have arrived. If you are reading it, the policy gate failed - please report it." },
  @{ N='3'; To=$local;  Expect=200; What="own number, LOCAL format ($local)"
     Msg="Rules test 3 of 3 - own number written in local format. Expected: delivered." }
)

$Out = @()
foreach ($c in $Cases) {
  $code = Send-Probe $c.To $c.Msg
  $verdict = if ($code -eq $c.Expect) { 'as expected' }
             elseif ($code -eq 200) { 'DELIVERED (unexpected)' }
             elseif ($code -eq 403) { 'REFUSED (unexpected)' }
             else { "FAILED ($code)" }
  $Out += [pscustomobject]@{ N=$c.N; Case=$c.What; Expect=$c.Expect; Got=$code; Verdict=$verdict }
  Start-Sleep -Milliseconds 600
}

Write-Host ''
Write-Host '  ============ R2 RULE TEST ============' -ForegroundColor Cyan
foreach ($x in $Out) {
  $col = if ($x.Verdict -eq 'as expected') {'Green'} else {'Red'}
  Write-Host ("   {0}  {1,-42} expect {2,-13} got {3,-5} {4}" -f $x.N,$x.Case,$x.Expect,$x.Got,$x.Verdict) -ForegroundColor $col
}

Write-Host ''
Write-Host '  ---- new audit lines written by this test ----' -ForegroundColor Cyan
if (Test-Path $audit) {
  $all = Get-Content $audit
  $new = $all | Select-Object -Skip $before
  if ($new) { $new | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray } }
  else      { Write-Host '   NONE - the gate recorded nothing. That is itself a finding.' -ForegroundColor Red }
  Write-Host ''
  Write-Host ("   audit.log: {0} lines before, {1} after (+{2})" -f $before,$all.Count,($all.Count-$before)) -ForegroundColor Gray
}
Write-Host ''
Write-Host '  All three "as expected" = R2 holds: your number delivers in either format,' -ForegroundColor Yellow
Write-Host '  anyone else is refused at the bridge. Check your phone for tests 1 and 3.' -ForegroundColor Yellow
Write-Host ''
