package store

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/zeebo/blake3"
)

var (
	installLog = "installs.jsonl"
	rootsLog   = "gcroots.jsonl"

	indexName = ".index"
)

// Store manages the content-addressed store for installed files.
type Store struct {
	path       string
	idx        *Index
	installLog *LogIndex
	rootsLog   *LogIndex
}

// InstallRecord tracks a completed install transaction.
type InstallRecord struct {
	InstallID string            `json:"install_id"`
	Completed time.Time         `json:"completed"`
	Files     map[string]string `json:"files"`
}

// GCRoot is a symlink to an object in the store.
type GCRoot struct {
	Timestamp   time.Time `json:"ts"`
	InstallID   string    `json:"install_id"`
	SymlinkPath string    `json:"symlink"`
	ObjectPath  string    `json:"object"`
}

// NewStore creates a new content-addressed store at the given path.
func NewStore(path string) (*Store, error) {
	fullPath, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("failed to get full store path: %w", err)
	}

	objectsDir := filepath.Join(fullPath, "objects")
	if err := os.MkdirAll(objectsDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create objects directory: %w", err)
	}

	idx, err := OpenIndex(filepath.Join(fullPath, indexName), 2)
	if err != nil {
		return nil, fmt.Errorf("failed to open index: %w", err)
	}

	return &Store{
		path:       fullPath,
		idx:        idx,
		installLog: idx.Log(0, filepath.Join(fullPath, installLog)),
		rootsLog:   idx.Log(1, filepath.Join(fullPath, rootsLog)),
	}, nil
}

// Close closes the store and releases all resources.
func (s *Store) Close() error {
	return s.idx.Close()
}

// StorePath returns the path to the directory containing the store objects.
// This path is always absolute.
func (s *Store) StorePath() string {
	return filepath.Join(s.path, "objects")
}

// ObjectPath returns the path to an object with the given digest.
func (s *Store) ObjectPath(digest string) string {
	return filepath.Join(s.path, "objects", digest)
}

// Put copies a file into the store and returns its digest.
func (s *Store) Put(source string) (string, error) {
	digest, err := hashFile(source)
	if err != nil {
		return "", fmt.Errorf("failed to hash file: %w", err)
	}

	objectPath := s.ObjectPath(digest)
	if _, err := os.Stat(objectPath); err == nil {
		return digest, nil
	}

	// copy to a temporary path and rename for atomic write
	err = copyToStore(source, objectPath, digest)
	if err != nil {
		return "", err
	}

	// verify the copy by re-hashing
	newDigest, err := hashFile(objectPath)
	if err != nil {
		os.Remove(objectPath)
		return "", fmt.Errorf("failed to verify copied file: %w", err)
	} else if newDigest != digest {
		os.Remove(objectPath)
		return "", fmt.Errorf("hash mismatch after copy: expected %s, got %s", digest, newDigest)
	}

	return digest, nil
}

// CommitInstall logs a completed install.
func (s *Store) CommitInstall(installID string, files map[string]string) error {
	roots, err := s.GetRoots()
	if err != nil {
		return err
	}
	// sort from newest to oldest
	slices.SortFunc(roots, func(a, b GCRoot) int {
		return b.Timestamp.Compare(a.Timestamp)
	})

	uncheckedFiles := maps.Clone(files)
	for _, root := range roots {
		if root.InstallID != installID {
			continue
		}
		for name, digest := range uncheckedFiles {
			if root.ObjectPath == s.ObjectPath(digest) {
				delete(uncheckedFiles, name)
				break
			}
		}
	}
	if len(uncheckedFiles) > 0 {
		for name := range uncheckedFiles {
			return fmt.Errorf("file %s was not linked during install", name)
		}
	}

	record := InstallRecord{
		InstallID: installID,
		Completed: time.Now(),
		Files:     files,
	}

	w, err := s.installLog.BeginAppendTx()
	if err != nil {
		return err
	}
	defer w.Close()

	if err := json.NewEncoder(w).Encode(record); err != nil {
		return err
	}

	return w.Close()
}

// CreateRoot appends a GC root to the log.
func (s *Store) CreateRoot(installID, dst, digest string) error {
	record := GCRoot{
		Timestamp:   time.Now(),
		InstallID:   installID,
		SymlinkPath: dst,
		ObjectPath:  s.ObjectPath(digest),
	}

	w, err := s.rootsLog.BeginAppendTx()
	if err != nil {
		return err
	}
	defer w.Close()

	if err := json.NewEncoder(w).Encode(record); err != nil {
		return err
	}

	return w.Close()
}

// GetInstalls parses all install records from the install log.
func (s *Store) GetInstalls() ([]InstallRecord, error) {
	r, err := s.installLog.BeginReadTx()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return []InstallRecord{}, nil
		}
		return nil, err
	}
	defer r.Close()

	records := make(map[string]InstallRecord)
	dec := json.NewDecoder(r)
	for {
		var rec InstallRecord
		if err := dec.Decode(&rec); err == io.EOF {
			break
		} else if err != nil {
			return nil, fmt.Errorf("failed to parse install record: %w", err)
		}

		if prev, ok := records[rec.InstallID]; !ok || rec.Completed.After(prev.Completed) {
			records[rec.InstallID] = rec
		}
	}

	result := make([]InstallRecord, 0, len(records))
	for _, record := range records {
		result = append(result, record)
	}

	return result, nil
}

// GetRoots parses all GC roots from the GC log.
func (s *Store) GetRoots() ([]GCRoot, error) {
	r, err := s.rootsLog.BeginReadTx()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return []GCRoot{}, nil
		}
		return nil, err
	}
	defer r.Close()

	var roots []GCRoot
	dec := json.NewDecoder(r)
	for {
		var root GCRoot
		if err := dec.Decode(&root); err == io.EOF {
			break
		} else if err != nil {
			return nil, fmt.Errorf("failed to parse GC root: %w", err)
		}
		roots = append(roots, root)
	}

	return roots, nil
}

// GC performs garbage collection on the store.
func (s *Store) GC() error {
	installs, err := s.GetInstalls()
	if err != nil {
		return fmt.Errorf("failed to read installs: %w", err)
	}

	roots, err := s.GetRoots()
	if err != nil {
		return fmt.Errorf("failed to read GC roots: %w", err)
	}

	installIDs := make(map[string]*InstallRecord)
	for i := range installs {
		installIDs[installs[i].InstallID] = &installs[i]
	}

	// deduplicate roots by destination, keeping the latest for each
	liveRoots := make(map[string]GCRoot)
	for _, root := range roots {
		target, err := os.Readlink(root.SymlinkPath)
		if err != nil {
			continue
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(filepath.Dir(root.SymlinkPath), target)
		}
		if filepath.Clean(target) != root.ObjectPath {
			continue
		}

		if existing, ok := liveRoots[root.SymlinkPath]; ok && !root.Timestamp.After(existing.Timestamp) {
			continue
		}
		liveRoots[root.SymlinkPath] = root
	}

	// collect live digests and install IDs from the surviving roots
	liveDigests := make(map[string]bool)
	liveInstallIDs := make(map[string]bool)
	for _, root := range liveRoots {
		liveDigests[filepath.Base(root.ObjectPath)] = true
		liveInstallIDs[root.InstallID] = true

		if _, ok := installIDs[root.InstallID]; !ok {
			fmt.Fprintf(os.Stderr, "warning: dangling install artifact %s from unknown install %s\n",
				root.SymlinkPath, root.InstallID)
		}
	}

	// delete orphan objects
	entries, err := os.ReadDir(filepath.Join(s.path, "objects"))
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to read objects directory: %w", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() && !liveDigests[entry.Name()] {
			if err := os.Remove(s.ObjectPath(entry.Name())); err != nil && !os.IsNotExist(err) {
				fmt.Fprintf(os.Stderr, "warning: failed to delete object %s: %v\n", entry.Name(), err)
			}
		}
	}

	// rewrite gcroots.jsonl with only live roots
	w, err := s.rootsLog.BeginWriteTx()
	if err != nil {
		return fmt.Errorf("failed to compact GC roots: %w", err)
	}
	defer w.Close()

	if err := w.Truncate(0); err != nil {
		return fmt.Errorf("failed to compact GC roots: %w", err)
	}
	enc := json.NewEncoder(w)
	for _, root := range liveRoots {
		if err := enc.Encode(root); err != nil {
			return fmt.Errorf("failed to compact GC roots: %w", err)
		}
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("failed to compact GC roots: %w", err)
	}

	// rewrite installs.jsonl with only installs that have live roots
	w2, err := s.installLog.BeginWriteTx()
	if err != nil {
		return fmt.Errorf("failed to compact installs: %w", err)
	}
	defer w2.Close()

	if err := w2.Truncate(0); err != nil {
		return fmt.Errorf("failed to compact installs: %w", err)
	}
	enc2 := json.NewEncoder(w2)
	for id, record := range installIDs {
		if liveInstallIDs[id] {
			if err := enc2.Encode(record); err != nil {
				return fmt.Errorf("failed to compact installs: %w", err)
			}
		}
	}
	return w2.Close()
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	hasher := blake3.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return "", err
	}

	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func copyFile(dst, src string) error {
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	if _, err := io.Copy(dstFile, srcFile); err != nil {
		return err
	}

	return dstFile.Close()
}
