package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
)

type SessionTags struct {
	Starred bool     `json:"starred"`
	Tags    []string `json:"tags"`
	Title   string   `json:"title,omitempty"`
	// Hidden — сессия убрана из списка (DELETE в клиенте); файлы на диске не трогаем.
	Hidden bool `json:"hidden,omitempty"`
}

type TagStore struct {
	mu       sync.RWMutex
	filePath string
	data     map[string]*SessionTags // sessionId -> tags
}

func NewTagStore(claudeHome string) *TagStore {
	ts := &TagStore{
		filePath: filepath.Join(claudeHome, "planulix-tags.json"),
		data:     make(map[string]*SessionTags),
	}
	ts.load()
	return ts
}

func (t *TagStore) load() {
	data, err := os.ReadFile(t.filePath)
	if err != nil {
		return
	}
	json.Unmarshal(data, &t.data)
}

func (t *TagStore) save() {
	data, err := json.MarshalIndent(t.data, "", "  ")
	if err != nil {
		return
	}
	os.WriteFile(t.filePath, data, 0644)
}

func (t *TagStore) Get(sessionID string) *SessionTags {
	t.mu.RLock()
	defer t.mu.RUnlock()
	if st, ok := t.data[sessionID]; ok {
		return st
	}
	return &SessionTags{}
}

func (t *TagStore) GetAll() map[string]*SessionTags {
	t.mu.RLock()
	defer t.mu.RUnlock()
	result := make(map[string]*SessionTags, len(t.data))
	for k, v := range t.data {
		result[k] = v
	}
	return result
}

// SetStar stars/unstars a session
func (s *SessionServer) SetStar(c *gin.Context) {
	id := c.Param("id")
	var req struct {
		Starred bool `json:"starred"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request"})
		return
	}

	s.tags.mu.Lock()
	if _, ok := s.tags.data[id]; !ok {
		s.tags.data[id] = &SessionTags{}
	}
	s.tags.data[id].Starred = req.Starred
	s.tags.save()
	s.tags.mu.Unlock()

	c.JSON(200, gin.H{"ok": true})
}

func (s *SessionServer) markSessionHidden(id string) {
	if id == "" {
		return
	}
	s.tags.mu.Lock()
	defer s.tags.mu.Unlock()
	if _, ok := s.tags.data[id]; !ok {
		s.tags.data[id] = &SessionTags{}
	}
	s.tags.data[id].Hidden = true
	s.tags.save()
}

// SetTags sets tags for a session
func (s *SessionServer) SetTags(c *gin.Context) {
	id := c.Param("id")
	var req struct {
		Tags []string `json:"tags"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request"})
		return
	}

	s.tags.mu.Lock()
	if _, ok := s.tags.data[id]; !ok {
		s.tags.data[id] = &SessionTags{}
	}
	s.tags.data[id].Tags = req.Tags
	s.tags.save()
	s.tags.mu.Unlock()

	c.JSON(200, gin.H{"ok": true})
}

// SetTitle stores a user-visible title override without modifying agent history files.
func (s *SessionServer) SetTitle(c *gin.Context) {
	id := c.Param("id")
	var req struct {
		Title string `json:"title"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request"})
		return
	}
	title := strings.TrimSpace(req.Title)
	if len(title) > 160 {
		title = title[:160]
	}

	s.tags.mu.Lock()
	if _, ok := s.tags.data[id]; !ok {
		s.tags.data[id] = &SessionTags{}
	}
	s.tags.data[id].Title = title
	s.tags.save()
	s.tags.mu.Unlock()

	c.JSON(200, gin.H{"ok": true, "title": title})
}

// GetTags returns all tags data
func (s *SessionServer) GetAllTags(c *gin.Context) {
	c.JSON(200, gin.H{"tags": s.tags.GetAll()})
}
