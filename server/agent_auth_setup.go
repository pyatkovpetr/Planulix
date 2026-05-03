package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type agentAuthRunner struct {
	mu       sync.Mutex
	running  bool
	agentID  string
	cancel   context.CancelFunc
	session  *exec.Cmd
	stdin    io.WriteCloser
	urlFile  string
	tmpDir   string
	allURLs  []string
	logTail  bytes.Buffer
	exitedAt time.Time
	exitErr  error
}

var globalAgentAuth agentAuthRunner

func normalizeSetupAgentID(id string) string {
	switch strings.TrimSpace(id) {
	case "claude", "claude-code":
		return "claude-code"
	case "kimi", "kimi-cli":
		return "kimi-cli"
	case "codex", "codex-cli":
		return "codex-cli"
	case "cursor":
		return "cursor"
	case "kiro", "kiro-cli":
		return "kiro-cli"
	case "opencode", "open-code":
		return "opencode"
	default:
		return strings.TrimSpace(id)
	}
}

func agentAuthShell(agentID, bin string) (string, error) {
	q := shellQuote(bin)
	switch agentID {
	case "claude-code":
		return fmt.Sprintf("exec %s auth login", q), nil
	case "cursor":
		return fmt.Sprintf("if %s login --help >/dev/null 2>&1; then exec %s login; elif %s auth login --help >/dev/null 2>&1; then exec %s auth login; else echo 'Cursor CLI login subcommand not detected; starting agent to trigger auth URL.'; exec %s; fi", q, q, q, q, q), nil
	case "codex-cli":
		return fmt.Sprintf("exec %s login", q), nil
	case "opencode":
		return fmt.Sprintf("if %s auth login --help >/dev/null 2>&1; then exec %s auth login; elif %s login --help >/dev/null 2>&1; then exec %s login; else echo 'OpenCode login subcommand not detected. Configure provider/API key manually.'; exit 2; fi", q, q, q, q), nil
	case "kiro-cli":
		return fmt.Sprintf("if %s login --help >/dev/null 2>&1; then exec %s login; elif %s auth login --help >/dev/null 2>&1; then exec %s auth login; else exec %s; fi", q, q, q, q, q), nil
	case "kimi-cli":
		return fmt.Sprintf("echo 'Kimi CLI usually uses API key/config or interactive /login inside kimi. Start kimi over SSH if browser login is required.'; exec %s", q), nil
	default:
		return "", fmt.Errorf("unsupported auth agent: %s", agentID)
	}
}

func agentAuthConfigured(agentID, bin string) bool {
	switch agentID {
	case "claude-code":
		return bin != "" && (envAny("ANTHROPIC_API_KEY") || claudeAuthStatusOK(bin))
	case "kimi-cli":
		return envAny("KIMI_API_KEY") || envAny("MOONSHOT_API_KEY")
	case "codex-cli":
		return envAny("OPENAI_API_KEY")
	case "opencode":
		return bin != ""
	case "cursor":
		return bin != ""
	case "kiro-cli":
		return bin != ""
	default:
		return false
	}
}

func (ar *agentAuthRunner) cleanupLocked(killProc bool) {
	if killProc && ar.session != nil && ar.session.Process != nil {
		_ = ar.session.Process.Kill()
	}
	if ar.stdin != nil {
		_ = ar.stdin.Close()
	}
	if ar.cancel != nil {
		ar.cancel()
	}
	td := ar.tmpDir
	ar.session = nil
	ar.stdin = nil
	ar.cancel = nil
	ar.tmpDir = ""
	ar.urlFile = ""
	ar.logTail.Reset()
	if td != "" {
		_ = os.RemoveAll(td)
	}
}

func (ar *agentAuthRunner) drain(r io.Reader) {
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := stripANSI(string(buf[:n]))
			ar.mu.Lock()
			for _, u := range oauthURLRegexp.FindAllString(chunk, -1) {
				ar.allURLs = appendUnique(ar.allURLs, []string{u})
			}
			if ar.logTail.Len() < 1<<20 {
				ar.logTail.WriteString(chunk)
			}
			ar.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
}

func (s *SessionServer) StartAgentAuth(c *gin.Context) {
	agentID := normalizeSetupAgentID(c.Param("id"))
	bin := resolveAgentCommand(agentID)
	if bin == "" {
		c.JSON(400, gin.H{"error": "agent CLI is not installed: " + agentID})
		return
	}
	inner, err := agentAuthShell(agentID, bin)
	if err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}

	globalAgentAuth.mu.Lock()
	// Replace any stale or stuck flow (avoid 409; client retry/stop raced with wait goroutine).
	if globalAgentAuth.running {
		globalAgentAuth.cleanupLocked(true)
		globalAgentAuth.running = false
	}
	globalAgentAuth.cleanupLocked(false)
	td, err := os.MkdirTemp("", "planulix-agent-auth-*")
	if err != nil {
		globalAgentAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": fmt.Sprintf("temp dir: %v", err)})
		return
	}
	urlCapture := filepath.Join(td, "browser_targets.log")
	shim := filepath.Join(td, "planulix_browser_capture.sh")
	shimBody := "#!/usr/bin/env bash\n" +
		fmt.Sprintf("printf '%%s\\n' \"$*\" >> %q\n", urlCapture) +
		"exit 0\n"
	if err := os.WriteFile(shim, []byte(shimBody), 0o755); err != nil {
		_ = os.RemoveAll(td)
		globalAgentAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	envExports := genericAgentExports(nil)
	if agentID == "claude-code" {
		envExports = claudeExportsForShell(nil)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	shellCmd := fmt.Sprintf("%s && export BROWSER=%q && %s", envExports, shim, inner)
	var cmd *exec.Cmd
	if _, err := exec.LookPath("script"); err == nil {
		cmd = exec.CommandContext(ctx, "script", "-q", "-c", shellCmd, "/dev/null")
	} else {
		cmd = exec.CommandContext(ctx, "bash", "-lc", shellCmd)
	}
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "DISPLAY=", "BROWSER="+shim)

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		_ = os.RemoveAll(td)
		globalAgentAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		cancel()
		_ = os.RemoveAll(td)
		globalAgentAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		_ = os.RemoveAll(td)
		globalAgentAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	if err := cmd.Start(); err != nil {
		cancel()
		_ = os.RemoveAll(td)
		globalAgentAuth.mu.Unlock()
		c.JSON(500, gin.H{"error": fmt.Sprintf("start: %v", err)})
		return
	}

	globalAgentAuth.agentID = agentID
	globalAgentAuth.tmpDir = td
	globalAgentAuth.urlFile = urlCapture
	globalAgentAuth.allURLs = globalAgentAuth.allURLs[:0]
	globalAgentAuth.logTail.Reset()
	globalAgentAuth.exitedAt = time.Time{}
	globalAgentAuth.exitErr = nil
	globalAgentAuth.running = true
	globalAgentAuth.cancel = cancel
	globalAgentAuth.session = cmd
	globalAgentAuth.stdin = stdinPipe
	globalAgentAuth.mu.Unlock()

	go globalAgentAuth.drain(stdoutPipe)
	go globalAgentAuth.drain(stderrPipe)
	go func(cmd *exec.Cmd) {
		waitErr := cmd.Wait()
		globalAgentAuth.mu.Lock()
		if globalAgentAuth.session != cmd {
			globalAgentAuth.mu.Unlock()
			return
		}
		fromFile := readURLFileTail(globalAgentAuth.urlFile)
		globalAgentAuth.allURLs = appendUnique(globalAgentAuth.allURLs, fromFile)
		globalAgentAuth.exitErr = waitErr
		globalAgentAuth.exitedAt = time.Now()
		globalAgentAuth.running = false
		globalAgentAuth.session = nil
		globalAgentAuth.stdin = nil
		globalAgentAuth.cancel = nil
		tdLocal := globalAgentAuth.tmpDir
		globalAgentAuth.tmpDir = ""
		globalAgentAuth.urlFile = ""
		globalAgentAuth.mu.Unlock()
		time.Sleep(250 * time.Millisecond)
		if tdLocal != "" {
			_ = os.RemoveAll(tdLocal)
		}
	}(cmd)

	c.JSON(200, gin.H{"ok": true, "agent": agentID})
}

func authCodeFromInput(code, callbackURL string) string {
	code = strings.TrimSpace(code)
	if code != "" && !strings.Contains(code, "://") {
		return code
	}
	raw := strings.TrimSpace(callbackURL)
	if raw == "" {
		raw = code
	}
	u, err := url.Parse(raw)
	if err != nil {
		return code
	}
	if v := strings.TrimSpace(u.Query().Get("code")); v != "" {
		return v
	}
	return code
}

func (s *SessionServer) SubmitAgentAuthCode(c *gin.Context) {
	agentID := normalizeSetupAgentID(c.Param("id"))
	var req struct {
		Code        string `json:"code"`
		CallbackURL string `json:"callbackUrl"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"ok": false, "error": "invalid request"})
		return
	}
	code := authCodeFromInput(req.Code, req.CallbackURL)
	if code == "" {
		c.JSON(400, gin.H{"ok": false, "error": "missing OAuth code"})
		return
	}

	globalAgentAuth.mu.Lock()
	defer globalAgentAuth.mu.Unlock()
	if !globalAgentAuth.running || globalAgentAuth.stdin == nil {
		c.JSON(409, gin.H{"ok": false, "error": "auth flow is not running"})
		return
	}
	if globalAgentAuth.agentID != "" && globalAgentAuth.agentID != agentID {
		c.JSON(409, gin.H{"ok": false, "error": "different auth flow is running", "agent": globalAgentAuth.agentID})
		return
	}
	if _, err := io.WriteString(globalAgentAuth.stdin, code+"\n"); err != nil {
		c.JSON(500, gin.H{"ok": false, "error": err.Error()})
		return
	}
	globalAgentAuth.logTail.WriteString("\n[planulix] OAuth code submitted to CLI stdin\n")
	c.JSON(200, gin.H{"ok": true, "agent": agentID})
}

func (s *SessionServer) AgentAuthState(c *gin.Context) {
	agentID := normalizeSetupAgentID(c.Param("id"))
	globalAgentAuth.mu.Lock()
	fromFile := []string(nil)
	if globalAgentAuth.urlFile != "" {
		fromFile = readURLFileTail(globalAgentAuth.urlFile)
	}
	all := appendUnique(append([]string{}, globalAgentAuth.allURLs...), fromFile)
	running := globalAgentAuth.running && (globalAgentAuth.agentID == agentID || agentID == "")
	logTail := globalAgentAuth.logTail.String()
	if len(logTail) > 8000 {
		logTail = logTail[len(logTail)-8000:]
	}
	exitErr := globalAgentAuth.exitErr
	exitedAt := globalAgentAuth.exitedAt
	activeAgent := globalAgentAuth.agentID
	globalAgentAuth.mu.Unlock()

	var exitMsg string
	if exitErr != nil {
		exitMsg = exitErr.Error()
	}
	bin := resolveAgentCommand(agentID)
	c.JSON(200, gin.H{
		"running":       running,
		"activeAgent":   activeAgent,
		"urls":          all,
		"log_tail":      logTail,
		"exited":        !running && !exitedAt.IsZero(),
		"exit_error":    exitMsg,
		"authenticated": agentAuthConfigured(agentID, bin),
	})
}

func (s *SessionServer) StopAgentAuth(c *gin.Context) {
	globalAgentAuth.mu.Lock()
	globalAgentAuth.cleanupLocked(true)
	globalAgentAuth.running = false
	globalAgentAuth.mu.Unlock()
	c.JSON(200, gin.H{"ok": true})
}

func (s *SessionServer) SmokeTestAgent(c *gin.Context) {
	agentID := normalizeSetupAgentID(c.Param("id"))
	if resolveAgentCommand(agentID) == "" {
		c.JSON(400, gin.H{"ok": false, "agent": agentID, "error": "agent CLI is not installed"})
		return
	}
	result := runAndStoreAgentSmokeTest(agentID, 90*time.Second)
	payload := gin.H{
		"ok":     result.OK,
		"agent":  agentID,
		"ready":  result.OK,
		"smoke":  result,
		"result": result,
	}
	if !result.OK {
		payload["error"] = result.Log
	}
	c.JSON(200, payload)
}
