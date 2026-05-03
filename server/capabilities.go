package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type CapabilityModel struct {
	Label        string  `json:"label"`
	ID           string  `json:"id"`
	Tier         string  `json:"tier,omitempty"`
	PriceInPerM  float64 `json:"priceInPerM"`
	PriceOutPerM float64 `json:"priceOutPerM"`
}

type CapabilityAgent struct {
	ID         string            `json:"id"`
	Label      string            `json:"label"`
	Command    string            `json:"command"`
	Installed  bool              `json:"installed"`
	Configured bool              `json:"configured"`
	Ready      bool              `json:"ready"`
	Smoke      AgentSmokeResult  `json:"smoke"`
	Version    string            `json:"version,omitempty"`
	Models     []CapabilityModel `json:"models"`
}

var claudeCapabilityModels = []CapabilityModel{
	{Label: "Sonnet 4", ID: "claude-sonnet-4-20250514", Tier: "Balanced", PriceInPerM: 3.0, PriceOutPerM: 15.0},
	{Label: "Sonnet 4.5", ID: "claude-sonnet-4-5-20250514", Tier: "Balanced", PriceInPerM: 3.0, PriceOutPerM: 15.0},
	{Label: "Opus 4", ID: "claude-opus-4-20250514", Tier: "Premium", PriceInPerM: 15.0, PriceOutPerM: 75.0},
	{Label: "Haiku 4.5", ID: "claude-haiku-4-5-20251001", Tier: "Fast", PriceInPerM: 1.0, PriceOutPerM: 5.0},
}

var kimiCapabilityModels = []CapabilityModel{
	{Label: "Kimi K2.5", ID: "kimi-k2.5", Tier: "Default", PriceInPerM: 0.60, PriceOutPerM: 2.50},
	{Label: "Kimi K2.6", ID: "kimi-k2.6", Tier: "Latest", PriceInPerM: 0.60, PriceOutPerM: 2.50},
	{Label: "Moonshot V1 8K", ID: "moonshot-v1-8k", Tier: "Legacy", PriceInPerM: 0.15, PriceOutPerM: 0.15},
	{Label: "Moonshot V1 32K", ID: "moonshot-v1-32k", Tier: "Legacy", PriceInPerM: 0.24, PriceOutPerM: 0.24},
	{Label: "Moonshot V1 128K", ID: "moonshot-v1-128k", Tier: "Long ctx", PriceInPerM: 0.30, PriceOutPerM: 0.30},
}

func commandVersion(bin string) string {
	if strings.TrimSpace(bin) == "" {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "--version").CombinedOutput()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.Split(string(out), "\n")[0])
}

func claudeAuthStatusOK(binary string) bool {
	binary = strings.TrimSpace(binary)
	if binary == "" {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := exec.CommandContext(ctx, binary, "auth", "status").Run(); err == nil {
		return true
	}
	return exec.CommandContext(ctx, binary, "auth", "status", "--json").Run() == nil
}

func commandInstalled(name string) bool {
	return resolveAgentCommand(name) != ""
}

func envAny(keys ...string) bool {
	for _, k := range keys {
		if strings.TrimSpace(os.Getenv(k)) != "" {
			return true
		}
	}
	return false
}

func (s *SessionServer) GetCapabilities(c *gin.Context) {
	claudeBin := resolveClaudeBinary()
	claudeInstalled := claudeBin != ""
	kimiBin := resolveAgentCommand("kimi-cli")
	kimiInstalled := kimiBin != ""
	codexBin := resolveAgentCommand("codex-cli")
	cursorBin := resolveAgentCommand("cursor")
	opencodeBin := resolveAgentCommand("opencode")
	kiroBin := resolveAgentCommand("kiro-cli")
	claudeConfigured := false
	if claudeInstalled {
		claudeConfigured = envAny("ANTHROPIC_API_KEY") || claudeAuthStatusOK(claudeBin)
	}
	claudeVers := ""
	if claudeInstalled {
		claudeVers = commandVersion(claudeBin)
	}
	claudeSmoke := agentSmokeCached("claude-code")
	kimiSmoke := agentSmokeCached("kimi-cli")
	codexSmoke := agentSmokeCached("codex-cli")
	cursorSmoke := agentSmokeCached("cursor")
	opencodeSmoke := agentSmokeCached("opencode")
	kiroSmoke := agentSmokeCached("kiro-cli")
	c.JSON(200, gin.H{
		"serverVersion": "dev",
		"agents": []CapabilityAgent{
			{
				ID:         "claude-code",
				Label:      "Claude",
				Command:    "claude",
				Installed:  claudeInstalled,
				Configured: claudeConfigured,
				Ready:      claudeInstalled && claudeConfigured && claudeSmoke.OK,
				Smoke:      claudeSmoke,
				Version:    claudeVers,
				Models:     claudeCapabilityModels,
			},
			{
				ID:         "kimi-cli",
				Label:      "Kimi",
				Command:    "kimi",
				Installed:  kimiInstalled,
				Configured: kimiInstalled || envAny("KIMI_API_KEY", "MOONSHOT_API_KEY"),
				Ready:      kimiInstalled && kimiSmoke.OK,
				Smoke:      kimiSmoke,
				Version:    commandVersion(kimiBin),
				Models:     kimiCapabilityModels,
			},
			{
				ID:         "codex-cli",
				Label:      "Codex",
				Command:    "codex",
				Installed:  codexBin != "",
				Configured: codexBin != "" && envAny("OPENAI_API_KEY"),
				Ready:      codexBin != "" && envAny("OPENAI_API_KEY") && codexSmoke.OK,
				Smoke:      codexSmoke,
				Version:    commandVersion(codexBin),
				Models: []CapabilityModel{
					{Label: "GPT-5.2 Codex", ID: "gpt-5.2-codex", Tier: "Default", PriceInPerM: 3.0, PriceOutPerM: 15.0},
				},
			},
			{
				ID:         "cursor",
				Label:      "Cursor",
				Command:    "agent",
				Installed:  cursorBin != "",
				Configured: cursorBin != "",
				Ready:      cursorBin != "" && cursorSmoke.OK,
				Smoke:      cursorSmoke,
				Version:    commandVersion(cursorBin),
				Models: []CapabilityModel{
					{Label: "GPT-5.2", ID: "gpt-5.2", Tier: "Cursor", PriceInPerM: 0, PriceOutPerM: 0},
				},
			},
			{
				ID:         "opencode",
				Label:      "OpenCode",
				Command:    "opencode",
				Installed:  opencodeBin != "",
				Configured: opencodeBin != "",
				Ready:      opencodeBin != "" && opencodeSmoke.OK,
				Smoke:      opencodeSmoke,
				Version:    commandVersion(opencodeBin),
				Models: []CapabilityModel{
					{Label: "Provider default", ID: "opencode-default", Tier: "Provider", PriceInPerM: 0, PriceOutPerM: 0},
				},
			},
			{
				ID:         "kiro-cli",
				Label:      "Kiro",
				Command:    "kiro-cli",
				Installed:  kiroBin != "",
				Configured: kiroBin != "",
				Ready:      kiroBin != "" && kiroSmoke.OK,
				Smoke:      kiroSmoke,
				Version:    commandVersion(kiroBin),
				Models: []CapabilityModel{
					{Label: "Kiro default", ID: "kiro-default", Tier: "Kiro", PriceInPerM: 0, PriceOutPerM: 0},
				},
			},
		},
	})
}
