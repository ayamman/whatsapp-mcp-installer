#!/usr/bin/env python3
"""Register the WhatsApp MCP server with Claude Desktop and Claude Code.
Merges one entry, preserves every other server, backs up first, never prints the key.
Usage: register_clients.py <installRoot> <keyFile|-> <port>
"-" reads the key from stdin so it never touches the disk.
"""
import json, os, shutil, sys, datetime, re

INSTALL_ROOT, KEYFILE, PORT = sys.argv[1], sys.argv[2], sys.argv[3]
EXE = os.path.join(INSTALL_ROOT, "whatsapp-mcp-server", "whatsapp-mcp.exe")
NAME = "whatsapp-mcp"
STALE = ["whatsapp", "whatsapp-mcp-go", "whatsapp_mcp"]

if not os.path.exists(EXE):
    sys.exit("FAIL: MCP binary not found at %s" % EXE)
key = (sys.stdin.read() if KEYFILE == "-" else open(KEYFILE, encoding="ascii").read()).strip()
if not re.fullmatch(r"[0-9a-f]{64}", key):
    sys.exit("FAIL: API key is not 64 hex chars")

ENTRY = {"command": EXE,
         "env": {"WHATSAPP_API_KEY": key,
                 "API_BASE_URL": "http://127.0.0.1:%s/api" % PORT}}

def register(path, label):
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        try:
            cfg = json.load(open(path, encoding="utf-8"))
        except Exception as e:
            print("  FAIL: %s is not valid JSON (%s); left untouched" % (label, e)); return False
    else:
        cfg = {}
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        print("  %s did not exist; creating" % label)
    servers = cfg.setdefault("mcpServers", {})
    for s in STALE:
        if s in servers:
            del servers[s]
            print("  removed stale '%s'" % s)
    servers[NAME] = ENTRY
    for proj, pv in (cfg.get("projects") or {}).items():
        pms = pv.get("mcpServers") if isinstance(pv, dict) else None
        if isinstance(pms, dict):
            for s in list(pms):
                if "whatsapp" in s.lower():
                    del pms[s]
                    print("  removed '%s' from project %s" % (s, proj))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    json.load(open(tmp, encoding="utf-8"))
    os.replace(tmp, path)
    print("  %s: now has %s" % (label, sorted(servers.keys())))
    return True

ok = True
appdata = os.environ.get("APPDATA")
if appdata:
    ok &= register(os.path.join(appdata, "Claude", "claude_desktop_config.json"), "Claude Desktop")
ok &= register(os.path.join(os.path.expanduser("~"), ".claude.json"), "Claude Code")
sys.exit(0 if ok else 1)
