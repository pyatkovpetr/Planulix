package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

type AgentType string

const (
	AgentClaudeCode AgentType = "claude-code"
	AgentCodexCLI   AgentType = "codex-cli"
	AgentCursor     AgentType = "cursor"
	AgentOpenCode   AgentType = "opencode"
	AgentKiroCLI    AgentType = "kiro-cli"
	AgentKimiCLI    AgentType = "kimi-cli"
)

// discoverAllAgentSessions discovers sessions from all supported agents
func (s *SessionServer) discoverAllAgentSessions() []SessionInfo {
	var sessions []SessionInfo

	// Claude Code — existing logic
	sessions = append(sessions, s.discoverSessions()...)

	// Codex CLI
	sessions = append(sessions, s.discoverCodexSessions()...)

	// Cursor
	sessions = append(sessions, s.discoverCursorSessions()...)

	// OpenCode
	sessions = append(sessions, s.discoverOpenCodeSessions()...)

	// Kiro CLI
	sessions = append(sessions, s.discoverKiroSessions()...)

	// Kimi Code CLI (~/.kimi/sessions/...)
	sessions = append(sessions, s.discoverKimiSessions()...)

	return sessions
}

// discoverKimiSessions lists Kimi sessions from ~/.kimi/sessions/<workdir-hash>/<session-id>/context.jsonl
func (s *SessionServer) discoverKimiSessions() []SessionInfo {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	cwdByDir := loadKimiSessionDirToCwd(home)
	root := filepath.Join(home, ".kimi", "sessions")
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}

	var sessions []SessionInfo
	for _, hashEntry := range entries {
		if !hashEntry.IsDir() {
			continue
		}
		dirName := hashEntry.Name()
		cwd := cwdByDir[dirName]
		grp := filepath.Join(root, dirName)
		sub, err := os.ReadDir(grp)
		if err != nil {
			continue
		}
		for _, se := range sub {
			if !se.IsDir() {
				continue
			}
			sid := se.Name()
			ctxPath := filepath.Join(grp, sid, "context.jsonl")
			st, err := os.Stat(ctxPath)
			if err != nil || st.IsDir() {
				continue
			}
			_, title := parseKimiContextHeader(ctxPath)
			if title == "" {
				title = sid
			}
			sessions = append(sessions, SessionInfo{
				SessionMeta: SessionMeta{
					SessionID: "kimi-" + sid,
					Cwd:       cwd,
					StartedAt: st.ModTime().UnixMilli(),
					Kind:      string(AgentKimiCLI),
					Entry:     "kimi",
				},
				Title:    title,
				IsActive: false,
				Extra: map[string]interface{}{
					"agent": "kimi-cli",
					"path":  ctxPath,
				},
			})
		}
	}

	return sessions
}

// discoverCodexSessions reads Codex CLI sessions from ~/.codex/
func (s *SessionServer) discoverCodexSessions() []SessionInfo {
	var sessions []SessionInfo
	home, _ := os.UserHomeDir()
	codexDir := filepath.Join(home, ".codex")

	if _, err := os.Stat(codexDir); os.IsNotExist(err) {
		return nil
	}

	filepath.Walk(codexDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(info.Name(), ".jsonl") {
			return nil
		}

		sessionID := "codex-" + strings.TrimSuffix(info.Name(), ".jsonl")
		title, msgCount := s.parseAgentJSONLHeader(path)

		sessions = append(sessions, SessionInfo{
			SessionMeta: SessionMeta{
				SessionID: sessionID,
				StartedAt: info.ModTime().UnixMilli(),
				Kind:      "codex-cli",
				Entry:     "codex",
			},
			Title: title,
			Extra: map[string]interface{}{
				"agent":    "codex-cli",
				"messages": msgCount,
				"path":     path,
			},
		})
		return nil
	})

	return sessions
}

// discoverCursorSessions reads Cursor agent transcripts
func (s *SessionServer) discoverCursorSessions() []SessionInfo {
	var sessions []SessionInfo
	home, _ := os.UserHomeDir()
	cursorDir := filepath.Join(home, ".cursor", "projects")

	if _, err := os.Stat(cursorDir); os.IsNotExist(err) {
		return nil
	}

	filepath.Walk(cursorDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(info.Name(), ".jsonl") {
			return nil
		}
		// Only pick up agent transcripts
		if !strings.Contains(path, "agent-transcripts") {
			return nil
		}

		sessionID := "cursor-" + strings.TrimSuffix(info.Name(), ".jsonl")
		title, msgCount := s.parseAgentJSONLHeader(path)

		// Extract project from path
		relPath, _ := filepath.Rel(cursorDir, path)
		parts := strings.Split(relPath, string(filepath.Separator))
		project := ""
		if len(parts) > 0 {
			project = parts[0]
		}

		sessions = append(sessions, SessionInfo{
			SessionMeta: SessionMeta{
				SessionID: sessionID,
				Cwd:       project,
				StartedAt: info.ModTime().UnixMilli(),
				Kind:      "cursor",
				Entry:     "cursor-agent",
			},
			Title: title,
			Extra: map[string]interface{}{
				"agent":    "cursor",
				"messages": msgCount,
				"path":     path,
			},
		})
		return nil
	})

	return sessions
}

// discoverOpenCodeSessions finds OpenCode sessions (checks for data dir presence)
func (s *SessionServer) discoverOpenCodeSessions() []SessionInfo {
	var sessions []SessionInfo
	home, _ := os.UserHomeDir()
	ocDir := filepath.Join(home, ".local", "share", "opencode")

	if _, err := os.Stat(ocDir); os.IsNotExist(err) {
		return nil
	}

	// OpenCode stores sessions in SQLite, but we look for any JSONL exports or logs
	filepath.Walk(ocDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(info.Name(), ".jsonl") && !strings.HasSuffix(info.Name(), ".json") {
			return nil
		}

		sessionID := "opencode-" + strings.TrimSuffix(strings.TrimSuffix(info.Name(), ".jsonl"), ".json")
		sessions = append(sessions, SessionInfo{
			SessionMeta: SessionMeta{
				SessionID: sessionID,
				StartedAt: info.ModTime().UnixMilli(),
				Kind:      "opencode",
				Entry:     "opencode",
			},
			Title: info.Name(),
			Extra: map[string]interface{}{
				"agent": "opencode",
				"path":  path,
			},
		})
		return nil
	})

	return sessions
}

// discoverKiroSessions finds Kiro CLI sessions
func (s *SessionServer) discoverKiroSessions() []SessionInfo {
	var sessions []SessionInfo
	home, _ := os.UserHomeDir()

	// macOS path
	kiroDir := filepath.Join(home, "Library", "Application Support", "kiro-cli")
	if _, err := os.Stat(kiroDir); os.IsNotExist(err) {
		// Linux path
		kiroDir = filepath.Join(home, ".local", "share", "kiro-cli")
	}
	if _, err := os.Stat(kiroDir); os.IsNotExist(err) {
		return nil
	}

	filepath.Walk(kiroDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(info.Name(), ".jsonl") && !strings.HasSuffix(info.Name(), ".json") {
			return nil
		}

		sessionID := "kiro-" + strings.TrimSuffix(strings.TrimSuffix(info.Name(), ".jsonl"), ".json")
		sessions = append(sessions, SessionInfo{
			SessionMeta: SessionMeta{
				SessionID: sessionID,
				StartedAt: info.ModTime().UnixMilli(),
				Kind:      "kiro-cli",
				Entry:     "kiro",
			},
			Title: info.Name(),
			Extra: map[string]interface{}{
				"agent": "kiro-cli",
				"path":  path,
			},
		})
		return nil
	})

	return sessions
}

// parseAgentJSONLHeader reads title and message count from a JSONL file (generic)
func (s *SessionServer) parseAgentJSONLHeader(path string) (string, int) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0
	}
	defer f.Close()

	var title string
	count := 0
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024)

	for scanner.Scan() {
		var raw map[string]interface{}
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			continue
		}
		typ, _ := raw["type"].(string)
		if typ == "ai-title" || typ == "title" {
			if t, ok := raw["title"].(string); ok {
				title = t
			}
		}
		if typ == "user" || typ == "assistant" || typ == "message" {
			count++
		}
	}

	return title, count
}
