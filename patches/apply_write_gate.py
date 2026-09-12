#!/usr/bin/env python3
"""Install the write gate, audit log and log redaction into the bridge.
Self-verifying: refuses to write unless every edit applied and every
verification passes. Idempotent: safe to re-run.
"""
import pathlib, re, shutil, sys, datetime

REPO = pathlib.Path(sys.argv[1])
SRC  = pathlib.Path(sys.argv[2])
MAIN = REPO / "whatsapp-bridge" / "main.go"
DEST = REPO / "whatsapp-bridge" / "policy.go"

# A checkout patched by an older build of this package calls the same helpers
# under a different prefix. Normalise them by shape rather than by their old
# spelling, or the "middleware rewire" anchor below is already gone and a
# perfectly healthy install fails to re-patch. (install.ps1 stashes local edits
# before re-patching, so this is a safety net for a checkout patched by hand.)
MIGRATE_RE = [
    (re.compile(r"\b\w+WriteGate\(apiMux\)"), "waWriteGate(apiMux)"),
    (re.compile(r"\b\w+MaskPhone\("),          "waMaskPhone("),
]

EDITS = [
    ("middleware rewire",
     "protected := auth.JwtAuthMiddleware(cfg, apiMux)",
     "protected := auth.JwtAuthMiddleware(cfg, waWriteGate(apiMux))"),
    ("redact every message body (media branch)",
     'slog.Info("message", "ts", timestamp, "direction", direction, "sender", sender, "media_type", mediaType, "filename", filename, "content", content)',
     'slog.Info("message", "ts", timestamp, "direction", direction, "sender", sender, "media_type", mediaType, "filename", filename, "content_len", len(content))'),
    ("redact every message body (text branch)",
     'slog.Info("message", "ts", timestamp, "direction", direction, "sender", sender, "content", content)',
     'slog.Info("message", "ts", timestamp, "direction", direction, "sender", sender, "content_len", len(content))'),
    ("redact outgoing send body",
     'slog.Info("received request to send message", "message", req.Message, "media_path", req.MediaPath)',
     'slog.Info("received request to send message", "message_len", len(req.Message), "has_media", req.MediaPath != "" || req.MediaBase64 != "")'),
    ("mask phone number on pair-phone",
     'slog.Info("pair-phone requested", "phone", body.Phone,',
     'slog.Info("pair-phone requested", "phone", waMaskPhone(body.Phone),'),
    ("neutralise MSG-DEBUG raw message dump",
     'logger.Infof("MSG-DEBUG id=%s chat=%s type=%s cat=%s raw=%s", msg.Info.ID, chatJID, msg.Info.Type, msg.Info.Category, string(b))',
     'logger.Debugf("MSG-DEBUG id=%s chat=%s type=%s cat=%s raw_len=%d", msg.Info.ID, chatJID, msg.Info.Type, msg.Info.Category, len(b))'),
    ("stop logging contact display names",
     'logger.Infof("Using existing chat name for %s: %s", chatJID, existingName)',
     'logger.Debugf("Using existing chat name for %s (len=%d)", chatJID, len(existingName))'),
]

if not MAIN.exists():
    sys.exit("FAIL: %s not found" % MAIN)

text = MAIN.read_text(encoding="utf-8")

before = text
for rx, repl in MIGRATE_RE:
    text = rx.sub(repl, text)
if text != before:
    MAIN.write_text(text, encoding="utf-8")
    print("migrated: normalised helper names in main.go")

applied, already = [], []

for label, old, new in EDITS:
    if new in text:
        already.append(label); continue
    n = text.count(old)
    if n == 0:
        sys.exit("FAIL: could not find the code for '%s'. Source differs from the reviewed commit." % label)
    if n > 1:
        sys.exit("FAIL: '%s' matched %d times; refusing to edit ambiguously." % (label, n))
    text = text.replace(old, new, 1)
    applied.append(label)

policy_new = SRC.read_text(encoding="utf-8")
policy_changed = (not DEST.exists()) or DEST.read_text(encoding="utf-8") != policy_new

if applied:
    bak = MAIN.with_suffix(".go.bak-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(MAIN, bak)
    MAIN.write_text(text, encoding="utf-8")
    print("backed up main.go -> %s" % bak.name)
if policy_changed:
    DEST.write_text(policy_new, encoding="utf-8")
    print("installed %s" % DEST.name)

for l in applied: print("APPLIED : %s" % l)
for l in already: print("already : %s" % l)

final = MAIN.read_text(encoding="utf-8")
problems = []
if "waWriteGate(apiMux)" not in final:
    problems.append("write gate is not wired into the middleware chain")
if 'auth.JwtAuthMiddleware(cfg, apiMux)' in final:
    problems.append("the ungated middleware line is still present")
for bad, why in [('"content", content)', "message content still logged"),
                 ('"message", req.Message', "outgoing send body still logged"),
                 ('"phone", body.Phone', "unmasked phone number still logged"),
                 ('cat=%s raw=%s', "MSG-DEBUG still dumps raw message content"),
                 ('chat name for %s: %s', "contact display names still logged")]:
    if bad in final:
        problems.append(why)
if not DEST.exists():
    problems.append("policy.go was not installed")
else:
    pol = DEST.read_text(encoding="utf-8")
    for need in ("func waWriteGate", "func waAudit", "func waNormalizeMSISDN",
                 "func waIsNotIndividual", "func waMaskPhone", "WHATSAPP_SEND_ALLOWLIST"):
        if need not in pol:
            problems.append("policy.go is missing %s" % need)

if problems:
    print("\nVERIFICATION FAILED:")
    for p in problems: print("  - %s" % p)
    sys.exit(1)

print("\nVERIFIED:")
print("  write gate wired in front of every /api route")
print("  message content, send bodies and phone numbers removed from logs")
print("  policy.go present with allowlist, audit and normalisation")
