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
	_, err := exec.LookPath(name)
	return err == nil
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
	kimiInstalled := commandInstalled("kimi")
	claudeConfigured := false
	if claudeInstalled {
		claudeConfigured = envAny("ANTHROPIC_API_KEY") || claudeAuthStatusOK(claudeBin)
	}
	claudeVers := ""
	if claudeInstalled {
		claudeVers = commandVersion(claudeBin)
	}
	kimiBin, _ := exec.LookPath("kimi")
	if kimiBin == "" {
		kimiBin = "kimi"
	}
	c.JSON(200, gin.H{
		"serverVersion": "dev",
		"agents": []CapabilityAgent{
			{
				ID:         "claude-code",
				Label:      "Claude",
				Command:    "claude",
				Installed:  claudeInstalled,
				Configured: claudeConfigured,
				Version:    claudeVers,
				Models:     claudeCapabilityModels,
			},
			{
				ID:         "kimi-cli",
				Label:      "Kimi",
				Command:    "kimi",
				Installed:  kimiInstalled,
				Configured: kimiInstalled || envAny("KIMI_API_KEY", "MOONSHOT_API_KEY"),
				Version:    commandVersion(kimiBin),
				Models:     kimiCapabilityModels,
			},
		},
	})
}
