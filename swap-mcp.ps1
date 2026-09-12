<#
  Confirm the old WhatsApp MCP is gone and the new one is registered.
  Reads both Claude configs, removes any WhatsApp entry that is NOT the new
  'whatsapp-mcp', and reports. Backs up each file first. Safe to re-run.

  Run as yourself:
    powershell -ExecutionPolicy Bypass -File .\swap-mcp.ps1
#>
$ErrorActionPreference = 'Continue'
$KEEP = 'whatsapp-mcp'          # the new server; everything else whatsapp-ish is old
$exe  = "$env:USERPROFILE\Dev\whatsapp-mcp-go\whatsapp-mcp-server\whatsapp-mcp.exe"

$targets = @(
  @{ label='Claude Desktop'; path="$env:APPDATA\Claude\claude_desktop_config.json" },
  @{ label='Claude Code';    path="$env:USERPROFILE\.claude.json" }
)

foreach ($t in $targets) {
  Write-Host ''
  Write-Host "== $($t.label): $($t.path)" -ForegroundColor Cyan
  if (-not (Test-Path $t.path)) { Write-Host '   (no config file - nothing registered here)' -ForegroundColor DarkGray; continue }

  try { $cfg = Get-Content $t.path -Raw | ConvertFrom-Json } catch { Write-Host "   NOT valid JSON, left untouched: $($_.Exception.Message)" -ForegroundColor Red; continue }

  $servers = $cfg.mcpServers
  if (-not $servers) { Write-Host '   no mcpServers section' -ForegroundColor DarkGray; continue }

  $names = @($servers.PSObject.Properties.Name)
  $wa    = @($names | Where-Object { $_ -match 'whatsapp' })
  Write-Host "   before: $([string]::Join(', ', $wa))" -ForegroundColor Gray

  # back up once per run
  Copy-Item $t.path "$($t.path).bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -EA SilentlyContinue

  $removed = @()
  foreach ($n in $wa) {
    if ($n -ne $KEEP) { $servers.PSObject.Properties.Remove($n); $removed += $n }
  }

  # project-level leftovers (Claude Code)
  if ($cfg.projects) {
    foreach ($p in $cfg.projects.PSObject.Properties) {
      $pms = $p.Value.mcpServers
      if ($pms) {
        foreach ($pn in @($pms.PSObject.Properties.Name)) {
          if ($pn -match 'whatsapp' -and $pn -ne $KEEP) { $pms.PSObject.Properties.Remove($pn); $removed += "$pn (project $($p.Name))" }
        }
      }
    }
  }

  if ($removed.Count) {
    $cfg | ConvertTo-Json -Depth 20 | Set-Content $t.path -Encoding UTF8
    Write-Host "   removed old: $([string]::Join(', ', $removed))" -ForegroundColor Yellow
  } else {
    Write-Host '   no old WhatsApp entries to remove' -ForegroundColor Green
  }

  if ($servers.$KEEP) {
    $cmd = $servers.$KEEP.command
    $ok  = Test-Path $cmd
    Write-Host "   new '$KEEP' -> $cmd  [$(if($ok){'exe found'}else{'EXE MISSING'})]" -ForegroundColor $(if($ok){'Green'}else{'Red'})
  } else {
    Write-Host "   '$KEEP' is NOT registered here - run install.ps1 to add it" -ForegroundColor Red
  }
}

Write-Host ''
Write-Host '  Done. Now QUIT Claude fully (check the arrow by the clock) and reopen it' -ForegroundColor Yellow
Write-Host '  so it reloads the server list.' -ForegroundColor Yellow
Write-Host ''
