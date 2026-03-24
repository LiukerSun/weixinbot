package admin

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	weixinLoginOutputLimit = 16000
	weixinLoginPollWindow  = 10 * time.Second
)

type weixinLoginSession struct {
	Instance    string
	ComposeFile string
	StartedAt   time.Time
	UpdatedAt   time.Time
	FinishedAt  time.Time
	Active      bool
	Connected   bool
	Status      string
	Message     string
	QRURL       string
	Output      string
	cancel      context.CancelFunc
	done        chan struct{}
}

type weixinGatewayLogEntry struct {
	Message string `json:"1"`
	Meta    struct {
		Date string `json:"date"`
	} `json:"_meta"`
}

func (s *Server) weixinLoginStatus(ctx context.Context, instance string) (WeixinLoginStatusResponse, error) {
	if _, err := s.instanceComposeFile(instance); err != nil {
		return WeixinLoginStatusResponse{}, err
	}
	s.refreshWeixinLoginQRCode(ctx, instance)
	return s.snapshotWeixinLogin(instance), nil
}

func (s *Server) startWeixinLogin(instance string, force bool) (WeixinLoginStatusResponse, error) {
	composeFile, err := s.instanceComposeFile(instance)
	if err != nil {
		return WeixinLoginStatusResponse{}, err
	}
	if err := s.ensureWeixinPluginReady(context.Background(), instance, composeFile); err != nil {
		return WeixinLoginStatusResponse{}, err
	}

	s.weixinMu.Lock()
	if existing := s.weixinQR[instance]; existing != nil && existing.Active {
		if !force {
			s.weixinMu.Unlock()
			s.refreshWeixinLoginQRCode(context.Background(), instance)
			return s.snapshotWeixinLogin(instance), nil
		}
		existing.cancel()
	}

	sessionCtx, cancel := context.WithCancel(context.Background())
	session := &weixinLoginSession{
		Instance:    instance,
		ComposeFile: composeFile,
		StartedAt:   time.Now().UTC(),
		UpdatedAt:   time.Now().UTC(),
		Active:      true,
		Status:      "starting",
		Message:     "正在生成微信二维码...",
		cancel:      cancel,
		done:        make(chan struct{}),
	}
	s.weixinQR[instance] = session
	s.weixinMu.Unlock()

	go s.runWeixinLogin(sessionCtx, session)

	deadline := time.Now().Add(weixinLoginPollWindow)
	for time.Now().Before(deadline) {
		s.refreshWeixinLoginQRCode(context.Background(), instance)
		response := s.snapshotWeixinLogin(instance)
		if response.QRURL != "" || !response.Active || response.Status == "connected" || response.Status == "error" {
			return response, nil
		}
		time.Sleep(300 * time.Millisecond)
	}

	return s.snapshotWeixinLogin(instance), nil
}

func (s *Server) ensureWeixinPluginReady(ctx context.Context, instance string, composeFile string) error {
	instanceDir := filepath.Join(s.cfg.InstancesDir, instance)
	extensionDir := filepath.Join(instanceDir, "state", "extensions", "openclaw-weixin")
	configPath := filepath.Join(instanceDir, "state", "openclaw.json")
	needsRepair := false

	if _, err := os.Stat(extensionDir); errors.Is(err, os.ErrNotExist) {
		needsRepair = true
		installCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
		defer cancel()
		commandArgs, cmdErr := s.composeArgs(
			composeFile,
			"run",
			"-T",
			"--rm",
			"--no-deps",
			"openclaw-cli",
			"plugins",
			"install",
			"@tencent-weixin/openclaw-weixin",
		)
		if cmdErr != nil {
			return cmdErr
		}
		if _, cmdErr = s.runCommand(installCtx, commandArgs[0], commandArgs[1:]...); cmdErr != nil {
			if _, statErr := os.Stat(extensionDir); statErr == nil {
				needsRepair = true
			} else {
				return fmt.Errorf("install weixin plugin for %s: %w", instance, cmdErr)
			}
		}
	} else if err != nil {
		return err
	}

	ok, err := weixinPluginConfigured(configPath)
	if err != nil {
		return err
	}
	if !ok {
		needsRepair = true
	}

	if !needsRepair {
		return nil
	}

	if _, err := s.runCommand(
		ctx,
		filepath.Join(s.cfg.ScriptsDir, "create-openclaw-instance.sh"),
		"--sync-instance-config",
		instanceDir,
	); err != nil {
		return fmt.Errorf("sync weixin config for %s: %w", instance, err)
	}

	commandArgs, err := s.composeArgs(composeFile, "restart", "openclaw-gateway")
	if err != nil {
		return err
	}
	if _, err := s.runCommand(ctx, commandArgs[0], commandArgs[1:]...); err != nil {
		return fmt.Errorf("restart gateway for %s: %w", instance, err)
	}

	services, err := s.instanceComposeServices(ctx, composeFile)
	if err != nil {
		return nil
	}
	if len(services) == 0 || !strings.Contains(strings.Join(services, ","), "openclaw-gateway") {
		return nil
	}

	waitCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	for {
		select {
		case <-waitCtx.Done():
			return fmt.Errorf("gateway restart timeout for %s", instance)
		default:
		}

		checkArgs, err := s.composeArgs(
			composeFile,
			"exec",
			"-T",
			"openclaw-gateway",
			"node",
			"-e",
			"fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
		)
		if err == nil {
			if _, err = s.runCommand(waitCtx, checkArgs[0], checkArgs[1:]...); err == nil {
				return nil
			}
		}
		time.Sleep(1 * time.Second)
	}
}

func weixinPluginConfigured(configPath string) (bool, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return false, err
	}

	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		return false, err
	}

	plugins, _ := config["plugins"].(map[string]any)
	if len(plugins) == 0 {
		return false, nil
	}

	allowList, _ := plugins["allow"].([]any)
	allowed := false
	for _, item := range allowList {
		if strings.TrimSpace(fmt.Sprint(item)) == "openclaw-weixin" {
			allowed = true
			break
		}
	}
	if !allowed {
		return false, nil
	}

	entries, _ := plugins["entries"].(map[string]any)
	entry, _ := entries["openclaw-weixin"].(map[string]any)
	enabled, _ := entry["enabled"].(bool)
	return enabled, nil
}

func (s *Server) stopWeixinLogin(instance string) (WeixinLoginStatusResponse, error) {
	if _, err := s.instanceComposeFile(instance); err != nil {
		return WeixinLoginStatusResponse{}, err
	}

	s.weixinMu.Lock()
	session := s.weixinQR[instance]
	s.weixinMu.Unlock()

	if session != nil && session.Active {
		session.cancel()
		select {
		case <-session.done:
		case <-time.After(3 * time.Second):
		}
	}

	return s.snapshotWeixinLogin(instance), nil
}

func (s *Server) runWeixinLogin(ctx context.Context, session *weixinLoginSession) {
	commandArgs, err := s.composeArgs(
		session.ComposeFile,
		"exec",
		"-T",
		"openclaw-gateway",
		"node",
		"dist/index.js",
		"channels",
		"login",
		"--channel",
		"openclaw-weixin",
		"--verbose",
		"--no-color",
	)
	if err != nil {
		s.finishWeixinLogin(session, "error", fmt.Sprintf("无法启动微信登录: %s", err), false)
		return
	}

	cmd := exec.CommandContext(ctx, commandArgs[0], commandArgs[1:]...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		s.finishWeixinLogin(session, "error", fmt.Sprintf("无法读取微信登录输出: %s", err), false)
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		s.finishWeixinLogin(session, "error", fmt.Sprintf("无法读取微信登录错误输出: %s", err), false)
		return
	}

	if err := cmd.Start(); err != nil {
		s.finishWeixinLogin(session, "error", fmt.Sprintf("无法执行微信登录命令: %s", err), false)
		return
	}

	go s.consumeWeixinLoginOutput(session, stdout)
	go s.consumeWeixinLoginOutput(session, stderr)

	waitErr := cmd.Wait()
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		s.finishWeixinLogin(session, "stopped", "微信登录已停止", false)
	case waitErr != nil:
		s.finishWeixinLogin(session, "error", fmt.Sprintf("微信登录失败: %s", waitErr), false)
	default:
		s.finishWeixinLogin(session, "connected", "微信登录完成", true)
	}
}

func (s *Server) consumeWeixinLoginOutput(session *weixinLoginSession, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		line := strings.TrimRight(stripANSIEscapeCodes(scanner.Text()), "\r")
		if line == "" {
			continue
		}

		s.weixinMu.Lock()
		session.UpdatedAt = time.Now().UTC()
		session.Output = appendTrimmedOutput(session.Output, line)
		switch {
		case strings.Contains(line, "正在启动微信扫码登录"):
			session.Status = "starting"
			session.Message = "正在生成微信二维码..."
		case strings.Contains(line, "使用微信扫描以下二维码"):
			session.Status = "qr_ready"
			if session.Message == "" {
				session.Message = "二维码已就绪，请使用微信扫描。"
			}
		case strings.Contains(line, "等待连接结果"):
			session.Status = "waiting_scan"
			session.Message = "二维码已就绪，请使用微信扫描。"
		case strings.Contains(line, "已扫码"):
			session.Status = "scanned"
			session.Message = "已扫码，请在微信中确认登录。"
		case strings.Contains(line, "二维码已过期"):
			session.Status = "refreshing"
			session.Message = "二维码已过期，正在刷新..."
		case strings.Contains(line, "新二维码已生成"):
			session.Status = "qr_ready"
			session.Message = "已生成新的二维码，请重新扫描。"
		}
		s.weixinMu.Unlock()
	}
}

func (s *Server) finishWeixinLogin(session *weixinLoginSession, status string, message string, connected bool) {
	s.weixinMu.Lock()
	defer s.weixinMu.Unlock()

	session.Active = false
	session.Connected = connected
	session.Status = status
	session.Message = message
	session.UpdatedAt = time.Now().UTC()
	session.FinishedAt = session.UpdatedAt

	select {
	case <-session.done:
	default:
		close(session.done)
	}
}

func appendTrimmedOutput(current string, line string) string {
	next := strings.TrimSpace(line)
	if next == "" {
		return current
	}
	if current == "" {
		return trimToLastRunes(next, weixinLoginOutputLimit)
	}

	joined := current + "\n" + next
	return trimToLastRunes(joined, weixinLoginOutputLimit)
}

func trimToLastRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[len(runes)-limit:])
}

func (s *Server) refreshWeixinLoginQRCode(ctx context.Context, instance string) {
	s.weixinMu.Lock()
	session := s.weixinQR[instance]
	s.weixinMu.Unlock()

	if session == nil {
		return
	}

	qrURL, err := s.latestWeixinQRCode(ctx, session.ComposeFile, session.StartedAt.Add(-5*time.Second))
	if err != nil || qrURL == "" {
		return
	}

	s.weixinMu.Lock()
	if current := s.weixinQR[instance]; current == session {
		current.QRURL = qrURL
		current.UpdatedAt = time.Now().UTC()
		if current.Active && (current.Status == "" || current.Status == "starting") {
			current.Status = "qr_ready"
			current.Message = "二维码已就绪，请使用微信扫描。"
		}
	}
	s.weixinMu.Unlock()
}

func (s *Server) latestWeixinQRCode(ctx context.Context, composeFile string, since time.Time) (string, error) {
	commandArgs, err := s.composeArgs(
		composeFile,
		"exec",
		"-T",
		"openclaw-gateway",
		"sh",
		"-lc",
		`LOG=$(ls -1 /tmp/openclaw/openclaw-*.log 2>/dev/null | tail -n 1); if [ -n "$LOG" ]; then tail -n 400 "$LOG"; fi`,
	)
	if err != nil {
		return "", err
	}

	output, err := s.runCommand(ctx, commandArgs[0], commandArgs[1:]...)
	if err != nil {
		return "", err
	}

	var latestURL string
	var latestAt time.Time
	for _, line := range splitLinesUnique(string(output)) {
		var entry weixinGatewayLogEntry
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			continue
		}
		if !strings.HasPrefix(entry.Message, "二维码链接: ") {
			continue
		}

		loggedAt, err := time.Parse(time.RFC3339, entry.Meta.Date)
		if err != nil {
			continue
		}
		if loggedAt.Before(since) {
			continue
		}

		qrURL := strings.TrimSpace(strings.TrimPrefix(entry.Message, "二维码链接: "))
		if qrURL == "" || loggedAt.Before(latestAt) {
			continue
		}
		latestAt = loggedAt
		latestURL = qrURL
	}

	return latestURL, nil
}

func (s *Server) snapshotWeixinLogin(instance string) WeixinLoginStatusResponse {
	s.weixinMu.Lock()
	defer s.weixinMu.Unlock()

	response := WeixinLoginStatusResponse{
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Instance:    instance,
		Status:      "idle",
		Message:     "当前没有进行中的微信登录。",
	}

	session := s.weixinQR[instance]
	if session == nil {
		return response
	}

	response.Active = session.Active
	response.Connected = session.Connected
	response.Status = session.Status
	response.Message = session.Message
	response.QRURL = session.QRURL
	response.Output = session.Output
	response.StartedAt = session.StartedAt.Format(time.RFC3339)
	response.UpdatedAt = session.UpdatedAt.Format(time.RFC3339)
	if !session.FinishedAt.IsZero() {
		response.FinishedAt = session.FinishedAt.Format(time.RFC3339)
	}
	if response.Status == "" {
		response.Status = "idle"
	}
	if response.Message == "" {
		if response.Active {
			response.Message = "微信登录进行中。"
		} else {
			response.Message = "当前没有进行中的微信登录。"
		}
	}

	return response
}
