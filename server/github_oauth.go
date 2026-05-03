package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	htempl "html"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

var (
	githubOAuthClientID     = strings.TrimSpace(os.Getenv("GITHUB_OAUTH_CLIENT_ID"))
	githubOAuthClientSecret = strings.TrimSpace(os.Getenv("GITHUB_OAUTH_CLIENT_SECRET"))
	// Optional: public URL of this API, e.g. http://127.0.0.1:8990 or https://planulix.example.com
	// Must match the "Authorization callback URL" host/path registered in the GitHub OAuth App.
	githubOAuthPublicBase = strings.TrimSpace(os.Getenv("GITHUB_OAUTH_PUBLIC_BASE"))
)

func githubOAuthServerConfigured() bool {
	return githubOAuthClientID != "" && githubOAuthClientSecret != ""
}

// GitHubOAuthStatus reports whether server-side GitHub OAuth is available (browser login, no client secret in app).
func (s *SessionServer) GitHubOAuthStatus(c *gin.Context) {
	c.JSON(200, gin.H{"configured": githubOAuthServerConfigured()})
}

func (s *SessionServer) cleanupGitHubOAuthPending() {
	now := time.Now()
	for k, v := range s.gitHubOAuthPending {
		if v == nil || now.After(v.deadline) {
			delete(s.gitHubOAuthPending, k)
		}
	}
}

func (s *SessionServer) startRedirectURI(c *gin.Context) string {
	if githubOAuthPublicBase != "" {
		return strings.TrimRight(githubOAuthPublicBase, "/") + "/api/github/oauth/callback"
	}
	proto := c.Request.Header.Get("X-Forwarded-Proto")
	if proto == "" {
		if c.Request.TLS != nil {
			proto = "https"
		} else {
			proto = "http"
		}
	}
	host := c.Request.Host
	if h := c.Request.Header.Get("X-Forwarded-Host"); h != "" {
		host = h
	}
	return fmt.Sprintf("%s://%s/api/github/oauth/callback", proto, host)
}

// StartGitHubOAuth returns authorize_url and state; client opens URL in browser, then polls GitHubOAuthResult.
func (s *SessionServer) StartGitHubOAuth(c *gin.Context) {
	if !githubOAuthServerConfigured() {
		c.JSON(501, gin.H{
			"error": "GitHub OAuth is not configured on this server",
			"hint":  "Set GITHUB_OAUTH_CLIENT_ID and GITHUB_OAUTH_CLIENT_SECRET. Register callback URL: {PUBLIC}/api/github/oauth/callback (use GITHUB_OAUTH_PUBLIC_BASE if needed).",
		})
		return
	}

	redirectURI := s.startRedirectURI(c)
	state := randomOAuthState()

	s.gitHubOAuthMu.Lock()
	s.cleanupGitHubOAuthPending()
	s.gitHubOAuthPending[state] = &pendingGitHubOAuth{
		deadline:    time.Now().Add(15 * time.Minute),
		redirectURI: redirectURI,
	}
	s.gitHubOAuthMu.Unlock()

	authURL := fmt.Sprintf(
		"https://github.com/login/oauth/authorize?client_id=%s&redirect_uri=%s&state=%s&scope=%s",
		url.QueryEscape(githubOAuthClientID),
		url.QueryEscape(redirectURI),
		url.QueryEscape(state),
		url.QueryEscape("repo read:user"),
	)
	c.JSON(200, gin.H{"authorize_url": authURL, "state": state, "redirect_uri": redirectURI})
}

func randomOAuthState() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

// GitHubOAuthCallback is called by GitHub in the user's browser (no Bearer auth).
func (s *SessionServer) GitHubOAuthCallback(c *gin.Context) {
	if c.Query("error") != "" {
		c.Data(200, "text/html; charset=utf-8", []byte(oauthDonePage("Отказано", "Можно закрыть это окно.")))
		return
	}
	code := c.Query("code")
	state := c.Query("state")
	if code == "" || state == "" {
		c.Status(400)
		return
	}

	s.gitHubOAuthMu.Lock()
	pending, ok := s.gitHubOAuthPending[state]
	if !ok || time.Now().After(pending.deadline) {
		s.gitHubOAuthMu.Unlock()
		c.Data(200, "text/html; charset=utf-8", []byte(oauthDonePage("Сессия истекла", "Начните вход снова из Planulix.")))
		return
	}
	redirectURI := pending.redirectURI
	s.gitHubOAuthMu.Unlock()

	token, err := exchangeGitHubOAuthCode(code, redirectURI)
	if err != nil {
		s.gitHubOAuthMu.Lock()
		delete(s.gitHubOAuthPending, state)
		s.gitHubOAuthMu.Unlock()
		c.Data(200, "text/html; charset=utf-8", []byte(oauthDonePage("Ошибка GitHub", htempl.EscapeString(err.Error()))))
		return
	}

	s.gitHubOAuthMu.Lock()
	delete(s.gitHubOAuthPending, state)
	if s.gitHubOAuthTokens == nil {
		s.gitHubOAuthTokens = make(map[string]string)
	}
	s.gitHubOAuthTokens[state] = token
	s.gitHubOAuthMu.Unlock()

	c.Data(200, "text/html; charset=utf-8", []byte(oauthDonePage("Готово", "Можно закрыть окно и вернуться в приложение.")))
}

func oauthDonePage(title, bodyHTML string) string {
	return fmt.Sprintf(`<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>%s</title></head><body style="font-family:system-ui,-apple-system,sans-serif;padding:2rem;background:#0f172a;color:#e2e8f0;max-width:36rem;"><h1 style="font-size:1.25rem;">%s</h1><p style="color:#94a3b8;line-height:1.5;">%s</p></body></html>`,
		htempl.EscapeString(title), htempl.EscapeString(title), bodyHTML)
}

func exchangeGitHubOAuthCode(code, redirectURI string) (string, error) {
	form := url.Values{}
	form.Set("client_id", githubOAuthClientID)
	form.Set("client_secret", githubOAuthClientSecret)
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)

	req, err := http.NewRequest(http.MethodPost, "https://github.com/login/oauth/access_token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	cli := &http.Client{Timeout: 30 * time.Second}
	res, err := cli.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("token exchange: HTTP %d: %s", res.StatusCode, string(body))
	}

	var out struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
		Desc        string `json:"error_description"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("token JSON: %w", err)
	}
	if out.Error != "" {
		return "", fmt.Errorf("%s: %s", out.Error, out.Desc)
	}
	if out.AccessToken == "" {
		return "", fmt.Errorf("empty access_token")
	}
	return out.AccessToken, nil
}

// GitHubOAuthResult returns the access token once after successful callback (single use).
func (s *SessionServer) GitHubOAuthResult(c *gin.Context) {
	state := c.Query("state")
	if state == "" {
		c.JSON(400, gin.H{"error": "state is required"})
		return
	}
	s.gitHubOAuthMu.Lock()
	tok, ok := s.gitHubOAuthTokens[state]
	if ok {
		delete(s.gitHubOAuthTokens, state)
	}
	s.gitHubOAuthMu.Unlock()
	if !ok {
		c.JSON(404, gin.H{"error": "pending", "message": "complete login in browser"})
		return
	}
	c.JSON(200, gin.H{"access_token": tok})
}
