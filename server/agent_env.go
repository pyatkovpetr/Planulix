package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Only these names may be forwarded from the mobile client into tmux/bash (no arbitrary env injection).
var allowedSessionAgentEnvKeys = map[string]bool{
	"KIMI_API_KEY":        true,
	"KIMI_BASE_URL":       true,
	"MOONSHOT_API_KEY":    true,
	"MOONSHOT_BASE_URL":   true,
	"OPENAI_BASE_URL":     true,
	"ANTHROPIC_API_KEY":   true,
	"OPENAI_API_KEY":      true,
}

// shellExportsFromAgentEnv builds "export K=v && export ..." for whitelisted keys (bash-safe quoting).
func shellExportsFromAgentEnv(m map[string]string) string {
	if len(m) == 0 {
		return ""
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		if !allowedSessionAgentEnvKeys[k] {
			continue
		}
		v := strings.TrimSpace(m[k])
		if v == "" {
			continue
		}
		parts = append(parts, fmt.Sprintf("export %s=%s", k, strconv.Quote(v)))
	}
	return strings.Join(parts, " && ")
}

// mergeSessionExports appends client exports after base so the same variable name from the client overrides the server default.
func mergeSessionExports(baseShellEnv, clientAgentExports string) string {
	clientAgentExports = strings.TrimSpace(clientAgentExports)
	if clientAgentExports == "" {
		return baseShellEnv
	}
	return baseShellEnv + " && " + clientAgentExports
}

// mergeAgentEnvPreferred merges whitelisted keys; [client] overrides [stored].
func mergeAgentEnvPreferred(client, stored map[string]string) map[string]string {
	out := make(map[string]string)
	if len(stored) > 0 {
		for k, v := range stored {
			v = strings.TrimSpace(v)
			if v == "" || !allowedSessionAgentEnvKeys[k] {
				continue
			}
			out[k] = v
		}
	}
	if len(client) > 0 {
		for k, v := range client {
			v = strings.TrimSpace(v)
			if v == "" || !allowedSessionAgentEnvKeys[k] {
				continue
			}
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
