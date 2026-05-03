package main

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/gin-gonic/gin"
)

const yadiskBase = "https://cloud-api.yandex.net/v1/disk"

// yadiskToken returns the OAuth token from env or empty string
func yadiskToken() string {
	return os.Getenv("YANDEX_DISK_TOKEN")
}

func yadiskHeaders() http.Header {
	h := http.Header{}
	h.Set("Authorization", "OAuth "+yadiskToken())
	h.Set("Accept", "application/json")
	return h
}

// GetNetworkInfo returns available interfaces (tailscale, amnezia, etc.)
func (s *SessionServer) GetNetworkInfo(c *gin.Context) {
	ifaces, _ := net.Interfaces()
	type IfaceInfo struct {
		Name string   `json:"name"`
		IPs  []string `json:"ips"`
		Kind string   `json:"kind"` // "public", "tailscale", "amnezia", "docker", "loopback", "other"
	}
	result := make([]IfaceInfo, 0)
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		var ips []string
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && ipnet.IP.To4() != nil {
				ips = append(ips, ipnet.IP.String())
			}
		}
		if len(ips) == 0 {
			continue
		}
		kind := "other"
		name := iface.Name
		if name == "lo" {
			kind = "loopback"
		} else if strings.HasPrefix(name, "tailscale") || strings.HasPrefix(name, "ts-") {
			kind = "tailscale"
		} else if strings.HasPrefix(name, "amn") || strings.HasPrefix(name, "wg") {
			kind = "amnezia"
		} else if strings.HasPrefix(name, "docker") || strings.HasPrefix(name, "br-") {
			kind = "docker"
		} else if strings.HasPrefix(name, "ens") || strings.HasPrefix(name, "eth") {
			kind = "public"
		}
		result = append(result, IfaceInfo{Name: name, IPs: ips, Kind: kind})
	}

	// Check port 8990 binding
	c.JSON(200, gin.H{
		"interfaces": result,
		"port":       8990,
		"hostname":   mustHostname(),
	})
}

func mustHostname() string {
	h, _ := os.Hostname()
	return h
}

// GetDiskInfo returns remote server disk info + Yandex Disk info
func (s *SessionServer) GetDiskInfo(c *gin.Context) {
	home, _ := os.UserHomeDir()
	projectsDir := filepath.Join(home, "projects")

	var stat syscall.Statfs_t
	syscall.Statfs(projectsDir, &stat)

	total := int64(stat.Blocks) * int64(stat.Bsize)
	free := int64(stat.Bavail) * int64(stat.Bsize)
	used := total - free

	// Projects dir size (sum)
	var projectsSize int64
	filepath.Walk(projectsDir, func(_ string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if info.Mode().IsRegular() {
			projectsSize += info.Size()
		}
		return nil
	})

	result := gin.H{
		"server": gin.H{
			"total":        total,
			"used":         used,
			"free":         free,
			"projectsSize": projectsSize,
			"projectsPath": projectsDir,
		},
	}

	// Yandex Disk info
	if yadiskToken() != "" {
		if info, err := fetchYadiskInfo(); err == nil {
			result["yadisk"] = gin.H{
				"total":      info["total_space"],
				"used":       info["used_space"],
				"free":       getInt64(info, "total_space") - getInt64(info, "used_space"),
				"configured": true,
			}
		} else {
			result["yadisk"] = gin.H{"configured": false, "error": err.Error()}
		}
	} else {
		result["yadisk"] = gin.H{"configured": false}
	}

	c.JSON(200, result)
}

func getInt64(m map[string]interface{}, key string) int64 {
	if v, ok := m[key].(float64); ok {
		return int64(v)
	}
	return 0
}

func fetchYadiskInfo() (map[string]interface{}, error) {
	req, _ := http.NewRequest("GET", yadiskBase, nil)
	req.Header = yadiskHeaders()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("yadisk %d", resp.StatusCode)
	}
	var data map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data, nil
}

// GetYadiskUploadURL returns a direct upload URL for a tar.gz on Yandex Disk
// The client uploads directly to this URL, then calls /api/yadisk/import
func (s *SessionServer) GetYadiskUploadURL(c *gin.Context) {
	if yadiskToken() == "" {
		c.JSON(500, gin.H{"error": "YANDEX_DISK_TOKEN not configured"})
		return
	}

	name := c.Query("name")
	if name == "" {
		c.JSON(400, gin.H{"error": "name is required"})
		return
	}

	// Ensure folder exists
	ensureYadiskFolder("disk:/Planulix")

	diskPath := fmt.Sprintf("disk:/Planulix/%s.tar.gz", name)

	u := fmt.Sprintf("%s/resources/upload?path=%s&overwrite=true", yadiskBase, url.QueryEscape(diskPath))
	req, _ := http.NewRequest("GET", u, nil)
	req.Header = yadiskHeaders()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		c.JSON(resp.StatusCode, gin.H{"error": fmt.Sprintf("yadisk %d: %s", resp.StatusCode, string(body))})
		return
	}

	var data map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	c.JSON(200, gin.H{
		"href":     data["href"],
		"diskPath": diskPath,
	})
}

func ensureYadiskFolder(diskPath string) {
	u := fmt.Sprintf("%s/resources?path=%s", yadiskBase, url.QueryEscape(diskPath))
	req, _ := http.NewRequest("PUT", u, nil)
	req.Header = yadiskHeaders()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	resp.Body.Close()
}

// ImportFromYadisk downloads a tar.gz from Yandex Disk and extracts it
func (s *SessionServer) ImportFromYadisk(c *gin.Context) {
	if yadiskToken() == "" {
		c.JSON(500, gin.H{"error": "YANDEX_DISK_TOKEN not configured"})
		return
	}

	var req struct {
		DiskPath  string `json:"diskPath"`
		Name      string `json:"name"`
		Overwrite bool   `json:"overwrite"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": "invalid request"})
		return
	}
	if req.DiskPath == "" || req.Name == "" {
		c.JSON(400, gin.H{"error": "diskPath and name required"})
		return
	}
	if strings.ContainsAny(req.Name, "/\\..") {
		c.JSON(400, gin.H{"error": "invalid name"})
		return
	}

	home, _ := os.UserHomeDir()
	targetDir := filepath.Join(home, "projects", req.Name)

	if _, err := os.Stat(targetDir); err == nil {
		if !req.Overwrite {
			c.JSON(409, gin.H{"error": "project already exists", "path": targetDir})
			return
		}
		os.RemoveAll(targetDir)
	}
	os.MkdirAll(targetDir, 0755)

	// Get download href
	u := fmt.Sprintf("%s/resources/download?path=%s", yadiskBase, url.QueryEscape(req.DiskPath))
	dReq, _ := http.NewRequest("GET", u, nil)
	dReq.Header = yadiskHeaders()
	dResp, err := http.DefaultClient.Do(dReq)
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	defer dResp.Body.Close()

	if dResp.StatusCode != 200 {
		body, _ := io.ReadAll(dResp.Body)
		c.JSON(500, gin.H{"error": fmt.Sprintf("yadisk download %d: %s", dResp.StatusCode, string(body))})
		return
	}

	var dData map[string]interface{}
	if err := json.NewDecoder(dResp.Body).Decode(&dData); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	href, _ := dData["href"].(string)
	if href == "" {
		c.JSON(500, gin.H{"error": "no download href"})
		return
	}

	// Fetch the file
	fResp, err := http.Get(href)
	if err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}
	defer fResp.Body.Close()

	// Extract tar.gz stream
	gz, err := gzip.NewReader(fResp.Body)
	if err != nil {
		c.JSON(500, gin.H{"error": fmt.Sprintf("gzip: %v", err)})
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
			c.JSON(500, gin.H{"error": fmt.Sprintf("tar: %v", err)})
			return
		}

		cleanName := filepath.Clean(header.Name)
		if strings.HasPrefix(cleanName, "..") || strings.HasPrefix(cleanName, "/") {
			continue
		}
		target := filepath.Join(targetDir, cleanName)

		// Defense in depth: ensure target is under targetDir
		absTarget, _ := filepath.Abs(target)
		absBase, _ := filepath.Abs(targetDir)
		if !strings.HasPrefix(absTarget, absBase+string(filepath.Separator)) && absTarget != absBase {
			continue
		}

		switch header.Typeflag {
		case tar.TypeDir:
			os.MkdirAll(target, 0755)
		case tar.TypeReg:
			os.MkdirAll(filepath.Dir(target), 0755)
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode&0777))
			if err != nil {
				continue
			}
			n, _ := io.Copy(f, tr)
			f.Close()
			totalSize += n
			fileCount++
		case tar.TypeSymlink, tar.TypeLink:
			// Only allow symlinks that stay within the project
			linkTarget := filepath.Join(filepath.Dir(target), header.Linkname)
			absLink, _ := filepath.Abs(linkTarget)
			if !strings.HasPrefix(absLink, absBase+string(filepath.Separator)) {
				continue
			}
			os.MkdirAll(filepath.Dir(target), 0755)
			os.Symlink(header.Linkname, target)
		}
	}

	// Optional: delete archive from Yandex Disk after successful import
	go deleteYadiskFile(req.DiskPath)

	c.JSON(200, gin.H{
		"ok":        true,
		"path":      targetDir,
		"fileCount": fileCount,
		"totalSize": totalSize,
	})
}

func deleteYadiskFile(diskPath string) {
	u := fmt.Sprintf("%s/resources?path=%s&permanently=true", yadiskBase, url.QueryEscape(diskPath))
	req, _ := http.NewRequest("DELETE", u, nil)
	req.Header = yadiskHeaders()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	resp.Body.Close()
}
