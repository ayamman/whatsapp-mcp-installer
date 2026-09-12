#!/usr/bin/env python3
"""Remove destructive WhatsApp group-management MCP tools.
Keeps list_groups (read-only). Removes the nine tools that change groups.
Self-verifying: refuses to write unless exactly the expected tools were removed.
Idempotent: a second run on an already-patched file reports "already" and exits 0.
"""
import re, sys, pathlib

REMOVE = [
    "create_group", "add_group_participants", "remove_group_participants",
    "promote_group_admins", "demote_group_admins", "set_group_name",
    "set_group_topic", "get_group_invite_link", "leave_group",
]
KEEP = ["list_groups"]

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

orig = src

block_re = re.compile(
    r"[ \t]*mcp\.AddTool\[[^\]]*\]\(server, &mcp\.Tool\{.*?\n[ \t]*\}, \w+Handler\)\n(?:\n)?",
    re.DOTALL,
)

removed = []

def repl(m):
    blk = m.group(0)
    nm = re.search(r'Name:\s*"([^"]+)"', blk)
    if nm and nm.group(1) in REMOVE:
        removed.append(nm.group(1))
        return ""
    return blk

src = block_re.sub(repl, src)
src = re.sub(r"[ \t]*// ── Group management ─+\n",
             "\t// Groups: read-only. Destructive group tools removed.\n", src)

still_present = [t for t in REMOVE if re.search(r'Name:\s*"%s"' % re.escape(t), src)]
kept_ok = all(('"%s"' % k) in src for k in KEEP)

# Idempotency (URS R8). Nothing left to remove, none of the nine registered and
# the read-only tool intact means this file was already patched. Report and
# change nothing, rather than failing and stopping the installer mid-run.
if not removed and not still_present and kept_ok:
    print("already: the nine destructive group tools are absent")
    print("already: kept %s" % ", ".join(KEEP))
    sys.exit(0)

missing = [t for t in REMOVE if t not in removed]
if missing:
    sys.exit("FAIL: did not find these tools to remove: %s (still registered: %s)"
             % (", ".join(missing), ", ".join(still_present) or "none"))
extra = [t for t in removed if t not in REMOVE]
if extra:
    sys.exit("FAIL: removed unexpected tools: %s" % ", ".join(extra))
for k in KEEP:
    if ('"%s"' % k) not in src:
        sys.exit("FAIL: %s was removed but must be kept" % k)
for t in REMOVE:
    if re.search(r'Name:\s*"%s"' % re.escape(t), src):
        sys.exit("FAIL: %s still registered after edit" % t)
if src == orig:
    sys.exit("FAIL: no change made")

path.write_text(src, encoding="utf-8")
print("OK removed %d tools: %s" % (len(removed), ", ".join(removed)))
print("OK kept: %s" % ", ".join(KEEP))
