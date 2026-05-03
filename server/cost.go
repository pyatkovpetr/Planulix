package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// Model pricing per 1M tokens (USD)
type ModelPricing struct {
	Input       float64 `json:"input"`
	Output      float64 `json:"output"`
	CacheRead   float64 `json:"cacheRead"`
	CacheCreate float64 `json:"cacheCreate"`
}

var modelPricingMap = map[string]ModelPricing{
	// Claude 4.x / Opus
	"claude-opus-4-20250514":   {Input: 15.0, Output: 75.0, CacheRead: 1.50, CacheCreate: 18.75},
	"claude-opus-4-0-20250514": {Input: 15.0, Output: 75.0, CacheRead: 1.50, CacheCreate: 18.75},
	// Claude 4.5 Sonnet
	"claude-sonnet-4-5-20250514": {Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75},
	// Claude 4 Sonnet
	"claude-sonnet-4-20250514": {Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75},
	// Claude 3.7 Sonnet
	"claude-3-7-sonnet-20250219": {Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75},
	// Claude 3.5 Sonnet
	"claude-3-5-sonnet-20241022": {Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75},
	"claude-3-5-sonnet-20240620": {Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75},
	// Claude 4.5 Haiku / 3.5 Haiku
	"claude-haiku-4-5-20251001": {Input: 1.0, Output: 5.0, CacheRead: 0.10, CacheCreate: 1.25},
	"claude-3-5-haiku-20241022": {Input: 1.0, Output: 5.0, CacheRead: 0.10, CacheCreate: 1.25},
	// Codex / GPT-5
	"codex": {Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75},
	"gpt-5": {Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75},
	// Moonshot Kimi (coding tier — approximate list rates; verify on console)
	"kimi-for-coding": {Input: 0.60, Output: 2.50, CacheRead: 0.15, CacheCreate: 0.60},
	"kimi-k2":         {Input: 0.60, Output: 2.50, CacheRead: 0.15, CacheCreate: 0.60},
	"kimi-k2-0905-preview":              {Input: 0.60, Output: 2.50, CacheRead: 0.15, CacheCreate: 0.60},
	"kimi-k2-thinking-turbo-preview":    {Input: 0.60, Output: 2.50, CacheRead: 0.15, CacheCreate: 0.60},
	"kimi-k2.5":                         {Input: 0.60, Output: 2.50, CacheRead: 0.15, CacheCreate: 0.60},
	"kimi-k2.6":                         {Input: 0.60, Output: 2.50, CacheRead: 0.15, CacheCreate: 0.60},
	"moonshot-v1-auto":                  {Input: 0.30, Output: 0.30, CacheRead: 0.08, CacheCreate: 0.30},
	"moonshot-v1-8k":                    {Input: 0.15, Output: 0.15, CacheRead: 0.04, CacheCreate: 0.15},
	"moonshot-v1-32k":                   {Input: 0.24, Output: 0.24, CacheRead: 0.06, CacheCreate: 0.24},
	"moonshot-v1-128k":                  {Input: 0.30, Output: 0.30, CacheRead: 0.08, CacheCreate: 0.30},
}

// Default pricing if model not found (Sonnet-level)
var defaultPricing = ModelPricing{Input: 3.0, Output: 15.0, CacheRead: 0.30, CacheCreate: 3.75}

func getModelPricing(model string) ModelPricing {
	if p, ok := modelPricingMap[model]; ok {
		return p
	}
	// Try prefix matching
	for key, p := range modelPricingMap {
		if strings.HasPrefix(model, key) || strings.HasPrefix(key, model) {
			return p
		}
	}
	// Guess by name
	lower := strings.ToLower(model)
	if strings.Contains(lower, "opus") {
		return modelPricingMap["claude-opus-4-20250514"]
	}
	if strings.Contains(lower, "haiku") {
		return modelPricingMap["claude-haiku-4-5-20251001"]
	}
	if strings.Contains(lower, "sonnet") {
		return modelPricingMap["claude-sonnet-4-20250514"]
	}
	if strings.Contains(lower, "kimi") {
		return modelPricingMap["kimi-for-coding"]
	}
	return defaultPricing
}

// PricedModel is one row for GET /api/pricing (UI + transparency).
type PricedModel struct {
	ID          string  `json:"id"`
	Family      string  `json:"family"`
	Input       float64 `json:"input"`
	Output      float64 `json:"output"`
	CacheRead   float64 `json:"cacheRead"`
	CacheCreate float64 `json:"cacheCreate"`
}

func pricingFamilyForModel(id string) string {
	lower := strings.ToLower(id)
	switch {
	case strings.Contains(lower, "kimi"):
		return "Moonshot Kimi"
	case strings.Contains(lower, "claude"):
		return "Anthropic Claude"
	case strings.Contains(lower, "gpt") || strings.Contains(lower, "codex"):
		return "OpenAI"
	default:
		return "Other"
	}
}

type TokenUsage struct {
	InputTokens              int64 `json:"inputTokens"`
	OutputTokens             int64 `json:"outputTokens"`
	CacheReadInputTokens     int64 `json:"cacheReadInputTokens"`
	CacheCreationInputTokens int64 `json:"cacheCreationInputTokens"`
}

type SessionCost struct {
	SessionID   string             `json:"sessionId"`
	Title       string             `json:"title"`
	TotalCost   float64            `json:"totalCost"`
	Usage       TokenUsage         `json:"usage"`
	CostByModel map[string]float64 `json:"costByModel"`
	Date        string             `json:"date"` // YYYY-MM-DD
}

type DailyCost struct {
	Date      string  `json:"date"`
	TotalCost float64 `json:"totalCost"`
	Sessions  int     `json:"sessions"`
}

type CostSummary struct {
	TotalCost     float64            `json:"totalCost"`
	TotalSessions int                `json:"totalSessions"`
	Usage         TokenUsage         `json:"usage"`
	CostByModel   map[string]float64 `json:"costByModel"`
	CostByProject map[string]float64 `json:"costByProject"`
	DailyCosts    []DailyCost        `json:"dailyCosts"`
	TopSessions   []SessionCost      `json:"topSessions"`
}

// parseJSONLCost extracts token usage and cost (Claude JSONL or Kimi context.jsonl).
func (s *SessionServer) parseJSONLCost(path string) (TokenUsage, map[string]float64, string, string) {
	if isKimiContextPath(path) {
		return parseKimiContextJSONLCost(path)
	}
	return parseClaudeJSONLCost(path)
}

func parseClaudeJSONLCost(path string) (TokenUsage, map[string]float64, string, string) {
	f, err := os.Open(path)
	if err != nil {
		return TokenUsage{}, nil, "", ""
	}
	defer f.Close()

	var usage TokenUsage
	costByModel := make(map[string]float64)
	var title string
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

		if typ == "assistant" {
			if ts, ok := raw["timestamp"].(string); ok && firstTimestamp == "" {
				firstTimestamp = ts
			}

			msgObj, ok := raw["message"].(map[string]interface{})
			if !ok {
				continue
			}

			model, _ := msgObj["model"].(string)
			usageObj, ok := msgObj["usage"].(map[string]interface{})
			if !ok {
				continue
			}

			inp := int64(getFloat(usageObj, "input_tokens"))
			out := int64(getFloat(usageObj, "output_tokens"))
			cacheRead := int64(getFloat(usageObj, "cache_read_input_tokens"))
			cacheCreate := int64(getFloat(usageObj, "cache_creation_input_tokens"))

			usage.InputTokens += inp
			usage.OutputTokens += out
			usage.CacheReadInputTokens += cacheRead
			usage.CacheCreationInputTokens += cacheCreate

			pricing := getModelPricing(model)
			cost := float64(inp)*pricing.Input/1e6 +
				float64(out)*pricing.Output/1e6 +
				float64(cacheRead)*pricing.CacheRead/1e6 +
				float64(cacheCreate)*pricing.CacheCreate/1e6

			if model == "" {
				model = "unknown"
			}
			costByModel[model] += cost
		} else if typ == "user" {
			if ts, ok := raw["timestamp"].(string); ok && firstTimestamp == "" {
				firstTimestamp = ts
			}
		}
	}

	return usage, costByModel, title, firstTimestamp
}

// kimiFindUsageMap digs usage/token_usage blocks out of Kimi context.jsonl (often nested; status lines may omit role).
func kimiFindUsageMap(raw map[string]interface{}, depth int) map[string]interface{} {
	if raw == nil || depth < 0 {
		return nil
	}
	for _, key := range []string{"usage", "token_usage", "tokenUsage"} {
		if m, ok := raw[key].(map[string]interface{}); ok && kimiUsageMapHasTokens(m) {
			return m
		}
	}
	for _, v := range raw {
		nested, ok := v.(map[string]interface{})
		if !ok {
			continue
		}
		if u := kimiFindUsageMap(nested, depth-1); u != nil {
			return u
		}
	}
	return nil
}

func kimiUsageMapHasTokens(m map[string]interface{}) bool {
	for _, k := range []string{
		"input_tokens", "output_tokens", "prompt_tokens", "completion_tokens",
		"input_other", "output", "input_cache_read", "input_cache_creation",
		"cache_read_input_tokens", "cached_tokens", "cache_creation_input_tokens",
	} {
		if getFloat(m, k) > 0 {
			return true
		}
	}
	return false
}

// kimiSplitTokensForCost maps Kimi/Moonshot usage shapes into our TokenUsage buckets (list estimates).
func kimiSplitTokensForCost(u map[string]interface{}) (inp, out, cread, ccreate int64, ok bool) {
	io := int64(getFloat(u, "input_other"))
	o := int64(getFloat(u, "output"))
	if o == 0 {
		o = int64(getFloat(u, "output_tokens"))
	}
	icr := int64(getFloat(u, "input_cache_read"))
	if icr == 0 {
		icr = int64(getFloat(u, "cached_tokens"))
	}
	icc := int64(getFloat(u, "input_cache_creation"))
	if io > 0 || o > 0 || icr > 0 || icc > 0 {
		return io, o, icr, icc, true
	}

	inpTok := int64(getFloat(u, "input_tokens"))
	outTok := int64(getFloat(u, "output_tokens"))
	if inpTok == 0 && outTok == 0 {
		inpTok = int64(getFloat(u, "prompt_tokens"))
		outTok = int64(getFloat(u, "completion_tokens"))
	}
	cr := int64(getFloat(u, "cache_read_input_tokens"))
	if cr == 0 {
		cr = int64(getFloat(u, "cached_tokens"))
	}
	cc := int64(getFloat(u, "cache_creation_input_tokens"))
	if inpTok > 0 || outTok > 0 || cr > 0 || cc > 0 {
		return inpTok, outTok, cr, cc, true
	}
	return 0, 0, 0, 0, false
}

func parseKimiContextJSONLCost(path string) (TokenUsage, map[string]float64, string, string) {
	f, err := os.Open(path)
	if err != nil {
		return TokenUsage{}, nil, "", ""
	}
	defer f.Close()

	var usage TokenUsage
	costByModel := make(map[string]float64)
	var title string
	var firstTimestamp string
	lastModel := "kimi-k2.5"
	var prevKimiCumTokens int64

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024)

	for scanner.Scan() {
		var raw map[string]interface{}
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			continue
		}
		role, _ := raw["role"].(string)
		metaType, _ := raw["type"].(string)
		isUsageMeta := role == "_usage" || metaType == "_usage"
		if !isUsageMeta && (role == "usage" || metaType == "usage") {
			if getInt64Flex(raw, "token_count") != 0 || getInt64Flex(raw, "total_tokens") != 0 ||
				getInt64Flex(raw, "totalTokens") != 0 {
				isUsageMeta = true
			}
		}
		if isUsageMeta {
			// Kimi CLI: cumulative token_count on _usage lines (or nested usage.*).
			tc := getInt64Flex(raw, "token_count")
			if tc == 0 {
				tc = getInt64Flex(raw, "total_tokens")
			}
			if tc == 0 {
				tc = getInt64Flex(raw, "totalTokens")
			}
			if tc == 0 {
				if u, ok := raw["usage"].(map[string]interface{}); ok {
					tc = getInt64Flex(u, "token_count")
					if tc == 0 {
						tc = getInt64Flex(u, "total_tokens")
					}
					if tc == 0 {
						tc = getInt64Flex(u, "totalTokens")
					}
				}
			}
			if tc < 0 {
				tc = 0
			}
			delta := tc - prevKimiCumTokens
			if delta < 0 {
				prevKimiCumTokens = 0
				delta = tc
			}
			prevKimiCumTokens = tc
			if delta > 0 {
				// No per-step input/output breakdown; split for list-price estimate (~45/55).
				inp := delta * 45 / 100
				out := delta - inp
				usage.InputTokens += inp
				usage.OutputTokens += out
				pricing := getModelPricing(lastModel)
				cost := float64(inp)*pricing.Input/1e6 +
					float64(out)*pricing.Output/1e6
				costByModel[lastModel] += cost
			}
			continue
		}
		if strings.HasPrefix(role, "_") {
			continue
		}
		if firstTimestamp == "" {
			for _, key := range []string{"timestamp", "created_at", "ts", "time"} {
				if ts, ok := raw[key].(string); ok && len(ts) >= 8 {
					firstTimestamp = ts
					break
				}
			}
		}
		if role == "user" && title == "" {
			text := kimiExtractContent(raw["content"])
			if text != "" {
				title = text
				if len(title) > 80 {
					title = title[:80] + "…"
				}
			}
		}
		if role == "assistant" {
			if m, ok := raw["model"].(string); ok && m != "" {
				lastModel = m
			}
		}

		u := kimiFindUsageMap(raw, 5)
		if u == nil {
			continue
		}
		inp, out, cacheRead, cacheCreate, ok := kimiSplitTokensForCost(u)
		if !ok {
			continue
		}
		model := lastModel
		if m, ok := raw["model"].(string); ok && m != "" {
			model = m
		}

		usage.InputTokens += inp
		usage.OutputTokens += out
		usage.CacheReadInputTokens += cacheRead
		usage.CacheCreationInputTokens += cacheCreate

		pricing := getModelPricing(model)
		cost := float64(inp)*pricing.Input/1e6 +
			float64(out)*pricing.Output/1e6 +
			float64(cacheRead)*pricing.CacheRead/1e6 +
			float64(cacheCreate)*pricing.CacheCreate/1e6
		costByModel[model] += cost
	}

	return usage, costByModel, title, firstTimestamp
}

func (s *SessionServer) appendCostAggregation(
	sessionID, project, title, firstTs string,
	modTime time.Time,
	usage TokenUsage,
	costByModel map[string]float64,
	summary *CostSummary,
	dailyMap map[string]*DailyCost,
	sessionCosts *[]SessionCost,
) {
	var totalCost float64
	for _, c := range costByModel {
		totalCost += c
	}
	if totalCost == 0 && usage.InputTokens == 0 && usage.OutputTokens == 0 &&
		usage.CacheReadInputTokens == 0 && usage.CacheCreationInputTokens == 0 {
		return
	}
	date := "unknown"
	if len(firstTs) >= 10 {
		date = firstTs[:10]
	} else if !modTime.IsZero() {
		date = modTime.UTC().Format("2006-01-02")
	}

	sc := SessionCost{
		SessionID:   sessionID,
		Title:       title,
		TotalCost:   totalCost,
		Usage:       usage,
		CostByModel: costByModel,
		Date:        date,
	}
	*sessionCosts = append(*sessionCosts, sc)

	summary.TotalCost += totalCost
	summary.TotalSessions++
	summary.Usage.InputTokens += usage.InputTokens
	summary.Usage.OutputTokens += usage.OutputTokens
	summary.Usage.CacheReadInputTokens += usage.CacheReadInputTokens
	summary.Usage.CacheCreationInputTokens += usage.CacheCreationInputTokens

	for model, cost := range costByModel {
		summary.CostByModel[model] += cost
	}
	summary.CostByProject[project] += totalCost

	if date != "unknown" {
		if dc, ok := dailyMap[date]; ok {
			dc.TotalCost += totalCost
			dc.Sessions++
		} else {
			dailyMap[date] = &DailyCost{Date: date, TotalCost: totalCost, Sessions: 1}
		}
	}
}

// GetModelPricing returns approximate USD / 1M token rates for models we know (plus Kimi).
func (s *SessionServer) GetModelPricing(c *gin.Context) {
	ids := make([]string, 0, len(modelPricingMap))
	for id := range modelPricingMap {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]PricedModel, 0, len(ids))
	for _, id := range ids {
		p := modelPricingMap[id]
		out = append(out, PricedModel{
			ID: id, Family: pricingFamilyForModel(id),
			Input: p.Input, Output: p.Output, CacheRead: p.CacheRead, CacheCreate: p.CacheCreate,
		})
	}
	c.JSON(200, gin.H{
		"currency":  "USD",
		"unit":      "per 1M tokens",
		"note":      "Approximate list prices for cost estimates; always verify with your provider invoice.",
		"models":    out,
	})
}

func getInt64Flex(m map[string]interface{}, key string) int64 {
	if v, ok := m[key].(float64); ok {
		return int64(v)
	}
	if v, ok := m[key].(json.Number); ok {
		n, _ := v.Int64()
		return n
	}
	return int64(getFloat(m, key))
}

func getFloat(m map[string]interface{}, key string) float64 {
	v, ok := m[key]
	if !ok || v == nil {
		return 0
	}
	switch x := v.(type) {
	case float64:
		return x
	case float32:
		return float64(x)
	case int:
		return float64(x)
	case int32:
		return float64(x)
	case int64:
		return float64(x)
	case uint:
		return float64(x)
	case uint64:
		return float64(x)
	case json.Number:
		f, _ := x.Float64()
		return f
	default:
		return 0
	}
}

// kimiUserHome matches discoverKimiSessions: real OS home, not necessarily filepath.Dir(CLAUDE_HOME).
func (s *SessionServer) kimiUserHome() string {
	h, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(h) == "" {
		return filepath.Dir(s.claudeHome)
	}
	return h
}

// GetCostSummary returns aggregated cost analytics
func (s *SessionServer) GetCostSummary(c *gin.Context) {
	summary := CostSummary{
		CostByModel:   make(map[string]float64),
		CostByProject: make(map[string]float64),
	}

	dailyMap := make(map[string]*DailyCost)
	var sessionCosts []SessionCost

	projectsDir := filepath.Join(s.claudeHome, "projects")
	filepath.Walk(projectsDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(info.Name(), ".jsonl") {
			return nil
		}

		usage, costByModel, title, firstTs := s.parseJSONLCost(path)
		sessionID := strings.TrimSuffix(info.Name(), ".jsonl")
		relPath, _ := filepath.Rel(projectsDir, path)
		parts := strings.Split(relPath, string(filepath.Separator))
		project := "unknown"
		if len(parts) >= 1 {
			project = parts[0]
		}
		s.appendCostAggregation(sessionID, project, title, firstTs, info.ModTime(), usage, costByModel, &summary, dailyMap, &sessionCosts)
		return nil
	})

	// Kimi CLI sessions: ~/.kimi/sessions/*/<uuid>/context.jsonl (same root as discoverKimiSessions).
	home := s.kimiUserHome()
	kimiRoot := filepath.Join(home, ".kimi", "sessions")
	filepath.Walk(kimiRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() || !strings.HasSuffix(path, "context.jsonl") {
			return nil
		}
		usage, costByModel, title, firstTs := s.parseJSONLCost(path)
		uuid := filepath.Base(filepath.Dir(path))
		sessionID := "kimi-" + uuid
		project := kimiCwdFromContextPath(home, path)
		if project == "" {
			project = "kimi"
		}
		s.appendCostAggregation(sessionID, project, title, firstTs, info.ModTime(), usage, costByModel, &summary, dailyMap, &sessionCosts)
		return nil
	})

	// Sort daily costs by date
	for _, dc := range dailyMap {
		summary.DailyCosts = append(summary.DailyCosts, *dc)
	}
	sort.Slice(summary.DailyCosts, func(i, j int) bool {
		return summary.DailyCosts[i].Date < summary.DailyCosts[j].Date
	})

	// Top 10 most expensive sessions
	sort.Slice(sessionCosts, func(i, j int) bool {
		return sessionCosts[i].TotalCost > sessionCosts[j].TotalCost
	})
	if len(sessionCosts) > 10 {
		sessionCosts = sessionCosts[:10]
	}
	summary.TopSessions = sessionCosts

	c.JSON(200, summary)
}

// GetSessionCost returns cost for a specific session
func (s *SessionServer) GetSessionCost(c *gin.Context) {
	id := c.Param("id")

	jsonlPath, _, _, _ := s.resolveJSONLPath(id)
	if jsonlPath == "" {
		c.JSON(404, gin.H{"error": "session not found"})
		return
	}

	usage, costByModel, title, firstTs := s.parseJSONLCost(jsonlPath)
	var totalCost float64
	for _, cost := range costByModel {
		totalCost += cost
	}

	date := firstTs
	if len(date) >= 10 {
		date = date[:10]
	} else if st, err := os.Stat(jsonlPath); err == nil {
		date = st.ModTime().UTC().Format("2006-01-02")
	} else {
		date = ""
	}

	c.JSON(200, SessionCost{
		SessionID:   id,
		Title:       title,
		TotalCost:   totalCost,
		Usage:       usage,
		CostByModel: costByModel,
		Date:        date,
	})
}

// GetActivity returns daily session counts for heatmap (last 365 days)
func (s *SessionServer) GetActivity(c *gin.Context) {
	dailyCount := make(map[string]int)
	var totalSessions int

	projectsDir := filepath.Join(s.claudeHome, "projects")
	filepath.Walk(projectsDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(info.Name(), ".jsonl") {
			return nil
		}

		// Get first timestamp from file
		f, err := os.Open(path)
		if err != nil {
			return nil
		}
		defer f.Close()

		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 1024*1024), 10*1024*1024)

		for scanner.Scan() {
			var raw map[string]interface{}
			if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
				continue
			}
			if ts, ok := raw["timestamp"].(string); ok && len(ts) >= 10 {
				date := ts[:10]
				dailyCount[date]++
				totalSessions++
				break
			}
		}
		return nil
	})

	// Also count from session metadata
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
		if meta.StartedAt > 0 {
			t := time.Unix(meta.StartedAt/1000, 0)
			date := t.Format("2006-01-02")
			if _, exists := dailyCount[date]; !exists {
				dailyCount[date] = 1
				totalSessions++
			}
		}
	}

	// Calculate streak
	currentStreak := 0
	longestStreak := 0
	today := time.Now()
	for i := 0; i < 365; i++ {
		d := today.AddDate(0, 0, -i).Format("2006-01-02")
		if dailyCount[d] > 0 {
			currentStreak++
		} else if i > 0 { // allow today to be zero
			break
		}
	}
	// Longest streak
	streak := 0
	for i := 0; i < 365; i++ {
		d := today.AddDate(0, 0, -i).Format("2006-01-02")
		if dailyCount[d] > 0 {
			streak++
			if streak > longestStreak {
				longestStreak = streak
			}
		} else {
			streak = 0
		}
	}

	// Build array sorted by date
	type DayActivity struct {
		Date  string `json:"date"`
		Count int    `json:"count"`
	}
	var days []DayActivity
	for date, count := range dailyCount {
		days = append(days, DayActivity{Date: date, Count: count})
	}
	sort.Slice(days, func(i, j int) bool { return days[i].Date < days[j].Date })

	c.JSON(200, gin.H{
		"days":          days,
		"totalSessions": totalSessions,
		"currentStreak": currentStreak,
		"longestStreak": longestStreak,
		"activeDays":    len(dailyCount),
	})
}
