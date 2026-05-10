package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveOpenCodeFromUserInstallDir(t *testing.T) {
	home := t.TempDir()
	binDir := filepath.Join(home, ".opencode", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(binDir, "opencode")
	if err := os.WriteFile(want, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("PLANULIX_SUBPROCESS_HOME", home)
	t.Setenv("PATH", "")

	got := resolveAgentCommand("opencode")
	if got != want {
		t.Fatalf("resolveAgentCommand(opencode) = %q; want %q", got, want)
	}
}

func TestCodexTaskCommandUsesWritableEphemeralSandbox(t *testing.T) {
	home := t.TempDir()
	binDir := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	codex := filepath.Join(binDir, "codex")
	if err := os.WriteFile(codex, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLANULIX_SUBPROCESS_HOME", home)
	t.Setenv("PATH", "")
	t.Setenv("PLANULIX_CODEX_CLI_SANDBOX", "")
	t.Setenv("PLANULIX_CODEX_SANDBOX", "")
	t.Setenv("PLANULIX_AGENT_SANDBOX", "")
	t.Setenv("PLANULIX_CODEX_CLI_FULL_ACCESS", "")
	t.Setenv("PLANULIX_AGENT_FULL_ACCESS", "")

	cmd, _, err := buildAgentCommand("codex-cli", "task", home, "commit test", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`exec --cd`, `--dangerously-bypass-approvals-and-sandbox`, `--ephemeral`, `--skip-git-repo-check`} {
		if !strings.Contains(cmd, want) {
			t.Fatalf("codex command %q does not contain %q", cmd, want)
		}
	}
}

func TestCollectSessionsListHidesManagedAgentHistory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PLANULIX_SUBPROCESS_HOME", home)
	claudeHome := filepath.Join(home, ".claude")
	if err := os.MkdirAll(claudeHome, 0o755); err != nil {
		t.Fatal(err)
	}
	historyDir := filepath.Join(home, ".codex", "sessions")
	if err := os.MkdirAll(historyDir, 0o755); err != nil {
		t.Fatal(err)
	}
	historyPath := filepath.Join(historyDir, "abc.jsonl")
	if err := os.WriteFile(historyPath, []byte(`{"type":"message","role":"assistant","content":"hi"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	srv := NewSessionServer(claudeHome)
	if srv.agentStore == nil {
		t.Fatal("agent store is nil")
	}
	if err := srv.agentStore.Upsert(&StoredAgentSession{
		ID:          "cd-1",
		Agent:       "codex-cli",
		Cwd:         home,
		Name:        "codex-chat",
		TmuxName:    "codex-chat",
		HistoryPath: historyPath,
		Status:      "done",
		StartedAt:   1,
	}); err != nil {
		t.Fatal(err)
	}

	sessions, _ := srv.CollectSessionsList(20)
	for _, sess := range sessions {
		if strings.HasPrefix(sess.SessionID, "codex-") {
			t.Fatalf("raw codex session %q leaked alongside managed cd-* session", sess.SessionID)
		}
	}
}

func TestGitControlStatusParsesBranchAheadBehind(t *testing.T) {
	st := gitControlStatus{}
	parseGitBranchLine("main...origin/main [ahead 2, behind 1]", &st)
	if st.Branch != "main" || st.Upstream != "origin/main" || st.Ahead != 2 || st.Behind != 1 {
		t.Fatalf("parsed status = %+v", st)
	}
}

func TestAgentManifestsExposeRequiredContracts(t *testing.T) {
	manifests := agentManifests()
	if len(manifests) == 0 {
		t.Fatal("no manifests")
	}
	for _, m := range manifests {
		if m.ID == "" || m.Command == "" || m.InstallCommand == "" || m.AuthCheck == "" || m.SmokeTest == "" {
			t.Fatalf("manifest has empty contract fields: %+v", m)
		}
		if len(m.DataPaths) == 0 || m.HistoryReader == "" || m.OneShot == "" || m.Resume == "" {
			t.Fatalf("manifest missing runtime fields: %+v", m)
		}
		if !m.Capabilities.Markdown {
			t.Fatalf("manifest should declare markdown support for Planulix renderer: %+v", m)
		}
	}
}

func TestTaskSpecRootUsesProjectSpecsDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "projects", "demo")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}
	got := taskSpecRoot(project)
	want := filepath.Join(project, "docs", "specs")
	if got != want {
		t.Fatalf("taskSpecRoot = %q; want %q", got, want)
	}
}
