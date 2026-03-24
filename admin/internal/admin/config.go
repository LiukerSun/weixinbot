package admin

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	ListenAddr     string
	InstancesDir   string
	QuotaConfig    string
	ScriptsDir     string
	WebDistDir     string
	AllowedOrigins []string
	AdminUsername  string
	AdminPassword  string
}

func LoadConfig() (Config, error) {
	scriptsDir, err := discoverScriptsDir()
	if err != nil {
		return Config{}, err
	}

	webDistDir, err := discoverWebDistDir()
	if err != nil {
		return Config{}, err
	}

	instancesDir := envOrDefault("OPENCLAW_INSTANCES_DIR", "/root/openclaw-instances")
	quotaConfig := envOrDefault("OPENCLAW_QUOTA_CONFIG", filepath.Join(instancesDir, "quota-config.json"))
	adminUsername := envOrDefault("OPENCLAW_ADMIN_USERNAME", "admin")
	adminPassword := strings.TrimSpace(os.Getenv("OPENCLAW_ADMIN_PASSWORD"))
	if adminPassword == "" {
		return Config{}, errors.New("missing OPENCLAW_ADMIN_PASSWORD")
	}

	return Config{
		ListenAddr:     envOrDefault("OPENCLAW_ADMIN_LISTEN", ":8088"),
		InstancesDir:   instancesDir,
		QuotaConfig:    quotaConfig,
		ScriptsDir:     scriptsDir,
		WebDistDir:     webDistDir,
		AllowedOrigins: splitAndTrim(envOrDefault("OPENCLAW_ADMIN_ALLOWED_ORIGINS", "http://127.0.0.1:5173,http://localhost:5173")),
		AdminUsername:  adminUsername,
		AdminPassword:  adminPassword,
	}, nil
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func splitAndTrim(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}

	parts := strings.Split(raw, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		value := strings.TrimSpace(part)
		if value != "" {
			result = append(result, value)
		}
	}
	return result
}

func discoverScriptsDir() (string, error) {
	if explicit := strings.TrimSpace(os.Getenv("OPENCLAW_SCRIPTS_DIR")); explicit != "" {
		return explicit, nil
	}

	cwd, _ := os.Getwd()
	if found := findAncestorWithFile(cwd, "openclaw-stats.sh"); found != "" {
		return found, nil
	}

	execPath, err := os.Executable()
	if err == nil {
		if found := findAncestorWithFile(filepath.Dir(execPath), "openclaw-stats.sh"); found != "" {
			return found, nil
		}
	}

	return "", fmt.Errorf("unable to locate scripts directory, set OPENCLAW_SCRIPTS_DIR")
}

func discoverWebDistDir() (string, error) {
	if explicit := strings.TrimSpace(os.Getenv("OPENCLAW_ADMIN_WEB_DIST")); explicit != "" {
		return explicit, nil
	}

	cwd, _ := os.Getwd()
	if found := findAncestorWithDir(cwd, filepath.Join("admin", "web", "dist")); found != "" {
		return filepath.Join(found, "admin", "web", "dist"), nil
	}
	if found := findAncestorWithDir(cwd, filepath.Join("admin", "web")); found != "" {
		return filepath.Join(found, "admin", "web", "dist"), nil
	}

	execPath, err := os.Executable()
	if err == nil {
		if found := findAncestorWithDir(filepath.Dir(execPath), filepath.Join("admin", "web", "dist")); found != "" {
			return filepath.Join(found, "admin", "web", "dist"), nil
		}
		if found := findAncestorWithDir(filepath.Dir(execPath), filepath.Join("admin", "web")); found != "" {
			return filepath.Join(found, "admin", "web", "dist"), nil
		}
	}

	return "", fmt.Errorf("unable to locate admin/web directory, set OPENCLAW_ADMIN_WEB_DIST")
}

func findAncestorWithFile(startDir, fileName string) string {
	current := filepath.Clean(startDir)

	for {
		candidate := filepath.Join(current, fileName)
		if stat, err := os.Stat(candidate); err == nil && !stat.IsDir() {
			return current
		}

		parent := filepath.Dir(current)
		if parent == current {
			return ""
		}
		current = parent
	}
}

func findAncestorWithDir(startDir, relativeDir string) string {
	current := filepath.Clean(startDir)

	for {
		candidate := filepath.Join(current, relativeDir)
		if stat, err := os.Stat(candidate); err == nil && stat.IsDir() {
			return current
		}

		parent := filepath.Dir(current)
		if parent == current {
			return ""
		}
		current = parent
	}
}
