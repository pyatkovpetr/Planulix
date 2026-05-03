package main

import (
	"bufio"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

// WriteFile saves content to a file path
func (s *SessionServer) WriteFile(c *gin.Context) {
	path := c.Query("path")
	if path == "" {
		c.JSON(400, gin.H{"error": "path is required"})
		return
	}

	// Same security as ReadFile
	home, _ := os.UserHomeDir()
	if !strings.HasPrefix(path, home) && !strings.HasPrefix(path, "/tmp") {
		c.JSON(403, gin.H{"error": "access denied"})
		return
	}

	var req struct {
		Content string `json:"content"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request"})
		return
	}

	// Ensure parent dir exists
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	if err := os.WriteFile(path, []byte(req.Content), 0644); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	info, _ := os.Stat(path)
	c.JSON(200, gin.H{
		"ok":   true,
		"size": info.Size(),
		"path": path,
	})
}

// GrepInFiles runs rg (or fallback to grep) across a project
func (s *SessionServer) GrepInFiles(c *gin.Context) {
	query := c.Query("q")
	cwd := c.Query("cwd")
	if query == "" || cwd == "" {
		c.JSON(400, gin.H{"error": "q and cwd required"})
		return
	}

	// Use ripgrep if available, otherwise grep
	var cmd *exec.Cmd
	if _, err := exec.LookPath("rg"); err == nil {
		cmd = exec.Command("rg",
			"--json",
			"--max-count", "10",
			"--max-filesize", "2M",
			"-g", "!.git",
			"-g", "!node_modules",
			"-g", "!build",
			"-g", "!dist",
			"-g", "!.dart_tool",
			query,
			cwd,
		)
	} else {
		cmd = exec.Command("grep",
			"-rn",
			"--include=*.*",
			"--exclude-dir=.git",
			"--exclude-dir=node_modules",
			"--exclude-dir=build",
			"--exclude-dir=dist",
			query,
			cwd,
		)
	}

	out, _ := cmd.Output() // ignore exit code (1 == no match)

	// Parse results
	type MatchLine struct {
		File    string `json:"file"`
		Line    int    `json:"line"`
		Content string `json:"content"`
	}

	matches := make([]MatchLine, 0, 200)
	maxMatches := 500

	if strings.Contains(cmd.Path, "rg") {
		// Parse rg JSON output
		scanner := bufio.NewScanner(strings.NewReader(string(out)))
		scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024)
		for scanner.Scan() && len(matches) < maxMatches {
			line := scanner.Text()
			// Simple extraction without full JSON parsing
			if !strings.Contains(line, `"type":"match"`) {
				continue
			}
			// Extract path, line number, and text via substring search
			pathStart := strings.Index(line, `"path":{"text":"`)
			if pathStart < 0 {
				continue
			}
			pathStart += len(`"path":{"text":"`)
			pathEnd := strings.Index(line[pathStart:], `"`)
			if pathEnd < 0 {
				continue
			}
			filePath := line[pathStart : pathStart+pathEnd]

			lineStart := strings.Index(line, `"line_number":`)
			if lineStart < 0 {
				continue
			}
			lineStart += len(`"line_number":`)
			lineEnd := strings.IndexAny(line[lineStart:], ",}")
			if lineEnd < 0 {
				continue
			}
			lineNum := 0
			for _, c := range line[lineStart : lineStart+lineEnd] {
				if c >= '0' && c <= '9' {
					lineNum = lineNum*10 + int(c-'0')
				}
			}

			textStart := strings.Index(line, `"lines":{"text":"`)
			if textStart < 0 {
				continue
			}
			textStart += len(`"lines":{"text":"`)
			textEnd := strings.Index(line[textStart:], `"}`)
			if textEnd < 0 {
				continue
			}
			text := line[textStart : textStart+textEnd]
			// Unescape
			text = strings.ReplaceAll(text, `\"`, `"`)
			text = strings.ReplaceAll(text, `\\`, `\`)
			text = strings.ReplaceAll(text, `\n`, "")
			text = strings.TrimSpace(text)
			if len(text) > 200 {
				text = text[:200] + "..."
			}

			matches = append(matches, MatchLine{
				File:    filePath,
				Line:    lineNum,
				Content: text,
			})
		}
	} else {
		// Parse grep output (file:line:content)
		for _, line := range strings.Split(string(out), "\n") {
			if line == "" || len(matches) >= maxMatches {
				continue
			}
			firstColon := strings.Index(line, ":")
			if firstColon < 0 {
				continue
			}
			secondColon := strings.Index(line[firstColon+1:], ":")
			if secondColon < 0 {
				continue
			}
			secondColon += firstColon + 1
			filePath := line[:firstColon]
			lineNumStr := line[firstColon+1 : secondColon]
			content := line[secondColon+1:]
			lineNum := 0
			for _, c := range lineNumStr {
				if c >= '0' && c <= '9' {
					lineNum = lineNum*10 + int(c-'0')
				}
			}
			if len(content) > 200 {
				content = content[:200] + "..."
			}
			matches = append(matches, MatchLine{File: filePath, Line: lineNum, Content: content})
		}
	}

	c.JSON(200, gin.H{
		"matches": matches,
		"total":   len(matches),
		"query":   query,
	})
}

// FileList returns a flat list of all files in a directory for Cmd+P picker
func (s *SessionServer) FileList(c *gin.Context) {
	cwd := c.Query("cwd")
	if cwd == "" {
		c.JSON(400, gin.H{"error": "cwd required"})
		return
	}

	var files []string
	filepath.Walk(cwd, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		name := info.Name()
		if info.IsDir() {
			if name == ".git" || name == "node_modules" || name == "build" || name == "dist" || name == ".dart_tool" || name == "target" || name == ".next" {
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(cwd, path)
		files = append(files, rel)
		if len(files) >= 5000 {
			return filepath.SkipAll
		}
		return nil
	})

	c.JSON(200, gin.H{"files": files, "total": len(files)})
}

// Terminal WebSocket
var terminalUpgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// TerminalWS opens a WebSocket-backed bash session via tmux
// Client messages: {"type":"input","data":"..."} or {"type":"resize","cols":N,"rows":M}
// Server messages: {"type":"output","data":"..."}
func (s *SessionServer) TerminalWS(c *gin.Context) {
	ws, err := terminalUpgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}
	defer ws.Close()

	cwd := c.Query("cwd")
	if cwd == "" {
		home, _ := os.UserHomeDir()
		cwd = home
	}

	// Use bash directly with a pseudo-pipe approach
	// Each WebSocket spawns its own bash; we use `script` for pty behavior
	cmd := exec.Command("bash", "-i")
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(),
		"TERM=xterm-256color",
		"PS1=\\u@\\h:\\w\\$ ",
	)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		ws.WriteJSON(map[string]interface{}{"type": "error", "data": err.Error()})
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		ws.WriteJSON(map[string]interface{}{"type": "error", "data": err.Error()})
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		ws.WriteJSON(map[string]interface{}{"type": "error", "data": err.Error()})
		return
	}

	if err := cmd.Start(); err != nil {
		ws.WriteJSON(map[string]interface{}{"type": "error", "data": err.Error()})
		return
	}

	// Send initial prompt info
	ws.WriteJSON(map[string]interface{}{"type": "output", "data": "\r\nPlanulix terminal ready. cwd: " + cwd + "\r\n"})

	// Goroutine: read from stdout/stderr, send to WS
	done := make(chan struct{})
	go pipeToWS(ws, stdout, done)
	go pipeToWS(ws, stderr, done)

	// Read from WS, write to stdin
	go func() {
		defer close(done)
		for {
			_, msg, err := ws.ReadMessage()
			if err != nil {
				return
			}
			// Simple protocol: first byte type, rest data
			if len(msg) < 1 {
				continue
			}
			// Parse JSON message
			content := string(msg)
			// Strip possible JSON wrapper
			if strings.HasPrefix(content, `{"type":"input","data":"`) {
				end := strings.LastIndex(content, `"}`)
				if end > 0 {
					data := content[len(`{"type":"input","data":"`):end]
					data = strings.ReplaceAll(data, `\"`, `"`)
					data = strings.ReplaceAll(data, `\\`, `\`)
					data = strings.ReplaceAll(data, `\n`, "\n")
					data = strings.ReplaceAll(data, `\r`, "\r")
					stdin.Write([]byte(data))
					continue
				}
			}
			// Otherwise treat as raw
			stdin.Write(msg)
		}
	}()

	<-done
	cmd.Process.Kill()
	cmd.Wait()
}

func pipeToWS(ws *websocket.Conn, r io.Reader, done chan struct{}) {
	buf := make([]byte, 4096)
	for {
		select {
		case <-done:
			return
		default:
		}
		n, err := r.Read(buf)
		if n > 0 {
			ws.WriteJSON(map[string]interface{}{"type": "output", "data": string(buf[:n])})
		}
		if err != nil {
			return
		}
	}
}
