package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type cloneGitHubBody struct {
	CloneURL  string `json:"clone_url" binding:"required"`
	Name      string `json:"name" binding:"required"`
	Token     string `json:"github_token"` // optional: private repos & higher rate limits
	Overwrite bool   `json:"overwrite"`
}

// CloneGitHubRepo runs `git clone` into ~/projects/<name>. Token is passed via
// https://x-access-token:TOKEN@github.com/... (never logged).
func (s *SessionServer) CloneGitHubRepo(c *gin.Context) {
	var body cloneGitHubBody
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(400, gin.H{"error": "expected JSON: clone_url, name, optional github_token"})
		return
	}
	name := strings.TrimSpace(body.Name)
	if name == "" || strings.ContainsAny(name, "/\\..") {
		c.JSON(400, gin.H{"error": "invalid project name"})
		return
	}

	cloneURL := strings.TrimSpace(body.CloneURL)
	if cloneURL == "" || (!strings.HasPrefix(cloneURL, "https://") && !strings.HasPrefix(cloneURL, "http://")) {
		c.JSON(400, gin.H{"error": "clone_url must be an https git URL"})
		return
	}

	home, _ := os.UserHomeDir()
	baseDir := filepath.Join(home, "projects")
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("failed to create projects dir: %v", err)})
		return
	}
	targetDir := filepath.Join(baseDir, name)

	if _, err := os.Stat(targetDir); err == nil {
		if !body.Overwrite {
			c.JSON(409, gin.H{"error": "project already exists", "path": targetDir})
			return
		}
		_ = normalizeProjectWritable(targetDir)
		if err := os.RemoveAll(targetDir); err != nil {
			c.JSON(500, gin.H{"error": fmt.Sprintf("failed to remove existing: %v", err)})
			return
		}
	}

	authedURL := cloneURL
	if tok := strings.TrimSpace(body.Token); tok != "" {
		authedURL = injectGitHubHTTPSAuth(cloneURL, tok)
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), 20*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", "clone", "--depth", "1", authedURL, targetDir)
	cmd.Env = append(os.Environ(),
		"GIT_TERMINAL_PROMPT=0",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		_ = os.RemoveAll(targetDir)
		c.JSON(500, gin.H{"error": fmt.Sprintf("git clone failed: %v", err), "details": sanitizeGitErr(string(out))})
		return
	}
	_ = out
	if err := normalizeProjectWritable(targetDir); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("normalize project permissions: %v", err), "path": targetDir})
		return
	}
	_ = exec.CommandContext(ctx, "git", "-C", targetDir, "config", "--local", "core.sharedRepository", "false").Run()
	_ = exec.CommandContext(ctx, "git", "-C", targetDir, "config", "--local", "core.fileMode", "true").Run()
	gitWritable, gitWritableError := probeGitWritable(targetDir)
	if !gitWritable {
		c.JSON(500, gin.H{
			"error":            "clone completed but .git is not writable",
			"path":             targetDir,
			"gitWritable":      false,
			"gitWritableError": gitWritableError,
			"repairSuggestion": "Run POST /api/projects/repair?name=" + name + " or fix filesystem mount/owner on the server.",
		})
		return
	}

	c.JSON(200, gin.H{"ok": true, "path": targetDir, "gitWritable": true})
}

func injectGitHubHTTPSAuth(httpsURL, token string) string {
	const pref = "https://"
	if !strings.HasPrefix(httpsURL, pref) {
		return httpsURL
	}
	hostPath := strings.TrimPrefix(httpsURL, pref)
	return pref + "x-access-token:" + token + "@" + hostPath
}

// sanitizeGitErr strips any accidental token-like fragments from error text.
func sanitizeGitErr(s string) string {
	s = strings.ReplaceAll(s, "x-access-token:", "x-access-token:***")
	if len(s) > 2000 {
		s = s[:2000] + "…"
	}
	return s
}
