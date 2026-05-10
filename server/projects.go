package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type ProjectInfo struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Branch    string `json:"branch,omitempty"`
	IsGit     bool   `json:"isGit"`
	Modified  int    `json:"modified,omitempty"`
	Untracked int    `json:"untracked,omitempty"`
}

// GetProjects scans common directories for git projects
func (s *SessionServer) GetProjects(c *gin.Context) {
	home, _ := os.UserHomeDir()
	scanDirs := []string{
		filepath.Join(home, "projects"),
		filepath.Join(home, "WORK"),
		filepath.Join(home, "work"),
		filepath.Join(home, "code"),
		filepath.Join(home, "dev"),
		filepath.Join(home, "src"),
	}

	// Allow custom scan dir via query
	if custom := c.Query("path"); custom != "" {
		scanDirs = []string{custom}
	}

	projects := make([]ProjectInfo, 0)
	seen := make(map[string]bool)

	for _, dir := range scanDirs {
		if _, err := os.Stat(dir); os.IsNotExist(err) {
			continue
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			fullPath := filepath.Join(dir, e.Name())
			if seen[fullPath] {
				continue
			}
			seen[fullPath] = true

			info := ProjectInfo{
				Name: e.Name(),
				Path: fullPath,
			}

			gitDir := filepath.Join(fullPath, ".git")
			if stat, err := os.Stat(gitDir); err == nil && stat.IsDir() {
				info.IsGit = true
				info.Branch = readGitBranch(fullPath)
				info.Modified, info.Untracked = quickGitCount(fullPath)
			}

			projects = append(projects, info)
		}
	}

	sort.Slice(projects, func(i, j int) bool {
		if projects[i].IsGit != projects[j].IsGit {
			return projects[i].IsGit
		}
		return projects[i].Name < projects[j].Name
	})

	c.JSON(200, gin.H{"projects": projects})
}

func readGitBranch(path string) string {
	headFile := filepath.Join(path, ".git", "HEAD")
	data, err := os.ReadFile(headFile)
	if err != nil {
		return ""
	}
	content := strings.TrimSpace(string(data))
	if strings.HasPrefix(content, "ref: refs/heads/") {
		return strings.TrimPrefix(content, "ref: refs/heads/")
	}
	if len(content) > 7 {
		return content[:7]
	}
	return content
}

func quickGitCount(path string) (int, int) {
	cmd := exec.Command("git", "-C", path, "status", "--porcelain")
	out, err := cmd.Output()
	if err != nil {
		return 0, 0
	}
	modified := 0
	untracked := 0
	for _, line := range strings.Split(string(out), "\n") {
		if len(line) < 2 {
			continue
		}
		if strings.HasPrefix(line, "??") {
			untracked++
		} else {
			modified++
		}
	}
	return modified, untracked
}

// FileTreeEntry represents one file or directory
type FileTreeEntry struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	IsDir    bool   `json:"isDir"`
	Size     int64  `json:"size,omitempty"`
	GitState string `json:"gitState,omitempty"` // "M", "A", "D", "??", ""
}

// GetFileTree returns a directory listing
func (s *SessionServer) GetFileTree(c *gin.Context) {
	path := c.Query("path")
	if path == "" {
		c.JSON(400, gin.H{"error": "path is required"})
		return
	}

	// Resolve ~
	if strings.HasPrefix(path, "~") {
		home, _ := os.UserHomeDir()
		path = filepath.Join(home, strings.TrimPrefix(path, "~"))
	}

	entries, err := os.ReadDir(path)
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	// Get git status for this dir (if inside a git repo)
	gitStates := getGitStates(path)

	result := make([]FileTreeEntry, 0, len(entries))
	for _, e := range entries {
		// Skip noise
		name := e.Name()
		if name == ".git" || name == "node_modules" || name == ".DS_Store" {
			continue
		}

		fullPath := filepath.Join(path, name)
		info, _ := e.Info()

		entry := FileTreeEntry{
			Name:  name,
			Path:  fullPath,
			IsDir: e.IsDir(),
		}
		if info != nil {
			entry.Size = info.Size()
		}
		if state, ok := gitStates[name]; ok {
			entry.GitState = state
		}

		result = append(result, entry)
	}

	// Sort: directories first, then alphabetically
	sort.Slice(result, func(i, j int) bool {
		if result[i].IsDir != result[j].IsDir {
			return result[i].IsDir
		}
		return strings.ToLower(result[i].Name) < strings.ToLower(result[j].Name)
	})

	c.JSON(200, gin.H{"entries": result, "path": path})
}

// getGitStates returns a map of filename -> git state for files in a directory
func getGitStates(dirPath string) map[string]string {
	result := make(map[string]string)

	// Find git root
	cmd := exec.Command("git", "-C", dirPath, "rev-parse", "--show-toplevel")
	out, err := cmd.Output()
	if err != nil {
		return result
	}
	gitRoot := strings.TrimSpace(string(out))

	// Get relative path from git root
	relPath, err := filepath.Rel(gitRoot, dirPath)
	if err != nil {
		return result
	}

	// Run git status
	cmd = exec.Command("git", "-C", gitRoot, "status", "--porcelain")
	out, err = cmd.Output()
	if err != nil {
		return result
	}

	for _, line := range strings.Split(string(out), "\n") {
		if len(line) < 4 {
			continue
		}
		state := strings.TrimSpace(line[:2])
		file := line[3:]
		// Handle rename (R old -> new)
		if idx := strings.Index(file, " -> "); idx >= 0 {
			file = file[idx+4:]
		}

		// Check if file is in our directory
		var rel string
		if relPath == "." {
			rel = file
		} else {
			if !strings.HasPrefix(file, relPath+"/") && file != relPath {
				continue
			}
			rel = strings.TrimPrefix(file, relPath+"/")
		}

		// Get just the top-level name (dir or file in current listing)
		if idx := strings.Index(rel, "/"); idx >= 0 {
			topName := rel[:idx]
			if _, exists := result[topName]; !exists {
				result[topName] = "M" // directory containing changes
			}
		} else {
			result[rel] = state
		}
	}

	return result
}

// GetGitStatus returns porcelain status for a directory
func (s *SessionServer) GetGitStatus(c *gin.Context) {
	cwd := c.Query("cwd")
	if cwd == "" {
		c.JSON(400, gin.H{"error": "cwd is required"})
		return
	}

	cmd := exec.Command("git", "-C", cwd, "status", "--porcelain", "-b")
	out, err := cmd.Output()
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	type StatusEntry struct {
		State string `json:"state"`
		File  string `json:"file"`
	}

	var branch string
	entries := make([]StatusEntry, 0)
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if strings.HasPrefix(line, "## ") {
			branchLine := strings.TrimPrefix(line, "## ")
			if idx := strings.Index(branchLine, "..."); idx >= 0 {
				branch = branchLine[:idx]
			} else {
				branch = branchLine
			}
			continue
		}
		if len(line) < 4 {
			continue
		}
		entries = append(entries, StatusEntry{
			State: strings.TrimSpace(line[:2]),
			File:  line[3:],
		})
	}

	c.JSON(200, gin.H{"branch": branch, "entries": entries})
}

// GetGitDiff returns unified diff for a file
func (s *SessionServer) GetGitDiff(c *gin.Context) {
	cwd := c.Query("cwd")
	file := c.Query("file")
	if cwd == "" || file == "" {
		c.JSON(400, gin.H{"error": "cwd and file are required"})
		return
	}

	// Try normal diff first
	cmd := exec.Command("git", "-C", cwd, "diff", "--no-color", "HEAD", "--", file)
	out, err := cmd.CombinedOutput()
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error(), "output": string(out)})
		return
	}

	diffText := string(out)

	// If empty, try untracked file (show as all additions)
	if strings.TrimSpace(diffText) == "" {
		fullPath := filepath.Join(cwd, file)
		if data, err := os.ReadFile(fullPath); err == nil {
			var b strings.Builder
			b.WriteString("diff --git a/" + file + " b/" + file + "\n")
			b.WriteString("new file\n")
			b.WriteString("--- /dev/null\n")
			b.WriteString("+++ b/" + file + "\n")
			scanner := bufio.NewScanner(strings.NewReader(string(data)))
			scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024)
			lineCount := 0
			for scanner.Scan() {
				lineCount++
			}
			b.WriteString("@@ -0,0 +1," + itoa(lineCount) + " @@\n")
			for _, line := range strings.Split(string(data), "\n") {
				b.WriteString("+" + line + "\n")
			}
			diffText = b.String()
		}
	}

	// Parse into structured format for easier client rendering
	lines := parseDiff(diffText)

	c.JSON(200, gin.H{
		"file":  file,
		"raw":   diffText,
		"lines": lines,
	})
}

type DiffLine struct {
	Type    string `json:"type"` // "add", "del", "context", "hunk", "header"
	Content string `json:"content"`
	OldLine int    `json:"oldLine,omitempty"`
	NewLine int    `json:"newLine,omitempty"`
}

func parseDiff(diff string) []DiffLine {
	var lines []DiffLine
	oldLine := 0
	newLine := 0
	for _, line := range strings.Split(diff, "\n") {
		if strings.HasPrefix(line, "diff --git") || strings.HasPrefix(line, "index ") || strings.HasPrefix(line, "---") || strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "new file") || strings.HasPrefix(line, "deleted file") {
			lines = append(lines, DiffLine{Type: "header", Content: line})
			continue
		}
		if strings.HasPrefix(line, "@@") {
			// Parse @@ -x,y +a,b @@
			lines = append(lines, DiffLine{Type: "hunk", Content: line})
			// Extract starting line numbers
			parts := strings.Split(line, " ")
			for _, p := range parts {
				if strings.HasPrefix(p, "-") {
					cleanP := strings.TrimPrefix(p, "-")
					if idx := strings.Index(cleanP, ","); idx >= 0 {
						cleanP = cleanP[:idx]
					}
					if n, err := parseInt(cleanP); err == nil {
						oldLine = n
					}
				} else if strings.HasPrefix(p, "+") {
					cleanP := strings.TrimPrefix(p, "+")
					if idx := strings.Index(cleanP, ","); idx >= 0 {
						cleanP = cleanP[:idx]
					}
					if n, err := parseInt(cleanP); err == nil {
						newLine = n
					}
				}
			}
			continue
		}
		if strings.HasPrefix(line, "+") {
			lines = append(lines, DiffLine{Type: "add", Content: line[1:], NewLine: newLine})
			newLine++
			continue
		}
		if strings.HasPrefix(line, "-") {
			lines = append(lines, DiffLine{Type: "del", Content: line[1:], OldLine: oldLine})
			oldLine++
			continue
		}
		if line != "" {
			content := line
			if strings.HasPrefix(line, " ") {
				content = line[1:]
			}
			lines = append(lines, DiffLine{Type: "context", Content: content, OldLine: oldLine, NewLine: newLine})
			oldLine++
			newLine++
		}
	}
	return lines
}

func parseInt(s string) (int, error) {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, &parseError{}
		}
		n = n*10 + int(c-'0')
	}
	return n, nil
}

type parseError struct{}

func (p *parseError) Error() string { return "parse error" }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := 20
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// GetGitLog returns recent commits
func (s *SessionServer) GetGitLog(c *gin.Context) {
	cwd := c.Query("cwd")
	if cwd == "" {
		c.JSON(400, gin.H{"error": "cwd is required"})
		return
	}

	limit := c.DefaultQuery("limit", "30")
	cmd := exec.Command("git", "-C", cwd, "log", "--pretty=format:%H%x01%an%x01%ae%x01%at%x01%s", "-n", limit)
	out, err := cmd.Output()
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	type Commit struct {
		Hash    string `json:"hash"`
		Short   string `json:"short"`
		Author  string `json:"author"`
		Email   string `json:"email"`
		Time    int64  `json:"time"`
		Message string `json:"message"`
	}

	commits := make([]Commit, 0)
	for _, line := range strings.Split(string(out), "\n") {
		parts := strings.Split(line, "\x01")
		if len(parts) < 5 {
			continue
		}
		var ts int64
		json.Unmarshal([]byte(parts[3]), &ts)
		// Simple parse
		t := int64(0)
		for _, c := range parts[3] {
			if c < '0' || c > '9' {
				break
			}
			t = t*10 + int64(c-'0')
		}
		commit := Commit{
			Hash:    parts[0],
			Short:   parts[0][:7],
			Author:  parts[1],
			Email:   parts[2],
			Time:    t,
			Message: parts[4],
		}
		commits = append(commits, commit)
	}

	c.JSON(200, gin.H{"commits": commits})
}

type gitPullBody struct {
	Cwd      string `json:"cwd"`
	Strategy string `json:"strategy"` // "ff-only" (default), "rebase", "merge"
}

func (s *SessionServer) GitPull(c *gin.Context) {
	var body gitPullBody
	if err := c.ShouldBindJSON(&body); err != nil {
		body.Cwd = c.Query("cwd")
		body.Strategy = c.Query("strategy")
	}
	cwd := normalizeSessionCwd(body.Cwd)
	if strings.TrimSpace(cwd) == "" {
		c.JSON(400, gin.H{"error": "cwd is required"})
		return
	}
	if _, ok := projectRootForPath(cwd); !ok {
		c.JSON(400, gin.H{"error": "git pull is only allowed inside ~/projects/<name>", "cwd": cwd})
		return
	}
	if err := ensureProjectWritableForAgent(cwd); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("project permission repair failed: %v", err), "cwd": cwd})
		return
	}

	args := []string{"-C", cwd, "pull"}
	switch strings.ToLower(strings.TrimSpace(body.Strategy)) {
	case "", "ff-only":
		args = append(args, "--ff-only")
	case "rebase":
		args = append(args, "--rebase")
	case "merge":
		// Git default merge behavior.
	default:
		c.JSON(400, gin.H{"error": "strategy must be one of: ff-only, rebase, merge"})
		return
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.CombinedOutput()
	output := sanitizeGitErr(string(out))
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error(), "output": output, "cwd": cwd})
		return
	}
	c.JSON(200, gin.H{"ok": true, "cwd": cwd, "output": output})
}
