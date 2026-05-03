package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	claudeBinLegacyFallback = "/home/claude/.nvm/versions/node/v24.14.1/bin/claude"
	kimiBinDefault          = "/usr/local/bin/kimi"
	kimiEnv                 = "export HOME=/root PATH=/usr/local/bin:/opt/kimi-cli/bin:$PATH TERM=xterm-256color"
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

func claudeSubprocessHome() string {
	if h := strings.TrimSpace(os.Getenv("PLANULIX_SUBPROCESS_HOME")); h != "" {
		return h
	}
	h, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(h) == "" {
		return "/root"
	}
	return h
}

func augmentPathFront(home string, basePath string, front ...string) string {
	basePath = strings.TrimSpace(basePath)
	if basePath == "" {
		basePath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	seen := make(map[string]struct{})
	out := make([]string, 0, len(front)+32)
	push := func(p string) {
		p = strings.TrimSpace(p)
		if p == "" {
			return
		}
		if _, ok := seen[p]; ok {
			return
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	for _, p := range front {
		push(p)
	}
	for _, p := range strings.Split(basePath, string(os.PathListSeparator)) {
		push(p)
	}
	return strings.Join(out, string(os.PathListSeparator))
}

// resolveClaudeBinary finds the Claude Code CLI: PLANULIX_CLAUDE_BIN, PATH, legacy fallback.
func resolveClaudeBinary() string {
	if v := strings.TrimSpace(os.Getenv("PLANULIX_CLAUDE_BIN")); v != "" {
		return v
	}
	if p, err := exec.LookPath("claude"); err == nil && strings.TrimSpace(p) != "" {
		return strings.TrimSpace(p)
	}
	if st, err := os.Stat(claudeBinLegacyFallback); err == nil && !st.IsDir() && st.Mode()&0111 != 0 {
		return claudeBinLegacyFallback
	}
	return ""
}

// claudeExportsForShell is used for tmux sessions and Claude setup (auth login).
func claudeExportsForShell(agentEnv map[string]string) string {
	home := claudeSubprocessHome()
	clBin := resolveClaudeBinary()
	front := []string{
		filepath.Join(home, ".npm-global", "bin"),
		filepath.Join(home, ".local", "bin"),
		"/usr/local/bin",
	}
	if clBin != "" {
		if dir := filepath.Dir(clBin); dir != "" && dir != "." {
			front = append([]string{dir}, front...)
		}
	}
	pathAug := augmentPathFront(home, os.Getenv("PATH"), front...)
	return mergeSessionExports(
		fmt.Sprintf("export HOME=%q PATH=%q TERM=xterm-256color", home, pathAug),
		shellExportsFromAgentEnv(agentEnv),
	)
}

func genericAgentExports(agentEnv map[string]string) string {
	home := claudeSubprocessHome()
	pathAug := augmentPathFront(
		home,
		os.Getenv("PATH"),
		filepath.Join(home, ".local", "bin"),
		filepath.Join(home, ".npm-global", "bin"),
		"/usr/local/bin",
		"/opt/kimi-cli/bin",
	)
	return mergeSessionExports(
		fmt.Sprintf("export HOME=%q PATH=%q TERM=xterm-256color", home, pathAug),
		shellExportsFromAgentEnv(agentEnv),
	)
}

func normalizeRequestedAgent(agent, model string) string {
	a := strings.ToLower(strings.TrimSpace(agent))
	switch a {
	case "", "claude", "claude-code":
		if isKimiAgent(agent, model) {
			return "kimi-cli"
		}
		return "claude-code"
	case "kimi", "kimi-cli":
		return "kimi-cli"
	case "codex", "codex-cli":
		return "codex-cli"
	case "cursor", "cursor-agent":
		return "cursor"
	case "kiro", "kiro-cli":
		return "kiro-cli"
	case "opencode", "open-code":
		return "opencode"
	default:
		return "claude-code"
	}
}

func modelFlagValue(model string) string {
	model = strings.TrimSpace(model)
	switch model {
	case "", "provider-default", "cursor-default", "kiro-default", "opencode-default":
		return ""
	default:
		return model
	}
}

// cursorCLIAllowedModel rejects Anthropic/Kimi/other provider ids accidentally sent while a Claude tab/model picker is visible.
func cursorCLIAllowedModel(model string) string {
	m := modelFlagValue(model)
	if m == "" {
		return ""
	}
	l := strings.ToLower(m)
	if strings.Contains(l, "claude") {
		return ""
	}
	if strings.Contains(l, "kimi") || strings.Contains(l, "moonshot") {
		return ""
	}
	return model
}

func agentTmuxPrefix(agent string) string {
	switch normalizeRequestedAgent(agent, "") {
	case "kimi-cli":
		return "kimi"
	case "codex-cli":
		return "codex"
	case "cursor":
		return "cursor"
	case "kiro-cli":
		return "kiro"
	case "opencode":
		return "opencode"
	default:
		return "claude"
	}
}

// buildAgentCommand builds shell fragment (no export prefix) and environment exports for tmux bash -c.
func buildAgentCommand(agent, mode, cwd, prompt, model string, agentEnv map[string]string) (cmd string, env string, err error) {
	switch normalizeRequestedAgent(agent, model) {
	case "kimi-cli":
		// Do not pass -m here. Kimi Code validates model names against the server-side
		// ~/.kimi/config.toml; UI/provider ids frequently do not match local aliases and
		// make a new chat die before it can be linked.
		base := fmt.Sprintf("%s -w %q -y", kimiBinDefault, cwd)
		env = mergeSessionExports(kimiEnvWithAuth(), shellExportsFromAgentEnv(agentEnv))
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("%s --print -p %q", base, prompt), env, nil
		}
		return base, env, nil
	case "codex-cli":
		bin := resolveAgentCommand("codex-cli")
		if bin == "" {
			return "", "", fmt.Errorf("codex CLI not found on server (install Codex CLI first)")
		}
		env = genericAgentExports(agentEnv)
		modelFlag := ""
		if m := modelFlagValue(model); m != "" {
			modelFlag = fmt.Sprintf(" --model %q", m)
		}
		q := strconv.Quote(bin)
		// `codex exec` (smoke/tests/headless) does not accept `--ask-for-approval` — that flag is for the interactive CLI / TUI.
		// Older Planulix builds passed `--ask-for-approval never`, which breaks codex-cli v0.12x+ exec.
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("%s exec --cd %q --sandbox workspace-write --skip-git-repo-check%s %q", q, cwd, modelFlag, prompt), env, nil
		}
		return fmt.Sprintf("%s --cd %q --sandbox workspace-write%s", q, cwd, modelFlag), env, nil
	case "cursor":
		bin := resolveAgentCommand("cursor")
		if bin == "" {
			return "", "", fmt.Errorf("Cursor CLI agent not found on server (install Cursor CLI first)")
		}
		env = genericAgentExports(agentEnv)
		modelFlag := ""
		if m := cursorCLIAllowedModel(model); m != "" {
			modelFlag = fmt.Sprintf(" --model %q", m)
		}
		q := strconv.Quote(bin)
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("%s -p --force%s %q", q, modelFlag, prompt), env, nil
		}
		return fmt.Sprintf("%s%s", q, modelFlag), env, nil
	case "kiro-cli":
		bin := resolveAgentCommand("kiro-cli")
		if bin == "" {
			return "", "", fmt.Errorf("Kiro CLI not found on server (install Kiro CLI first)")
		}
		env = genericAgentExports(agentEnv)
		q := strconv.Quote(bin)
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("%s chat --no-interactive --trust-all-tools %q", q, prompt), env, nil
		}
		return fmt.Sprintf("%s chat --trust-all-tools", q), env, nil
	case "opencode":
		bin := resolveAgentCommand("opencode")
		if bin == "" {
			return "", "", fmt.Errorf("OpenCode CLI not found on server (install OpenCode first)")
		}
		env = genericAgentExports(agentEnv)
		q := strconv.Quote(bin)
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("%s run --print %q", q, prompt), env, nil
		}
		return q, env, nil
	default:
		clBin := resolveClaudeBinary()
		if clBin == "" {
			return "", "", fmt.Errorf("claude CLI not found on server (install Claude Code or set PLANULIX_CLAUDE_BIN)")
		}
		cdTo := strings.TrimSpace(cwd)
		if cdTo == "" {
			cdTo = claudeSubprocessHome()
			if cdTo == "" {
				cdTo = "/"
			}
		}
		modelFlag := ""
		if model != "" {
			modelFlag = fmt.Sprintf(" --model %s", model)
		}
		env = claudeExportsForShell(agentEnv)
		q := strconv.Quote(clBin)
		permissionFlag := " --dangerously-skip-permissions"
		if os.Geteuid() == 0 {
			permissionFlag = ""
		}
		if mode == "task" {
			if prompt == "" {
				return "", "", fmt.Errorf("prompt is required for task mode")
			}
			return fmt.Sprintf("cd %q && %s%s%s -p %q", cdTo, q, permissionFlag, modelFlag, prompt), env, nil
		}
		return fmt.Sprintf("cd %q && %s%s%s", cdTo, q, permissionFlag, modelFlag), env, nil
	}
}

// buildClaudeResumeShell returns a bash -c script for one-shot resume + print.
func buildClaudeResumeShell(cwd, claudeSessionID, text string, agentEnv map[string]string, model string) string {
	clBin := resolveClaudeBinary()
	if clBin == "" {
		return "echo missing_claude_binary; exit 1"
	}
	env := claudeExportsForShell(agentEnv)
	modelFlag := ""
	if m := modelFlagValue(model); m != "" {
		modelFlag = " --model " + m
	}
	permissionFlag := " --dangerously-skip-permissions"
	if os.Geteuid() == 0 {
		permissionFlag = ""
	}
	q := strconv.Quote(clBin)
	return fmt.Sprintf(
		"%s && cd %q && %s%s%s --resume %s -p %q",
		env, cwd, q, permissionFlag, modelFlag, claudeSessionID, text,
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
