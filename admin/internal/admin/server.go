package admin

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

type Server struct {
	cfg       Config
	mux       *http.ServeMux
	fileMutex sync.Mutex
}

func NewServer(cfg Config) (*Server, error) {
	server := &Server{
		cfg: cfg,
		mux: http.NewServeMux(),
	}

	server.routes()
	return server, nil
}

func (s *Server) Handler() http.Handler {
	return s.withCORS(s.withBasicAuth(s.mux))
}

func (s *Server) routes() {
	s.mux.HandleFunc("/api/healthz", s.handleHealthz)
	s.mux.HandleFunc("/api/instances", s.handleInstances)
	s.mux.HandleFunc("/api/instances/", s.handleInstanceActions)
	s.mux.Handle("/", s.handleFrontend())
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]any{
		"ok":        true,
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *Server) handleInstances(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		response, err := s.buildInstancesResponse(r.Context())
		if err != nil {
			s.writeError(w, http.StatusInternalServerError, err)
			return
		}
		s.writeJSON(w, http.StatusOK, response)
	case http.MethodPost:
		var request CreateInstanceRequest
		if err := decodeJSONBody(r, &request); err != nil {
			s.writeError(w, http.StatusBadRequest, err)
			return
		}

		result, err := s.createInstance(r.Context(), request)
		if err != nil {
			s.writeError(w, http.StatusBadRequest, err)
			return
		}
		s.writeJSON(w, http.StatusCreated, result)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleInstanceActions(w http.ResponseWriter, r *http.Request) {
	pathValue := strings.TrimPrefix(r.URL.Path, "/api/instances/")
	pathValue = strings.Trim(pathValue, "/")
	if pathValue == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	parts := strings.Split(pathValue, "/")
	instanceName := parts[0]
	if instanceName == "" {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	if len(parts) == 1 && r.Method == http.MethodGet {
		view, err := s.getInstanceView(r.Context(), instanceName)
		if err != nil {
			s.writeError(w, http.StatusNotFound, err)
			return
		}
		s.writeJSON(w, http.StatusOK, view)
		return
	}

	if len(parts) != 2 || r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var (
		result any
		err    error
	)

	switch parts[1] {
	case "pause":
		result, err = s.instanceComposeAction(r.Context(), instanceName, "stop", "openclaw-gateway")
	case "resume":
		result, err = s.instanceComposeAction(r.Context(), instanceName, "up", "-d", "openclaw-gateway")
	case "restart":
		result, err = s.instanceComposeAction(r.Context(), instanceName, "restart", "openclaw-gateway")
	case "quota":
		var request QuotaUpdateRequest
		if err = decodeJSONBody(r, &request); err == nil {
			result, err = s.updateQuota(r.Context(), instanceName, request)
		}
	default:
		http.NotFound(w, r)
		return
	}

	if err != nil {
		s.writeError(w, http.StatusBadRequest, err)
		return
	}

	s.writeJSON(w, http.StatusOK, result)
}

func (s *Server) buildInstancesResponse(ctx context.Context) (ListInstancesResponse, error) {
	stats, err := s.runStats(ctx, "")
	if err != nil {
		return ListInstancesResponse{}, err
	}

	quotaConfig, err := loadQuotaConfig(s.cfg.QuotaConfig)
	if err != nil {
		return ListInstancesResponse{}, err
	}

	response := ListInstancesResponse{
		GeneratedAt:      time.Now().UTC().Format(time.RFC3339),
		Instances:        make([]InstanceView, 0, len(stats.Instances)),
		Totals:           stats.Totals,
		ScannedInstances: stats.ScannedInstances,
		QuotaConfigPath:  s.cfg.QuotaConfig,
	}

	for _, instance := range stats.Instances {
		view, err := s.composeInstanceView(ctx, instance, quotaConfig)
		if err != nil {
			return ListInstancesResponse{}, err
		}
		response.Instances = append(response.Instances, view)
	}

	slices.SortFunc(response.Instances, func(left, right InstanceView) int {
		if left.Stats.Totals.TotalTokens == right.Stats.Totals.TotalTokens {
			return strings.Compare(left.Stats.Instance, right.Stats.Instance)
		}
		if left.Stats.Totals.TotalTokens > right.Stats.Totals.TotalTokens {
			return -1
		}
		return 1
	})

	return response, nil
}

func (s *Server) getInstanceView(ctx context.Context, instanceName string) (InstanceView, error) {
	stats, err := s.runStats(ctx, instanceName)
	if err != nil {
		return InstanceView{}, err
	}
	if len(stats.Instances) == 0 {
		return InstanceView{}, fmt.Errorf("instance not found: %s", instanceName)
	}

	quotaConfig, err := loadQuotaConfig(s.cfg.QuotaConfig)
	if err != nil {
		return InstanceView{}, err
	}

	return s.composeInstanceView(ctx, stats.Instances[0], quotaConfig)
}

func (s *Server) composeInstanceView(ctx context.Context, instance InstanceStats, quotaConfig QuotaConfig) (InstanceView, error) {
	quotaSource := quotaConfig.Instances[instance.Instance]
	effectiveQuota := mergeQuotaPolicy(quotaConfig.Defaults, quotaSource)
	quotaUsage := map[string]int64{}
	quotaExceeded := map[string]bool{}
	quotaRatio := map[string]float64{}

	if len(effectiveQuota.Limits) > 0 && effectiveQuota.Validity.Active {
		usageByWindow, err := s.loadQuotaUsage(ctx, instance.Instance, effectiveQuota)
		if err != nil {
			return InstanceView{}, err
		}
		for window, limit := range effectiveQuota.Limits {
			usage := usageByWindow[window]
			quotaUsage[window] = usage
			quotaExceeded[window] = usage >= limit
			if limit > 0 {
				quotaRatio[window] = float64(usage) / float64(limit)
			}
		}
	}
	if status := effectiveQuota.Validity.Status; status == "upcoming" || status == "expired" || status == "invalid" {
		quotaExceeded["validity"] = true
	}

	var quotaState *QuotaState
	statePath := filepath.Join(instance.Path, "state", "quota-controller.json")
	if data, err := os.ReadFile(statePath); err == nil {
		var parsed QuotaState
		if json.Unmarshal(data, &parsed) == nil {
			quotaState = &parsed
		}
	}

	var topModel *ModelSummary
	if len(instance.Models) > 0 {
		value := instance.Models[0]
		topModel = &value
	}

	return InstanceView{
		Stats:          instance,
		Quota:          effectiveQuota,
		QuotaState:     quotaState,
		QuotaUsage:     quotaUsage,
		QuotaExceeded:  quotaExceeded,
		QuotaRatio:     quotaRatio,
		QuotaSource:    quotaSource,
		DefaultQuota:   quotaConfig.Defaults,
		RecentTopModel: topModel,
		Actions: map[string]ActionHint{
			"pause":   {Label: "Pause", Method: "POST", Path: fmt.Sprintf("/api/instances/%s/pause", instance.Instance)},
			"resume":  {Label: "Resume", Method: "POST", Path: fmt.Sprintf("/api/instances/%s/resume", instance.Instance)},
			"restart": {Label: "Restart", Method: "POST", Path: fmt.Sprintf("/api/instances/%s/restart", instance.Instance)},
			"quota":   {Label: "Quota", Method: "POST", Path: fmt.Sprintf("/api/instances/%s/quota", instance.Instance)},
		},
	}, nil
}

func (s *Server) loadQuotaUsage(ctx context.Context, instance string, quota EffectiveQuota) (map[string]int64, error) {
	windows := windowsFromEffectiveQuota(quota)
	result := make(map[string]int64, len(windows))
	now := time.Now()
	var validFrom time.Time
	if quota.Validity.StartDate != "" {
		if parsed, ok := parseQuotaDate(quota.Validity.StartDate); ok {
			validFrom = parsed
		}
	}
	var currentPeriodStart time.Time
	if quota.Validity.CurrentPeriodStart != "" {
		if parsed, ok := parseQuotaDate(quota.Validity.CurrentPeriodStart); ok {
			currentPeriodStart = parsed
		}
	}

	for _, window := range windows {
		switch window {
		case "daily":
			dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
			since := maxQuotaDate(dayStart, validFrom)
			stats, err := s.runStatsWithArgs(ctx, instance, []string{"--since", since.Format(quotaDateLayout)})
			if err != nil {
				return nil, err
			}
			result[window] = stats.Totals.TotalTokens
		case "monthly":
			since := currentPeriodStart
			if since.IsZero() {
				monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
				since = maxQuotaDate(monthStart, validFrom)
			}
			stats, err := s.runStatsWithArgs(ctx, instance, []string{"--since", since.Format(quotaDateLayout)})
			if err != nil {
				return nil, err
			}
			result[window] = stats.Totals.TotalTokens
		case "total":
			extraArgs := []string{}
			if !validFrom.IsZero() {
				extraArgs = append(extraArgs, "--since", validFrom.Format(quotaDateLayout))
			}
			stats, err := s.runStatsWithArgs(ctx, instance, extraArgs)
			if err != nil {
				return nil, err
			}
			result[window] = stats.Totals.TotalTokens
		}
	}

	return result, nil
}

func (s *Server) runStats(ctx context.Context, instance string) (StatsSummary, error) {
	return s.runStatsWithArgs(ctx, instance, nil)
}

func (s *Server) runStatsWithArgs(ctx context.Context, instance string, extraArgs []string) (StatsSummary, error) {
	args := []string{"--json", "--base-dir", s.cfg.InstancesDir}
	if instance != "" {
		args = append(args, "--instance", instance)
	}
	args = append(args, extraArgs...)

	output, err := s.runCommand(ctx, filepath.Join(s.cfg.ScriptsDir, "openclaw-stats.sh"), args...)
	if err != nil {
		return StatsSummary{}, err
	}

	var summary StatsSummary
	if err := json.Unmarshal(output, &summary); err != nil {
		return StatsSummary{}, err
	}
	return summary, nil
}

func (s *Server) updateQuota(ctx context.Context, instance string, request QuotaUpdateRequest) (InstanceView, error) {
	s.fileMutex.Lock()
	defer s.fileMutex.Unlock()

	cfg, err := loadQuotaConfig(s.cfg.QuotaConfig)
	if err != nil {
		return InstanceView{}, err
	}

	policy := cfg.Instances[instance]
	if policy == nil {
		policy = &QuotaPolicy{}
		cfg.Instances[instance] = policy
	}

	if err := applyQuotaUpdate(policy, request); err != nil {
		return InstanceView{}, err
	}

	if err := saveQuotaConfig(s.cfg.QuotaConfig, cfg); err != nil {
		return InstanceView{}, err
	}

	_, _ = s.runCommand(ctx, filepath.Join(s.cfg.ScriptsDir, "openclaw-quota-control.sh"), "check", "--config", s.cfg.QuotaConfig, "--base-dir", s.cfg.InstancesDir, "--instance", instance)

	return s.getInstanceView(ctx, instance)
}

func (s *Server) instanceComposeAction(ctx context.Context, instance string, composeArgs ...string) (ActionResponse, error) {
	instanceDir := filepath.Join(s.cfg.InstancesDir, instance)
	composeFile := filepath.Join(instanceDir, "docker-compose.yml")
	if _, err := os.Stat(composeFile); err != nil {
		return ActionResponse{}, fmt.Errorf("instance not found: %s", instance)
	}

	commandArgs, err := s.composeArgs(composeFile, composeArgs...)
	if err != nil {
		return ActionResponse{}, err
	}

	if _, err := s.runCommand(ctx, commandArgs[0], commandArgs[1:]...); err != nil {
		return ActionResponse{}, err
	}

	return ActionResponse{
		OK:       true,
		Message:  fmt.Sprintf("%s %s", instance, strings.Join(composeArgs, " ")),
		Instance: instance,
		Command:  strings.Join(commandArgs, " "),
	}, nil
}

func (s *Server) createInstance(ctx context.Context, request CreateInstanceRequest) (InstanceView, error) {
	name := strings.TrimSpace(request.Name)
	if name == "" {
		return InstanceView{}, errors.New("name is required")
	}

	gatewayPort := strings.TrimSpace(request.GatewayPort)
	if gatewayPort == "" {
		gatewayPort = "auto"
	}
	bridgePort := strings.TrimSpace(request.BridgePort)
	if bridgePort == "" {
		bridgePort = "auto"
	}

	args := []string{name, gatewayPort, bridgePort}
	withWeixin := true
	if request.WithWeixin != nil {
		withWeixin = *request.WithWeixin
	}
	if withWeixin {
		args = append(args, "--with-weixin")
	} else {
		args = append(args, "--without-weixin")
	}

	skipLogin := true
	if request.SkipWeixinLogin != nil {
		skipLogin = *request.SkipWeixinLogin
	}
	if skipLogin {
		args = append(args, "--skip-weixin-login")
	}

	provider := strings.TrimSpace(request.PrimaryModelProvider)
	if provider == "" {
		provider = "zai"
	}
	args = append(args, "--primary-model-provider", provider)

	appendIfValue := func(flag, value string) {
		if strings.TrimSpace(value) != "" {
			args = append(args, flag, strings.TrimSpace(value))
		}
	}

	appendIfValue("--zai-api-key", request.ZAIAPIKey)
	appendIfValue("--zai-model", request.ZAIModel)
	appendIfValue("--openai-api-key", request.OpenAIAPIKey)
	appendIfValue("--openai-base-url", request.OpenAIBaseURL)
	appendIfValue("--openai-model", request.OpenAIModel)
	appendIfValue("--brave-api-key", request.BraveAPIKey)

	if _, err := s.runCommand(ctx, filepath.Join(s.cfg.ScriptsDir, "create-openclaw-instance.sh"), args...); err != nil {
		return InstanceView{}, err
	}

	if request.Quota != nil {
		if _, err := s.updateQuota(ctx, name, *request.Quota); err != nil {
			return InstanceView{}, err
		}
	}

	return s.getInstanceView(ctx, name)
}

func (s *Server) composeArgs(composeFile string, commandArgs ...string) ([]string, error) {
	if _, err := exec.LookPath("docker-compose"); err == nil {
		return append([]string{"docker-compose", "-f", composeFile}, commandArgs...), nil
	}

	if _, err := exec.LookPath("docker"); err == nil {
		if _, err := s.runCommand(context.Background(), "docker", "compose", "version"); err == nil {
			return append([]string{"docker", "compose", "-f", composeFile}, commandArgs...), nil
		}
	}

	return nil, errors.New("docker compose is not available")
}

func (s *Server) runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	command.Env = append(os.Environ(), fmt.Sprintf("OPENCLAW_INSTANCES_DIR=%s", s.cfg.InstancesDir))

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Run(); err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = strings.TrimSpace(stdout.String())
		}
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("%s %s failed: %s", name, strings.Join(args, " "), message)
	}

	return stdout.Bytes(), nil
}

func (s *Server) handleFrontend() http.Handler {
	fileServer := http.FileServer(http.Dir(s.cfg.WebDistDir))
	indexFile := filepath.Join(s.cfg.WebDistDir, "index.html")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}

		cleanPath := strings.TrimPrefix(filepath.Clean(r.URL.Path), string(filepath.Separator))
		targetPath := filepath.Join(s.cfg.WebDistDir, cleanPath)
		if stat, err := os.Stat(targetPath); err == nil && !stat.IsDir() {
			fileServer.ServeHTTP(w, r)
			return
		}

		file, err := os.Open(indexFile)
		if err != nil {
			http.Error(w, "frontend build not found", http.StatusInternalServerError)
			return
		}
		defer file.Close()

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = io.Copy(w, file)
	})
}

func (s *Server) withCORS(next http.Handler) http.Handler {
	allowed := map[string]bool{}
	for _, origin := range s.cfg.AllowedOrigins {
		allowed[origin] = true
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && allowed[origin] {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
		}

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func (s *Server) withBasicAuth(next http.Handler) http.Handler {
	realm := `Basic realm="OpenClaw Admin"`

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/healthz" {
			next.ServeHTTP(w, r)
			return
		}

		username, password, ok := r.BasicAuth()
		if ok &&
			subtle.ConstantTimeCompare([]byte(username), []byte(s.cfg.AdminUsername)) == 1 &&
			subtle.ConstantTimeCompare([]byte(password), []byte(s.cfg.AdminPassword)) == 1 {
			next.ServeHTTP(w, r)
			return
		}

		w.Header().Set("WWW-Authenticate", realm)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	})
}

func decodeJSONBody(r *http.Request, target any) error {
	defer r.Body.Close()

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	return nil
}

func (s *Server) writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func (s *Server) writeError(w http.ResponseWriter, status int, err error) {
	s.writeJSON(w, status, map[string]any{
		"ok":    false,
		"error": err.Error(),
	})
}
