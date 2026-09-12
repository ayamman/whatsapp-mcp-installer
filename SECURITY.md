# Security model and known limits

Read this before rolling the installer out to more than one laptop.

## What the package guarantees

| Property | How it is enforced |
|---|---|
| Sends reach only the number that paired | The allowlist is derived from the bridge's own `jid` after the QR scan, never typed into a config. It cannot be mistyped into somebody else's number. |
| Every other write is refused | A gate wraps the whole `/api` mux *below* the tool layer, so removing an MCP tool is not the control — anything holding the API key still hits the gate. 14 endpoints plus all `group/*` return 403. |
| Not reachable from the network | The bridge binds `127.0.0.1`. Verified live by `verify.ps1` (T7). |
| No message text in logs | Seven log statements in the upstream bridge are rewritten to log lengths and hashes instead of content. Verified live (T10). |
| Secrets never committed | Generated on the machine, stored in Windows user environment variables, passed to the registrar on stdin. Verified against the repo and its git history (T11). |
| Every send and refusal is recorded | `store/audit.log`, one JSON object per line, with the message's length and SHA-256 — never its text. Verified that *this run* was recorded (T13). |

`verify.ps1` re-runs all 24 checks against a live install at any time.

## What it does not guarantee

**1. The one-line bootstrap trusts this GitHub account.**
`irm … | iex` runs whatever `get.ps1` contains at the moment you run it. The
bootstrap then pins the *package* to the newest tag and prints the ref and the
archive's SHA-256, so what got installed is auditable afterwards — but the
bootstrap itself is fetched from `main` and is not pinned. Anyone who takes over
the account can change it.

Mitigations, in order of strength:

- Clone the repo and read it before running, instead of piping (see the README).
- Pass `-Ref v1.0.0` to pin an exact reviewed version.
- Keep 2FA on the account that owns this repo. That is the whole root of trust.

**2. It compiles from source on every laptop.** A CGO dependency means each
machine needs a C compiler (~261 MB). Removing that so one machine can build for
all is the right fix for a fleet and has not been done.

**3. Smart App Control.** The bridge is unsigned. If Windows moves from
Evaluation to Enforcement, the bridge stops running. The gate blocks the install
when Enforcement is already on, but it cannot stop Windows changing its mind
later.

**4. No uninstaller.** `install-manifest.json` records everything needed for a
deterministic removal — install root, both binary hashes, the scheduled task,
env vars, client configs touched. The script that consumes it does not exist yet.

**5. No audit-log retention.** `audit.log` grows without limit.

**6. Unofficial WhatsApp connection.** This is against WhatsApp's terms of
service and the number can be banned. Nothing technical here changes that.

## Reporting a problem

Open an issue. Do not include `install.log` contents if you have edited the
package — the stock log contains no secrets and no message text, but a modified
one might.
