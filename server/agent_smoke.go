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
	return runAgentSmokeTestWithEnv(agentID, timeout, nil)
}

func envMapAny(agentEnv map[string]string, keys ...string) bool {
	for _, key := range keys {
		if strings.TrimSpace(agentEnv[key]) != "" {
			return true
		}
	}
	return false
}

func agentAuthConfiguredForSmoke(agentID, bin string, agentEnv map[string]string) bool {
	switch agentID {
	case "claude-code":
		return bin != "" && (envMapAny(agentEnv, "ANTHROPIC_API_KEY") || envAny("ANTHROPIC_API_KEY") || claudeAuthStatusOK(bin))
	case "kimi-cli":
		return envMapAny(agentEnv, "KIMI_API_KEY", "MOONSHOT_API_KEY") || envAny("KIMI_API_KEY", "MOONSHOT_API_KEY")
	case "codex-cli":
		return envMapAny(agentEnv, "OPENAI_API_KEY") || envAny("OPENAI_API_KEY")
	default:
		return agentAuthConfigured(agentID, bin)
	}
}

func runAgentSmokeTestWithEnv(agentID string, timeout time.Duration, agentEnv map[string]string) AgentSmokeResult {
	agentID = normalizeSetupAgentID(agentID)
	agentEnv = mergeAgentEnvPreferred(agentEnv, nil)
	bin := resolveAgentCommand(agentID)
	if bin == "" {
		return AgentSmokeResult{OK: false, CheckedAt: time.Now().UnixMilli(), Log: "CLI binary not found"}
	}
	if !agentAuthConfiguredForSmoke(agentID, bin, agentEnv) {
		return AgentSmokeResult{OK: false, CheckedAt: time.Now().UnixMilli(), Log: "CLI is installed but not authenticated/configured"}
	}

	home, _ := os.UserHomeDir()
	if home == "" {
		home = "."
	}
	prompt := "Reply with exactly: PLANULIX_OK"
	cmdFrag, env, err := buildAgentCommand(agentID, "task", home, prompt, "", agentEnv)
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
	return runAndStoreAgentSmokeTestWithEnv(agentID, timeout, nil)
}

func runAndStoreAgentSmokeTestWithEnv(agentID string, timeout time.Duration, agentEnv map[string]string) AgentSmokeResult {
	agentID = normalizeSetupAgentID(agentID)
	r := runAgentSmokeTestWithEnv(agentID, timeout, agentEnv)
	globalAgentSmoke.set(agentID, r)
	return r
}
