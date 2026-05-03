package main

import (
	"net/url"
	"strings"
)

// oauthQueryLike returns the substring that looks like a URL query (?code=…) or raw &... pairs.
func oauthQueryLike(s string) string {
	s = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(s, "\r", ""), "\n", ""))
	if s == "" {
		return ""
	}
	if i := strings.Index(s, "?"); i >= 0 {
		return strings.TrimSpace(s[i+1:])
	}
	return s
}

func oauthQueryValue(q, wantKey string) string {
	wantKey = strings.TrimSpace(wantKey)
	q = strings.TrimSpace(q)
	for _, part := range strings.Split(q, "&") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		k, v, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		if strings.TrimSpace(k) != wantKey {
			continue
		}
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		decoded, err := url.QueryUnescape(v)
		if err != nil || strings.TrimSpace(decoded) == "" {
			return v
		}
		return strings.TrimSpace(decoded)
	}
	return ""
}

func oauthCodeFromPairs(q string) string {
	return oauthQueryValue(q, "code")
}

func oauthIDTokenFromPairs(q string) string {
	return oauthQueryValue(q, "id_token")
}

func oauthPlainCodeAmpersandState(s string) string {
	s = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(s, "\r", ""), "\n", ""))
	idx := strings.Index(s, "&state=")
	if idx <= 0 {
		return ""
	}
	pfx := strings.TrimSpace(s[:idx])
	if pfx == "" {
		return ""
	}
	for _, chk := range []string{"=", "?", "/", " "} {
		if strings.Contains(pfx, chk) {
			return ""
		}
	}
	return pfx
}

func extractOAuthCodeFromPaste(s string) string {
	s = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(s, "\r", ""), "\n", ""))
	if s == "" {
		return ""
	}

	if u, err := url.Parse(s); err == nil && u.Scheme != "" && strings.Contains(s, "://") && u.RawQuery != "" {
		if v := oauthCodeFromPairs(u.RawQuery); v != "" {
			return v
		}
		if v := oauthIDTokenFromPairs(u.RawQuery); v != "" {
			return v
		}
	}

	qblob := oauthQueryLike(s)
	if qb := oauthCodeFromPairs(qblob); qb != "" {
		return qb
	}
	if qb := oauthIDTokenFromPairs(qblob); qb != "" {
		return qb
	}

	if pc := oauthPlainCodeAmpersandState(qblob); pc != "" {
		return pc
	}

	if !strings.ContainsAny(s, "&=?/") && s != "" {
		return s
	}

	return ""
}

func authCodeFromInput(codeField, callbackURL string) string {
	codeField = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(codeField, "\r", ""), "\n", ""))
	callbackURL = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(callbackURL, "\r", ""), "\n", ""))

	for _, s := range []string{callbackURL, codeField} {
		if s == "" {
			continue
		}
		if v := extractOAuthCodeFromPaste(s); v != "" {
			return v
		}
	}
	return ""
}
