package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/gin-gonic/gin"
)

type SkillInfo struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Path        string `json:"path"`
}

// GetSkills scans ~/.claude/skills/ for available Claude Code skills
func (s *SessionServer) GetSkills(c *gin.Context) {
	skillsDir := filepath.Join(s.claudeHome, "skills")
	entries, err := os.ReadDir(skillsDir)
	if err != nil {
		c.JSON(200, gin.H{"skills": []SkillInfo{}})
		return
	}

	skills := make([]SkillInfo, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		info := SkillInfo{
			Name: e.Name(),
			Path: filepath.Join(skillsDir, e.Name()),
		}

		// Try to read SKILL.md description (frontmatter or first paragraph)
		skillMd := filepath.Join(skillsDir, e.Name(), "SKILL.md")
		if data, err := os.ReadFile(skillMd); err == nil {
			info.Description = extractSkillDescription(string(data))
		}

		skills = append(skills, info)
	}

	sort.Slice(skills, func(i, j int) bool { return skills[i].Name < skills[j].Name })
	c.JSON(200, gin.H{"skills": skills, "total": len(skills)})
}

func extractSkillDescription(content string) string {
	// Try YAML frontmatter first: look for description: ...
	if strings.HasPrefix(content, "---") {
		end := strings.Index(content[3:], "---")
		if end > 0 {
			fm := content[3 : 3+end]
			for _, line := range strings.Split(fm, "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "description:") {
					desc := strings.TrimSpace(strings.TrimPrefix(line, "description:"))
					desc = strings.Trim(desc, `"'`)
					if len(desc) > 120 {
						desc = desc[:120] + "..."
					}
					return desc
				}
			}
		}
	}

	// Fallback: first non-header, non-empty line
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "---") {
			continue
		}
		if len(line) > 120 {
			line = line[:120] + "..."
		}
		return line
	}
	return ""
}
