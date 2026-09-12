package main

// Local write policy for the WhatsApp bridge.
//
// One gate in front of every /api route. Reads pass. Sending is permitted only
// to numbers on WHATSAPP_SEND_ALLOWLIST. Every other mutating endpoint is
// refused, including the ones that exist only as REST and were never MCP tools
// (/edit, /revoke, /react) and every /group/* operation.
//
// This sits below the tool layer on purpose: removing an MCP tool only stops
// the model, while anything holding the API key can still call the REST endpoint.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path"
	"strings"
	"sync"
	"time"
)

const (
	waAuditPath   = "store/audit.log"
	waMaxSendBody = 128 << 20 // 128 MiB, enough for base64 media

	// waCountryCode is the international dialling prefix these numbers use.
	// A Malaysian mobile is written either 60123456789 or 0123456789 - the same
	// phone. The allowlist is derived from the JID, which is always
	// international, so without the expansion below a user sending to their OWN
	// number the way they normally write it is refused.
	//
	// Change this to your own country's prefix if you are not in Malaysia.
	waCountryCode = "60"
)

var (
	waAllowOnce sync.Once
	waAllowSet  map[string]struct{}
	waAuditMu   sync.Mutex
)

// POST endpoints that do not change anything on WhatsApp, or that are required
// to establish the link in the first place. Pairing needs the physical phone,
// so it cannot be abused to send anything.
var waPermittedPost = map[string]bool{
	"/download":              true, // fetches media bytes for a message already visible
	"/auth/pair-phone":       true,
	"/auth/passkey-request":  true,
	"/auth/passkey-response": true,
	"/auth/passkey-code":     true,
	"/auth/passkey-confirm":  true,
}

// waEquivalentForms returns every spelling of one MSISDN that denotes the same
// phone: the digits as given, plus its international/local counterpart. The
// mapping is one-to-one, so this widens the allowlist to other spellings of the
// SAME number and never to a different number.
func waEquivalentForms(n string) []string {
	if n == "" {
		return nil
	}
	out := []string{n}
	switch {
	case strings.HasPrefix(n, waCountryCode) && len(n) > len(waCountryCode):
		out = append(out, "0"+n[len(waCountryCode):])
	case strings.HasPrefix(n, "0") && len(n) > 1:
		out = append(out, waCountryCode+n[1:])
	}
	return out
}

// waCanonicalMSISDN returns the international form, which is the only form a
// WhatsApp address accepts (60123456789@s.whatsapp.net). Widening the
// allowlist let a local-format number PASS the gate, but the handler then built
// 0123456789@s.whatsapp.net, hung for ~100s on a user-info lookup and failed -
// with an ALLOW already written to the audit log. The gate must therefore hand
// the handler the canonical number, so ALLOW means delivered.
func waCanonicalMSISDN(n string) string {
	if strings.HasPrefix(n, "0") && len(n) > 1 {
		return waCountryCode + n[1:]
	}
	return n
}

func waLoadAllowlist() {
	waAllowOnce.Do(func() {
		waAllowSet = make(map[string]struct{})
		phones := 0
		for _, p := range strings.Split(os.Getenv("WHATSAPP_SEND_ALLOWLIST"), ",") {
			n := waNormalizeMSISDN(p)
			if n == "" {
				continue
			}
			phones++
			for _, form := range waEquivalentForms(n) {
				waAllowSet[form] = struct{}{}
			}
		}
		if len(waAllowSet) == 0 {
			slog.Warn("policy: WHATSAPP_SEND_ALLOWLIST is empty - ALL sends will be refused (fail closed)")
		} else {
			slog.Info("policy: send allowlist loaded",
				"phones", phones, "accepted_spellings", len(waAllowSet))
		}
	})
}

// waNormalizeMSISDN reduces a recipient to bare digits: strips a JID domain,
// then a device suffix, then every non-digit. "+60 12-345 6789" and
// "60123456789:42@s.whatsapp.net" both become "60123456789".
func waNormalizeMSISDN(s string) string {
	if i := strings.IndexByte(s, '@'); i >= 0 {
		s = s[:i]
	}
	if i := strings.IndexByte(s, ':'); i >= 0 {
		s = s[:i]
	}
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// waMaskPhone keeps only the last 4 digits for logging.
func waMaskPhone(s string) string {
	d := waNormalizeMSISDN(s)
	if len(d) <= 4 {
		return "****"
	}
	return "****" + d[len(d)-4:]
}

// waIsNotIndividual rejects groups, broadcasts and status regardless of digits,
// so a group JID can never coincidentally match an allowlisted number.
func waIsNotIndividual(rec string) bool {
	r := strings.ToLower(rec)
	return strings.Contains(r, "@g.us") ||
		strings.Contains(r, "@broadcast") ||
		strings.Contains(r, "status@")
}

// waAudit appends one JSON object per line. Never the message body - only its
// length and SHA-256, so the log proves what was sent without holding content.
func waAudit(decision, endpoint, recipient, reason string, bodyLen int, bodySHA string) {
	waAuditMu.Lock()
	defer waAuditMu.Unlock()
	if err := os.MkdirAll("store", 0o700); err != nil {
		slog.Error("audit: cannot create store dir", "err", err)
		return
	}
	f, err := os.OpenFile(waAuditPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		slog.Error("audit: cannot open audit log", "err", err)
		return
	}
	defer f.Close()
	line, err := json.Marshal(map[string]any{
		"ts":          time.Now().UTC().Format(time.RFC3339),
		"decision":    decision,
		"endpoint":    endpoint,
		"recipient":   recipient,
		"reason":      reason,
		"body_len":    bodyLen,
		"body_sha256": bodySHA,
	})
	if err != nil {
		return
	}
	if _, err := f.Write(append(line, '\n')); err != nil {
		slog.Error("audit: write failed", "err", err)
	}
}

func waRefuse(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusForbidden)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"error":  "refused by local policy",
		"detail": msg,
	})
}

// waWriteGate wraps the whole API mux.
func waWriteGate(next http.Handler) http.Handler {
	waLoadAllowlist()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
			next.ServeHTTP(w, r) // reads always pass
			return
		}

		p := path.Clean(r.URL.Path)

		if waPermittedPost[p] {
			next.ServeHTTP(w, r)
			return
		}

		if p != "/send" {
			waAudit("DENY", p, "", "endpoint not permitted by local write policy", 0, "")
			slog.Warn("policy: write refused", "endpoint", p, "method", r.Method)
			waRefuse(w, "this bridge is read-only except for sending to the configured allowlist; "+p+" is not permitted")
			return
		}

		raw, err := io.ReadAll(io.LimitReader(r.Body, waMaxSendBody))
		_ = r.Body.Close()
		if err != nil {
			waAudit("DENY", p, "", "unreadable request body", 0, "")
			http.Error(w, "cannot read request body", http.StatusBadRequest)
			return
		}
		// Hand the untouched body to the real handler.
		r.Body = io.NopCloser(bytes.NewReader(raw))
		r.ContentLength = int64(len(raw))

		var probe struct {
			Recipient string `json:"recipient"`
			Message   string `json:"message"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			waAudit("DENY", p, "", "unparseable send payload", len(raw), "")
			waRefuse(w, "send payload could not be parsed")
			return
		}

		sum := sha256.Sum256([]byte(probe.Message))
		sha := hex.EncodeToString(sum[:])
		msgLen := len(probe.Message)

		if len(waAllowSet) == 0 {
			waAudit("DENY", p, probe.Recipient, "allowlist not configured (fail closed)", msgLen, sha)
			slog.Warn("policy: send refused, allowlist not configured")
			waRefuse(w, "WHATSAPP_SEND_ALLOWLIST is not configured, so every send is refused")
			return
		}
		if strings.TrimSpace(probe.Recipient) == "" {
			waAudit("DENY", p, "", "empty recipient", msgLen, sha)
			waRefuse(w, "recipient is required")
			return
		}
		if waIsNotIndividual(probe.Recipient) {
			waAudit("DENY", p, probe.Recipient, "group, broadcast or status destination", msgLen, sha)
			slog.Warn("policy: send refused, not an individual chat")
			waRefuse(w, "sending to groups, broadcasts or status is not permitted")
			return
		}

		n := waNormalizeMSISDN(probe.Recipient)
		if _, ok := waAllowSet[n]; !ok {
			waAudit("DENY", p, n, "recipient not on allowlist", msgLen, sha)
			slog.Warn("policy: send refused, recipient not allowlisted")
			waRefuse(w, "this recipient is not on the send allowlist")
			return
		}

		// Canonicalise the recipient the handler will see. Only that one field is
		// rewritten; every other field keeps its exact bytes (RawMessage), so media,
		// quotes and mentions pass through untouched. A recipient given as a full
		// JID (contains '@') is left alone - the handler parses those itself.
		canon := waCanonicalMSISDN(n)
		if !strings.Contains(probe.Recipient, "@") && probe.Recipient != canon {
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(raw, &fields); err == nil {
				if enc, err := json.Marshal(canon); err == nil {
					fields["recipient"] = enc
					if rewritten, err := json.Marshal(fields); err == nil {
						raw = rewritten
						r.Body = io.NopCloser(bytes.NewReader(raw))
						r.ContentLength = int64(len(raw))
					}
				}
			}
		}

		waAudit("ALLOW", p, canon, "", msgLen, sha)
		next.ServeHTTP(w, r)
	})
}
