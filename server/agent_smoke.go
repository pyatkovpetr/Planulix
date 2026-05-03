package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type AgentSmokeResult struct {
	OK        bool   `json:"ok"`
	CheckedAt int64  `json:"checkedAt,omitempty"`
	Log       string `json:"log,omitempty"`
}

type agentSmokeStore struct {
	path string
	mu   sync.RWMutex
	byID map[string]AgentSmokeResult
}

func defaultAgentSmokeStorePath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.Join(".", "agent-smoke.json")
	}
	return filepath.Join(home, ".planulix", "agent-smoke.json")
}

func newAgentSmokeStore() *agentSmokeStore {
	st := &agentSmokeStore{
		path: defaultAgentSmokeStorePath(),
		byID: map[string]AgentSmokeResult{},
	}
	_ = os.MkdirAll(filepath.Dir(st.path), 0o755)
	_ = st.load()
	return st
}

func (st *agentSmokeStore) load() error {
	st.mu.Lock()
	defer st.mu.Unlock()
	data, err := os.ReadFile(st.path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, &st.byID)
}

func (st *agentSmokeStore) get(id string) AgentSmokeResult {
	st.mu.RLock()
	defer st.mu.RUnlock()
	return st.byID[id]
}

func (st *agentSmokeStore) set(id string, r AgentSmokeResult) {
	st.mu.Lock()
	st.byID[id] = r
	data, err := json.MarshalIndent(st.byID, "", "  ")
	if err == nil {
		_ = os.WriteFile(st.path, data, 0o600)
	}
	st.mu.Unlock()
}

var globalAgentSmoke = newAgentSmokeStore()

func runAgentSmokeTest(agentID string, timeout time.Duration) AgentSmokeResult {
	agentID = normalizeSetupAgentID(agentID)
	if resolveAgentCommand(agentID) == "" {
		return AgentSmokeResult{OK: false, CheckedAt: time.Now().UnixMilli(), Log: "CLI binary not found"}
	}
	if !agentAuthConfigured(agentID, resolveAgentCommand(agentID)) {
		return AgentSmokeResult{OK: false, CheckedAt: time.Now().UnixMilli(), Log: "CLI is installed but not authenticated/configured"}
	}

	home, _ := os.UserHomeDir()
	if home == "" {
		home = "."
	}
	prompt := "Reply with exactly: PLANULIX_OK"
	cmdFrag, env, err := buildAgentCommand(agentID, "task", home, prompt, "", nil)
	if err != nil {
		return AgentSmokeResult{OK: false, CheckedAt: time.Now().UnixMilli(), Log: err.Error()}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-lc", fmt.Sprintf("%s && %s", env, cmdFrag))
	out, err := cmd.CombinedOutput()
	log := strings.TrimSpace(stripANSI(string(out)))
	if len(log) > 4000 {
		log = log[len(log)-4000:]
	}
	ok := err == nil && strings.Contains(strings.ToUpper(log), "PLANULIX_OK")
	if err != nil {
		if log == "" {
			log = err.Error()
		} else {
			log = err.Error() + ": " + log
		}
	}
	if ctx.Err() == context.DeadlineExceeded {
		log = "smoke test timed out: " + log
	}
	return AgentSmokeResult{OK: ok, CheckedAt: time.Now().UnixMilli(), Log: log}
}

func agentSmokeCached(agentID string) AgentSmokeResult {
	return globalAgentSmoke.get(normalizeSetupAgentID(agentID))
}

func runAndStoreAgentSmokeTest(agentID string, timeout time.Duration) AgentSmokeResult {
	agentID = normalizeSetupAgentID(agentID)
	r := runAgentSmokeTest(agentID, timeout)
	globalAgentSmoke.set(agentID, r)
	return r
}
