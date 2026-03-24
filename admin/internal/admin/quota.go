package admin

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const quotaDateLayout = "2006-01-02"

func normalizeQuotaConfig(cfg QuotaConfig) QuotaConfig {
	if cfg.Instances == nil {
		cfg.Instances = map[string]*QuotaPolicy{}
	}

	cfg.Defaults = normalizeQuotaPolicy(cfg.Defaults)
	for key, policy := range cfg.Instances {
		if policy == nil {
			cfg.Instances[key] = &QuotaPolicy{}
			continue
		}
		normalized := normalizeQuotaPolicy(*policy)
		cfg.Instances[key] = &normalized
	}

	return cfg
}

func normalizeQuotaPolicy(policy QuotaPolicy) QuotaPolicy {
	limits := make(map[string]int64, len(policy.Limits))
	for rawKey, rawValue := range policy.Limits {
		key := normalizeWindowName(rawKey)
		if key == "" || rawValue <= 0 {
			continue
		}
		limits[key] = rawValue
	}
	policy.Limits = limits

	if len(policy.StopServices) == 0 {
		policy.StopServices = nil
	} else {
		seen := map[string]bool{}
		cleaned := make([]string, 0, len(policy.StopServices))
		for _, service := range policy.StopServices {
			value := strings.TrimSpace(service)
			if value == "" || seen[value] {
				continue
			}
			seen[value] = true
			cleaned = append(cleaned, value)
		}
		policy.StopServices = cleaned
	}

	policy.ValidFrom = strings.TrimSpace(policy.ValidFrom)
	policy.ValidUntil = strings.TrimSpace(policy.ValidUntil)

	return policy
}

func normalizeWindowName(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "day", "daily":
		return "daily"
	case "month", "monthly":
		return "monthly"
	case "total", "all", "all-time", "all_time", "lifetime":
		return "total"
	default:
		return ""
	}
}

func mergeQuotaPolicy(defaults QuotaPolicy, source *QuotaPolicy) EffectiveQuota {
	merged := EffectiveQuota{
		Disabled:              defaults.Disabled,
		Limits:                map[string]int64{},
		StopServices:          append([]string{}, defaults.StopServices...),
		ResumeWhenWithinLimit: true,
		Validity:              buildQuotaValidity(defaults.ValidFrom, defaults.ValidUntil, time.Now()),
	}

	if defaults.ResumeWhenWithinLimit != nil {
		merged.ResumeWhenWithinLimit = *defaults.ResumeWhenWithinLimit
	}

	for key, value := range defaults.Limits {
		merged.Limits[key] = value
	}

	if source == nil {
		if len(merged.StopServices) == 0 {
			merged.StopServices = []string{"openclaw-gateway"}
		}
		return merged
	}

	if source.Disabled {
		merged.Disabled = true
	}
	for key, value := range source.Limits {
		merged.Limits[normalizeWindowName(key)] = value
	}
	if source.ValidFrom != "" || source.ValidUntil != "" {
		merged.Validity = buildQuotaValidity(source.ValidFrom, source.ValidUntil, time.Now())
	}
	if len(source.StopServices) > 0 {
		merged.StopServices = append([]string{}, source.StopServices...)
	}
	if source.ResumeWhenWithinLimit != nil {
		merged.ResumeWhenWithinLimit = *source.ResumeWhenWithinLimit
	}
	if len(merged.StopServices) == 0 {
		merged.StopServices = []string{"openclaw-gateway"}
	}

	return merged
}

func loadQuotaConfig(path string) (QuotaConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return normalizeQuotaConfig(QuotaConfig{}), nil
		}
		return QuotaConfig{}, err
	}

	var cfg QuotaConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return QuotaConfig{}, err
	}

	return normalizeQuotaConfig(cfg), nil
}

func saveQuotaConfig(path string, cfg QuotaConfig) error {
	cfg = normalizeQuotaConfig(cfg)

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	tempFile, err := os.CreateTemp(filepath.Dir(path), "quota-config-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tempFile.Name())

	encoder := json.NewEncoder(tempFile)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(cfg); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}

	return os.Rename(tempFile.Name(), path)
}

func applyQuotaUpdate(policy *QuotaPolicy, request QuotaUpdateRequest) error {
	if policy.Limits == nil {
		policy.Limits = map[string]int64{}
	}

	mode := strings.ToLower(strings.TrimSpace(request.Mode))
	if mode == "" {
		mode = "set"
	}

	applyValue := func(name string, incoming *int64) {
		if incoming == nil {
			return
		}
		key := normalizeWindowName(name)
		if key == "" {
			return
		}

		if mode == "add" {
			nextValue := policy.Limits[key] + *incoming
			if nextValue <= 0 {
				delete(policy.Limits, key)
				return
			}
			policy.Limits[key] = nextValue
			return
		}

		if *incoming <= 0 {
			delete(policy.Limits, key)
			return
		}
		policy.Limits[key] = *incoming
	}

	applyValue("daily", request.Daily)
	applyValue("monthly", request.Monthly)
	applyValue("total", request.Total)

	if request.Disabled != nil {
		policy.Disabled = *request.Disabled
	}
	if request.ResumeWhenWithinLimit != nil {
		value := *request.ResumeWhenWithinLimit
		policy.ResumeWhenWithinLimit = &value
	}
	if request.ValidFrom != nil || request.ValidUntil != nil {
		validFrom := policy.ValidFrom
		validUntil := policy.ValidUntil
		if request.ValidFrom != nil {
			validFrom = strings.TrimSpace(*request.ValidFrom)
		}
		if request.ValidUntil != nil {
			validUntil = strings.TrimSpace(*request.ValidUntil)
		}
		normalizedFrom, normalizedUntil, err := normalizeValidityRange(validFrom, validUntil)
		if err != nil {
			return err
		}
		policy.ValidFrom = normalizedFrom
		policy.ValidUntil = normalizedUntil
	}

	normalized := normalizeQuotaPolicy(*policy)
	*policy = normalized
	return nil
}

func windowsFromEffectiveQuota(quota EffectiveQuota) []string {
	windows := make([]string, 0, len(quota.Limits))
	for key := range quota.Limits {
		windows = append(windows, key)
	}
	slices.Sort(windows)
	return windows
}

func normalizeValidityRange(validFrom string, validUntil string) (string, string, error) {
	validFrom = strings.TrimSpace(validFrom)
	validUntil = strings.TrimSpace(validUntil)
	if validFrom == "" && validUntil == "" {
		return "", "", nil
	}
	if validFrom == "" || validUntil == "" {
		return "", "", fmt.Errorf("validFrom and validUntil must be set together")
	}

	startDate, ok := parseQuotaDate(validFrom)
	if !ok {
		return "", "", fmt.Errorf("invalid validFrom date: %s", validFrom)
	}
	endDate, ok := parseQuotaDate(validUntil)
	if !ok {
		return "", "", fmt.Errorf("invalid validUntil date: %s", validUntil)
	}

	if !endDate.After(startDate) {
		return "", "", fmt.Errorf("validUntil must be later than validFrom")
	}

	return formatQuotaDate(startDate), formatQuotaDate(endDate), nil
}

func buildQuotaValidity(validFrom string, validUntil string, now time.Time) QuotaValidity {
	result := QuotaValidity{
		StartDate: strings.TrimSpace(validFrom),
		EndDate:   strings.TrimSpace(validUntil),
		Status:    "none",
		Active:    true,
	}
	if result.StartDate == "" && result.EndDate == "" {
		return result
	}
	if result.StartDate == "" || result.EndDate == "" {
		result.Status = "invalid"
		result.Active = false
		return result
	}

	startDate, ok := parseQuotaDate(result.StartDate)
	if !ok {
		result.Status = "invalid"
		result.Active = false
		return result
	}
	endDate, ok := parseQuotaDate(result.EndDate)
	if !ok {
		result.Status = "invalid"
		result.Active = false
		return result
	}

	if durationMonths, ok := exactDurationMonths(startDate, endDate); ok {
		result.DurationMonths = durationMonths
	}

	today := truncateToDay(now)
	switch {
	case today.Before(startDate):
		result.Status = "upcoming"
		result.Active = false
	case !today.Before(endDate):
		result.Status = "expired"
		result.Active = false
	default:
		result.Status = "active"
		result.Active = true
		periodStart, periodEnd := currentQuotaPeriod(startDate, endDate, today)
		result.CurrentPeriodStart = formatQuotaDate(periodStart)
		result.CurrentPeriodEnd = formatQuotaDate(periodEnd)
	}

	return result
}

func parseQuotaDate(raw string) (time.Time, bool) {
	parsed, err := time.ParseInLocation(quotaDateLayout, strings.TrimSpace(raw), time.Local)
	if err != nil {
		return time.Time{}, false
	}
	return truncateToDay(parsed), true
}

func formatQuotaDate(value time.Time) string {
	return truncateToDay(value).Format(quotaDateLayout)
}

func truncateToDay(value time.Time) time.Time {
	return time.Date(value.Year(), value.Month(), value.Day(), 0, 0, 0, 0, value.Location())
}

func addMonthsClamped(value time.Time, months int) time.Time {
	value = truncateToDay(value)
	totalMonths := int(value.Month()) - 1 + months
	year := value.Year() + totalMonths/12
	monthIndex := totalMonths % 12
	if monthIndex < 0 {
		monthIndex += 12
		year--
	}
	month := time.Month(monthIndex + 1)
	day := value.Day()
	maxDay := daysInMonth(year, month, value.Location())
	if day > maxDay {
		day = maxDay
	}
	return time.Date(year, month, day, 0, 0, 0, 0, value.Location())
}

func daysInMonth(year int, month time.Month, location *time.Location) int {
	return time.Date(year, month+1, 0, 0, 0, 0, 0, location).Day()
}

func exactDurationMonths(startDate time.Time, endDate time.Time) (int, bool) {
	startDate = truncateToDay(startDate)
	endDate = truncateToDay(endDate)
	for months := 1; months <= 240; months++ {
		expectedEnd := addMonthsClamped(startDate, months)
		if expectedEnd.Equal(endDate) {
			return months, true
		}
		if expectedEnd.After(endDate) {
			break
		}
	}
	return 0, false
}

func currentQuotaPeriod(startDate time.Time, endDate time.Time, now time.Time) (time.Time, time.Time) {
	startDate = truncateToDay(startDate)
	endDate = truncateToDay(endDate)
	now = truncateToDay(now)

	currentStart := startDate
	for months := 1; months <= 240; months++ {
		nextStart := addMonthsClamped(startDate, months)
		if nextStart.After(now) || !nextStart.Before(endDate) {
			break
		}
		currentStart = nextStart
	}

	currentEnd := addMonthsClamped(currentStart, 1)
	if currentEnd.After(endDate) {
		currentEnd = endDate
	}
	return currentStart, currentEnd
}

func maxQuotaDate(values ...time.Time) time.Time {
	var result time.Time
	for _, value := range values {
		if value.IsZero() {
			continue
		}
		if result.IsZero() || value.After(result) {
			result = value
		}
	}
	return result
}
