#!/usr/bin/env python3
"""Speak MCP stdio to whatsapp-mcp.exe and report the tool list."""
import json, os, subprocess, sys, threading, time
EXE, KEY, BASE = sys.argv[1], sys.argv[2], sys.argv[3]
BANNED = ["create_group","add_group_participants","remove_group_participants",
          "promote_group_admins","demote_group_admins","set_group_name",
          "set_group_topic","get_group_invite_link","leave_group"]
if len(KEY) != 64 and os.path.exists(KEY):
    KEY = open(KEY, encoding="ascii").read().strip()
env = dict(os.environ); env["WHATSAPP_API_KEY"] = KEY; env["API_BASE_URL"] = BASE
p = subprocess.Popen([EXE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env, text=True, encoding="utf-8", bufsize=1)
threading.Thread(target=lambda: [None for _ in p.stderr], daemon=True).start()
def send(o): p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
def read(i, t=30):
    end=time.time()+t
    while time.time()<end:
        l=p.stdout.readline()
        if not l: return None
        l=l.strip()
        if not l: continue
        try: m=json.loads(l)
        except Exception: continue
        if m.get("id")==i: return m
    return None
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-verify","version":"1"}}})
if not read(1):
    print("TOOLS 0 banned=initialize-failed"); p.kill(); sys.exit(1)
send({"jsonrpc":"2.0","method":"notifications/initialized"})
send({"jsonrpc":"2.0","id":2,"method":"tools/list"})
r = read(2)
p.kill()
if not r:
    print("TOOLS 0 banned=list-failed"); sys.exit(1)
names = [t["name"] for t in r.get("result", {}).get("tools", [])]
leaked = [b for b in BANNED if b in names]
print("TOOLS %d banned=%s" % (len(names), ",".join(leaked) if leaked else "none"))
