package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

const (
	claudeBinDefault = "/home/claude/.nvm/versions/node/v24.14.1/bin/claude"
	claudeEnv        = "export HOME=/home/claude PATH=/home/claude/.nvm/versions/node/v24.14.1/bin:$PATH TERM=xterm-256color"
	kimiBinDefault   = "/usr/local/bin/kimi"
	kimiEnv          = "export HOME=/root PATH=/usr/local/bin:/opt/kimi-cli/bin:$PATH TERM=xterm-256color"
)

// kimiAuthEnvExports adds API keys from the planulix process environment (e.g. systemd EnvironmentFile=/root/planulix.env)
// so Kimi works when ~/.kimi/config.toml has an empty api_key. See: KIMI_API_KEY / MOONSHOT_API_KEY.
func kimiAuthEnvExports() string {
	var parts []string
	add := func(name, val string) {
		v := strings.TrimSpace(val)
		if v == "" {
			return
		}
		parts = append(parts, fmt.Sprintf("export %s=%s", name, strconv.Quote(v)))
	}
	add("KIMI_API_KEY", os.Getenv("KIMI_API_KEY"))
	add("MOONSHOT_API_KEY", os.Getenv("MOONSHOT_API_KEY"))
	moonURL := strings.TrimSpace(os.Getenv("MOONSHOT_BASE_URL"))
	kimiURL := strings.TrimSpace(os.Getenv("KIMI_BASE_URL"))
	if kimiURL == "" {
		kimiURL = moonURL
	}
	if moonURL != "" {
		add("MOONSHOT_BASE_URL", moonURL)
	}
	if kimiURL != "" {
		add("KIMI_BASE_URL", kimiURL)
	}
	return strings.Join(parts, " && ")
}

func kimiEnvWithAuth() string {
	if auth := kimiAuthEnvExports(); auth != "" {
		return auth + " && " + kimiEnv
	}
	return kimiEnv
}

// buildAgentCommand builds shell fragment (no export prefix) and environment exports for tmux bash -c.
func buildAgentCommand(agent, mode, cwd, prompt, model string, agentEnv map[string]string) (cmd string, env string, err error) {
	switch agent {
	case "kimi-cli":
		modelFlag := ""
		if m := strings.TrimSpace(model); m != "" {
			modelFlag = fmt.Sprintf(" -m %q", m)
		}
		base := fmt.Sprintf("%s -w %q -y%s", kimiBinDefault, cwd, modelFlag)
		env = mergeSessionExports(kimiEnvWithAuth(), shellExportsFromAgentEnv(agentEnv))
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("%s --print -p %q", base, prompt), env, nil
		}
		return base, env, nil
	default:
		modelFlag := ""
		if model != "" {
			modelFlag = fmt.Sprintf(" --model %s", model)
		}
		env = mergeSessionExports(claudeEnv, shellExportsFromAgentEnv(agentEnv))
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("%s --dangerously-skip-permissions%s -p %q", claudeBinDefault, modelFlag, prompt), env, nil
		}
		return fmt.Sprintf("%s --dangerously-skip-permissions%s", claudeBinDefault, modelFlag), env, nil
	}
}

// buildClaudeResumeShell returns a bash -c script for one-shot resume + print.
func buildClaudeResumeShell(cwd, claudeSessionID, text string, agentEnv map[string]string, model string) string {
	env := mergeSessionExports(claudeEnv, shellExportsFromAgentEnv(agentEnv))
	modelFlag := ""
	if m := strings.TrimSpace(model); m != "" {
		modelFlag = " --model " + m
	}
	return fmt.Sprintf(
		"%s && cd %q && %s --dangerously-skip-permissions%s --resume %s -p %q",
		env, cwd, claudeBinDefault, modelFlag, claudeSessionID, text,
	)
}

// kimiAPIID strips the kimi- prefix for --session.
func kimiAPIID(sessionID string) string {
	id := strings.TrimSpace(sessionID)
	id = strings.TrimPrefix(id, "kimi-")
	return id
}

// buildKimiResumeShell one-shot message to an existing Kimi session id (uuid).
// We intentionally omit -m: an explicit model that is not listed under [models] in
// ~/.kimi/config.toml makes kimi --print fail with "LLM not set" (MoonshotAI/kimi-cli#1954).
// Resume should use the session's stored model / CLI default.
func buildKimiResumeShell(cwd, sessionUUID, text string, agentEnv map[string]string, _model string) string {
	env := mergeSessionExports(kimiEnvWithAuth(), shellExportsFromAgentEnv(agentEnv))
	base := fmt.Sprintf("%s -w %q -y", kimiBinDefault, cwd)
	return fmt.Sprintf(
		"%s && cd %q && %s --session %q --print -p %q",
		env, cwd, base, sessionUUID, text,
	)
}
