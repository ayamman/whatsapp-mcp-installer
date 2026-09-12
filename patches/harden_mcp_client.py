#!/usr/bin/env python3
"""Hardening for the MCP server (the half that sits ABOVE the bridge).

S4  API_BASE_URL fails closed instead of defaulting to the upstream author's
    private LAN address (http://192.168.178.119:30015/api). If that variable is
    ever missing, this process would otherwise post the API key and message
    payloads to a stranger's network - or to whatever answers on that address
    inside yours.

S3  send_media/upload_media can be given a public URL which the MCP server
    fetches SERVER-SIDE. That fetch happens above the bridge, so the write gate
    never sees it: it cannot be stopped by the allowlist. On a laptop inside an
    office network that is a request originating inside the network. This adds a
    dialer that refuses loopback, RFC1918, link-local and multicast addresses -
    enforced at the socket, so redirects and DNS rebinding are covered too.

Self-verifying and idempotent, like the other patchers in this package.
Usage: harden_mcp_client.py <installRoot>
"""
import re, sys, pathlib

ROOT = pathlib.Path(sys.argv[1])
TOOLS = ROOT / "whatsapp-mcp-server" / "helpers" / "tools.go"
MCPT  = ROOT / "whatsapp-mcp-server" / "helpers" / "mcp_tool.go"
for f in (TOOLS, MCPT):
    if not f.exists():
        sys.exit("FAIL: %s not found" % f)

# A checkout patched by an older build of this package carries the same helpers
# under a different prefix. Normalise them by shape rather than by their old
# spelling, so the anchors below still match and a healthy install can re-patch.
# (install.ps1 stashes local edits before re-patching, so this is a safety net
# for a checkout patched by hand.)
MIGRATE_RE = [
    (re.compile(r"\b\w+SafeHTTPClient\b"), "waSafeHTTPClient"),
    (re.compile(r"\b\w+BlockedIP\b"),      "waBlockedIP"),
    (re.compile(r"refused by \w+ policy"),   "refused by local policy"),
]

changed = []

for f in (TOOLS, MCPT):
    s = f.read_text(encoding="utf-8")
    o = s
    for rx, repl in MIGRATE_RE:
        s = rx.sub(repl, s)
    if s != o:
        f.write_text(s, encoding="utf-8")
        print("migrated: %s" % f.name)

# ---------------------------------------------------------------- S4
t = TOOLS.read_text(encoding="utf-8")
S4_OLD = '\tif v := ReadEnv("API_BASE_URL", "http://192.168.178.119:30015/api"); v != "" {\n\t\treturn v\n\t}\n\tconst fallback = "http://localhost:8080/api"\n\tslog.Warn("api_base_url not set, using default", "fallback", fallback)\n\treturn fallback'
S4_NEW = '''\tif v := ReadEnv("API_BASE_URL", ""); v != "" {
\t\treturn v
\t}
\t// Fail closed. Upstream defaulted to a private address on the author's own
\t// network; unset here, this process would have sent the API key and every
\t// message payload to whatever answers there. There is no safe guess.
\tslog.Error("API_BASE_URL is not set - refusing to start rather than guess a bridge address")
\tos.Exit(2)
\treturn ""'''
if S4_OLD in t:
    t = t.replace(S4_OLD, S4_NEW, 1); changed.append("S4 : API_BASE_URL fails closed")
    TOOLS.write_text(t, encoding="utf-8")
elif "refusing to start rather than guess" in t:
    print("already : S4 API_BASE_URL fails closed")
else:
    sys.exit("FAIL: could not find readApiBaseURL's default in tools.go")

# ---------------------------------------------------------------- S3
m = MCPT.read_text(encoding="utf-8")
GUARD = '''
// waBlockedIP reports whether an address is one this tool must never reach:
// loopback, private (RFC1918), link-local, unique-local, multicast or
// unspecified. The MCP server runs on a laptop inside an office network, so a
// URL fetch here is a request originating INSIDE that network. The bridge's
// write gate cannot see this call - it happens above the bridge - so the check
// has to live here.
func waBlockedIP(ip net.IP) bool {
\treturn ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsUnspecified() ||
\t\tip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() ||
\t\tip.IsInterfaceLocalMulticast()
}

// waSafeHTTPClient refuses to connect to internal addresses. The check lives in
// the dialer rather than on the hostname so that redirects and DNS rebinding are
// covered too: every connection this client opens is checked at the socket.
func waSafeHTTPClient(timeout time.Duration) *http.Client {
\tdialer := &net.Dialer{Timeout: timeout}
\treturn &http.Client{
\t\tTimeout: timeout,
\t\tTransport: &http.Transport{
\t\t\tDialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
\t\t\t\thost, _, err := net.SplitHostPort(addr)
\t\t\t\tif err != nil {
\t\t\t\t\treturn nil, err
\t\t\t\t}
\t\t\t\tips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
\t\t\t\tif err != nil {
\t\t\t\t\treturn nil, err
\t\t\t\t}
\t\t\t\tfor _, ip := range ips {
\t\t\t\t\tif waBlockedIP(ip) {
\t\t\t\t\t\treturn nil, fmt.Errorf("refused by local policy: %s resolves to internal address %s", host, ip)
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\treturn dialer.DialContext(ctx, network, addr)
\t\t\t},
\t\t},
\t}
}
'''

if "func waSafeHTTPClient" in m:
    print("already : S3 server-side URL fetch is guarded")
else:
    # imports
    for pkg in ('"net"', '"time"'):
        if re.search(r'^\t%s$' % re.escape(pkg), m, re.M) is None:
            m = m.replace('\t"net/http"\n', '\t"net"\n\t"net/http"\n', 1) if pkg == '"net"' \
                else m.replace('\t"strings"\n', '\t"strings"\n\t"time"\n', 1)
    if not re.search(r'^\t"net"$', m, re.M) or not re.search(r'^\t"time"$', m, re.M):
        sys.exit("FAIL: could not add the net/time imports to mcp_tool.go")
    # the arbitrary-URL fetch only - NOT the manager upload client further down
    ANCHOR = '''\t\thttpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
\t\tif err != nil {
\t\t\treturn &mcp.CallToolResult{IsError: true}, map[string]any{"success": false, "error": err.Error()}, nil
\t\t}
\t\tclient := &http.Client{Timeout: apiTimeout}'''
    if m.count(ANCHOR) != 1:
        sys.exit("FAIL: expected exactly one arbitrary-URL fetch site, found %d" % m.count(ANCHOR))
    m = m.replace(ANCHOR, ANCHOR.replace(
        '\t\tclient := &http.Client{Timeout: apiTimeout}',
        '\t\tclient := waSafeHTTPClient(apiTimeout) // refuses internal addresses'), 1)
    m = m.rstrip("\n") + "\n" + GUARD
    MCPT.write_text(m, encoding="utf-8")
    changed.append("S3 : server-side URL fetch refuses internal addresses")

# ---------------------------------------------------------------- verify
t = TOOLS.read_text(encoding="utf-8"); m = MCPT.read_text(encoding="utf-8")
problems = []
if "192.168.178.119" in t:
    problems.append("the upstream private-LAN default is still in tools.go")
if "refusing to start rather than guess" not in t:
    problems.append("API_BASE_URL does not fail closed")
if "func waSafeHTTPClient" not in m:
    problems.append("the safe HTTP client is missing")
if "client := waSafeHTTPClient(apiTimeout)" not in m:
    problems.append("the URL fetch is not using the safe client")
if re.search(r'client := &http\.Client\{Timeout: apiTimeout\}\n\t\tresp, err := client\.Do\(httpReq\)', m):
    problems.append("the URL fetch is still using an unguarded client")
if problems:
    sys.exit("FAIL: " + "; ".join(problems))

for c in changed:
    print("APPLIED : " + c)
print()
print("VERIFIED:")
print("  API_BASE_URL fails closed; the private-LAN default is gone")
print("  server-side URL fetches refuse loopback, RFC1918, link-local and multicast")
