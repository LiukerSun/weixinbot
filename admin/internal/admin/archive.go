package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

type archiveMetadata struct {
	ID          string       `json:"id"`
	Instance    string       `json:"instance"`
	ArchiveFile string       `json:"archiveFile"`
	ArchivedAt  string       `json:"archivedAt"`
	QuotaSource *QuotaPolicy `json:"quotaSource,omitempty"`
}

func (s *Server) listArchives() ([]ArchiveInfo, error) {
	if err := os.MkdirAll(s.cfg.ArchivesDir, 0o755); err != nil {
		return nil, err
	}

	entries, err := os.ReadDir(s.cfg.ArchivesDir)
	if err != nil {
		return nil, err
	}

	archives := make([]ArchiveInfo, 0)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}

		metadata, err := s.readArchiveMetadataByPath(filepath.Join(s.cfg.ArchivesDir, entry.Name()))
		if err != nil {
			continue
		}

		archivePath := filepath.Join(s.cfg.ArchivesDir, metadata.ArchiveFile)
		stat, err := os.Stat(archivePath)
		if err != nil || stat.IsDir() {
			continue
		}

		_, instanceErr := os.Stat(filepath.Join(s.cfg.InstancesDir, metadata.Instance))
		restorable := errors.Is(instanceErr, os.ErrNotExist)

		archives = append(archives, ArchiveInfo{
			ID:          metadata.ID,
			Instance:    metadata.Instance,
			ArchiveFile: metadata.ArchiveFile,
			ArchivePath: archivePath,
			ArchivedAt:  metadata.ArchivedAt,
			SizeBytes:   stat.Size(),
			Restorable:  restorable,
		})
	}

	slices.SortFunc(archives, func(left, right ArchiveInfo) int {
		if left.ArchivedAt == right.ArchivedAt {
			return strings.Compare(right.ID, left.ID)
		}
		if left.ArchivedAt > right.ArchivedAt {
			return -1
		}
		return 1
	})

	return archives, nil
}

func (s *Server) archiveInstance(ctx context.Context, instance string) (ActionResponse, error) {
	s.fileMutex.Lock()
	defer s.fileMutex.Unlock()

	instanceDir := filepath.Join(s.cfg.InstancesDir, instance)
	composeFile := filepath.Join(instanceDir, "docker-compose.yml")
	if _, err := os.Stat(composeFile); err != nil {
		return ActionResponse{}, fmt.Errorf("instance not found: %s", instance)
	}

	if err := os.MkdirAll(s.cfg.ArchivesDir, 0o755); err != nil {
		return ActionResponse{}, err
	}

	commandArgs, err := s.composeArgs(composeFile, "down", "--remove-orphans")
	if err != nil {
		return ActionResponse{}, err
	}
	if _, err := s.runCommand(ctx, commandArgs[0], commandArgs[1:]...); err != nil {
		return ActionResponse{}, err
	}

	quotaConfig, err := loadQuotaConfig(s.cfg.QuotaConfig)
	if err != nil {
		return ActionResponse{}, err
	}

	now := time.Now().UTC()
	archiveID := fmt.Sprintf("%s--%s", instance, now.Format("20060102T150405Z"))
	archiveFile := fmt.Sprintf("%s.tar.gz", archiveID)
	archivePath := filepath.Join(s.cfg.ArchivesDir, archiveFile)
	tempArchivePath := archivePath + ".tmp"

	if _, err := s.runCommand(ctx, "tar", "-czf", tempArchivePath, "-C", s.cfg.InstancesDir, instance); err != nil {
		return ActionResponse{}, err
	}
	if err := os.Rename(tempArchivePath, archivePath); err != nil {
		_ = os.Remove(tempArchivePath)
		return ActionResponse{}, err
	}

	metadata := archiveMetadata{
		ID:          archiveID,
		Instance:    instance,
		ArchiveFile: archiveFile,
		ArchivedAt:  now.Format(time.RFC3339),
		QuotaSource: cloneQuotaPolicy(quotaConfig.Instances[instance]),
	}
	if err := s.writeArchiveMetadata(metadata); err != nil {
		return ActionResponse{}, err
	}

	if quotaConfig.Instances != nil {
		delete(quotaConfig.Instances, instance)
		if err := saveQuotaConfig(s.cfg.QuotaConfig, quotaConfig); err != nil {
			return ActionResponse{}, err
		}
	}

	if err := os.RemoveAll(instanceDir); err != nil {
		return ActionResponse{}, err
	}

	return ActionResponse{
		OK:       true,
		Message:  fmt.Sprintf("%s archived to %s", instance, archiveFile),
		Instance: instance,
		Command:  archivePath,
	}, nil
}

func (s *Server) restoreArchive(ctx context.Context, archiveID string) (ActionResponse, error) {
	s.fileMutex.Lock()
	defer s.fileMutex.Unlock()

	metadata, err := s.readArchiveMetadata(archiveID)
	if err != nil {
		return ActionResponse{}, err
	}

	instanceDir := filepath.Join(s.cfg.InstancesDir, metadata.Instance)
	if _, err := os.Stat(instanceDir); err == nil {
		return ActionResponse{}, fmt.Errorf("instance already exists: %s", metadata.Instance)
	} else if !errors.Is(err, os.ErrNotExist) {
		return ActionResponse{}, err
	}

	archivePath := filepath.Join(s.cfg.ArchivesDir, metadata.ArchiveFile)
	if _, err := os.Stat(archivePath); err != nil {
		return ActionResponse{}, fmt.Errorf("archive not found: %s", metadata.ArchiveFile)
	}

	if err := os.MkdirAll(s.cfg.InstancesDir, 0o755); err != nil {
		return ActionResponse{}, err
	}

	if _, err := s.runCommand(ctx, "tar", "-xzf", archivePath, "-C", s.cfg.InstancesDir); err != nil {
		return ActionResponse{}, err
	}

	quotaConfig, err := loadQuotaConfig(s.cfg.QuotaConfig)
	if err != nil {
		return ActionResponse{}, err
	}
	if metadata.QuotaSource != nil {
		if quotaConfig.Instances == nil {
			quotaConfig.Instances = map[string]*QuotaPolicy{}
		}
		quotaConfig.Instances[metadata.Instance] = cloneQuotaPolicy(metadata.QuotaSource)
		if err := saveQuotaConfig(s.cfg.QuotaConfig, quotaConfig); err != nil {
			return ActionResponse{}, err
		}
	}

	composeFile := filepath.Join(instanceDir, "docker-compose.yml")
	commandArgs, err := s.composeArgs(composeFile, "up", "-d")
	if err != nil {
		return ActionResponse{}, err
	}
	if _, err := s.runCommand(ctx, commandArgs[0], commandArgs[1:]...); err != nil {
		return ActionResponse{}, err
	}

	_, _ = s.runCommand(
		ctx,
		filepath.Join(s.cfg.ScriptsDir, "openclaw-quota-control.sh"),
		"check",
		"--config", s.cfg.QuotaConfig,
		"--base-dir", s.cfg.InstancesDir,
		"--instance", metadata.Instance,
	)

	return ActionResponse{
		OK:       true,
		Message:  fmt.Sprintf("%s restored from %s", metadata.Instance, metadata.ArchiveFile),
		Instance: metadata.Instance,
		Command:  archivePath,
	}, nil
}

func (s *Server) readArchiveMetadata(id string) (archiveMetadata, error) {
	return s.readArchiveMetadataByPath(filepath.Join(s.cfg.ArchivesDir, fmt.Sprintf("%s.json", id)))
}

func (s *Server) readArchiveMetadataByPath(filePath string) (archiveMetadata, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return archiveMetadata{}, err
	}

	var metadata archiveMetadata
	if err := json.Unmarshal(data, &metadata); err != nil {
		return archiveMetadata{}, err
	}
	if metadata.ID == "" || metadata.Instance == "" || metadata.ArchiveFile == "" {
		return archiveMetadata{}, errors.New("invalid archive metadata")
	}
	return metadata, nil
}

func (s *Server) writeArchiveMetadata(metadata archiveMetadata) error {
	tempFile, err := os.CreateTemp(s.cfg.ArchivesDir, "archive-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tempFile.Name())

	encoder := json.NewEncoder(tempFile)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(metadata); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}

	return os.Rename(tempFile.Name(), filepath.Join(s.cfg.ArchivesDir, fmt.Sprintf("%s.json", metadata.ID)))
}

func cloneQuotaPolicy(source *QuotaPolicy) *QuotaPolicy {
	if source == nil {
		return nil
	}

	cloned := &QuotaPolicy{
		Disabled:   source.Disabled,
		ValidFrom:  source.ValidFrom,
		ValidUntil: source.ValidUntil,
	}
	if len(source.Limits) > 0 {
		cloned.Limits = make(map[string]int64, len(source.Limits))
		for key, value := range source.Limits {
			cloned.Limits[key] = value
		}
	}
	if len(source.StopServices) > 0 {
		cloned.StopServices = append([]string{}, source.StopServices...)
	}
	if source.ResumeWhenWithinLimit != nil {
		value := *source.ResumeWhenWithinLimit
		cloned.ResumeWhenWithinLimit = &value
	}
	return cloned
}
