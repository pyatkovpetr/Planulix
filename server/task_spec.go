package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type taskSpecRequest struct {
	Cwd    string `json:"cwd"`
	Prompt string `json:"prompt"`
	Agent  string `json:"agent"`
	Model  string `json:"model"`
	Title  string `json:"title"`
}

func (s *SessionServer) CreateTaskSpec(c *gin.Context) {
	var req taskSpecRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request"})
		return
	}
	req.Cwd = normalizeSessionCwd(req.Cwd)
	req.Prompt = strings.TrimSpace(req.Prompt)
	if req.Prompt == "" {
		c.JSON(400, gin.H{"error": "prompt is required"})
		return
	}
	if err := ensureProjectWritableForAgent(req.Cwd); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("project permission repair failed: %v", err), "cwd": req.Cwd})
		return
	}

	specRoot := taskSpecRoot(req.Cwd)
	id := fmt.Sprintf("PLX-%s", time.Now().Format("20060102-150405"))
	dir := filepath.Join(specRoot, id)
	if err := os.MkdirAll(dir, 0755); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	agent := normalizeRequestedAgent(req.Agent, req.Model)
	title := strings.TrimSpace(req.Title)
	if title == "" {
		title = firstLine(req.Prompt)
	}
	product := renderProductSpec(id, title, req.Prompt)
	tech := renderTechSpec(id, title, req.Cwd, agent, req.Model)
	productPath := filepath.Join(dir, "product.md")
	techPath := filepath.Join(dir, "tech.md")
	if err := os.WriteFile(productPath, []byte(product), 0644); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	if err := os.WriteFile(techPath, []byte(tech), 0644); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	launchPrompt := fmt.Sprintf("Работай по сохраненной спецификации задачи.\n\nSpec: %s\nProduct: %s\nTech: %s\n\nИсходный запрос пользователя:\n%s", dir, productPath, techPath, req.Prompt)
	c.JSON(201, gin.H{
		"ok":           true,
		"id":           id,
		"path":         dir,
		"productPath":  productPath,
		"techPath":     techPath,
		"launchPrompt": launchPrompt,
	})
}

func taskSpecRoot(cwd string) string {
	root, ok := projectRootForPath(cwd)
	if ok {
		return filepath.Join(root, "docs", "specs")
	}
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return filepath.Join(".", "specs")
	}
	return filepath.Join(home, ".planulix", "specs")
}

func firstLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			if len(line) > 80 {
				return line[:80] + "..."
			}
			return line
		}
	}
	return "Planulix task"
}

func renderProductSpec(id, title, prompt string) string {
	return fmt.Sprintf(`# %s Product Spec

## Goal
%s

## User Request
%s

## Expected Behavior
- Keep the existing user workflow intact.
- Make the requested behavior visible in Planulix UI or server responses.
- Report honest failure reasons instead of generic agent errors.

## Edge Cases
- Missing CLI/auth configuration.
- Read-only project or .git directory.
- Network or GitHub push failures.
- Empty or malformed agent history files.

## Acceptance
- The task has a clear implementation diff.
- The relevant checks pass.
- The final response names changed files and any remaining risk.
`, id, title, prompt)
}

func renderTechSpec(id, title, cwd, agent, model string) string {
	if strings.TrimSpace(model) == "" {
		model = "provider-default"
	}
	return fmt.Sprintf(`# %s Tech Spec

## Task
%s

## Context
- cwd: %s
- agent: %s
- model: %s

## Implementation Notes
- Prefer existing Planulix APIs and UI patterns.
- Keep server-side state explicit and serializable.
- Do not create duplicate raw agent sessions when Planulix owns a managed `+"`cd-*`"+` session.
- Preserve writable Git worktrees and return exact permission/network failures.

## Verification
- Run focused Go tests for server behavior.
- Run Flutter analyze/tests for UI changes.
- Exercise the affected chat/session flow when practical.
`, id, title, cwd, agent, model)
}
