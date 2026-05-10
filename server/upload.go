package main

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// UploadProject receives a tar.gz archive and extracts it into ~/projects/<name>
// Request: POST /api/upload?name=projectName
// Body: tar.gz data
func (s *SessionServer) UploadProject(c *gin.Context) {
	name := c.Query("name")
	if name == "" {
		c.JSON(400, gin.H{"error": "name query param is required"})
		return
	}

	// Sanitize name — no slashes, no dots
	if strings.ContainsAny(name, "/\\..") {
		c.JSON(400, gin.H{"error": "invalid project name"})
		return
	}

	home, _ := os.UserHomeDir()
	baseDir := filepath.Join(home, "projects")
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("failed to create projects dir: %v", err)})
		return
	}

	targetDir := filepath.Join(baseDir, name)

	// Check if already exists
	overwrite := c.Query("overwrite") == "true"
	if _, err := os.Stat(targetDir); err == nil {
		if !overwrite {
			c.JSON(409, gin.H{"error": "project already exists", "path": targetDir})
			return
		}
		_ = normalizeProjectWritable(targetDir)
		// Remove existing
		if err := os.RemoveAll(targetDir); err != nil {
			c.JSON(500, gin.H{"error": fmt.Sprintf("failed to remove existing: %v", err)})
			return
		}
	}

	if err := os.MkdirAll(targetDir, 0755); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("failed to create target dir: %v", err)})
		return
	}

	// Extract tar.gz from request body
	gz, err := gzip.NewReader(c.Request.Body)
	if err != nil {
		c.JSON(400, gin.H{"error": fmt.Sprintf("not a gzip stream: %v", err)})
		return
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	fileCount := 0
	var totalSize int64

	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			c.JSON(500, gin.H{"error": fmt.Sprintf("tar read error: %v", err)})
			return
		}

		// Prevent path traversal
		cleanName := filepath.Clean(header.Name)
		if strings.HasPrefix(cleanName, "..") || strings.HasPrefix(cleanName, "/") {
			continue
		}

		target := filepath.Join(targetDir, cleanName)

		// Ensure target is still under targetDir after join (defense in depth)
		absTarget, _ := filepath.Abs(target)
		absBase, _ := filepath.Abs(targetDir)
		if !strings.HasPrefix(absTarget, absBase+string(filepath.Separator)) && absTarget != absBase {
			continue
		}

		// Reject symlinks entirely to prevent escape
		if header.Typeflag == tar.TypeSymlink || header.Typeflag == tar.TypeLink {
			linkTarget := filepath.Join(filepath.Dir(target), header.Linkname)
			absLink, _ := filepath.Abs(linkTarget)
			if !strings.HasPrefix(absLink, absBase+string(filepath.Separator)) {
				continue
			}
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0755); err != nil {
				c.JSON(500, gin.H{"error": fmt.Sprintf("mkdir: %v", err)})
				return
			}
		case tar.TypeReg:
			// Ensure parent dir
			if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
				c.JSON(500, gin.H{"error": fmt.Sprintf("mkdir parent: %v", err)})
				return
			}
			mode := os.FileMode(header.Mode & 0777)
			if mode == 0 {
				mode = 0644
			}
			mode |= 0600
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
			if err != nil {
				c.JSON(500, gin.H{"error": fmt.Sprintf("create file: %v", err)})
				return
			}
			n, err := io.Copy(f, tr)
			f.Close()
			if err != nil {
				c.JSON(500, gin.H{"error": fmt.Sprintf("write file: %v", err)})
				return
			}
			totalSize += n
			fileCount++
		case tar.TypeSymlink:
			os.MkdirAll(filepath.Dir(target), 0755)
			os.Symlink(header.Linkname, target)
		}
	}

	if err := normalizeProjectWritable(targetDir); err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("normalize project permissions: %v", err)})
		return
	}

	c.JSON(200, gin.H{
		"ok":        true,
		"path":      targetDir,
		"fileCount": fileCount,
		"totalSize": totalSize,
	})
}

// UploadImage saves an uploaded image to /tmp/planulix-images/ and returns the server path
func (s *SessionServer) UploadImage(c *gin.Context) {
	ext := c.Query("ext")
	if ext == "" {
		ext = "png"
	}
	// Whitelist extensions
	if ext != "png" && ext != "jpg" && ext != "jpeg" && ext != "gif" && ext != "webp" {
		c.JSON(400, gin.H{"error": "unsupported image type"})
		return
	}

	dir := "/tmp/planulix-images"
	os.MkdirAll(dir, 0755)

	filename := fmt.Sprintf("img-%d.%s", time.Now().UnixNano(), ext)
	path := filepath.Join(dir, filename)

	f, err := os.Create(path)
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	defer f.Close()

	n, err := io.Copy(f, c.Request.Body)
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	c.JSON(200, gin.H{
		"ok":   true,
		"path": path,
		"size": n,
	})
}

// DeleteProject removes a project directory
func (s *SessionServer) DeleteProject(c *gin.Context) {
	name := c.Query("name")
	if name == "" || strings.ContainsAny(name, "/\\..") {
		c.JSON(400, gin.H{"error": "invalid project name"})
		return
	}

	home, _ := os.UserHomeDir()
	targetDir := filepath.Join(home, "projects", name)

	if _, err := os.Stat(targetDir); os.IsNotExist(err) {
		c.JSON(404, gin.H{"error": "project not found"})
		return
	}

	_ = normalizeProjectWritable(targetDir)
	if err := os.RemoveAll(targetDir); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	c.JSON(200, gin.H{"ok": true})
}

// Ensure http package is used (for future additions)
var _ = http.StatusOK
