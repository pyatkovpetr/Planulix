package main

type AgentCapabilities struct {
	Commit   bool `json:"commit"`
	Push     bool `json:"push"`
	Sandbox  bool `json:"sandbox"`
	Images   bool `json:"images"`
	Markdown bool `json:"markdown"`
	Resume   bool `json:"resume"`
	OneShot  bool `json:"oneShot"`
}

type AgentManifest struct {
	ID             string            `json:"id"`
	Label          string            `json:"label"`
	Command        string            `json:"command"`
	InstallCommand string            `json:"installCommand"`
	AuthCheck      string            `json:"authCheck"`
	SmokeTest      string            `json:"smokeTest"`
	DataPaths      []string          `json:"dataPaths"`
	HistoryReader  string            `json:"historyReader"`
	OneShot        string            `json:"oneShot"`
	Resume         string            `json:"resume"`
	Capabilities   AgentCapabilities `json:"capabilities"`
}

func agentManifests() []AgentManifest {
	return []AgentManifest{
		{
			ID:             "claude-code",
			Label:          "Claude Code",
			Command:        "claude",
			InstallCommand: "POST /api/setup/agents/claude-code/install",
			AuthCheck:      "ANTHROPIC_API_KEY or claude auth status",
			SmokeTest:      "claude -p sanity prompt",
			DataPaths:      []string{"~/.claude/sessions/**/*.jsonl"},
			HistoryReader:  "Claude JSONL parser",
			OneShot:        "claude -p",
			Resume:         "claude --resume <session> -p",
			Capabilities:   AgentCapabilities{Commit: true, Push: true, Sandbox: true, Images: true, Markdown: true, Resume: true, OneShot: true},
		},
		{
			ID:             "kimi-cli",
			Label:          "Kimi Code",
			Command:        "kimi",
			InstallCommand: "POST /api/setup/agents/kimi-cli/install",
			AuthCheck:      "KIMI_API_KEY/MOONSHOT_API_KEY or kimi login/config",
			SmokeTest:      "kimi --print -p sanity prompt",
			DataPaths:      []string{"~/.kimi/sessions/*/<id>/context.jsonl"},
			HistoryReader:  "Kimi context.jsonl parser",
			OneShot:        "kimi --print -p",
			Resume:         "kimi --session <id> --print -p",
			Capabilities:   AgentCapabilities{Commit: true, Push: true, Sandbox: true, Images: false, Markdown: true, Resume: true, OneShot: true},
		},
		{
			ID:             "codex-cli",
			Label:          "Codex CLI",
			Command:        "codex",
			InstallCommand: "POST /api/setup/agents/codex-cli/install",
			AuthCheck:      "OPENAI_API_KEY or Codex OAuth artifacts",
			SmokeTest:      "codex exec sanity prompt",
			DataPaths:      []string{"~/.codex/**/*.jsonl"},
			HistoryReader:  "Codex JSONL parser + Planulix managed session link",
			OneShot:        "codex exec --cd <cwd>",
			Resume:         "interactive session via managed tmux",
			Capabilities:   AgentCapabilities{Commit: true, Push: true, Sandbox: true, Images: true, Markdown: true, Resume: false, OneShot: true},
		},
		{
			ID:             "cursor",
			Label:          "Cursor CLI",
			Command:        "agent",
			InstallCommand: "POST /api/setup/agents/cursor/install",
			AuthCheck:      "agent binary available and configured",
			SmokeTest:      "agent -p sanity prompt",
			DataPaths:      []string{"~/.cursor/projects/**/agent-transcripts/*.jsonl"},
			HistoryReader:  "Cursor agent transcript parser",
			OneShot:        "agent -p",
			Resume:         "interactive session via managed tmux",
			Capabilities:   AgentCapabilities{Commit: true, Push: true, Sandbox: true, Images: false, Markdown: true, Resume: false, OneShot: true},
		},
		{
			ID:             "opencode",
			Label:          "OpenCode",
			Command:        "opencode",
			InstallCommand: "POST /api/setup/agents/opencode/install",
			AuthCheck:      "opencode binary available and provider configured",
			SmokeTest:      "opencode run --print sanity prompt",
			DataPaths:      []string{"~/.local/share/opencode"},
			HistoryReader:  "JSON/JSONL export/log discovery",
			OneShot:        "opencode run --print",
			Resume:         "interactive session via managed tmux",
			Capabilities:   AgentCapabilities{Commit: true, Push: true, Sandbox: false, Images: false, Markdown: true, Resume: false, OneShot: true},
		},
		{
			ID:             "kiro-cli",
			Label:          "Kiro CLI",
			Command:        "kiro-cli",
			InstallCommand: "POST /api/setup/agents/kiro-cli/install",
			AuthCheck:      "kiro login/browser auth",
			SmokeTest:      "kiro chat --no-interactive sanity prompt",
			DataPaths:      []string{"~/.local/share/kiro-cli", "~/Library/Application Support/kiro-cli"},
			HistoryReader:  "Kiro JSON/JSONL discovery",
			OneShot:        "kiro chat --no-interactive",
			Resume:         "interactive session via managed tmux",
			Capabilities:   AgentCapabilities{Commit: true, Push: true, Sandbox: true, Images: false, Markdown: true, Resume: false, OneShot: true},
		},
	}
}
