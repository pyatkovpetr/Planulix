package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// StoredAgentSession is persisted metadata for agent sessions (survives server restarts).
type StoredAgentSession struct {
	ID              string `json:"id"`
	Agent           string `json:"agent"`
	Cwd             string `json:"cwd"`
	Name            string `json:"name"`
	TmuxName        string `json:"tmuxName"`
	ExternalID      string `json:"externalId,omitempty"`
	HistoryPath     string `json:"historyPath,omitempty"`
	ClaudeSessionID string `json:"claudeSessionId,omitempty"`
	Status          string `json:"status"`
	StartedAt       int64  `json:"startedAt"`
	UpdatedAt       int64  `json:"updatedAt"`
}

// AgentSessionStore persists managed sessions to ~/.planulix/agent-sessions.json
type AgentSessionStore struct {
	path string
	mu   sync.RWMutex
	byID map[string]*StoredAgentSession
}

func defaultAgentSessionStorePath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.Join(".", "agent-sessions.json")
	}
	return filepath.Join(home, ".planulix", "agent-sessions.json")
}

func NewAgentSessionStore(statePath string) (*AgentSessionStore, error) {
	if statePath == "" {
		statePath = defaultAgentSessionStorePath()
	}
	_ = os.MkdirAll(filepath.Dir(statePath), 0o755)
	st := &AgentSessionStore{
		path: statePath,
		byID: make(map[string]*StoredAgentSession),
	}
	if _, err := os.Stat(st.path); err != nil {
		return st, nil
	}
	if err := st.reloadLocked(false); err != nil {
		// Corrupt file — start fresh so the server keeps running.
		log.Printf("agent session store: reset after load error: %v", err)
		st.byID = make(map[string]*StoredAgentSession)
	}
	return st, nil
}

func (st *AgentSessionStore) reloadLocked(alreadyLocked bool) error {
	if !alreadyLocked {
		st.mu.Lock()
		defer st.mu.Unlock()
	}
	data, err := os.ReadFile(st.path)
	if err != nil {
		return err
	}
	var list []StoredAgentSession
	if err := json.Unmarshal(data, &list); err != nil {
		return err
	}
	st.byID = make(map[string]*StoredAgentSession, len(list))
	for i := range list {
		rec := list[i]
		cp := rec
		st.byID[cp.ID] = &cp
	}
	return nil
}

func (st *AgentSessionStore) saveLocked() error {
	list := make([]StoredAgentSession, 0, len(st.byID))
	for _, v := range st.byID {
		if v != nil {
			list = append(list, *v)
		}
	}
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	tmp := st.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, st.path)
}

// Get returns a copy-safe pointer to stored session or nil.
func (st *AgentSessionStore) Get(id string) *StoredAgentSession {
	st.mu.RLock()
	defer st.mu.RUnlock()
	v, ok := st.byID[id]
	if !ok || v == nil {
		return nil
	}
	cp := *v
	return &cp
}

// Upsert writes or replaces a record and flushes to disk.
func (st *AgentSessionStore) Upsert(rec *StoredAgentSession) error {
	if rec == nil || rec.ID == "" {
		return nil
	}
	rec.UpdatedAt = time.Now().UnixMilli()
	st.mu.Lock()
	rec2 := *rec
	st.byID[rec.ID] = &rec2
	err := st.saveLocked()
	st.mu.Unlock()
	return err
}

// Delete removes a session id from the store.
func (st *AgentSessionStore) Delete(id string) error {
	if id == "" {
		return nil
	}
	st.mu.Lock()
	delete(st.byID, id)
	err := st.saveLocked()
	st.mu.Unlock()
	return err
}

// List returns snapshots of all stored sessions (for merging into session lists).
func (st *AgentSessionStore) List() []StoredAgentSession {
	st.mu.RLock()
	defer st.mu.RUnlock()
	out := make([]StoredAgentSession, 0, len(st.byID))
	for _, v := range st.byID {
		if v != nil {
			out = append(out, *v)
		}
	}
	return out
}

// ToStored builds a snapshot from an in-memory tmux session.
func (ts *TmuxSession) ToStored() *StoredAgentSession {
	if ts == nil {
		return nil
	}
	ext := ""
	if ts.KimiSession != "" {
		ext = ts.KimiSession
	}
	hist := ts.HistoryPath
	cl := ts.ClaudeSession
	return &StoredAgentSession{
		ID:              ts.ID,
		Agent:           ts.Agent,
		Cwd:             ts.Cwd,
		Name:            ts.Name,
		TmuxName:        ts.Name,
		ExternalID:      ext,
		HistoryPath:     hist,
		ClaudeSessionID: cl,
		Status:          ts.Status,
		StartedAt:       ts.StartedAt,
		UpdatedAt:       time.Now().UnixMilli(),
	}
}
