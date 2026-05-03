package main

import (
	"context"
	"crypto/subtle"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

// perIPRateLimiter is a tiny token-bucket limiter keyed by client IP.
// It caps request rate without pulling in an external dependency.
type perIPRateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*ipBucket
	rate    float64 // tokens per second
	burst   float64
	maxIdle time.Duration
}

type ipBucket struct {
	tokens   float64
	lastSeen time.Time
}

func newPerIPRateLimiter(rate, burst float64) *perIPRateLimiter {
	l := &perIPRateLimiter{
		buckets: make(map[string]*ipBucket),
		rate:    rate,
		burst:   burst,
		maxIdle: 5 * time.Minute,
	}
	go l.gcLoop()
	return l
}

func (l *perIPRateLimiter) gcLoop() {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for range t.C {
		now := time.Now()
		l.mu.Lock()
		for k, b := range l.buckets {
			if now.Sub(b.lastSeen) > l.maxIdle {
				delete(l.buckets, k)
			}
		}
		l.mu.Unlock()
	}
}

func (l *perIPRateLimiter) Allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	b, ok := l.buckets[ip]
	if !ok {
		b = &ipBucket{tokens: l.burst, lastSeen: now}
		l.buckets[ip] = b
	} else {
		b.tokens += now.Sub(b.lastSeen).Seconds() * l.rate
		if b.tokens > l.burst {
			b.tokens = l.burst
		}
		b.lastSeen = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "agent" {
		RunCloudGatewayAgentWorker()
		return
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8990"
	}

	token := os.Getenv("AUTH_TOKEN")
	if token == "" {
		// Default token is intentionally empty — refuse to start so release builds
		// don't ship with a well-known secret.
		log.Fatal("AUTH_TOKEN is required; refusing to start with an empty/default token")
	}
	expectedAuthHeader := "Bearer " + token

	claudeHome := os.Getenv("CLAUDE_HOME")
	if claudeHome == "" {
		home, _ := os.UserHomeDir()
		claudeHome = home + "/.claude"
	}

	srv := NewSessionServer(claudeHome)

	r := gin.Default()

	// GitHub browser OAuth: GitHub redirects the user's browser here (no Bearer token).
	r.GET("/api/github/oauth/callback", srv.GitHubOAuthCallback)

	// Rate limit: 20 req/s per IP, burst of 60. Protects polling endpoints.
	limiter := newPerIPRateLimiter(20, 60)
	r.Use(func(c *gin.Context) {
		if !limiter.Allow(c.ClientIP()) {
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "rate limit"})
			return
		}
		c.Next()
	})

	// Auth middleware — accepts Bearer header OR ?token= query param (for WebSocket).
	// Constant-time comparison to avoid timing leaks.
	api := r.Group("/api", func(c *gin.Context) {
		auth := c.GetHeader("Authorization")
		if subtle.ConstantTimeCompare([]byte(auth), []byte(expectedAuthHeader)) == 1 {
			c.Next()
			return
		}
		if q := c.Query("token"); subtle.ConstantTimeCompare([]byte(q), []byte(token)) == 1 {
			c.Next()
			return
		}
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
	})

	api.GET("/sessions", srv.ListSessions)
	api.GET("/sessions/:id", srv.GetSession)
	api.POST("/sessions", srv.CreateSession)
	api.POST("/sessions/:id/message", srv.SendMessage)
	api.DELETE("/sessions/:id", srv.StopSession)
	api.POST("/sessions/:id/interrupt", srv.InterruptSession)
	api.POST("/sessions/:id/continue", srv.ContinueSession)
	api.GET("/sessions/:id/stream", srv.StreamSession)
	api.GET("/sessions/:id/events", srv.SessionEventsWS)
	api.GET("/file", srv.ReadFile)
	api.GET("/cost", srv.GetCostSummary)
	api.GET("/pricing", srv.GetModelPricing)
	api.GET("/capabilities", srv.GetCapabilities)
	api.GET("/sessions/:id/cost", srv.GetSessionCost)
	api.GET("/search", srv.Search)
	api.GET("/activity", srv.GetActivity)
	api.PUT("/sessions/:id/star", srv.SetStar)
	api.PUT("/sessions/:id/tags", srv.SetTags)
	api.PUT("/sessions/:id/title", srv.SetTitle)
	api.GET("/tags", srv.GetAllTags)
	api.GET("/projects", srv.GetProjects)
	api.POST("/upload", srv.UploadProject)
	api.POST("/projects/clone", srv.CloneGitHubRepo)
	// Короткий алиас (если прокси/старые клиенты мешают длинному пути).
	api.POST("/clone", srv.CloneGitHubRepo)
	api.DELETE("/projects", srv.DeleteProject)
	api.GET("/disk-info", srv.GetDiskInfo)
	api.GET("/yadisk/upload-url", srv.GetYadiskUploadURL)
	api.POST("/yadisk/import", srv.ImportFromYadisk)
	api.PUT("/file", srv.WriteFile)
	api.GET("/grep", srv.GrepInFiles)
	api.GET("/files/list", srv.FileList)
	api.GET("/terminal", srv.TerminalWS)
	api.GET("/files/tree", srv.GetFileTree)
	api.GET("/git/status", srv.GetGitStatus)
	api.GET("/git/diff", srv.GetGitDiff)
	api.GET("/git/log", srv.GetGitLog)
	api.GET("/network-info", srv.GetNetworkInfo)
	api.POST("/upload-image", srv.UploadImage)
	api.GET("/skills", srv.GetSkills)

	api.GET("/github/oauth/status", srv.GitHubOAuthStatus)
	api.POST("/github/oauth/start", srv.StartGitHubOAuth)
	api.GET("/github/oauth/result", srv.GitHubOAuthResult)

	api.POST("/setup/claude-code/install", srv.InstallClaudeCode)
	api.POST("/setup/claude-code/auth/start", srv.StartClaudeCodeAuth)
	api.GET("/setup/claude-code/auth/state", srv.ClaudeAuthState)
	api.POST("/setup/claude-code/auth/stop", srv.StopClaudeCodeAuth)

	// Public health check (no auth) for ping
	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(200, gin.H{"ok": true, "service": "planulix"})
	})

	hs := &http.Server{
		Addr:              ":" + port,
		Handler:           r,
		ReadHeaderTimeout: 15 * time.Second,
	}

	go func() {
		log.Printf("Planulix server starting on :%s (claude_home=%s)", port, claudeHome)
		if err := hs.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	// Graceful shutdown: drain active requests before exit.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := hs.Shutdown(ctx); err != nil {
		log.Printf("forced shutdown: %v", err)
	}
	log.Println("server stopped")
}
