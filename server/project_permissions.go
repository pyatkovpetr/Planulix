package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

func projectPathByName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || strings.ContainsAny(name, "/\\..") {
		return "", fmt.Errorf("invalid project name")
	}
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return "", fmt.Errorf("home directory not found")
	}
	return filepath.Join(home, "projects", name), nil
}

func normalizeProjectWritable(root string) error {
	root = strings.TrimSpace(root)
	if root == "" {
		return fmt.Errorf("empty project path")
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	info, err := os.Stat(absRoot)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("project path is not a directory")
	}

	var firstErr error
	err = filepath.Walk(absRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			return nil
		}
		if info == nil {
			return nil
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil
		}

		mode := info.Mode().Perm()
		if info.IsDir() {
			mode |= 0700
			mode &^= 0022
		} else {
			mode |= 0600
			if mode&0111 != 0 {
				mode |= 0100
			}
		}
		if chmodErr := os.Chmod(path, mode); chmodErr != nil && firstErr == nil {
			firstErr = chmodErr
		}
		return nil
	})
	if err != nil && firstErr == nil {
		firstErr = err
	}
	return firstErr
}

func projectRootForPath(path string) (string, bool) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", false
	}
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return "", false
	}
	projectsDir, err := filepath.Abs(filepath.Join(home, "projects"))
	if err != nil {
		return "", false
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return "", false
	}
	rel, err := filepath.Rel(projectsDir, absPath)
	if err != nil || rel == "." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || rel == ".." {
		return "", false
	}
	parts := strings.Split(rel, string(filepath.Separator))
	if len(parts) == 0 || strings.TrimSpace(parts[0]) == "" {
		return "", false
	}
	return filepath.Join(projectsDir, parts[0]), true
}

func ensureProjectWritableForAgent(cwd string) error {
	root, ok := projectRootForPath(cwd)
	if !ok {
		return nil
	}
	if err := normalizeProjectWritable(root); err != nil {
		return err
	}
	gitDir, hasGit, reason := resolveGitDir(root)
	if !hasGit {
		return nil
	}
	if rel, err := filepath.Rel(root, gitDir); err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		_ = normalizeProjectWritable(gitDir)
	}
	if ok, errText := probeGitDirWritable(gitDir); !ok {
		if errText == "" {
			errText = reason
		}
		return fmt.Errorf(".git is not writable: %s", errText)
	}
	return nil
}

func resolveGitDir(root string) (string, bool, string) {
	cmd := exec.Command("git", "-C", root, "rev-parse", "--absolute-git-dir")
	out, err := cmd.Output()
	if err == nil {
		gitDir := strings.TrimSpace(string(out))
		if gitDir != "" {
			if info, statErr := os.Stat(gitDir); statErr == nil && info.IsDir() {
				return gitDir, true, ""
			}
		}
	}

	gitPath := filepath.Join(root, ".git")
	info, statErr := os.Stat(gitPath)
	if statErr != nil {
		return "", false, "no .git directory"
	}
	if info.IsDir() {
		return gitPath, true, ""
	}
	data, readErr := os.ReadFile(gitPath)
	if readErr != nil {
		return "", false, readErr.Error()
	}
	line := strings.TrimSpace(string(data))
	const prefix = "gitdir:"
	if !strings.HasPrefix(strings.ToLower(line), prefix) {
		return "", false, ".git is not a directory or gitdir file"
	}
	gitDir := strings.TrimSpace(line[len(prefix):])
	if gitDir == "" {
		return "", false, "empty gitdir in .git file"
	}
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(root, gitDir)
	}
	gitDir = filepath.Clean(gitDir)
	if info, err := os.Stat(gitDir); err == nil && info.IsDir() {
		return gitDir, true, ""
	}
	return "", false, "gitdir target does not exist"
}

func probeGitDirWritable(gitDir string) (bool, string) {
	testPath := filepath.Join(gitDir, fmt.Sprintf(".planulix-write-test-%d", time.Now().UnixNano()))
	if err := os.WriteFile(testPath, []byte("ok\n"), 0600); err != nil {
		return false, err.Error()
	}
	_ = os.Remove(testPath)
	return true, ""
}

func probeGitWritable(root string) (bool, string) {
	gitDir, ok, reason := resolveGitDir(root)
	if !ok {
		return false, reason
	}
	return probeGitDirWritable(gitDir)
}

type gitControlStatus struct {
	IsGit            bool   `json:"isGit"`
	Branch           string `json:"branch,omitempty"`
	Upstream         string `json:"upstream,omitempty"`
	Ahead            int    `json:"ahead,omitempty"`
	Behind           int    `json:"behind,omitempty"`
	Modified         int    `json:"modified,omitempty"`
	Untracked        int    `json:"untracked,omitempty"`
	GitWritable      bool   `json:"gitWritable"`
	GitWritableError string `json:"gitWritableError,omitempty"`
	CommitStatus     string `json:"commitStatus,omitempty"`
	PushStatus       string `json:"pushStatus,omitempty"`
	Error            string `json:"error,omitempty"`
}

func gitControlStatusForPath(cwd string) gitControlStatus {
	cwd = strings.TrimSpace(cwd)
	if cwd == "" {
		return gitControlStatus{Error: "cwd is empty"}
	}
	cmd := exec.Command("git", "-C", cwd, "status", "--porcelain=v1", "-b")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return gitControlStatus{Error: strings.TrimSpace(stripANSI(string(out) + " " + err.Error()))}
	}
	st := gitControlStatus{IsGit: true}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) > 0 && strings.HasPrefix(lines[0], "## ") {
		parseGitBranchLine(strings.TrimPrefix(lines[0], "## "), &st)
	}
	for _, line := range lines[1:] {
		if len(line) < 2 {
			continue
		}
		if strings.HasPrefix(line, "??") {
			st.Untracked++
		} else {
			st.Modified++
		}
	}
	st.GitWritable, st.GitWritableError = probeGitWritable(cwd)
	if !st.GitWritable {
		st.CommitStatus = "blocked: .git is not writable"
		st.PushStatus = "blocked: .git is not writable"
	} else if st.Modified+st.Untracked > 0 {
		st.CommitStatus = "changes pending"
	} else {
		st.CommitStatus = "clean"
	}
	switch {
	case !st.GitWritable:
	case st.Upstream == "":
		st.PushStatus = "no upstream"
	case st.Ahead > 0:
		st.PushStatus = fmt.Sprintf("%d commit(s) ahead", st.Ahead)
	default:
		st.PushStatus = "up to date"
	}
	return st
}

func parseGitBranchLine(line string, st *gitControlStatus) {
	if st == nil {
		return
	}
	base := line
	if idx := strings.Index(base, " ["); idx >= 0 {
		status := strings.TrimSuffix(base[idx+2:], "]")
		base = base[:idx]
		for _, part := range strings.Split(status, ",") {
			part = strings.TrimSpace(part)
			if strings.HasPrefix(part, "ahead ") {
				st.Ahead, _ = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(part, "ahead ")))
			}
			if strings.HasPrefix(part, "behind ") {
				st.Behind, _ = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(part, "behind ")))
			}
		}
	}
	if idx := strings.Index(base, "..."); idx >= 0 {
		st.Branch = base[:idx]
		st.Upstream = base[idx+3:]
		return
	}
	st.Branch = base
}

func (s *SessionServer) RepairProject(c *gin.Context) {
	name := c.Query("name")
	targetDir, err := projectPathByName(name)
	if err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}
	if err := normalizeProjectWritable(targetDir); err != nil {
		c.JSON(500, gin.H{"error": err.Error(), "path": targetDir})
		return
	}
	gitWritable, gitWritableError := probeGitWritable(targetDir)
	c.JSON(200, gin.H{
		"ok":               true,
		"path":             targetDir,
		"gitWritable":      gitWritable,
		"gitWritableError": gitWritableError,
	})
}
