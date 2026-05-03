package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"

	"github.com/gin-gonic/gin"
)

type SearchResult struct {
	SessionID string `json:"sessionId"`
	Title     string `json:"title"`
	Snippet   string `json:"snippet"`
	Score     int    `json:"score"`
	Timestamp string `json:"timestamp"`
	IsActive  bool   `json:"isActive"`
}

// Search searches across all sessions using trigram fuzzy matching + substring
func (s *SessionServer) Search(c *gin.Context) {
	query := strings.TrimSpace(c.Query("q"))
	if query == "" {
		c.JSON(400, gin.H{"error": "query is required"})
		return
	}

	queryLower := strings.ToLower(query)
	queryTrigrams := trigrams(queryLower)
	var results []SearchResult

	projectsDir := filepath.Join(s.claudeHome, "projects")
	filepath.Walk(projectsDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(info.Name(), ".jsonl") {
			return nil
		}

		sessionID := strings.TrimSuffix(info.Name(), ".jsonl")
		result := s.searchInSession(path, sessionID, queryLower, queryTrigrams)
		if result != nil {
			// Check if active
			s.mu.RLock()
			for _, ts := range s.tmuxSessions {
				if ts.ClaudeSession == sessionID || ts.ID == sessionID {
					result.IsActive = ts.Status == "running"
					break
				}
			}
			s.mu.RUnlock()

			results = append(results, *result)
		}
		return nil
	})

	// Sort by score descending
	sort.Slice(results, func(i, j int) bool {
		return results[i].Score > results[j].Score
	})

	// Limit to 50
	if len(results) > 50 {
		results = results[:50]
	}

	c.JSON(200, gin.H{"results": results, "total": len(results), "query": query})
}

func (s *SessionServer) searchInSession(path, sessionID, queryLower string, queryTrigrams map[string]bool) *SearchResult {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var title string
	var bestSnippet string
	var bestScore int
	var firstTimestamp string

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
			continue
		}

		if typ != "user" && typ != "assistant" {
			continue
		}

		if ts, ok := raw["timestamp"].(string); ok && firstTimestamp == "" {
			firstTimestamp = ts
		}

		// Extract text content from message
		msgObj, ok := raw["message"].(map[string]interface{})
		if !ok {
			continue
		}

		text := extractMessageText(msgObj)
		if text == "" {
			continue
		}

		textLower := strings.ToLower(text)

		// Score: exact substring match gets highest score
		score := 0
		if strings.Contains(textLower, queryLower) {
			score = 100
		} else {
			// Trigram similarity
			textTrigrams := trigrams(textLower)
			score = trigramSimilarity(queryTrigrams, textTrigrams)
		}

		if score > bestScore {
			bestScore = score
			bestSnippet = extractSnippet(text, queryLower, 120)
		}
	}

	// Also check title
	if title != "" {
		titleLower := strings.ToLower(title)
		if strings.Contains(titleLower, queryLower) {
			bestScore += 50 // Boost for title match
			if bestSnippet == "" {
				bestSnippet = title
			}
		}
	}

	if bestScore < 20 {
		return nil
	}

	return &SearchResult{
		SessionID: sessionID,
		Title:     title,
		Snippet:   bestSnippet,
		Score:     bestScore,
		Timestamp: firstTimestamp,
	}
}

func extractMessageText(msgObj map[string]interface{}) string {
	content := msgObj["content"]
	switch c := content.(type) {
	case string:
		return c
	case []interface{}:
		var parts []string
		for _, block := range c {
			if bm, ok := block.(map[string]interface{}); ok {
				if t, ok := bm["text"].(string); ok {
					parts = append(parts, t)
				}
			}
		}
		return strings.Join(parts, " ")
	}
	return ""
}

func extractSnippet(text, query string, maxLen int) string {
	textLower := strings.ToLower(text)
	idx := strings.Index(textLower, strings.ToLower(query))
	if idx < 0 {
		// No exact match — return beginning
		if len(text) > maxLen {
			return text[:maxLen] + "..."
		}
		return text
	}

	start := idx - 40
	if start < 0 {
		start = 0
	}
	end := idx + len(query) + 80
	if end > len(text) {
		end = len(text)
	}

	snippet := text[start:end]
	if start > 0 {
		snippet = "..." + snippet
	}
	if end < len(text) {
		snippet += "..."
	}
	return snippet
}

// trigrams generates character trigrams from a string
func trigrams(s string) map[string]bool {
	s = strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return ' '
	}, s)

	tg := make(map[string]bool)
	runes := []rune(s)
	for i := 0; i+2 < len(runes); i++ {
		tri := string(runes[i : i+3])
		if strings.TrimSpace(tri) != "" {
			tg[tri] = true
		}
	}
	return tg
}

func trigramSimilarity(a, b map[string]bool) int {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	matches := 0
	for tri := range a {
		if b[tri] {
			matches++
		}
	}
	// Jaccard-like score scaled to 0-99
	union := len(a) + len(b) - matches
	if union == 0 {
		return 0
	}
	return matches * 99 / union
}
