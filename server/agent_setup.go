package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type agentSetupSpec struct {
	ID          string
	Label       string
	Command     string
	CheckPaths  []string
	InstallBody string
	Notes       string
}

var ansiEscapeRegexp = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

func stripANSI(s string) string {
	return ansiEscapeRegexp.ReplaceAllString(s, "")
}

func commandPath(candidates ...string) string {
	for _, c := range candidates {
		c = strings.TrimSpace(c)
		if c == "" {
			continue
		}
		if strings.Contains(c, "/") {
			if st, err := os.Stat(c); err == nil && !st.IsDir() && st.Mode()&0111 != 0 {
				return c
			}
			continue
		}
		if p, err := exec.LookPath(c); err == nil && strings.TrimSpace(p) != "" {
			return strings.TrimSpace(p)
		}
	}
	return ""
}

func resolveAgentCommand(id string) string {
	switch strings.TrimSpace(id) {
	case "claude-code", "claude":
		return resolveClaudeBinary()
	case "kimi-cli", "kimi":
		return commandPath("kimi", kimiBinDefault, "/opt/kimi-cli/bin/kimi")
	case "codex-cli", "codex":
		return commandPath("codex")
	case "cursor":
		return commandPath("agent")
	case "opencode":
		return commandPath("opencode")
	case "kiro-cli", "kiro":
		return commandPath("kiro-cli", "kiro")
	default:
		return ""
	}
}

func agentSetupSpecs() map[string]agentSetupSpec {
	return map[string]agentSetupSpec{
		"claude-code": {
			ID:          "claude-code",
			Label:       "Claude Code",
			Command:     "claude",
			InstallBody: embeddedClaudeInstallScript,
			Notes:       "После установки настройте ANTHROPIC_API_KEY или выполните claude auth login.",
		},
		"kimi-cli": {
			ID:      "kimi-cli",
			Label:   "Kimi Code",
			Command: "kimi",
			InstallBody: `set -euo pipefail
FORCE="${PLANULIX_AGENT_FORCE_UPDATE:-0}"
if [ "$FORCE" != "1" ] && command -v kimi >/dev/null 2>&1; then kimi --version || true; exit 0; fi
if command -v curl >/dev/null 2>&1; then
  curl -LsSf https://code.kimi.com/install.sh | bash
elif command -v uv >/dev/null 2>&1; then
  uv tool install --python 3.13 kimi-cli
else
  echo "ERROR: need curl or uv to install Kimi Code CLI" >&2
  exit 20
fi
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/kimi-cli/bin:$PATH"
command -v kimi >/dev/null 2>&1 || test -x /usr/local/bin/kimi || test -x /opt/kimi-cli/bin/kimi
kimi --version 2>/dev/null || true`,
			Notes: "Сессии читаются из ~/.kimi/sessions/*/<session-id>/context.jsonl. Для работы нужен KIMI_API_KEY/MOONSHOT_API_KEY или login/config Kimi.",
		},
		"codex-cli": {
			ID:      "codex-cli",
			Label:   "Codex CLI",
			Command: "codex",
			InstallBody: `set -euo pipefail
FORCE="${PLANULIX_AGENT_FORCE_UPDATE:-0}"
if [ "$FORCE" != "1" ] && command -v codex >/dev/null 2>&1; then codex --version || true; exit 0; fi
if ! command -v npm >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg >/dev/null || true
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nodejs npm >/dev/null
  else
    echo "ERROR: need npm or Node.js package manager" >&2
    exit 20
  fi
fi
npm install -g @openai/codex@latest
command -v codex >/dev/null 2>&1
codex --version 2>/dev/null || true`,
			Notes: "Сессии обнаруживаются в ~/.codex/**/*.jsonl. Для работы войдите через codex или передайте OPENAI_API_KEY.",
		},
		"cursor": {
			ID:      "cursor",
			Label:   "Cursor CLI",
			Command: "agent",
			InstallBody: `set -euo pipefail
FORCE="${PLANULIX_AGENT_FORCE_UPDATE:-0}"
if [ "$FORCE" != "1" ] && command -v agent >/dev/null 2>&1; then agent --version || true; exit 0; fi
curl https://cursor.com/install -fsS | bash
export PATH="$HOME/.local/bin:$PATH"
command -v agent >/dev/null 2>&1
agent --version 2>/dev/null || true`,
			Notes: "Planulix сейчас читает Cursor transcripts из ~/.cursor/projects/**/agent-transcripts/*.jsonl; запуск Cursor-agent из UI требует отдельной интеграции.",
		},
		"opencode": {
			ID:      "opencode",
			Label:   "OpenCode",
			Command: "opencode",
			InstallBody: `set -euo pipefail
FORCE="${PLANULIX_AGENT_FORCE_UPDATE:-0}"
if [ "$FORCE" != "1" ] && command -v opencode >/dev/null 2>&1; then opencode --version || true; exit 0; fi
if command -v curl >/dev/null 2>&1; then
  curl -fsSL https://opencode.ai/install | bash || true
fi
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
if [ -f "$HOME/.profile" ]; then . "$HOME/.profile" >/dev/null 2>&1 || true; fi
hash -r
if ! command -v opencode >/dev/null 2>&1; then
  found="$(find "$HOME" -maxdepth 4 -type f -name opencode -perm -111 2>/dev/null | head -n 1 || true)"
  if [ -n "$found" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$found" "$HOME/.local/bin/opencode"
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
if ! command -v opencode >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  npm i -g opencode-ai@latest
  hash -r
fi
command -v opencode >/dev/null 2>&1
opencode --version 2>/dev/null || true`,
			Notes: "OpenCode хранит данные в ~/.local/share/opencode; Planulix пока показывает JSON/JSONL экспорты/логи из этого каталога.",
		},
		"kiro-cli": {
			ID:      "kiro-cli",
			Label:   "Kiro CLI",
			Command: "kiro-cli",
			InstallBody: `set -euo pipefail
FORCE="${PLANULIX_AGENT_FORCE_UPDATE:-0}"
if [ "$FORCE" != "1" ] && (command -v kiro-cli >/dev/null 2>&1 || command -v kiro >/dev/null 2>&1); then
  (kiro-cli --version || kiro --version || true) 2>/dev/null
  exit 0
fi
curl -fsSL https://cli.kiro.dev/install | bash
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
command -v kiro-cli >/dev/null 2>&1 || command -v kiro >/dev/null 2>&1
(kiro-cli --version || kiro --version || true) 2>/dev/null`,
			Notes: "Kiro CLI использует login через браузер. Planulix ищет данные в ~/.local/share/kiro-cli (Linux) или ~/Library/Application Support/kiro-cli.",
		},
	}
}

func (s *SessionServer) InstallAgentCLI(c *gin.Context) {
	id := strings.TrimSpace(c.Param("id"))
	if id == "claude" {
		id = "claude-code"
	}
	if id == "kimi" {
		id = "kimi-cli"
	}
	if id == "codex" {
		id = "codex-cli"
	}
	if id == "kiro" {
		id = "kiro-cli"
	}
	spec, ok := agentSetupSpecs()[id]
	if !ok {
		c.JSON(400, gin.H{"ok": false, "error": "unsupported agent: " + id})
		return
	}
	force := c.Query("force") == "1" || strings.EqualFold(c.Query("force"), "true")
	if p := resolveAgentCommand(spec.ID); p != "" && !force {
		c.JSON(200, gin.H{"ok": true, "alreadyInstalled": true, "command": p, "log": fmt.Sprintf("%s already installed: %s", spec.Label, p), "notes": spec.Notes})
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 10*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-lc", spec.InstallBody)
	cmd.Env = append(os.Environ(),
		"DEBIAN_FRONTEND=noninteractive",
		fmt.Sprintf("PLANULIX_AGENT_FORCE_UPDATE=%d", map[bool]int{true: 1, false: 0}[force]),
		"PATH="+augmentPathFront(claudeSubprocessHome(), os.Getenv("PATH"), "/usr/local/bin", "/usr/bin", "/bin", "/root/.local/bin"),
	)
	out, err := cmd.CombinedOutput()
	logStr := strings.TrimSpace(stripANSI(string(out)))
	installedPath := resolveAgentCommand(spec.ID)
	ok = err == nil && installedPath != ""
	payload := gin.H{
		"ok":        ok,
		"agent":     spec.ID,
		"label":     spec.Label,
		"command":   spec.Command,
		"path":      installedPath,
		"log":       logStr,
		"notes":     spec.Notes,
		"installed": installedPath != "",
		"updated":   force,
	}
	if err != nil {
		payload["error"] = err.Error()
	}
	c.JSON(200, payload)
}
