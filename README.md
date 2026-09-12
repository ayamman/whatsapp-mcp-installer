# Local WhatsApp MCP — installer

Connects one WhatsApp account to Claude on one Windows laptop. Reads your chats.
Sends **only to your own number**. Nothing else.

The bridge runs on your machine and listens on `127.0.0.1` only. It is not a
cloud service and there is no server to sign in to.

## Install

Open **PowerShell** (a normal one — *not* "Run as administrator") and paste:

```powershell
irm https://raw.githubusercontent.com/ayamman/whatsapp-mcp-installer/main/get.ps1 | iex
```

That downloads the newest released version, prints the exact commit it fetched,
and runs the installer.

**Stage 1 is a requirement check.** If your laptop is missing something, it
prints exactly what and **stops without changing anything**. Fix the listed
items and run it again.

When the QR code appears: on your phone, **WhatsApp → Linked Devices → Link a
Device**, then scan. The square refreshes itself — scan whichever one is on
screen.

At the end, **quit Claude completely and reopen it** (check the arrow near the
clock — closing the window is not quitting). Your WhatsApp tools appear after
the restart.

### Options

The pipe form cannot take arguments. Use the script-block form:

```powershell
# check the laptop and stop, changing nothing
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ayamman/whatsapp-mcp-installer/main/get.ps1))) -DryRun

# pin this laptop to an exact version
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ayamman/whatsapp-mcp-installer/main/get.ps1))) -Ref v1.0.0

# do not let it install missing build tools for you
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ayamman/whatsapp-mcp-installer/main/get.ps1))) -NoAutoFix
```

### Or download first, read it, then run

If you would rather not pipe a script from the internet straight into your shell
— a reasonable position — clone and run it locally:

```powershell
git clone https://github.com/ayamman/whatsapp-mcp-installer $env:USERPROFILE\Dev\whatsapp-mcp-installer
cd $env:USERPROFILE\Dev\whatsapp-mcp-installer
powershell -ExecutionPolicy Bypass -File .\install.ps1 -AutoFix
```

## Before you start

- Windows 10/11, 64-bit
- Your phone with WhatsApp, to scan a QR code
- About 20 minutes, most of it unattended
- Roughly 1 GB of build tooling on a fresh laptop — git, Go, Python and a C
  compiler. `-AutoFix` (on by default) installs missing ones at user scope
- Your laptop stays on for this to work

## What it does to your laptop

| | |
|---|---|
| Installs to | `%USERPROFILE%\Dev\whatsapp-mcp-go` |
| Working files | `%USERPROFILE%\Dev\wa-mcp` — logs, launcher, manifest |
| Background service | Scheduled task "WhatsAppBridge (local)", starts at logon, no elevation |
| Network | Listens on `127.0.0.1` only. Not reachable from your network |
| Secrets | Generated on your machine, stored in Windows user environment variables. Never in this repo, never in git |
| Your messages | SQLite files under `whatsapp-bridge\store`. They stay on your laptop |

## What it will not do

- **Send to anyone but you.** The allowlist is set from the number that actually
  paired, so it cannot be pointed at somebody else. Your own number is accepted
  written either way — `60123456789` or `0123456789`.
- Create, rename or leave groups; add or remove members; edit, delete or react to
  messages; mark chats read; change your presence; log your account out. All
  refused at the bridge, not merely hidden from the model.
- Write your message text into any log file.

Every send and every refusal is recorded in `whatsapp-bridge\store\audit.log`
with the message's length and SHA-256 — never its text.

## Checking it later

```powershell
powershell -ExecutionPolicy Bypass -File .\verify.ps1
```

Runs 24 acceptance checks against your live install, including proving that a
send to another number is refused.

```powershell
powershell -ExecutionPolicy Bypass -File .\test-rules.ps1
```

Sends one message to your own number in both spellings and probes one refusal.

## Things you should know

- **This uses an unofficial WhatsApp connection. It is against WhatsApp's terms
  of service and the number can be banned.** Understand that before you link a
  number that matters to you.
- Pairing uses one of WhatsApp's **four linked-device slots** on your number.
- **Smart App Control**: if Windows has it in Enforcement the installer stops,
  because the bridge is an unsigned program. The gate tells you.
- Do not install into OneDrive. Sync corrupts the message database. The gate
  checks this.

## If something goes wrong

The full transcript is at `%USERPROFILE%\Dev\wa-mcp\install.log`. It contains no
passwords and no message text, so it is safe to share when asking for help.

## Not covered

macOS and Linux. The requirement gate is Windows-only — a Mac needs Xcode
Command Line Tools rather than a Windows compiler, and Gatekeeper rather than
Smart App Control.

## What this repo actually contains

This is the **installer and the security patches**, not the WhatsApp bridge
itself. The bridge is third-party software
([vimigo-lee/whatsapp-mcp-go](https://github.com/vimigo-lee/whatsapp-mcp-go)),
cloned at a pinned commit and then patched by this package before it is built:

```
install.ps1                     8-stage orchestrator
get.ps1                         one-line bootstrap
verify.ps1                      24 acceptance checks
test-rules.ps1                  three-message send-rule proof
swap-mcp.ps1                    clean up older MCP registrations
lib/preflight.ps1               19-check requirement gate, -Simulate for dry runs
patches/policy.go               write gate, allowlist, audit log
patches/apply_write_gate.py     self-verifying patcher, idempotent
patches/harden_mcp_client.py    fail-closed API base URL, SSRF guard
patches/remove_group_tools.py   self-verifying tool removal
patches/register_clients.py     Claude Desktop + Claude Code registration
patches/list_tools.py           live MCP tools/list check
```

Every patcher verifies its own result and refuses to write if anything is off.
All are idempotent — a second run reports "already" and changes nothing.

See [SECURITY.md](SECURITY.md) for the trust model and known limits.

## Licence

MIT — see [LICENSE](LICENSE). The bridge it installs is licensed separately by
its own authors.
