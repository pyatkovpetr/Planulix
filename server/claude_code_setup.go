package main

import (
	"bytes"
	"context"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

//go:embed claude_install_script.sh
var embeddedClaudeInstallScript string

type claudeAuthRunner struct {
	mu       sync.Mutex
	running  bool
	cancel   context.CancelFunc
	session  *exec.Cmd
	urlFile  string
	shimPath string
	tmpDir   string
	allURLs  []string
	stderr   bytes.Buffer
	exitedAt time.Time
	exitErr  error
}

var globalClaudeAuth claudeAuthRunner

var oauthURLRegexp = regexp.MustCompile(`https?://[^\s'"\]<>\)\\]+`)

// InstallClaudeCode runs the bundled shell script that installs npm + Claude Code CLI.
func (s *SessionServer) InstallClaudeCode(c *gin.Context) {
	ctx, cancel := context.WithTimeout(c.Request.Context(), 8*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-s")
	cmd.Env = append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")
	cmd.Stdin = strings.NewReader(embeddedClaudeInstallScript)
	out, err := cmd.CombinedOutput()
	logStr := strings.TrimSpace(string(out))
	ok := err == nil && resolveClaudeBinary() != ""
	if err != nil {
		c.JSON(200, gin.H{"ok": ok, "log": logStr, "error": err.Error()})
		return
	}
	c.JSON(200, gin.H{"ok": ok, "log": logStr})
}

func readURLFileTail(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil || len(b) == 0 {
		return nil
	}
	var urls []string
	for _, m := range oauthURLRegexp.FindAllString(string(b), -1) {
		urls = append(urls, strings.TrimSuffix(m, ")"))
	}
	return dedupePreserve(urls)
}

func dedupePreserve(in []string) []string {
	seen := make(map[string]struct{})
	out := make([]string, 0, len(in))
	for _, x := range in {
		x = strings.TrimSpace(x)
		if x == "" {
			continue
		}
		if _, ok := seen[x]; ok {
			continue
		}
		seen[x] = struct{}{}
		out = append(out, x)
	}
	return out
}

func appendUnique(dst []string, from []string) []string {
	return dedupePreserve(append(append([]string{}, dst...), from...))
}

func (ar *claudeAuthRunner) cleanupLocked(killProc bool) {
	if killProc && ar.session != nil && ar.session.Process != nil {
		_ = ar.session.Process.Kill()
	}
	ar.session = nil
	if ar.cancel != nil {
		ar.cancel()
	}
	ar.cancel = nil
	td := ar.tmpDir
	ar.tmpDir = ""
	ar.urlFile = ""
	ar.shimPath = ""
	ar.stderr.Reset()
	if td != "" {
		_ = os.RemoveAll(td)
	}
}

// StopClaudeCodeAuth cancels browser-login helper if running.
func (s *SessionServer) StopClaudeCodeAuth(c *gin.Context) {
	globalClaudeAuth.mu.Lock()
	if globalClaudeAuth.cancel != nil {
		globalClaudeAuth.cancel()
	}
	globalClaudeAuth.cleanupLocked(true)
	globalClaudeAuth.running = false
	globalClaudeAuth.mu.Unlock()
	c.JSON(200, gin.H{"ok": true})
}

// StartClaudeCodeAuth runs `claude auth login` with BROWSER=… capturing authorize URLs on headless VPS.
func (s *SessionServer) StartClaudeCodeAuth(c *gin.Context) {
	bin := resolveClaudeBinary()
	if bin == "" {
		c.JSON(400, gin.H{"error": "claude is not installed (run install first)"})
		return
	}
	globalClaudeAuth.mu.Lock()
	if globalClaudeAuth.running {
		globalClaudeAuth.mu.Unlock()
		c.JSON(409, gin.H{"error": "auth flow already running"})
		return
	}
	globalClaudeAuth.cleanupLocked(false)
	td, err := os.MkdirTemp("", "planulix-claude-auth-*")
	if err != nil {
		globalClaudeAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": fmt.Sprintf("temp dir: %v", err)})
		return
	}
	urlCapture := filepath.Join(td, "browser_targets.log")
	shim := filepath.Join(td, "planulix_browser_capture.sh")
	shimBody := "#!/usr/bin/env bash\n" +
		fmt.Sprintf("printf '%%s\\n' \"$*\" >> %q\n", urlCapture)
	if err := os.WriteFile(shim, []byte(shimBody), 0o755); err != nil {
		_ = os.RemoveAll(td)
		globalClaudeAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	envExports := claudeExportsForShell(nil)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	shellCmd := fmt.Sprintf("%s && export BROWSER=%q && exec %s auth login", envExports, shim, shellQuote(bin))
	var cmd *exec.Cmd
	if _, err := exec.LookPath("script"); err == nil {
		cmd = exec.CommandContext(ctx, "script", "-q", "-c", shellCmd, "/dev/null")
	} else {
		cmd = exec.CommandContext(ctx, "bash", "-lc", shellCmd)
	}
	cmd.Env = append(os.Environ(),
		"TERM=xterm-256color",
		"DISPLAY=",
		"BROWSER="+shim,
	)
	globalClaudeAuth.tmpDir = td
	globalClaudeAuth.urlFile = urlCapture
	globalClaudeAuth.shimPath = shim
	globalClaudeAuth.allURLs = globalClaudeAuth.allURLs[:0]
	globalClaudeAuth.stderr.Reset()
	globalClaudeAuth.exitedAt = time.Time{}
	globalClaudeAuth.exitErr = nil
	globalClaudeAuth.running = true
	globalClaudeAuth.cancel = cancel

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		_ = os.RemoveAll(td)
		globalClaudeAuth.running = false
		globalClaudeAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		cancel()
		_ = os.RemoveAll(td)
		globalClaudeAuth.running = false
		globalClaudeAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	if err := cmd.Start(); err != nil {
		cancel()
		_ = os.RemoveAll(td)
		globalClaudeAuth.running = false
		globalClaudeAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": fmt.Sprintf("start: %v", err)})
		return
	}
	globalClaudeAuth.session = cmd
	globalClaudeAuth.mu.Unlock()

	go globalClaudeAuth.drainOAuthPipe(stdoutPipe)
	go globalClaudeAuth.drainOAuthPipe(stderrPipe)
	go func() {
		waitErr := cmd.Wait()
		globalClaudeAuth.mu.Lock()
		fromFile := readURLFileTail(globalClaudeAuth.urlFile)
		globalClaudeAuth.allURLs = appendUnique(globalClaudeAuth.allURLs, fromFile)
		globalClaudeAuth.exitErr = waitErr
		globalClaudeAuth.exitedAt = time.Now()
		globalClaudeAuth.running = false
		globalClaudeAuth.session = nil
		globalClaudeAuth.cancel = nil
		tdLocal := globalClaudeAuth.tmpDir
		globalClaudeAuth.tmpDir = ""
		globalClaudeAuth.urlFile = ""
		globalClaudeAuth.shimPath = ""
		globalClaudeAuth.mu.Unlock()
		time.Sleep(250 * time.Millisecond)
		if tdLocal != "" {
			_ = os.RemoveAll(tdLocal)
		}
	}()

	c.JSON(200, gin.H{"ok": true})
}

func shellQuote(s string) string {
	s = strings.ReplaceAll(s, `'`, `'\"'\"'`)
	return `'` + s + `'`
}

func (ar *claudeAuthRunner) drainOAuthPipe(r io.Reader) {
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := string(buf[:n])
			ar.mu.Lock()
			for _, u := range oauthURLRegexp.FindAllString(chunk, -1) {
				ar.allURLs = appendUnique(ar.allURLs, []string{u})
			}
			if ar.stderr.Len() < 1<<20 {
				ar.stderr.WriteString(chunk)
			}
			ar.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
}

// ClaudeAuthState JSON for polling URLs + completion.
func (s *SessionServer) ClaudeAuthState(c *gin.Context) {
	globalClaudeAuth.mu.Lock()
	fromFile := []string(nil)
	if globalClaudeAuth.urlFile != "" {
		fromFile = readURLFileTail(globalClaudeAuth.urlFile)
	}
	all := appendUnique(append([]string{}, globalClaudeAuth.allURLs...), fromFile)
	running := globalClaudeAuth.running
	se := globalClaudeAuth.stderr.String()
	if len(se) > 8000 {
		se = se[len(se)-8000:]
	}
	exitErr := globalClaudeAuth.exitErr
	exitedAt := globalClaudeAuth.exitedAt
	globalClaudeAuth.mu.Unlock()

	bin := resolveClaudeBinary()
	authReady := bin != "" && (envAny("ANTHROPIC_API_KEY") || claudeAuthStatusOK(bin))

	var exitMsg string
	if exitErr != nil {
		exitMsg = exitErr.Error()
	}

	c.JSON(200, gin.H{
		"running":       running,
		"urls":          all,
		"log_tail":      se,
		"exited":        !running && !exitedAt.IsZero(),
		"exit_error":    exitMsg,
		"authenticated": authReady,
	})
}
