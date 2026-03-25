package admin

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

const maxConversationPreviewLength = 120
const defaultConversationPageSize = 80
const maxConversationPageSize = 200
const maxConversationBlockTextChars = 12000
const maxConversationArgumentChars = 8000
const maxInlineConversationImageChars = 24000

type conversationRegistryEntry struct {
	SessionKey      string                       `json:"-"`
	SessionID       string                       `json:"sessionId"`
	UpdatedAt       int64                        `json:"updatedAt"`
	ChatType        string                       `json:"chatType"`
	SessionFile     string                       `json:"sessionFile"`
	Origin          *conversationRegistryOrigin  `json:"origin"`
	DeliveryContext *conversationDeliveryContext `json:"deliveryContext"`
}

type conversationRegistryOrigin struct {
	Label string `json:"label"`
}

type conversationDeliveryContext struct {
	To string `json:"to"`
}

type conversationFileEntry struct {
	Type       string                    `json:"type"`
	ID         string                    `json:"id"`
	Timestamp  string                    `json:"timestamp"`
	Provider   string                    `json:"provider"`
	ModelID    string                    `json:"modelId"`
	CustomType string                    `json:"customType"`
	Data       *conversationSnapshotData `json:"data"`
	Message    *conversationMessageBody  `json:"message"`
}

type conversationSnapshotData struct {
	Timestamp int64  `json:"timestamp"`
	Provider  string `json:"provider"`
	ModelID   string `json:"modelId"`
}

type conversationMessageBody struct {
	Role       string                    `json:"role"`
	Content    []conversationContentItem `json:"content"`
	Timestamp  int64                     `json:"timestamp"`
	Provider   string                    `json:"provider"`
	Model      string                    `json:"model"`
	Usage      *UsageTotals              `json:"usage"`
	StopReason string                    `json:"stopReason"`
	ToolCallID string                    `json:"toolCallId"`
	ToolName   string                    `json:"toolName"`
	IsError    bool                      `json:"isError"`
}

type conversationContentItem struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Data      string          `json:"data"`
}

func (s *Server) listConversations(instance string) (ConversationListResponse, error) {
	sessionsDir, err := s.instanceSessionsDir(instance)
	if err != nil {
		return ConversationListResponse{}, err
	}

	registry, err := loadConversationRegistry(filepath.Join(sessionsDir, "sessions.json"))
	if err != nil {
		return ConversationListResponse{}, err
	}

	entries, err := os.ReadDir(sessionsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return ConversationListResponse{
				GeneratedAt: time.Now().UTC().Format(time.RFC3339),
				Instance:    instance,
				Sessions:    []ConversationSummary{},
			}, nil
		}
		return ConversationListResponse{}, err
	}

	summaries := make([]ConversationSummary, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !isConversationFileName(entry.Name()) {
			continue
		}

		summary, err := s.readConversationSummary(filepath.Join(sessionsDir, entry.Name()), registry)
		if err != nil {
			continue
		}
		summaries = append(summaries, summary)
	}

	slices.SortFunc(summaries, func(left, right ConversationSummary) int {
		leftTime := conversationSortTime(left)
		rightTime := conversationSortTime(right)
		switch {
		case leftTime > rightTime:
			return -1
		case leftTime < rightTime:
			return 1
		case left.Current && !right.Current:
			return -1
		case !left.Current && right.Current:
			return 1
		default:
			return strings.Compare(left.FileName, right.FileName)
		}
	})

	return ConversationListResponse{
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		Instance:    instance,
		Sessions:    summaries,
	}, nil
}

func (s *Server) getConversationDetail(instance string, conversationID string, offsetRaw string, limitRaw string) (ConversationDetailResponse, error) {
	sessionsDir, err := s.instanceSessionsDir(instance)
	if err != nil {
		return ConversationDetailResponse{}, err
	}

	registry, err := loadConversationRegistry(filepath.Join(sessionsDir, "sessions.json"))
	if err != nil {
		return ConversationDetailResponse{}, err
	}

	fileName := filepath.Base(strings.TrimSpace(conversationID))
	if fileName == "." || fileName == "" || !isConversationFileName(fileName) {
		return ConversationDetailResponse{}, fmt.Errorf("invalid conversation id: %s", conversationID)
	}

	filePath := filepath.Join(sessionsDir, fileName)
	conversation, messages, err := s.readConversationDetail(filePath, registry)
	if err != nil {
		return ConversationDetailResponse{}, err
	}

	totalMessages := len(messages)
	offset, limit := normalizeConversationWindow(offsetRaw, limitRaw, totalMessages)
	end := min(totalMessages, offset+limit)
	window := []ConversationMessageView{}
	if offset < end {
		window = messages[offset:end]
	}

	return ConversationDetailResponse{
		GeneratedAt:   time.Now().UTC().Format(time.RFC3339),
		Instance:      instance,
		Conversation:  conversation,
		Messages:      window,
		Offset:        offset,
		Limit:         limit,
		TotalMessages: totalMessages,
		HasOlder:      offset > 0,
		HasNewer:      end < totalMessages,
	}, nil
}

func (s *Server) readConversationSummary(filePath string, registry map[string]conversationRegistryEntry) (ConversationSummary, error) {
	conversation, _, err := s.parseConversationFile(filePath, registry, false)
	return conversation, err
}

func (s *Server) readConversationDetail(filePath string, registry map[string]conversationRegistryEntry) (ConversationSummary, []ConversationMessageView, error) {
	return s.parseConversationFile(filePath, registry, true)
}

func (s *Server) parseConversationFile(
	filePath string,
	registry map[string]conversationRegistryEntry,
	includeMessages bool,
) (ConversationSummary, []ConversationMessageView, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return ConversationSummary{}, nil, err
	}

	fileName := filepath.Base(filePath)
	sessionID := conversationSessionID(fileName)
	status := conversationFileStatus(fileName)
	registryEntry, hasRegistryEntry := registry[sessionID]
	current := hasRegistryEntry && filepath.Base(registryEntry.SessionFile) == sessionID+".jsonl" && status == "active"

	summary := ConversationSummary{
		ID:        fileName,
		SessionID: sessionID,
		FileName:  fileName,
		FilePath:  filePath,
		Status:    status,
		Current:   current,
	}

	if hasRegistryEntry {
		summary.SessionKey = registryEntry.SessionKey
		summary.ChatType = registryEntry.ChatType
		summary.OriginLabel = conversationOriginLabel(registryEntry)
		if registryEntry.UpdatedAt > 0 {
			summary.UpdatedAt = time.UnixMilli(registryEntry.UpdatedAt).UTC().Format(time.RFC3339)
		}
	}

	if hasRegistryEntry && summary.SessionKey == "" {
		summary.SessionKey = sessionID
	}

	lines := strings.Split(string(data), "\n")
	messages := make([]ConversationMessageView, 0)
	var (
		lastProvider string
		lastModel    string
	)

	for _, rawLine := range lines {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}

		var entry conversationFileEntry
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			continue
		}

		switch entry.Type {
		case "session":
			if summary.CreatedAt == "" {
				summary.CreatedAt = entry.Timestamp
			}
		case "model_change":
			lastProvider = firstNonEmpty(entry.Provider, lastProvider)
			lastModel = firstNonEmpty(entry.ModelID, lastModel)
		case "custom":
			if entry.CustomType == "model-snapshot" && entry.Data != nil {
				lastProvider = firstNonEmpty(entry.Data.Provider, lastProvider)
				lastModel = firstNonEmpty(entry.Data.ModelID, lastModel)
				if entry.Data.Timestamp > 0 {
					summary.RecentModel = &RecentModelInfo{
						Provider:  firstNonEmpty(entry.Data.Provider, "unknown"),
						Model:     firstNonEmpty(entry.Data.ModelID, "unknown"),
						ModelRef:  toConversationModelRef(entry.Data.Provider, entry.Data.ModelID),
						Timestamp: time.UnixMilli(entry.Data.Timestamp).UTC().Format(time.RFC3339),
					}
				}
			}
		case "message":
			if entry.Message == nil {
				continue
			}

			messageTime := conversationMessageTimestamp(entry)
			if summary.LastMessageAt == "" && messageTime != "" {
				summary.LastMessageAt = messageTime
			}
			if messageTime != "" && (summary.LastMessageAt == "" || messageTime > summary.LastMessageAt) {
				summary.LastMessageAt = messageTime
			}

			summary.MessageCount += 1
			switch entry.Message.Role {
			case "user":
				summary.UserMessages += 1
			case "assistant":
				summary.AssistantMessages += 1
			case "toolResult":
				summary.ToolMessages += 1
			}

			if summary.Preview == "" {
				if preview := conversationPreviewText(entry.Message.Content); preview != "" {
					summary.Preview = preview
				}
			}

			if entry.Message.Role == "assistant" {
				provider := firstNonEmpty(entry.Message.Provider, lastProvider)
				model := firstNonEmpty(entry.Message.Model, lastModel)
				if provider != "" || model != "" {
					summary.RecentModel = &RecentModelInfo{
						Provider:  firstNonEmpty(provider, "unknown"),
						Model:     firstNonEmpty(model, "unknown"),
						ModelRef:  toConversationModelRef(provider, model),
						Timestamp: messageTime,
					}
				}
			}

			if includeMessages {
				messageView := ConversationMessageView{
					ID:         entry.ID,
					Role:       entry.Message.Role,
					EntryType:  entry.Type,
					Timestamp:  messageTime,
					Provider:   firstNonEmpty(entry.Message.Provider, lastProvider),
					Model:      firstNonEmpty(entry.Message.Model, lastModel),
					ToolName:   entry.Message.ToolName,
					ToolCallID: entry.Message.ToolCallID,
					StopReason: entry.Message.StopReason,
					Error:      entry.Message.IsError,
					Content:    make([]ConversationContentBlock, 0, len(entry.Message.Content)),
				}
				if entry.Message.Usage != nil {
					usageCopy := *entry.Message.Usage
					messageView.Usage = &usageCopy
				}
				for _, item := range entry.Message.Content {
					messageView.Content = append(messageView.Content, convertConversationContent(item))
				}
				messages = append(messages, messageView)
			}
		}
	}

	if summary.UpdatedAt == "" {
		summary.UpdatedAt = firstNonEmpty(summary.LastMessageAt, summary.CreatedAt)
	}
	if summary.Preview == "" {
		summary.Preview = "暂无可展示的文本内容"
	}

	return summary, messages, nil
}

func (s *Server) instanceSessionsDir(instance string) (string, error) {
	instanceDir := filepath.Join(s.cfg.InstancesDir, instance)
	if stat, err := os.Stat(instanceDir); err != nil || !stat.IsDir() {
		return "", fmt.Errorf("instance not found: %s", instance)
	}
	return filepath.Join(instanceDir, "state", "agents", "main", "sessions"), nil
}

func loadConversationRegistry(filePath string) (map[string]conversationRegistryEntry, error) {
	if _, err := os.Stat(filePath); err != nil {
		if os.IsNotExist(err) {
			return map[string]conversationRegistryEntry{}, nil
		}
		return nil, err
	}

	data, err := os.ReadFile(filePath)
	if err != nil {
		return nil, err
	}

	var raw map[string]conversationRegistryEntry
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}

	result := make(map[string]conversationRegistryEntry, len(raw))
	for sessionKey, entry := range raw {
		if strings.TrimSpace(entry.SessionID) == "" {
			continue
		}
		entry.SessionKey = sessionKey
		if strings.TrimSpace(entry.SessionFile) == "" {
			entry.SessionFile = entry.SessionID + ".jsonl"
		}
		result[entry.SessionID] = entry
	}
	return result, nil
}

func convertConversationContent(item conversationContentItem) ConversationContentBlock {
	block := ConversationContentBlock{Type: item.Type}

	switch item.Type {
	case "text":
		block.Text = truncateConversationContentText(item.Text, maxConversationBlockTextChars)
		if wasConversationTextTruncated(item.Text, block.Text) {
			block.Note = "文本已截断，避免界面卡死"
		}
	case "thinking":
		block.Text = truncateConversationContentText(item.Thinking, maxConversationBlockTextChars)
		if wasConversationTextTruncated(item.Thinking, block.Text) {
			block.Note = "思考内容已截断"
		}
	case "toolCall":
		block.Name = item.Name
		block.Arguments = truncateConversationContentText(
			formatConversationJSON(item.Arguments),
			maxConversationArgumentChars,
		)
	case "image":
		trimmed := strings.TrimSpace(item.Data)
		if trimmed == "" {
			block.Note = "图片内容为空"
			return block
		}
		if len(trimmed) > maxInlineConversationImageChars {
			block.Note = "图片内容已省略，避免界面卡死"
			return block
		}
		block.DataURL = buildConversationImageDataURL(trimmed)
		if block.DataURL == "" {
			block.Note = "图片内容存在，但暂时无法预览"
		}
	default:
		block.Text = truncateConversationContentText(
			formatConversationJSON(mustMarshalConversationItem(item)),
			maxConversationBlockTextChars,
		)
		if block.Text == "" {
			block.Note = "该内容块为空"
		}
	}

	return block
}

func mustMarshalConversationItem(item conversationContentItem) json.RawMessage {
	data, _ := json.Marshal(item)
	return data
}

func buildConversationImageDataURL(encoded string) string {
	trimmed := strings.TrimSpace(encoded)
	if trimmed == "" {
		return ""
	}

	sampleLength := min(len(trimmed), 4096)
	sampleLength -= sampleLength % 4
	if sampleLength <= 0 {
		return ""
	}

	sample, err := base64.StdEncoding.DecodeString(trimmed[:sampleLength])
	if err != nil {
		return ""
	}

	mimeType := http.DetectContentType(sample)
	if mimeType == "application/octet-stream" {
		mimeType = "image/png"
	}

	return fmt.Sprintf("data:%s;base64,%s", mimeType, trimmed)
}

func isConversationFileName(name string) bool {
	return strings.Contains(name, ".jsonl") && conversationSessionID(name) != ""
}

func conversationSessionID(name string) string {
	before, _, found := strings.Cut(name, ".jsonl")
	if !found {
		return ""
	}
	return strings.TrimSpace(before)
}

func conversationFileStatus(name string) string {
	switch {
	case strings.Contains(name, ".deleted."):
		return "deleted"
	case strings.Contains(name, ".reset."):
		return "reset"
	default:
		return "active"
	}
}

func conversationOriginLabel(entry conversationRegistryEntry) string {
	switch {
	case entry.Origin != nil && strings.TrimSpace(entry.Origin.Label) != "":
		return strings.TrimSpace(entry.Origin.Label)
	case entry.DeliveryContext != nil && strings.TrimSpace(entry.DeliveryContext.To) != "":
		return strings.TrimSpace(entry.DeliveryContext.To)
	default:
		return ""
	}
}

func conversationPreviewText(items []conversationContentItem) string {
	for _, item := range items {
		if item.Type == "text" && strings.TrimSpace(item.Text) != "" {
			return truncateConversationText(item.Text, maxConversationPreviewLength)
		}
		if item.Type == "thinking" && strings.TrimSpace(item.Thinking) != "" {
			return truncateConversationText(item.Thinking, maxConversationPreviewLength)
		}
	}
	return ""
}

func truncateConversationText(value string, maxLen int) string {
	normalized := strings.Join(strings.Fields(strings.TrimSpace(value)), " ")
	if maxLen <= 0 || len(normalized) <= maxLen {
		return normalized
	}
	return normalized[:maxLen-1] + "…"
}

func conversationMessageTimestamp(entry conversationFileEntry) string {
	if entry.Message != nil && entry.Message.Timestamp > 0 {
		return time.UnixMilli(entry.Message.Timestamp).UTC().Format(time.RFC3339)
	}
	return entry.Timestamp
}

func toConversationModelRef(provider string, model string) string {
	return fmt.Sprintf("%s/%s", firstNonEmpty(provider, "unknown"), firstNonEmpty(model, "unknown"))
}

func formatConversationJSON(value json.RawMessage) string {
	trimmed := strings.TrimSpace(string(value))
	if trimmed == "" || trimmed == "null" {
		return ""
	}

	var parsed any
	if err := json.Unmarshal(value, &parsed); err != nil {
		return trimmed
	}

	formatted, err := json.MarshalIndent(parsed, "", "  ")
	if err != nil {
		return trimmed
	}
	return string(formatted)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func conversationSortTime(summary ConversationSummary) string {
	return firstNonEmpty(summary.UpdatedAt, summary.LastMessageAt, summary.CreatedAt)
}

func normalizeConversationWindow(offsetRaw string, limitRaw string, totalMessages int) (int, int) {
	limit := defaultConversationPageSize
	if parsed, err := parsePositiveInt(limitRaw); err == nil && parsed > 0 {
		limit = parsed
	}
	if limit > maxConversationPageSize {
		limit = maxConversationPageSize
	}

	if totalMessages < 0 {
		totalMessages = 0
	}

	offset := max(0, totalMessages-limit)
	if parsed, err := parsePositiveInt(offsetRaw); err == nil {
		offset = parsed
	}
	if offset > totalMessages {
		offset = totalMessages
	}

	return offset, limit
}

func parsePositiveInt(raw string) (int, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return 0, fmt.Errorf("empty")
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 0 {
		return 0, fmt.Errorf("invalid integer: %s", raw)
	}
	return parsed, nil
}

func truncateConversationContentText(value string, maxLen int) string {
	if maxLen <= 0 {
		return ""
	}
	if len(value) <= maxLen {
		return value
	}
	return value[:maxLen] + "\n\n[truncated]"
}

func wasConversationTextTruncated(original string, truncated string) bool {
	return len(original) > len(truncated) || strings.HasSuffix(truncated, "\n\n[truncated]")
}
