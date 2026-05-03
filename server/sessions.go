package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type SessionServer struct {
	claudeHome   string
	tmuxSessions map[string]*TmuxSession
	mu           sync.RWMutex
	tags         *TagStore
	agentStore   *AgentSessionStore

	gitHubOAuthMu      sync.Mutex
	gitHubOAuthPending map[string]*pendingGitHubOAuth
	gitHubOAuthTokens  map[string]string
}

type pendingGitHubOAuth struct {
	deadline    time.Time
	redirectURI string
}

type TmuxSession struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Cwd           string `json:"cwd"`
	StartedAt     int64  `json:"startedAt"`
	Status        string `json:"status"` // running, stopped, done
	Mode          string `json:"mode"`   // chat, task
	Agent         string `json:"agent,omitempty"`
	Prompt        string `json:"prompt,omitempty"`
	Model         string `json:"model,omitempty"`
	ClaudeSession string `json:"claudeSessionId,omitempty"` // linked Claude session ID
	KimiSession   string `json:"kimiSessionId,omitempty"`   // kimi-<uuid> when linked
	HistoryPath   string `json:"historyPath,omitempty"`     // explicit context.jsonl / transcript path
	// Whitelisted keys from createSession (Kimi headless --print); not JSON-serialized / not persisted.
	ResumeEnv map[string]string `json:"-"`
}

type SessionMeta struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	Cwd       string `json:"cwd"`
	StartedAt int64  `json:"startedAt"`
	Kind      string `json:"kind"`
	Entry     string `json:"entrypoint"`
}

type Message struct {
	Type      string      `json:"type"`
	Role      string      `json:"role,omitempty"`
	Content   interface{} `json:"content,omitempty"`
	Timestamp string      `json:"timestamp,omitempty"`
	Model     string      `json:"model,omitempty"`
	SessionID string      `json:"sessionId,omitempty"`
}

type SessionInfo struct {
	SessionMeta
	Title       string                 `json:"title,omitempty"`
	Messages    []Message              `json:"messages,omitempty"`
	IsActive    bool                   `json:"isActive"`
	ProjectName string                 `json:"projectName,omitempty"`
	ProjectPath string                 `json:"projectPath,omitempty"`
	Extra       map[string]interface{} `json:"extra,omitempty"`
}

func inferProjectInfo(cwd string) (name, path string) {
	cwd = strings.TrimSpace(cwd)
	if cwd == "" {
		return "", ""
	}
	parts := strings.Split(cwd, string(os.PathSeparator))
	for i, p := range parts {
		if p == "projects" && i+1 < len(parts) && parts[i+1] != "" {
			projectParts := parts[:i+2]
			if len(projectParts) > 0 && projectParts[0] == "" {
				return parts[i+1], string(os.PathSeparator) + filepath.Join(projectParts[1:]...)
			}
			return parts[i+1], filepath.Join(projectParts...)
		}
	}
	base := filepath.Base(cwd)
	if base == "." || base == string(os.PathSeparator) || base == "" {
		return cwd, cwd
	}
	return base, cwd
}

func normalizeSessionCwd(cwd string) string {
	cwd = strings.TrimSpace(cwd)
	home, _ := os.UserHomeDir()
	if cwd == "" {
		if home != "" {
			return home
		}
		return "/"
	}
	if st, err := os.Stat(cwd); err == nil && st.IsDir() {
		return cwd
	}
	if home != "" {
		return home
	}
	return "/"
}

func NewSessionServer(claudeHome string) *SessionServer {
	st, err := NewAgentSessionStore("")
	if err != nil {
		log.Printf("agent session store init: %v", err)
	}
	return &SessionServer{
		claudeHome:         claudeHome,
		tmuxSessions:       make(map[string]*TmuxSession),
		tags:               NewTagStore(claudeHome),
		agentStore:         st,
		gitHubOAuthPending: make(map[string]*pendingGitHubOAuth),
		gitHubOAuthTokens:  make(map[string]string),
	}
}

func (s *SessionServer) persistManaged(ts *TmuxSession) {
	if s.agentStore == nil || ts == nil {
		return
	}
	_ = s.agentStore.Upsert(ts.ToStored())
}

// resolveJSONLPath finds the history file for a session id (managed cd-*, kimi-*, or Claude id).
func (s *SessionServer) resolveJSONLPath(clientID string) (jsonlPath, canonicalID, agent string, tmuxAlive bool) {
	agent = "claude-code"
	canonicalID = clientID

	s.mu.RLock()
	ts, inMem := s.tmuxSessions[clientID]
	s.mu.RUnlock()

	var rec *StoredAgentSession
	if s.agentStore != nil {
		rec = s.agentStore.Get(clientID)
	}

	if rec != nil {
		s.recoverStoredLink(rec)
		if s.agentStore != nil {
			rec = s.agentStore.Get(clientID)
		}
		if rec.Agent != "" {
			agent = rec.Agent
		}
		if rec.HistoryPath != "" {
			if st, err := os.Stat(rec.HistoryPath); err == nil && !st.IsDir() {
				jsonlPath = rec.HistoryPath
			}
		}
		switch {
		case rec.Agent == "kimi-cli" && rec.ExternalID != "":
			canonicalID = rec.ExternalID
		case rec.ClaudeSessionID != "":
			canonicalID = rec.ClaudeSessionID
		case rec.ExternalID != "":
			canonicalID = rec.ExternalID
		}
	}

	if inMem {
		if ts.Agent != "" {
			agent = ts.Agent
		}
		if ts.KimiSession != "" {
			canonicalID = ts.KimiSession
		}
		if ts.ClaudeSession != "" {
			canonicalID = ts.ClaudeSession
		}
		if ts.HistoryPath != "" && jsonlPath == "" {
			if st, err := os.Stat(ts.HistoryPath); err == nil && !st.IsDir() {
				jsonlPath = ts.HistoryPath
			}
		}
		tmuxAlive = exec.Command("tmux", "has-session", "-t", ts.Name).Run() == nil
	} else if rec != nil && rec.TmuxName != "" {
		tmuxAlive = exec.Command("tmux", "has-session", "-t", rec.TmuxName).Run() == nil
	}

	if jsonlPath == "" {
		jsonlPath = s.findSessionJSONL(canonicalID)
	}
	if jsonlPath == "" && clientID != canonicalID {
		jsonlPath = s.findSessionJSONL(clientID)
	}
	if jsonlPath == "" {
		if p, a := s.findDiscoveredAgentHistoryPath(clientID); p != "" {
			jsonlPath = p
			if a != "" && !strings.HasPrefix(clientID, "cd-") {
				agent = a
			}
		}
	}
	// Persisted Planulix managed rows (`cd-*`) are authoritative for agent routing — in-memory tmux state can transiently diverge.
	if strings.HasPrefix(clientID, "cd-") && rec != nil && strings.TrimSpace(rec.Agent) != "" {
		agent = strings.TrimSpace(rec.Agent)
	}
	return jsonlPath, canonicalID, agent, tmuxAlive
}

func countUserAssistant(messages []Message) (users, assistants int) {
	for _, m := range messages {
		switch m.Type {
		case "user":
			users++
		case "assistant":
			assistants++
		}
	}
	return users, assistants
}

func messageContentText(content interface{}) string {
	switch v := content.(type) {
	case string:
		return v
	case []interface{}:
		var b strings.Builder
		for _, item := range v {
			switch x := item.(type) {
			case string:
				b.WriteString(x)
			case map[string]interface{}:
				if x["type"] == "text" {
					if txt, ok := x["text"].(string); ok {
						b.WriteString(txt)
					}
				}
			}
		}
		return b.String()
	default:
		return ""
	}
}

func titleFromContent(content interface{}) string {
	t := strings.TrimSpace(messageContentText(content))
	if len(t) > 80 {
		t = t[:80] + "…"
	}
	return t
}

func isKimiAgent(agent, model string) bool {
	a := strings.ToLower(strings.TrimSpace(agent))
	m := strings.ToLower(strings.TrimSpace(model))
	return a == "kimi" || a == "kimi-cli" || strings.Contains(m, "kimi")
}

// CollectSessionsList builds the same session list as the HTTP API (for SaaS agent relay).
func (s *SessionServer) CollectSessionsList(limit int) ([]SessionInfo, int) {
	if limit <= 0 {
		limit = 50
	}
	sessions := s.discoverAllAgentSessions()

	// Add managed tmux sessions
	s.mu.RLock()
	for _, ts := range s.tmuxSessions {
		found := false
		for i, sess := range sessions {
			if sess.SessionID == ts.ID {
				sessions[i].IsActive = ts.Status == "running"
				if sessions[i].Extra == nil {
					sessions[i].Extra = make(map[string]interface{})
				}
				sessions[i].Extra["agent"] = ts.Agent
				sessions[i].Extra["planulixManaged"] = true
				found = true
				break
			}
		}
		if !found {
			sessions = append(sessions, SessionInfo{
				SessionMeta: SessionMeta{
					SessionID: ts.ID,
					Cwd:       ts.Cwd,
					StartedAt: ts.StartedAt,
					Kind:      ts.Mode,
					Entry:     "planulix",
				},
				Title:    ts.Name,
				IsActive: ts.Status == "running",
				Extra: map[string]interface{}{
					"agent":           ts.Agent,
					"planulixManaged": true,
				},
			})
		}
	}
	s.mu.RUnlock()

	// Persisted Planulix-managed sessions (visible after restart, etc.)
	if s.agentStore != nil {
		for _, rec := range s.agentStore.List() {
			if !strings.HasPrefix(rec.ID, "cd-") {
				continue
			}
			found := false
			for _, sess := range sessions {
				if sess.SessionID == rec.ID {
					found = true
					break
				}
			}
			if found {
				continue
			}
			isActive := rec.Status == "running"
			if rec.TmuxName != "" {
				isActive = isActive && exec.Command("tmux", "has-session", "-t", rec.TmuxName).Run() == nil
			}
			sessions = append(sessions, SessionInfo{
				SessionMeta: SessionMeta{
					SessionID: rec.ID,
					Cwd:       rec.Cwd,
					StartedAt: rec.StartedAt,
					Kind:      "chat",
					Entry:     "planulix",
				},
				Title:    rec.Name,
				IsActive: isActive,
				Extra: map[string]interface{}{
					"agent":           rec.Agent,
					"planulixManaged": true,
					"fromStore":       true,
					"storeStatus":     rec.Status,
				},
			})
		}
	}

	// Enrich with tags/stars
	allTags := s.tags.GetAll()
	for i, sess := range sessions {
		pn, pp := inferProjectInfo(sess.Cwd)
		sessions[i].ProjectName = pn
		sessions[i].ProjectPath = pp
		if st, ok := allTags[sess.SessionID]; ok {
			if st.Title != "" {
				sessions[i].Title = st.Title
			}
			if sessions[i].Extra == nil {
				sessions[i].Extra = make(map[string]interface{})
			}
			sessions[i].Extra["starred"] = st.Starred
			sessions[i].Extra["tags"] = st.Tags
			if st.Title != "" {
				sessions[i].Extra["titleOverride"] = st.Title
			}
		}
	}

	// Drop sessions explicitly dismissed (DELETE in app — Kimi/Codex/… stay on disk otherwise).
	filtered := sessions[:0]
	for _, sess := range sessions {
		if s.tags.Get(sess.SessionID).Hidden {
			continue
		}
		filtered = append(filtered, sess)
	}
	sessions = filtered

	// Sort: starred first, then by startedAt descending
	sort.Slice(sessions, func(i, j int) bool {
		si := sessions[i].Extra != nil && sessions[i].Extra["starred"] == true
		sj := sessions[j].Extra != nil && sessions[j].Extra["starred"] == true
		if si != sj {
			return si
		}
		return sessions[i].StartedAt > sessions[j].StartedAt
	})

	total := len(sessions)
	if len(sessions) > limit {
		sessions = sessions[:limit]
	}
	return sessions, total
}

// ListSessions returns all Claude Code sessions found in ~/.claude/
func (s *SessionServer) ListSessions(c *gin.Context) {
	limit := 50
	if l := c.Query("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			limit = n
		}
	}
	sessions, total := s.CollectSessionsList(limit)
	c.JSON(200, gin.H{"sessions": sessions, "total": total})
}

// GetSession returns session details with messages
func (s *SessionServer) GetSession(c *gin.Context) {
	id := c.Param("id")

	jsonlPath, canonicalID, agentName, tmuxAlive := s.resolveJSONLPath(id)

	s.mu.RLock()
	ts, isManaged := s.tmuxSessions[id]
	s.mu.RUnlock()
	cwd := ""
	if isManaged {
		cwd = ts.Cwd
	} else if s.agentStore != nil {
		if rec := s.agentStore.Get(id); rec != nil {
			cwd = rec.Cwd
		}
	}

	var messages []Message
	var title string
	if jsonlPath != "" {
		messages, title = s.parseJSONL(jsonlPath)
	}

	if isManaged && title == "" {
		title = ts.Name
	}
	if !isManaged && title == "" && s.agentStore != nil {
		if rec := s.agentStore.Get(id); rec != nil {
			title = rec.Name
		}
	}
	if st := s.tags.Get(id); st.Title != "" {
		title = st.Title
	}

	historyLinked := jsonlPath != ""

	limit := 100
	if l := c.Query("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 {
			limit = n
		}
	}

	offset := 0
	if o := c.Query("offset"); o != "" {
		if n, err := strconv.Atoi(o); err == nil && n >= 0 {
			offset = n
		}
	}

	total := len(messages)
	if offset > total {
		offset = total
	}
	end := offset + limit
	if end > total {
		end = total
	}

	diag := gin.H{
		"agent":           agentName,
		"tmuxAlive":       tmuxAlive,
		"historyLinked":   historyLinked,
		"historyPath":     jsonlPath,
		"canonicalId":     canonicalID,
		"planulixManaged": isManaged,
	}
	if agentName == "kimi-cli" && historyLinked {
		u, a := countUserAssistant(messages)
		if u > 0 && a == 0 {
			diag["authHint"] = strings.Join([]string{
				"Kimi: есть сообщения пользователя, но нет ответов в истории.",
				"Частые причины: (1) неверный endpoint — для platform.moonshot.ai включите «Международный Moonshot» (передаются MOONSHOT_BASE_URL и KIMI_BASE_URL=https://api.moonshot.ai/v1), затем начните новую сессию в чате;",
				"(2) нет ключа или неверный endpoint — в настройках или KIMI_API_KEY + KIMI_BASE_URL в /root/planulix.env; для Kimi Code в ~/.kimi/config.toml провайдер обычно base_url = https://api.kimi.com/coding/v1 (см. доки);",
				"(3) «LLM not set» при автоматизации часто значит, что имя модели из приложения не заведено в [models] на сервере — см. https://github.com/MoonshotAI/kimi-cli/issues/1954; выполните на VPS `kimi` → /login или приведите config.toml в соответствие; resume с сервера идёт без флага -m, чтобы использовалась модель сессии.",
			}, " ")
		}
	}

	c.JSON(200, gin.H{
		"sessionId":   id,
		"title":       title,
		"cwd":         cwd,
		"projectName": func() string { n, _ := inferProjectInfo(cwd); return n }(),
		"projectPath": func() string { _, p := inferProjectInfo(cwd); return p }(),
		"messages":    messages[offset:end],
		"total":       total,
		"offset":      offset,
		"diagnostics": diag,
	})
}

// CreateSession starts a new Claude Code session in tmux
// mode: "chat" (interactive, default) or "task" (one-shot with -p)
func (s *SessionServer) CreateSession(c *gin.Context) {
	var req struct {
		Cwd      string            `json:"cwd"`
		Prompt   string            `json:"prompt"`
		Name     string            `json:"name"`
		Mode     string            `json:"mode"`     // "chat" or "task"
		Model    string            `json:"model"`    // "opus", "sonnet", "haiku" or full model id
		Agent    string            `json:"agent"`    // "claude-code" (default) or "kimi-cli"
		AgentEnv map[string]string `json:"agentEnv"` // optional: KIMI_API_KEY, ANTHROPIC_API_KEY, … (whitelisted)
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request"})
		return
	}

	req.Cwd = normalizeSessionCwd(req.Cwd)
	if req.Mode == "" {
		req.Mode = "chat"
	}
	if req.Name == "" {
		prefix := agentTmuxPrefix(req.Agent)
		// Unix-second names collide under double-create or rapid taps; tmux rejects duplicate targets.
		req.Name = fmt.Sprintf("%s-%d", prefix, time.Now().UnixMilli())
	}

	sessionID := fmt.Sprintf("cd-%d", time.Now().UnixMilli())

	agent := normalizeRequestedAgent(req.Agent, req.Model)

	agentCmd, shellEnv, err := buildAgentCommand(agent, req.Mode, req.Cwd, req.Prompt, req.Model, req.AgentEnv)
	if err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}

	// Create tmux session. Use a full PATH so CLI agents can find dependencies.
	shellCmd := shellEnv + " && " + agentCmd
	cmd := exec.Command("tmux", "new-session", "-d", "-s", req.Name, "-c", req.Cwd, "bash", "-c", shellCmd)
	output, err := cmd.CombinedOutput()
	if err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("failed to create tmux session: %v (output: %s)", err, string(output))})
		return
	}

	if agent == "claude-code" {
		// Auto-confirm Claude startup dialogs (trust folder, skip-permissions acceptance).
		go func() {
			time.Sleep(2 * time.Second)
			exec.Command("tmux", "send-keys", "-t", req.Name, "Enter").Run()
			time.Sleep(3 * time.Second)
			exec.Command("tmux", "send-keys", "-t", req.Name, "Down").Run()
			time.Sleep(200 * time.Millisecond)
			exec.Command("tmux", "send-keys", "-t", req.Name, "Enter").Run()
		}()
	}

	ts := &TmuxSession{
		ID:        sessionID,
		Name:      req.Name,
		Cwd:       req.Cwd,
		StartedAt: time.Now().UnixMilli(),
		Status:    "running",
		Mode:      req.Mode,
		Agent:     agent,
		Prompt:    req.Prompt,
		Model:     strings.TrimSpace(req.Model),
		ResumeEnv: mergeAgentEnvPreferred(req.AgentEnv, nil),
	}

	s.mu.Lock()
	s.tmuxSessions[sessionID] = ts
	s.mu.Unlock()

	s.persistManaged(ts)

	// For chat mode with initial prompt, send after the CLI starts.
	// Claude/Kimi use their resume APIs after linking; Cursor is sent through /message.
	if req.Mode == "chat" && req.Prompt != "" && agent != "kimi-cli" && agent != "claude-code" && agent != "cursor" {
		go func() {
			wait := 5 * time.Second
			time.Sleep(wait) // wait for CLI agent to fully init
			exec.Command("tmux", "send-keys", "-t", req.Name, "-l", req.Prompt).Run()
			exec.Command("tmux", "send-keys", "-t", req.Name, "Enter").Run()
		}()
	}

	// Background: link to Claude's actual session by watching for new JSONL files
	if agent == "claude-code" {
		go s.linkClaudeSession(sessionID, req.Name, req.Cwd)
	}
	if agent == "kimi-cli" {
		go s.linkKimiSession(sessionID, req.Name, req.Cwd)
	}
	if agent != "claude-code" && agent != "kimi-cli" {
		go s.linkGenericAgentSession(sessionID, req.Name, req.Cwd, agent)
	}

	c.JSON(201, gin.H{"session": ts})
}

func (s *SessionServer) linkGenericAgentSession(managedID, tmuxName, cwd, agent string) {
	existing := map[string]bool{}
	for _, sess := range s.discoverAllAgentSessions() {
		if sess.Extra == nil {
			continue
		}
		if a, _ := sess.Extra["agent"].(string); a == agent {
			if p, _ := sess.Extra["path"].(string); p != "" {
				existing[p] = true
			}
		}
	}
	for i := 0; i < 45; i++ {
		time.Sleep(1 * time.Second)
		for _, sess := range s.discoverAllAgentSessions() {
			if sess.Extra == nil {
				continue
			}
			if a, _ := sess.Extra["agent"].(string); a != agent {
				continue
			}
			p, _ := sess.Extra["path"].(string)
			if p == "" || existing[p] {
				continue
			}
			s.mu.Lock()
			if ts, ok := s.tmuxSessions[managedID]; ok {
				ts.HistoryPath = p
				ts.ClaudeSession = sess.SessionID
				s.persistManaged(ts)
			}
			s.mu.Unlock()
			log.Printf("Linked managed session %s -> %s history %s (cwd=%s)", managedID, agent, p, cwd)
			return
		}
		if exec.Command("tmux", "has-session", "-t", tmuxName).Run() != nil {
			s.mu.Lock()
			if ts, ok := s.tmuxSessions[managedID]; ok {
				ts.Status = "done"
				s.persistManaged(ts)
			}
			s.mu.Unlock()
			return
		}
	}
}

// linkClaudeSession watches for a new Claude Code session JSONL file
// and links it to our managed session
func (s *SessionServer) linkClaudeSession(managedID, tmuxName, cwd string) {
	// Get list of existing session files before
	existingFiles := make(map[string]bool)
	sessDir := filepath.Join(s.claudeHome, "sessions")
	entries, _ := os.ReadDir(sessDir)
	for _, e := range entries {
		existingFiles[e.Name()] = true
	}

	// Poll for new session file (up to 30 seconds)
	for i := 0; i < 30; i++ {
		time.Sleep(1 * time.Second)

		entries, err := os.ReadDir(sessDir)
		if err != nil {
			continue
		}

		for _, e := range entries {
			if existingFiles[e.Name()] || !strings.HasSuffix(e.Name(), ".json") {
				continue
			}

			// New file found — read it
			data, err := os.ReadFile(filepath.Join(sessDir, e.Name()))
			if err != nil {
				continue
			}

			var meta SessionMeta
			if err := json.Unmarshal(data, &meta); err != nil {
				continue
			}

			// Check if this session matches our cwd
			if meta.Cwd == cwd {
				prompt := ""
				model := ""
				var env map[string]string
				s.mu.Lock()
				if ts, ok := s.tmuxSessions[managedID]; ok {
					ts.ClaudeSession = meta.SessionID
					if p := s.findSessionJSONL(meta.SessionID); p != "" {
						ts.HistoryPath = p
					}
					prompt = strings.TrimSpace(ts.Prompt)
					model = strings.TrimSpace(ts.Model)
					env = mergeAgentEnvPreferred(ts.ResumeEnv, nil)
					s.persistManaged(ts)
				}
				s.mu.Unlock()
				log.Printf("Linked managed session %s -> Claude session %s", managedID, meta.SessionID)
				if prompt != "" {
					go func() {
						cmd := exec.Command("bash", "-c", buildClaudeResumeShell(cwd, meta.SessionID, prompt, env, model))
						if output, err := cmd.CombinedOutput(); err != nil {
							log.Printf("Claude initial prompt resume failed for %s: %v (output: %s)", meta.SessionID, err, string(output))
						}
					}()
				}
				return
			}
		}

		// Also check if tmux session is still alive
		checkCmd := exec.Command("tmux", "has-session", "-t", tmuxName)
		if checkCmd.Run() != nil {
			// tmux session died
			s.mu.Lock()
			if ts, ok := s.tmuxSessions[managedID]; ok {
				ts.Status = "done"
				s.persistManaged(ts)
			}
			s.mu.Unlock()
			return
		}
	}
}

// runKimiResumeSend runs kimi --session … --print in bash (same env wiring as buildKimiResumeShell).
func (s *SessionServer) runKimiResumeSend(cwd, sessionUUID, text string, agentEnv map[string]string, model, logCtx string) {
	_, _ = s.runKimiResumeSendResult(cwd, sessionUUID, text, agentEnv, model, logCtx)
}

func (s *SessionServer) runKimiResumeSendResult(cwd, sessionUUID, text string, agentEnv map[string]string, model, logCtx string) (string, error) {
	if strings.TrimSpace(text) == "" || strings.TrimSpace(sessionUUID) == "" {
		return "", fmt.Errorf("empty text or session id")
	}
	cmd := exec.Command("bash", "-c", buildKimiResumeShell(cwd, sessionUUID, text, agentEnv, model))
	output, err := cmd.CombinedOutput()
	outStr := strings.TrimSpace(string(output))
	if err != nil {
		log.Printf("Kimi resume send [%s] failed for %s: %v (output: %s)", logCtx, sessionUUID, err, outStr)
		return "", fmt.Errorf("%w: %s", err, outStr)
	}
	if strings.Contains(outStr, "LLM not set") {
		log.Printf("Kimi resume [%s] for %s: LLM not set — set Kimi key + KIMI_BASE_URL (or MOONSHOT_BASE_URL) in Planulix app or /root/planulix.env; if the session was first opened without keys, start a new chat session. Output: %s", logCtx, sessionUUID, outStr)
		return "", fmt.Errorf("kimi LLM not set")
	}
	answer := kimiCleanPrintOutput(outStr)
	if answer == "" {
		answer = outStr
	}
	log.Printf("Kimi resume send [%s] ok for %s (bytes=%d clean_bytes=%d)", logCtx, sessionUUID, len(outStr), len(answer))
	return answer, nil
}

func (s *SessionServer) runClaudeResumeSendResult(cwd, claudeSID, text string, agentEnv map[string]string, model, logCtx string) (string, error) {
	if strings.TrimSpace(text) == "" || strings.TrimSpace(claudeSID) == "" {
		return "", fmt.Errorf("empty text or session id")
	}
	cmd := exec.Command("bash", "-c", buildClaudeResumeShell(cwd, claudeSID, text, agentEnv, model))
	output, err := cmd.CombinedOutput()
	outStr := strings.TrimSpace(stripANSI(string(output)))
	if err != nil {
		log.Printf("Claude resume send [%s] failed for %s: %v (output: %s)", logCtx, claudeSID, err, outStr)
		return "", fmt.Errorf("%w: %s", err, outStr)
	}
	log.Printf("Claude resume send [%s] ok for %s (bytes=%d)", logCtx, claudeSID, len(outStr))
	return outStr, nil
}

func runAgentTaskSendResult(agent, cwd, text string, agentEnv map[string]string, model, logCtx string) (string, error) {
	if strings.TrimSpace(text) == "" {
		return "", fmt.Errorf("empty text")
	}
	if strings.TrimSpace(cwd) == "" {
		home, _ := os.UserHomeDir()
		cwd = home
	}
	cmdFrag, env, err := buildAgentCommand(agent, "task", cwd, text, model, agentEnv)
	if err != nil {
		return "", err
	}
	cmd := exec.Command("bash", "-c", fmt.Sprintf("%s && %s", env, cmdFrag))
	output, err := cmd.CombinedOutput()
	outStr := strings.TrimSpace(stripANSI(string(output)))
	if err != nil {
		log.Printf("%s task send [%s] failed: %v (output: %s)", agent, logCtx, err, outStr)
		return "", fmt.Errorf("%w: %s", err, outStr)
	}
	if normalizeRequestedAgent(agent, model) == "kimi-cli" {
		if cleaned := kimiCleanPrintOutput(outStr); cleaned != "" {
			outStr = cleaned
		}
	}
	if normalizeRequestedAgent(agent, model) == "codex-cli" {
		if cleaned := codexCleanExecOutput(outStr); cleaned != "" {
			outStr = cleaned
		}
	}
	log.Printf("%s task send [%s] ok (bytes=%d)", agent, logCtx, len(outStr))
	return outStr, nil
}

func codexCleanExecOutput(stdout string) string {
	stdout = strings.TrimSpace(strings.ReplaceAll(stdout, "\r\n", "\n"))
	if stdout == "" {
		return ""
	}
	lines := strings.Split(stdout, "\n")

	start := -1
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.EqualFold(strings.TrimSpace(lines[i]), "codex") {
			start = i + 1
			break
		}
	}
	if start < 0 || start >= len(lines) {
		return stdout
	}

	end := len(lines)
	for i := start; i < len(lines); i++ {
		switch strings.ToLower(strings.TrimSpace(lines[i])) {
		case "tokens used":
			end = i
		case "--------":
			if i > start {
				end = i
			}
		}
		if end != len(lines) {
			break
		}
	}

	answer := strings.TrimSpace(strings.Join(lines[start:end], "\n"))
	if answer == "" {
		return stdout
	}
	return answer
}

func (s *SessionServer) planulixTranscriptPath(id string) string {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		home = "."
	}
	return filepath.Join(home, ".planulix", "transcripts", id+".jsonl")
}

func appendPlanulixTranscript(path, userText, assistantText, model string) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("empty transcript path")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	writeMsg := func(role, content string) error {
		if strings.TrimSpace(content) == "" {
			return nil
		}
		line, err := json.Marshal(map[string]interface{}{
			"type": role,
			"message": map[string]interface{}{
				"role":    role,
				"content": content,
				"model":   model,
			},
			"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		})
		if err != nil {
			return err
		}
		if _, err := f.Write(append(line, '\n')); err != nil {
			return err
		}
		return nil
	}
	if err := writeMsg("user", userText); err != nil {
		return err
	}
	return writeMsg("assistant", assistantText)
}

func (s *SessionServer) appendManagedLocalTranscript(ts *TmuxSession, userText, assistantText, model string) {
	if ts == nil {
		return
	}
	if strings.TrimSpace(ts.HistoryPath) == "" || !strings.Contains(ts.HistoryPath, ".planulix") {
		ts.HistoryPath = s.planulixTranscriptPath(ts.ID)
	}
	if err := appendPlanulixTranscript(ts.HistoryPath, userText, assistantText, model); err != nil {
		log.Printf("append local transcript for %s failed: %v", ts.ID, err)
		return
	}
	s.persistManaged(ts)
}

func (s *SessionServer) appendStoredLocalTranscript(rec *StoredAgentSession, userText, assistantText, model string) {
	if s.agentStore == nil || rec == nil {
		return
	}
	if strings.TrimSpace(rec.HistoryPath) == "" || !strings.Contains(rec.HistoryPath, ".planulix") {
		rec.HistoryPath = s.planulixTranscriptPath(rec.ID)
	}
	if err := appendPlanulixTranscript(rec.HistoryPath, userText, assistantText, model); err != nil {
		log.Printf("append stored transcript for %s failed: %v", rec.ID, err)
		return
	}
	rec.Status = "running"
	_ = s.agentStore.Upsert(rec)
}

func (s *SessionServer) recoverKimiLink(cwd string, startedAt int64) (externalID, historyPath string) {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" || strings.TrimSpace(cwd) == "" {
		return "", ""
	}
	cwdMap := loadKimiSessionDirToCwd(home)
	cutoff := startedAt - int64((2 * time.Minute).Milliseconds())
	var bestMod int64
	for key, mappedCwd := range cwdMap {
		if mappedCwd != cwd {
			continue
		}
		root := filepath.Join(home, ".kimi", "sessions", key)
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			ctxPath := filepath.Join(root, e.Name(), "context.jsonl")
			st, err := os.Stat(ctxPath)
			if err != nil || st.IsDir() {
				continue
			}
			mod := st.ModTime().UnixMilli()
			if startedAt > 0 && mod < cutoff {
				continue
			}
			if mod >= bestMod {
				bestMod = mod
				externalID = "kimi-" + e.Name()
				historyPath = ctxPath
			}
		}
	}
	return externalID, historyPath
}

func (s *SessionServer) recoverClaudeLink(cwd string, startedAt int64) (sessionID, historyPath string) {
	if strings.TrimSpace(cwd) == "" {
		return "", ""
	}
	sessDir := filepath.Join(s.claudeHome, "sessions")
	entries, err := os.ReadDir(sessDir)
	if err != nil {
		return "", ""
	}
	cutoff := startedAt - int64((2 * time.Minute).Milliseconds())
	var bestStarted int64
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := filepath.Join(sessDir, e.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var meta SessionMeta
		if err := json.Unmarshal(data, &meta); err != nil {
			continue
		}
		if meta.Cwd != cwd || strings.TrimSpace(meta.SessionID) == "" {
			continue
		}
		candidateStarted := meta.StartedAt
		if candidateStarted == 0 {
			if st, err := os.Stat(path); err == nil {
				candidateStarted = st.ModTime().UnixMilli()
			}
		}
		if startedAt > 0 && candidateStarted < cutoff {
			continue
		}
		jsonlPath := s.findSessionJSONL(meta.SessionID)
		if jsonlPath == "" {
			continue
		}
		if candidateStarted >= bestStarted {
			bestStarted = candidateStarted
			sessionID = meta.SessionID
			historyPath = jsonlPath
		}
	}
	return sessionID, historyPath
}

func (s *SessionServer) recoverStoredLink(rec *StoredAgentSession) {
	if s.agentStore == nil || rec == nil {
		return
	}
	switch rec.Agent {
	case "kimi-cli":
		if rec.ExternalID != "" && rec.HistoryPath != "" {
			return
		}
		ext, hist := s.recoverKimiLink(rec.Cwd, rec.StartedAt)
		if ext == "" || hist == "" {
			return
		}
		rec.ExternalID = ext
		rec.HistoryPath = hist
	case "claude-code":
		if rec.ClaudeSessionID != "" && rec.HistoryPath != "" {
			return
		}
		sid, hist := s.recoverClaudeLink(rec.Cwd, rec.StartedAt)
		if sid == "" || hist == "" {
			return
		}
		rec.ClaudeSessionID = sid
		rec.HistoryPath = hist
	default:
		return
	}
	_ = s.agentStore.Upsert(rec)
}

// linkKimiSession watches ~/.kimi/sessions/<workdir-hash>/ for a new session dir with context.jsonl.
func (s *SessionServer) linkKimiSession(managedID, tmuxName, cwd string) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return
	}
	existing := make(map[string]bool)
	startedCutoff := time.Now().Add(-5 * time.Second)
	keysSeen := make(map[string]bool)
	keysForCwd := func() []string {
		cwdMap := loadKimiSessionDirToCwd(home)
		var keys []string
		for k, p := range cwdMap {
			if p == cwd {
				keys = append(keys, k)
			}
		}
		return keys
	}
	primeExisting := func(key string) {
		if keysSeen[key] {
			return
		}
		keysSeen[key] = true
		root := filepath.Join(home, ".kimi", "sessions", key)
		entries, _ := os.ReadDir(root)
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			ctxPath := filepath.Join(root, e.Name(), "context.jsonl")
			st, err := os.Stat(ctxPath)
			if err == nil && !st.IsDir() && st.ModTime().Before(startedCutoff) {
				existing[key+"/"+e.Name()] = true
			}
		}
	}
	for i := 0; i < 45; i++ {
		time.Sleep(1 * time.Second)
		keys := keysForCwd()
		for _, key := range keys {
			primeExisting(key)
			root := filepath.Join(home, ".kimi", "sessions", key)
			entries, err := os.ReadDir(root)
			if err != nil {
				continue
			}
			for _, e := range entries {
				if !e.IsDir() {
					continue
				}
				sk := key + "/" + e.Name()
				if existing[sk] {
					continue
				}
				ctxPath := filepath.Join(root, e.Name(), "context.jsonl")
				if st, err := os.Stat(ctxPath); err != nil || st.IsDir() {
					continue
				}
				var prompt string
				var model string
				var resumeEnv map[string]string
				uuid := e.Name()
				s.mu.Lock()
				if ts, ok := s.tmuxSessions[managedID]; ok {
					ts.KimiSession = "kimi-" + uuid
					ts.HistoryPath = ctxPath
					prompt = ts.Prompt
					model = ts.Model
					if ts.ResumeEnv != nil {
						resumeEnv = make(map[string]string, len(ts.ResumeEnv))
						for k, v := range ts.ResumeEnv {
							resumeEnv[k] = v
						}
					}
					s.persistManaged(ts)
				}
				s.mu.Unlock()
				log.Printf("Linked managed session %s -> Kimi session %s", managedID, uuid)
				if strings.TrimSpace(prompt) != "" {
					go s.runKimiResumeSend(cwd, uuid, prompt, resumeEnv, model, "initial-link")
				}
				return
			}
		}
		checkCmd := exec.Command("tmux", "has-session", "-t", tmuxName)
		if checkCmd.Run() != nil {
			s.mu.Lock()
			if ts, ok := s.tmuxSessions[managedID]; ok {
				ts.Status = "done"
				s.persistManaged(ts)
			}
			s.mu.Unlock()
			return
		}
	}
}

func sendLiteralToTmux(tmuxName, text string) error {
	if err := exec.Command("tmux", "send-keys", "-t", tmuxName, "-l", text).Run(); err != nil {
		return err
	}
	return exec.Command("tmux", "send-keys", "-t", tmuxName, "Enter").Run()
}

// SendMessage sends input to a tmux session
func (s *SessionServer) SendMessage(c *gin.Context) {
	id := c.Param("id")

	var req struct {
		Text     string            `json:"text"`
		Model    string            `json:"model"`
		AgentEnv map[string]string `json:"agentEnv"`
	}
	if err := c.ShouldBindJSON(&req); err != nil || req.Text == "" {
		c.JSON(400, gin.H{"error": "text is required"})
		return
	}

	s.mu.RLock()
	ts, ok := s.tmuxSessions[id]
	s.mu.RUnlock()

	// If managed session exists, check if tmux is still alive
	if ok {
		checkCmd := exec.Command("tmux", "has-session", "-t", ts.Name)
		if checkCmd.Run() != nil {
			// tmux died — remove from map, fall through to resume
			s.mu.Lock()
			delete(s.tmuxSessions, id)
			s.mu.Unlock()
			ok = false
		}
	}

	if !ok {
		jsonlPath, canon, agentName, _ := s.resolveJSONLPath(id)
		rec := (*StoredAgentSession)(nil)
		if s.agentStore != nil {
			rec = s.agentStore.Get(id)
		}
		if agentName == "" && rec != nil {
			agentName = strings.TrimSpace(rec.Agent)
		}
		restoredAgent := ""
		if rec != nil {
			restoredAgent = strings.TrimSpace(rec.Agent)
		}
		if rec != nil && strings.TrimSpace(rec.TmuxName) != "" && restoredAgent != "cursor" && !(restoredAgent == "claude-code" && strings.TrimSpace(rec.ClaudeSessionID) != "") {
			if exec.Command("tmux", "has-session", "-t", rec.TmuxName).Run() == nil {
				if err := sendLiteralToTmux(rec.TmuxName, req.Text); err != nil {
					c.JSON(500, gin.H{"error": fmt.Sprintf("failed to send to restored tmux session: %v", err)})
					return
				}
				c.JSON(200, gin.H{"ok": true, "restoredTmux": true})
				return
			}
		}
		cwd := ""
		if rec != nil {
			cwd = rec.Cwd
		}
		cwd = normalizeSessionCwd(cwd)

		isKimi := agentName == "kimi-cli" || strings.HasPrefix(id, "kimi-") || strings.HasPrefix(canon, "kimi-")
		if isKimi {
			uuid := ""
			switch {
			case strings.HasPrefix(canon, "kimi-"):
				uuid = kimiAPIID(canon)
			case strings.HasPrefix(id, "kimi-"):
				uuid = kimiAPIID(id)
			case rec != nil && rec.ExternalID != "":
				uuid = kimiAPIID(rec.ExternalID)
			}
			if uuid == "" {
				agentEnv := mergeAgentEnvPreferred(req.AgentEnv, nil)
				answer, err := runAgentTaskSendResult("kimi-cli", cwd, req.Text, agentEnv, req.Model, "unlinked-fallback")
				if err != nil {
					c.JSON(409, gin.H{"error": "kimi session not linked yet; wait a few seconds and retry", "diagnostics": gin.H{
						"historyLinked": jsonlPath != "",
						"fallbackError": err.Error(),
					}})
					return
				}
				if rec != nil && strings.HasPrefix(id, "cd-") {
					s.appendStoredLocalTranscript(rec, req.Text, answer, req.Model)
				}
				c.JSON(200, gin.H{"ok": true, "assistant": answer, "fallbackTask": true})
				return
			}
			if cwd == "" {
				cwd = s.findSessionCwd("kimi-" + uuid)
			}
			if cwd == "" {
				home, _ := os.UserHomeDir()
				cwd = home
			}
			agentEnv := mergeAgentEnvPreferred(req.AgentEnv, nil)
			model := strings.TrimSpace(req.Model)
			answer, err := s.runKimiResumeSendResult(cwd, uuid, req.Text, agentEnv, model, "unmanaged")
			if err != nil {
				c.JSON(502, gin.H{"error": err.Error()})
				return
			}
			c.JSON(200, gin.H{"ok": true, "assistant": answer})
			return
		}
		if agentName == "cursor" {
			if cwd == "" {
				home, _ := os.UserHomeDir()
				cwd = home
			}
			answer, err := runAgentTaskSendResult("cursor", cwd, req.Text, req.AgentEnv, req.Model, "unmanaged")
			if err != nil {
				c.JSON(502, gin.H{"error": err.Error()})
				return
			}
			if rec != nil && strings.HasPrefix(id, "cd-") {
				s.appendStoredLocalTranscript(rec, req.Text, answer, req.Model)
			}
			c.JSON(200, gin.H{"ok": true, "assistant": answer})
			return
		}
		// Discovered JSONL sessions (tmux died or opened outside Planulix): Codex/Kiro/OpenCode
		// have no Planulix "resume shell" wrapper yet — run one-shot CLI task in cwd (same as Cursor).
		if agentName == "codex-cli" || agentName == "kiro-cli" || agentName == "opencode" {
			if cwd == "" {
				home, _ := os.UserHomeDir()
				cwd = home
			}
			agentEnv := mergeAgentEnvPreferred(req.AgentEnv, nil)
			answer, err := runAgentTaskSendResult(agentName, cwd, req.Text, agentEnv, req.Model, "detached-exec-fallback")
			if err != nil {
				c.JSON(502, gin.H{"error": err.Error()})
				return
			}
			if rec != nil && strings.HasPrefix(id, "cd-") {
				s.appendStoredLocalTranscript(rec, req.Text, answer, req.Model)
			}
			c.JSON(200, gin.H{"ok": true, "assistant": answer, "fallbackTask": true})
			return
		}

		claudeSessionID := canon
		if jsonlPath == "" {
			jsonlPath = s.findSessionJSONL(id)
		}
		if jsonlPath == "" {
			answer, err := runAgentTaskSendResult("claude-code", cwd, req.Text, req.AgentEnv, req.Model, "unlinked-fallback")
			if err != nil {
				c.JSON(404, gin.H{"error": "session not found", "fallbackError": err.Error()})
				return
			}
			if rec != nil && strings.HasPrefix(id, "cd-") {
				s.appendStoredLocalTranscript(rec, req.Text, answer, req.Model)
			}
			c.JSON(200, gin.H{"ok": true, "assistant": answer, "fallbackTask": true})
			return
		}
		if rec != nil && rec.ClaudeSessionID != "" {
			claudeSessionID = rec.ClaudeSessionID
		}
		if strings.HasPrefix(id, "cd-") && (rec == nil || strings.TrimSpace(rec.ClaudeSessionID) == "") {
			answer, err := runAgentTaskSendResult("claude-code", cwd, req.Text, req.AgentEnv, req.Model, "stored-unlinked-fallback")
			if err != nil {
				c.JSON(409, gin.H{"error": "claude session not linked yet; wait a few seconds and retry", "fallbackError": err.Error()})
				return
			}
			if rec != nil {
				s.appendStoredLocalTranscript(rec, req.Text, answer, req.Model)
			}
			c.JSON(200, gin.H{"ok": true, "assistant": answer, "fallbackTask": true})
			return
		}

		if cwd == "" {
			cwd = s.findSessionCwd(claudeSessionID)
		}
		if cwd == "" {
			home, _ := os.UserHomeDir()
			cwd = home
		}

		agentEnv := req.AgentEnv
		model := req.Model
		answer, err := s.runClaudeResumeSendResult(cwd, claudeSessionID, req.Text, agentEnv, model, "unmanaged")
		if err != nil {
			c.JSON(502, gin.H{"error": err.Error()})
			return
		}
		c.JSON(200, gin.H{"ok": true, "assistant": answer})
		return
	}

	managedAgent := ""
	if ok {
		managedAgent = strings.TrimSpace(ts.Agent)
		if strings.HasPrefix(id, "cd-") && s.agentStore != nil {
			if r := s.agentStore.Get(id); r != nil && strings.TrimSpace(r.Agent) != "" {
				managedAgent = strings.TrimSpace(r.Agent)
			}
		}
	}

	// Kimi (managed, linked): interactive tmux often misses multi-byte / pasted input via send-keys.
	// Use the same one-shot API as the unlinked path — updates context.jsonl Kimi already uses.
	if managedAgent == "kimi-cli" {
		if strings.TrimSpace(ts.KimiSession) == "" {
			if s.agentStore != nil {
				if rec := s.agentStore.Get(id); rec != nil {
					s.recoverStoredLink(rec)
					if rec2 := s.agentStore.Get(id); rec2 != nil && strings.TrimSpace(rec2.ExternalID) != "" {
						ts.KimiSession = rec2.ExternalID
						ts.HistoryPath = rec2.HistoryPath
					}
				}
			}
		}
		if strings.TrimSpace(ts.KimiSession) == "" {
			for i := 0; i < 30; i++ {
				time.Sleep(500 * time.Millisecond)
				s.mu.RLock()
				linked := ""
				if latest, exists := s.tmuxSessions[id]; exists && latest != nil {
					linked = strings.TrimSpace(latest.KimiSession)
				}
				s.mu.RUnlock()
				if linked != "" {
					ts.KimiSession = linked
					break
				}
			}
		}
		if strings.TrimSpace(ts.KimiSession) == "" {
			c.JSON(409, gin.H{"error": "kimi session not linked yet; wait a few seconds and retry"})
			return
		}
		uuid := kimiAPIID(ts.KimiSession)
		cwd := ts.Cwd
		if cwd == "" {
			cwd = s.findSessionCwd(ts.KimiSession)
		}
		if cwd == "" {
			home, _ := os.UserHomeDir()
			cwd = home
		}
		agentEnv := mergeAgentEnvPreferred(req.AgentEnv, ts.ResumeEnv)
		model := strings.TrimSpace(req.Model)
		if model == "" {
			model = ts.Model
		}
		text := req.Text
		answer, err := s.runKimiResumeSendResult(cwd, uuid, text, agentEnv, model, "managed-tmux")
		if err != nil {
			c.JSON(502, gin.H{"error": err.Error()})
			return
		}
		c.JSON(200, gin.H{"ok": true, "assistant": answer})
		return
	}

	if managedAgent == "cursor" {
		model := strings.TrimSpace(req.Model)
		if model == "" {
			model = ts.Model
		}
		answer, err := runAgentTaskSendResult("cursor", ts.Cwd, req.Text, req.AgentEnv, model, "managed-tmux")
		if err != nil {
			c.JSON(502, gin.H{"error": err.Error()})
			return
		}
		s.appendManagedLocalTranscript(ts, req.Text, answer, model)
		c.JSON(200, gin.H{"ok": true, "assistant": answer})
		return
	}

	if managedAgent == "codex-cli" || managedAgent == "kiro-cli" || managedAgent == "opencode" {
		cwd := normalizeSessionCwd(ts.Cwd)
		model := strings.TrimSpace(req.Model)
		if model == "" {
			model = ts.Model
		}
		agentEnv := mergeAgentEnvPreferred(req.AgentEnv, ts.ResumeEnv)
		answer, err := runAgentTaskSendResult(managedAgent, cwd, req.Text, agentEnv, model, "managed-exec-fallback")
		if err != nil {
			c.JSON(502, gin.H{"error": err.Error()})
			return
		}
		s.appendManagedLocalTranscript(ts, req.Text, answer, model)
		c.JSON(200, gin.H{"ok": true, "assistant": answer, "fallbackTask": true})
		return
	}

	if managedAgent == "claude-code" {
		if strings.TrimSpace(ts.ClaudeSession) == "" {
			if s.agentStore != nil {
				if rec := s.agentStore.Get(id); rec != nil {
					s.recoverStoredLink(rec)
					if rec2 := s.agentStore.Get(id); rec2 != nil && strings.TrimSpace(rec2.ClaudeSessionID) != "" {
						ts.ClaudeSession = rec2.ClaudeSessionID
						ts.HistoryPath = rec2.HistoryPath
					}
				}
			}
		}
		if strings.TrimSpace(ts.ClaudeSession) == "" {
			for i := 0; i < 20; i++ {
				time.Sleep(500 * time.Millisecond)
				s.mu.RLock()
				linked := ""
				if latest, exists := s.tmuxSessions[id]; exists && latest != nil {
					linked = strings.TrimSpace(latest.ClaudeSession)
				}
				s.mu.RUnlock()
				if linked != "" {
					ts.ClaudeSession = linked
					break
				}
			}
		}
		if strings.TrimSpace(ts.ClaudeSession) == "" {
			cwd := normalizeSessionCwd(ts.Cwd)
			model := strings.TrimSpace(req.Model)
			if model == "" {
				model = ts.Model
			}
			answer, err := runAgentTaskSendResult("claude-code", cwd, req.Text, req.AgentEnv, model, "managed-unlinked-fallback")
			if err != nil {
				c.JSON(409, gin.H{"error": "claude session not linked yet; wait a few seconds and retry", "fallbackError": err.Error()})
				return
			}
			s.appendManagedLocalTranscript(ts, req.Text, answer, model)
			c.JSON(200, gin.H{"ok": true, "assistant": answer, "fallbackTask": true})
			return
		}
		cwd := ts.Cwd
		if cwd == "" {
			cwd = s.findSessionCwd(ts.ClaudeSession)
		}
		if cwd == "" {
			home, _ := os.UserHomeDir()
			cwd = home
		}
		model := strings.TrimSpace(req.Model)
		if model == "" {
			model = ts.Model
		}
		answer, err := s.runClaudeResumeSendResult(cwd, ts.ClaudeSession, req.Text, req.AgentEnv, model, "managed-tmux")
		if err != nil {
			c.JSON(502, gin.H{"error": err.Error()})
			return
		}
		c.JSON(200, gin.H{"ok": true, "assistant": answer})
		return
	}

	// Send keys to tmux
	// Use -l for literal text to handle special chars, then Enter separately
	if err := sendLiteralToTmux(ts.Name, req.Text); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("failed to send: %v", err)})
		return
	}

	c.JSON(200, gin.H{"ok": true})
}

// StopSession kills a tmux session and/or removes it from the list
func (s *SessionServer) StopSession(c *gin.Context) {
	id := c.Param("id")

	// Try managed sessions first
	s.mu.Lock()
	ts, ok := s.tmuxSessions[id]
	if ok {
		stCopy := ts.ToStored()
		ts.Status = "stopped"
		exec.Command("tmux", "kill-session", "-t", ts.Name).Run()
		delete(s.tmuxSessions, id)
		if s.agentStore != nil && stCopy != nil {
			stCopy.Status = "stopped"
			_ = s.agentStore.Upsert(stCopy)
		}
	}
	s.mu.Unlock()

	if ok {
		s.markSessionHidden(id)
		c.JSON(200, gin.H{"ok": true})
		return
	}

	// For non-managed sessions (discovered from ~/.claude/sessions/), try to kill the process
	sessDir := filepath.Join(s.claudeHome, "sessions")
	entries, _ := os.ReadDir(sessDir)
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(sessDir, e.Name()))
		if err != nil {
			continue
		}
		var meta SessionMeta
		if err := json.Unmarshal(data, &meta); err != nil {
			continue
		}
		if meta.SessionID == id && meta.PID > 0 {
			// Kill the Claude Code process
			if p, err := os.FindProcess(meta.PID); err == nil {
				p.Signal(os.Interrupt)
			}
			s.markSessionHidden(id)
			c.JSON(200, gin.H{"ok": true})
			return
		}
	}

	// Not found anywhere — hide from list (Kimi/Cursor/… discovered sessions)
	s.markSessionHidden(id)
	c.JSON(200, gin.H{"ok": true})
}

// InterruptSession sends Ctrl+C to the managed tmux pane (stop long tool / generation).
func (s *SessionServer) InterruptSession(c *gin.Context) {
	id := c.Param("id")
	s.mu.RLock()
	ts, ok := s.tmuxSessions[id]
	s.mu.RUnlock()
	if !ok {
		c.JSON(404, gin.H{"error": "managed session not found"})
		return
	}
	if exec.Command("tmux", "has-session", "-t", ts.Name).Run() != nil {
		c.JSON(409, gin.H{"error": "tmux session not running"})
		return
	}
	exec.Command("tmux", "send-keys", "-t", ts.Name, "C-c").Run()
	c.JSON(200, gin.H{"ok": true})
}

// ContinueSession sends Enter to the managed tmux pane (ack prompt / continue like “play”).
func (s *SessionServer) ContinueSession(c *gin.Context) {
	id := c.Param("id")
	s.mu.RLock()
	ts, ok := s.tmuxSessions[id]
	s.mu.RUnlock()
	if !ok {
		c.JSON(404, gin.H{"error": "managed session not found"})
		return
	}
	if exec.Command("tmux", "has-session", "-t", ts.Name).Run() != nil {
		c.JSON(409, gin.H{"error": "tmux session not running"})
		return
	}
	exec.Command("tmux", "send-keys", "-t", ts.Name, "Enter").Run()
	c.JSON(200, gin.H{"ok": true})
}

// StreamSession streams session updates via SSE (normalized envelope: v=1, kind=init|message).
func (s *SessionServer) StreamSession(c *gin.Context) {
	id := c.Param("id")

	jsonlPath, canonicalID, agentName, tmuxAlive := s.resolveJSONLPath(id)
	if jsonlPath == "" {
		c.JSON(404, gin.H{
			"error": "session not found",
			"diagnostics": gin.H{
				"sessionId":   id,
				"canonicalId": canonicalID,
				"agent":       agentName,
			},
		})
		return
	}

	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache")
	c.Header("Connection", "keep-alive")

	flusher, ok := c.Writer.(http.Flusher)
	if !ok {
		c.JSON(500, gin.H{"error": "streaming not supported"})
		return
	}

	messages, title := s.parseJSONL(jsonlPath)
	initData, _ := json.Marshal(gin.H{
		"v":           1,
		"kind":        "init",
		"title":       title,
		"total":       len(messages),
		"sessionId":   id,
		"agent":       agentName,
		"tmuxAlive":   tmuxAlive,
		"historyPath": jsonlPath,
	})
	fmt.Fprintf(c.Writer, "data: %s\n\n", initData)
	flusher.Flush()

	ctx := c.Request.Context()
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	isKimi := isKimiContextPath(jsonlPath)
	kimiSeenCount := len(messages)
	lastSize := fileSize(jsonlPath)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			newSize := fileSize(jsonlPath)
			if newSize > lastSize {
				var newMessages []Message
				if isKimi {
					newMessages = kimiCanonicalAfter(jsonlPath, kimiSeenCount)
					kimiSeenCount += len(newMessages)
				} else {
					newMessages = s.readNewLines(jsonlPath, lastSize)
				}
				for _, msg := range newMessages {
					env, _ := json.Marshal(gin.H{"v": 1, "kind": "message", "message": msg})
					fmt.Fprintf(c.Writer, "data: %s\n\n", env)
				}
				flusher.Flush()
				lastSize = newSize
			}

			fmt.Fprintf(c.Writer, ": heartbeat\n\n")
			flusher.Flush()
		}
	}
}

// SessionEventsWS streams the same normalized events as SSE over WebSocket (JSON objects).
func (s *SessionServer) SessionEventsWS(c *gin.Context) {
	id := c.Param("id")
	ws, err := terminalUpgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}
	defer ws.Close()

	jsonlPath, _, agentName, tmuxAlive := s.resolveJSONLPath(id)
	if jsonlPath == "" {
		_ = ws.WriteJSON(gin.H{"v": 1, "kind": "error", "message": "session not found"})
		return
	}

	messages, title := s.parseJSONL(jsonlPath)
	if err := ws.WriteJSON(gin.H{
		"v":           1,
		"kind":        "init",
		"title":       title,
		"total":       len(messages),
		"sessionId":   id,
		"agent":       agentName,
		"tmuxAlive":   tmuxAlive,
		"historyPath": jsonlPath,
	}); err != nil {
		return
	}

	// For kimi: track canonical message count (deduplication-aware).
	// For others: track file byte offset.
	isKimi := isKimiContextPath(jsonlPath)
	kimiSeenCount := len(messages)
	lastSize := fileSize(jsonlPath)
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	clientDone := make(chan struct{})
	go func() {
		defer close(clientDone)
		for {
			if _, _, err := ws.ReadMessage(); err != nil {
				return
			}
		}
	}()

	for {
		select {
		case <-clientDone:
			return
		case <-ticker.C:
			newSize := fileSize(jsonlPath)
			if newSize > lastSize {
				if isKimi {
					// Re-parse with full replay-dedup; emit only genuinely new messages.
					newMsgs := kimiCanonicalAfter(jsonlPath, kimiSeenCount)
					for _, msg := range newMsgs {
						if err := ws.WriteJSON(gin.H{"v": 1, "kind": "message", "message": msg}); err != nil {
							return
						}
					}
					kimiSeenCount += len(newMsgs)
				} else {
					for _, msg := range s.readNewLines(jsonlPath, lastSize) {
						if err := ws.WriteJSON(gin.H{"v": 1, "kind": "message", "message": msg}); err != nil {
							return
						}
					}
				}
				lastSize = newSize
			}
		}
	}
}

// --- helpers ---

func (s *SessionServer) discoverSessions() []SessionInfo {
	var sessions []SessionInfo

	// Read session metadata files
	sessDir := filepath.Join(s.claudeHome, "sessions")
	entries, err := os.ReadDir(sessDir)
	if err != nil {
		return sessions
	}

	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}

		data, err := os.ReadFile(filepath.Join(sessDir, e.Name()))
		if err != nil {
			continue
		}

		var meta SessionMeta
		if err := json.Unmarshal(data, &meta); err != nil {
			continue
		}

		info := SessionInfo{SessionMeta: meta}

		// Check if process is still running
		if meta.PID > 0 {
			info.IsActive = isProcessRunning(meta.PID)
		}

		// Try to find title from JSONL
		if jsonlPath := s.findSessionJSONL(meta.SessionID); jsonlPath != "" {
			_, title := s.parseJSONLHeader(jsonlPath)
			info.Title = title
		}

		sessions = append(sessions, info)
	}

	return sessions
}

func (s *SessionServer) findSessionJSONL(sessionID string) string {
	if strings.HasPrefix(sessionID, "kimi-") {
		home, _ := os.UserHomeDir()
		if p := findKimiContextJSONL(home, sessionID); p != "" {
			return p
		}
	}

	// Search in projects directories
	projectsDir := filepath.Join(s.claudeHome, "projects")
	var found string

	filepath.Walk(projectsDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if strings.Contains(info.Name(), sessionID) && strings.HasSuffix(info.Name(), ".jsonl") {
			found = path
			return filepath.SkipAll
		}
		return nil
	})

	return found
}

func (s *SessionServer) findSessionCwd(sessionID string) string {
	sessDir := filepath.Join(s.claudeHome, "sessions")
	entries, err := os.ReadDir(sessDir)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(sessDir, e.Name()))
		if err != nil {
			continue
		}
		var meta SessionMeta
		if err := json.Unmarshal(data, &meta); err != nil {
			continue
		}
		if meta.SessionID == sessionID {
			return meta.Cwd
		}
	}
	if strings.HasPrefix(sessionID, "kimi-") {
		home, _ := os.UserHomeDir()
		if p := findKimiContextJSONL(home, sessionID); p != "" {
			return kimiCwdFromContextPath(home, p)
		}
	}
	return ""
}

func (s *SessionServer) parseJSONL(path string) ([]Message, string) {
	if isKimiContextPath(path) {
		return parseKimiContextJSONL(path)
	}

	f, err := os.Open(path)
	if err != nil {
		return nil, ""
	}
	defer f.Close()

	var messages []Message
	var title string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024) // 10MB max line

	for scanner.Scan() {
		line := scanner.Bytes()
		var raw map[string]interface{}
		if err := json.Unmarshal(line, &raw); err != nil {
			continue
		}

		typ, _ := raw["type"].(string)

		switch typ {
		case "ai-title":
			if t, ok := raw["title"].(string); ok {
				title = t
			}
		case "user", "assistant":
			msg := Message{Type: typ}
			if msgObj, ok := raw["message"].(map[string]interface{}); ok {
				msg.Role, _ = msgObj["role"].(string)
				msg.Content = msgObj["content"]
				msg.Model, _ = msgObj["model"].(string)
			}
			if ts, ok := raw["timestamp"].(string); ok {
				msg.Timestamp = ts
			}
			msg.SessionID, _ = raw["sessionId"].(string)
			messages = append(messages, msg)
		default:
			// Cursor agent transcripts and Planulix local transcripts use a simpler
			// `{role,message}` shape instead of Claude Code's `{type,message}` envelope.
			role, _ := raw["role"].(string)
			if role != "user" && role != "assistant" {
				continue
			}
			msg := Message{Type: role, Role: role}
			if msgObj, ok := raw["message"].(map[string]interface{}); ok {
				if r, ok := msgObj["role"].(string); ok && r != "" {
					msg.Role = r
				}
				if content, ok := msgObj["content"]; ok {
					msg.Content = content
				}
				msg.Model, _ = msgObj["model"].(string)
			} else if content, ok := raw["content"]; ok {
				msg.Content = content
			}
			if ts, ok := raw["timestamp"].(string); ok {
				msg.Timestamp = ts
			}
			msg.SessionID, _ = raw["sessionId"].(string)
			if title == "" && role == "user" {
				title = titleFromContent(msg.Content)
			}
			messages = append(messages, msg)
		}
	}

	return messages, title
}

func (s *SessionServer) parseJSONLHeader(path string) (int, string) {
	if isKimiContextPath(path) {
		return parseKimiContextHeader(path)
	}

	f, err := os.Open(path)
	if err != nil {
		return 0, ""
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
		if typ == "ai-title" {
			if t, ok := raw["title"].(string); ok {
				title = t
			}
		}
		if typ == "user" || typ == "assistant" {
			count++
		}
		// Only scan first 50 lines for header info
		if count > 5 && title != "" {
			break
		}
	}

	return count, title
}

func (s *SessionServer) readNewLines(path string, fromOffset int64) []Message {
	if isKimiContextPath(path) {
		// For kimi: byte offset is not meaningful — caller must use the canonical-count path.
		// This fallback is kept for SSE (StreamSession) and reads full file with dedup.
		// The offset is approximated: read raw entries starting from byte, then re-dedup.
		// In practice StreamSession is not used by current clients; WS (SessionEventsWS)
		// handles kimi via kimiSeenCount. Return empty here to avoid sending junk.
		return nil
	}

	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	if _, err := f.Seek(fromOffset, io.SeekStart); err != nil {
		return nil
	}

	var messages []Message
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024)

	for scanner.Scan() {
		var raw map[string]interface{}
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			continue
		}
		typ, _ := raw["type"].(string)
		if typ == "user" || typ == "assistant" {
			msg := Message{Type: typ}
			if msgObj, ok := raw["message"].(map[string]interface{}); ok {
				msg.Role, _ = msgObj["role"].(string)
				msg.Content = msgObj["content"]
				msg.Model, _ = msgObj["model"].(string)
			}
			if ts, ok := raw["timestamp"].(string); ok {
				msg.Timestamp = ts
			}
			messages = append(messages, msg)
		}
	}

	return messages
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

func isProcessRunning(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	// On Unix, FindProcess always succeeds; signal 0 checks existence
	err = p.Signal(os.Signal(nil))
	if err != nil {
		// Try alternative
		_, err = os.Stat(fmt.Sprintf("/proc/%d", pid))
		return err == nil
	}
	return true
}

// ReadFile returns the contents of a file on the server
func (s *SessionServer) ReadFile(c *gin.Context) {
	path := c.Query("path")
	if path == "" {
		c.JSON(400, gin.H{"error": "path is required"})
		return
	}

	// Security: only allow reading under home directory
	home, _ := os.UserHomeDir()
	if !strings.HasPrefix(path, home) && !strings.HasPrefix(path, "/tmp") {
		c.JSON(403, gin.H{"error": "access denied"})
		return
	}

	info, err := os.Stat(path)
	if err != nil {
		c.JSON(404, gin.H{"error": "file not found"})
		return
	}

	if info.IsDir() {
		entries, _ := os.ReadDir(path)
		var files []map[string]interface{}
		for _, e := range entries {
			fi, _ := e.Info()
			files = append(files, map[string]interface{}{
				"name":  e.Name(),
				"isDir": e.IsDir(),
				"size":  fi.Size(),
			})
		}
		c.JSON(200, gin.H{"type": "directory", "path": path, "files": files})
		return
	}

	// Limit file size to 1MB
	if info.Size() > 1024*1024 {
		c.JSON(200, gin.H{"type": "file", "path": path, "size": info.Size(), "content": "[File too large to display]"})
		return
	}

	data, err := os.ReadFile(path)
	if err != nil {
		c.JSON(500, gin.H{"error": "failed to read file"})
		return
	}

	c.JSON(200, gin.H{"type": "file", "path": path, "size": info.Size(), "content": string(data)})
}

func init() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
}
