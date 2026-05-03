package main

import (
	"bufio"
	"crypto/md5"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// loadKimiSessionDirToCwd maps Kimi session storage folder names (md5 or kaos_md5) to project cwd.
func loadKimiSessionDirToCwd(home string) map[string]string {
	out := make(map[string]string)
	path := filepath.Join(home, ".kimi", "kimi.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	var raw struct {
		WorkDirs []struct {
			Path string `json:"path"`
			Kaos string `json:"kaos"`
		} `json:"work_dirs"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return out
	}
	for _, wd := range raw.WorkDirs {
		kaos := wd.Kaos
		if kaos == "" {
			kaos = "local"
		}
		sum := fmt.Sprintf("%x", md5.Sum([]byte(wd.Path)))
		key := sum
		if kaos != "local" {
			key = kaos + "_" + sum
		}
		out[key] = wd.Path
	}
	return out
}

func findKimiContextJSONL(home, sessionID string) string {
	id := sessionID
	if strings.HasPrefix(id, "kimi-") {
		id = strings.TrimPrefix(id, "kimi-")
	}
	root := filepath.Join(home, ".kimi", "sessions")
	entries, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p := filepath.Join(root, e.Name(), id, "context.jsonl")
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func isKimiContextPath(path string) bool {
	return strings.Contains(path, ".kimi") && strings.Contains(path, "sessions") && strings.HasSuffix(path, "context.jsonl")
}

func kimiCwdFromContextPath(home, ctxPath string) string {
	// .../sessions/<dirBasename>/<uuid>/context.jsonl
	dirBasename := filepath.Base(filepath.Dir(filepath.Dir(ctxPath)))
	m := loadKimiSessionDirToCwd(home)
	return m[dirBasename]
}

// kimiNormalizeLiteralEscapes turns JSON/string forms that kimi-cli sometimes stores
// (literal backslash-n instead of real newlines) into normal newlines. Without this,
// the same prompt differs from the optimistic client copy and appears twice in the UI.
func kimiNormalizeLiteralEscapes(s string) string {
	s = strings.ReplaceAll(s, "\\r\\n", "\n")
	s = strings.ReplaceAll(s, "\\n", "\n")
	s = strings.ReplaceAll(s, "\\t", "\t")
	s = strings.ReplaceAll(s, "\\'", "'")
	s = strings.ReplaceAll(s, `\"`, `"`)
	return s
}

// kimiCleanPrintOutput extracts the human-readable assistant text from Kimi
// Code CLI's --print event dump. Recent CLI builds print Python-like events
// such as TextPart(text='...') instead of plain text.
func kimiCleanPrintOutput(stdout string) string {
	stdout = strings.TrimSpace(stdout)
	if stdout == "" {
		return ""
	}

	var parts []string
	for i := 0; i < len(stdout); i++ {
		idx := strings.Index(stdout[i:], "text=")
		if idx < 0 {
			break
		}
		i += idx + len("text=")
		if i >= len(stdout) {
			break
		}
		quote := stdout[i]
		if quote != '\'' && quote != '"' {
			continue
		}
		i++
		var b strings.Builder
		escaped := false
		for ; i < len(stdout); i++ {
			ch := stdout[i]
			if escaped {
				b.WriteByte('\\')
				b.WriteByte(ch)
				escaped = false
				continue
			}
			if ch == '\\' {
				escaped = true
				continue
			}
			if ch == quote {
				break
			}
			b.WriteByte(ch)
		}
		text := strings.TrimSpace(kimiNormalizeLiteralEscapes(b.String()))
		if text != "" {
			parts = append(parts, text)
		}
	}
	if len(parts) > 0 {
		return strings.Join(parts, "\n")
	}
	if strings.Contains(stdout, "TurnBegin(") || strings.Contains(stdout, "TextPart(") || strings.Contains(stdout, "TurnEnd(") {
		return ""
	}
	return stdout
}

func kimiExtractContent(c interface{}) string {
	switch v := c.(type) {
	case string:
		return v
	case []interface{}:
		var b strings.Builder
		for _, item := range v {
			m, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			if typ, _ := m["type"].(string); typ == "text" {
				if txt, ok := m["text"].(string); ok {
					b.WriteString(txt)
				}
			}
		}
		return b.String()
	default:
		return ""
	}
}

// kimiRawEntry holds a single parsed role+text pair from context.jsonl before dedup.
type kimiRawEntry struct {
	role string
	text string
}

// readKimiRawEntries scans context.jsonl and returns all non-empty user/assistant lines.
func readKimiRawEntries(path string) ([]kimiRawEntry, string) {
	f, err := os.Open(path)
	if err != nil {
		return nil, ""
	}
	defer f.Close()

	var entries []kimiRawEntry
	var title string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024)

	for scanner.Scan() {
		var raw map[string]interface{}
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			continue
		}
		role, _ := raw["role"].(string)
		if role == "" || strings.HasPrefix(role, "_") {
			continue
		}
		if role != "user" && role != "assistant" {
			continue
		}
		text := strings.TrimSpace(kimiNormalizeLiteralEscapes(kimiExtractContent(raw["content"])))
		if text == "" {
			continue
		}
		if title == "" && role == "user" {
			title = text
			if len(title) > 80 {
				title = title[:80] + "…"
			}
		}
		entries = append(entries, kimiRawEntry{role: role, text: text})
	}
	return entries, title
}

// deduplicateKimiReplay removes context-replay lines that kimi-cli writes when running
// `--session --print -p`: it prepends the entire conversation history before the new
// exchange. We detect a replay by checking if a run of messages starting at position i
// matches the beginning of the canonical list already built (≥2 lines = one full turn).
func deduplicateKimiReplay(entries []kimiRawEntry) []Message {
	type canon struct{ role, text string }
	known := make([]canon, 0, len(entries))
	result := make([]Message, 0, len(entries))

	i := 0
	for i < len(entries) {
		// Only attempt replay detection once we have at least one full turn (user+assistant).
		if len(known) >= 2 {
			k := 0
			for k < len(known) && i+k < len(entries) {
				if known[k].role == entries[i+k].role && known[k].text == entries[i+k].text {
					k++
				} else {
					break
				}
			}
			if k >= 2 {
				// This is a replay of a known prefix — skip it.
				i += k
				continue
			}
		}
		known = append(known, canon{role: entries[i].role, text: entries[i].text})
		result = append(result, Message{Type: entries[i].role, Content: entries[i].text})
		i++
	}
	return result
}

func parseKimiContextJSONL(path string) ([]Message, string) {
	entries, title := readKimiRawEntries(path)
	return deduplicateKimiReplay(entries), title
}

// kimiCanonicalAfter returns canonical messages from context.jsonl that come after
// the first fromCount messages. Used by SessionEventsWS to stream only new messages.
func kimiCanonicalAfter(path string, fromCount int) []Message {
	all, _ := parseKimiContextJSONL(path)
	if fromCount >= len(all) {
		return nil
	}
	return all[fromCount:]
}

func parseKimiContextHeader(path string) (int, string) {
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
		role, _ := raw["role"].(string)
		if role == "" || strings.HasPrefix(role, "_") {
			continue
		}
		if role == "user" || role == "assistant" {
			count++
			if title == "" && role == "user" {
				title = strings.TrimSpace(kimiNormalizeLiteralEscapes(kimiExtractContent(raw["content"])))
				if len(title) > 80 {
					title = title[:80] + "…"
				}
			}
		}
		if count > 5 && title != "" {
			break
		}
	}

	return count, title
}

// kimiAppendNewMessages returns genuinely new canonical messages after fromCount.
// The fromOffset parameter is kept for interface compatibility with readNewLines but
// is unused — we re-read the whole file and rely on deduplicateKimiReplay.
func kimiAppendNewMessages(path string, fromCount int) []Message {
	return kimiCanonicalAfter(path, fromCount)
}
