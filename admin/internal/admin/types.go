package admin

type UsageTotals struct {
	Input       int64 `json:"input"`
	Output      int64 `json:"output"`
	CacheRead   int64 `json:"cacheRead"`
	CacheWrite  int64 `json:"cacheWrite"`
	TotalTokens int64 `json:"totalTokens"`
}

type ContainerStats struct {
	Total   int `json:"total"`
	Running int `json:"running"`
	Exited  int `json:"exited"`
	Other   int `json:"other"`
}

type ModelSummary struct {
	Provider          string      `json:"provider"`
	Model             string      `json:"model"`
	ModelRef          string      `json:"modelRef"`
	AssistantMessages int64       `json:"assistantMessages"`
	Totals            UsageTotals `json:"totals"`
}

type RecentModelInfo struct {
	Provider  string `json:"provider"`
	Model     string `json:"model"`
	ModelRef  string `json:"modelRef"`
	Timestamp string `json:"timestamp,omitempty"`
}

type InstanceStats struct {
	Instance               string           `json:"instance"`
	Path                   string           `json:"path"`
	ConfiguredPrimaryModel string           `json:"configuredPrimaryModel"`
	RecentModel            *RecentModelInfo `json:"recentModel,omitempty"`
	ContainerStats         ContainerStats   `json:"containerStats"`
	GatewayState           string           `json:"gatewayState"`
	SessionFiles           int              `json:"sessionFiles"`
	AssistantMessages      int64            `json:"assistantMessages"`
	Totals                 UsageTotals      `json:"totals"`
	Models                 []ModelSummary   `json:"models"`
}

type StatsSummary struct {
	BaseDir            string          `json:"baseDir"`
	ScannedInstances   int             `json:"scannedInstances"`
	ScannedSessionFile int             `json:"scannedSessionFiles"`
	AssistantMessages  int64           `json:"assistantMessages"`
	Totals             UsageTotals     `json:"totals"`
	Instances          []InstanceStats `json:"instances"`
}

type QuotaPolicy struct {
	Disabled              bool             `json:"disabled,omitempty"`
	Limits                map[string]int64 `json:"limits,omitempty"`
	StopServices          []string         `json:"stopServices,omitempty"`
	ResumeWhenWithinLimit *bool            `json:"resumeWhenWithinLimit,omitempty"`
	ValidFrom             string           `json:"validFrom,omitempty"`
	ValidUntil            string           `json:"validUntil,omitempty"`
}

type QuotaConfig struct {
	Defaults  QuotaPolicy             `json:"defaults"`
	Instances map[string]*QuotaPolicy `json:"instances,omitempty"`
}

type QuotaState struct {
	Instance              string             `json:"instance"`
	Paused                bool               `json:"paused"`
	UpdatedAt             string             `json:"updatedAt,omitempty"`
	PausedAt              string             `json:"pausedAt,omitempty"`
	ResumedAt             string             `json:"resumedAt,omitempty"`
	PauseReason           string             `json:"pauseReason,omitempty"`
	ResumeWhenWithinLimit bool               `json:"resumeWhenWithinLimit"`
	StopServices          []string           `json:"stopServices,omitempty"`
	ExceededWindows       []QuotaWindowUsage `json:"exceededWindows,omitempty"`
}

type QuotaValidity struct {
	StartDate          string `json:"startDate,omitempty"`
	EndDate            string `json:"endDate,omitempty"`
	DurationMonths     int    `json:"durationMonths,omitempty"`
	Status             string `json:"status,omitempty"`
	Active             bool   `json:"active"`
	CurrentPeriodStart string `json:"currentPeriodStart,omitempty"`
	CurrentPeriodEnd   string `json:"currentPeriodEnd,omitempty"`
}

type QuotaWindowUsage struct {
	Window      string `json:"window"`
	UsageTokens int64  `json:"usageTokens"`
	LimitTokens int64  `json:"limitTokens"`
}

type EffectiveQuota struct {
	Disabled              bool             `json:"disabled"`
	Limits                map[string]int64 `json:"limits"`
	StopServices          []string         `json:"stopServices"`
	ResumeWhenWithinLimit bool             `json:"resumeWhenWithinLimit"`
	Validity              QuotaValidity    `json:"validity"`
}

type InstanceView struct {
	Stats         InstanceStats         `json:"stats"`
	Quota         EffectiveQuota        `json:"quota"`
	QuotaState    *QuotaState           `json:"quotaState,omitempty"`
	QuotaUsage    map[string]int64      `json:"quotaUsage"`
	QuotaExceeded map[string]bool       `json:"quotaExceeded"`
	QuotaRatio    map[string]float64    `json:"quotaRatio"`
	QuotaSource   *QuotaPolicy          `json:"quotaSource,omitempty"`
	DefaultQuota  QuotaPolicy           `json:"defaultQuota"`
	RecentModel   *RecentModelInfo      `json:"recentModel,omitempty"`
	Tags          map[string]string     `json:"tags,omitempty"`
	Actions       map[string]ActionHint `json:"actions"`
}

type ArchiveInfo struct {
	ID          string `json:"id"`
	Instance    string `json:"instance"`
	ArchiveFile string `json:"archiveFile"`
	ArchivePath string `json:"archivePath"`
	ArchivedAt  string `json:"archivedAt"`
	SizeBytes   int64  `json:"sizeBytes"`
	Restorable  bool   `json:"restorable"`
}

type ActionHint struct {
	Label  string `json:"label"`
	Method string `json:"method"`
	Path   string `json:"path"`
}

type ListInstancesResponse struct {
	GeneratedAt      string         `json:"generatedAt"`
	Instances        []InstanceView `json:"instances"`
	Archives         []ArchiveInfo  `json:"archives"`
	Totals           UsageTotals    `json:"totals"`
	ScannedInstances int            `json:"scannedInstances"`
	QuotaConfigPath  string         `json:"quotaConfigPath"`
	ArchivesDir      string         `json:"archivesDir"`
}

type QuotaUpdateRequest struct {
	Mode                  string  `json:"mode"`
	Daily                 *int64  `json:"daily"`
	Monthly               *int64  `json:"monthly"`
	Total                 *int64  `json:"total"`
	Disabled              *bool   `json:"disabled"`
	ResumeWhenWithinLimit *bool   `json:"resumeWhenWithinLimit"`
	ValidFrom             *string `json:"validFrom"`
	ValidUntil            *string `json:"validUntil"`
}

type CreateInstanceRequest struct {
	Name                 string              `json:"name"`
	GatewayPort          string              `json:"gatewayPort"`
	BridgePort           string              `json:"bridgePort"`
	WithWeixin           *bool               `json:"withWeixin"`
	SkipWeixinLogin      *bool               `json:"skipWeixinLogin"`
	PrimaryModelProvider string              `json:"primaryModelProvider"`
	ZAIAPIKey            string              `json:"zaiApiKey"`
	ZAIModel             string              `json:"zaiModel"`
	OpenAIAPIKey         string              `json:"openaiApiKey"`
	OpenAIBaseURL        string              `json:"openaiBaseUrl"`
	OpenAIModel          string              `json:"openaiModel"`
	BraveAPIKey          string              `json:"braveApiKey"`
	Quota                *QuotaUpdateRequest `json:"quota,omitempty"`
}

type ActionResponse struct {
	OK       bool   `json:"ok"`
	Message  string `json:"message"`
	Instance string `json:"instance,omitempty"`
	Command  string `json:"command,omitempty"`
}

type InstanceLogsResponse struct {
	GeneratedAt string   `json:"generatedAt"`
	Instance    string   `json:"instance"`
	Service     string   `json:"service"`
	Tail        int      `json:"tail"`
	Services    []string `json:"services"`
	Content     string   `json:"content"`
}

type ConversationSummary struct {
	ID                string           `json:"id"`
	SessionID         string           `json:"sessionId"`
	FileName          string           `json:"fileName"`
	FilePath          string           `json:"filePath"`
	Status            string           `json:"status"`
	Current           bool             `json:"current"`
	SessionKey        string           `json:"sessionKey,omitempty"`
	ChatType          string           `json:"chatType,omitempty"`
	OriginLabel       string           `json:"originLabel,omitempty"`
	CreatedAt         string           `json:"createdAt,omitempty"`
	UpdatedAt         string           `json:"updatedAt,omitempty"`
	LastMessageAt     string           `json:"lastMessageAt,omitempty"`
	MessageCount      int              `json:"messageCount"`
	UserMessages      int              `json:"userMessages"`
	AssistantMessages int              `json:"assistantMessages"`
	ToolMessages      int              `json:"toolMessages"`
	Preview           string           `json:"preview,omitempty"`
	RecentModel       *RecentModelInfo `json:"recentModel,omitempty"`
}

type ConversationContentBlock struct {
	Type      string `json:"type"`
	Text      string `json:"text,omitempty"`
	Name      string `json:"name,omitempty"`
	Arguments string `json:"arguments,omitempty"`
	DataURL   string `json:"dataUrl,omitempty"`
	Note      string `json:"note,omitempty"`
}

type ConversationMessageView struct {
	ID         string                     `json:"id,omitempty"`
	Role       string                     `json:"role"`
	EntryType  string                     `json:"entryType"`
	Timestamp  string                     `json:"timestamp,omitempty"`
	Provider   string                     `json:"provider,omitempty"`
	Model      string                     `json:"model,omitempty"`
	ToolName   string                     `json:"toolName,omitempty"`
	ToolCallID string                     `json:"toolCallId,omitempty"`
	StopReason string                     `json:"stopReason,omitempty"`
	Error      bool                       `json:"error,omitempty"`
	Usage      *UsageTotals               `json:"usage,omitempty"`
	Content    []ConversationContentBlock `json:"content"`
}

type ConversationListResponse struct {
	GeneratedAt string                `json:"generatedAt"`
	Instance    string                `json:"instance"`
	Sessions    []ConversationSummary `json:"sessions"`
}

type ConversationDetailResponse struct {
	GeneratedAt   string                    `json:"generatedAt"`
	Instance      string                    `json:"instance"`
	Conversation  ConversationSummary       `json:"conversation"`
	Messages      []ConversationMessageView `json:"messages"`
	Offset        int                       `json:"offset"`
	Limit         int                       `json:"limit"`
	TotalMessages int                       `json:"totalMessages"`
	HasOlder      bool                      `json:"hasOlder"`
	HasNewer      bool                      `json:"hasNewer"`
}

type WeixinLoginStartRequest struct {
	Force bool `json:"force"`
}

type WeixinLoginStatusResponse struct {
	GeneratedAt string `json:"generatedAt"`
	Instance    string `json:"instance"`
	Active      bool   `json:"active"`
	Connected   bool   `json:"connected"`
	Status      string `json:"status"`
	Message     string `json:"message,omitempty"`
	QRURL       string `json:"qrUrl,omitempty"`
	Output      string `json:"output,omitempty"`
	StartedAt   string `json:"startedAt,omitempty"`
	UpdatedAt   string `json:"updatedAt,omitempty"`
	FinishedAt  string `json:"finishedAt,omitempty"`
}
