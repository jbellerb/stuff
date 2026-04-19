package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"tools/installer/internal/store"
	pb "tools/installer/third-party/buckproto/install"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var (
	errNotFound   = errors.New("file not found in pending installs")
	errFileExists = errors.New("file already exists at destination")
)

type errorInstall struct {
	err      error
	message  string
	category pb.ErrorCategory
}

func (e *errorInstall) Error() string {
	return fmt.Sprintf("%s: %v", e.message, e.err)
}

func (e *errorInstall) Unwrap() error {
	return e.err
}

type installState struct {
	objects map[string]string
	pending map[string]struct{}
}

type Server struct {
	pb.UnimplementedInstallerServer

	mu       sync.Mutex
	installs map[string]installState
	store    *store.Store
	done     chan struct{}
}

// NewServer creates a new installer server.
func NewServer(st *store.Store) *Server {
	return &Server{
		installs: make(map[string]installState),
		store:    st,
		done:     make(chan struct{}),
	}
}

func expandName(name string) (string, error) {
	if strings.HasPrefix(name, "~/") {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("failed to get home directory: %w", err)
		}
		name = filepath.Join(homeDir, name[2:])
	}

	fullName, err := filepath.Abs(name)
	if err != nil {
		return "", fmt.Errorf("failed to get full path of install name: %w", err)
	}

	return fullName, nil
}

// Install implements /install.Installer/Install.
func (s *Server) Install(
	ctx context.Context, req *pb.InstallInfoRequest,
) (*pb.InstallResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installID := req.GetInstallId()
	fileNames := req.GetFileNames()

	state := installState{
		objects: make(map[string]string, len(fileNames)),
		pending: make(map[string]struct{}, len(fileNames)),
	}
	for _, name := range fileNames {
		state.pending[name] = struct{}{}
	}
	s.installs[installID] = state

	slog.InfoContext(
		ctx,
		"registered install task",
		"rpc.install.id", installID,
		"rpc.install.pending", len(state.pending),
	)

	return &pb.InstallResponse{InstallId: installID}, nil
}

func (s *Server) createSymlink(dst, src string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return fmt.Errorf("failed to create parent directories: %w", err)
	}

	for {
		if err := os.Symlink(src, dst); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrExist) {
			return fmt.Errorf("failed to create symlink: %w", err)
		}

		info, err := os.Lstat(dst)
		if err != nil {
			return fmt.Errorf("failed to stat destination: %w", err)
		} else if info.Mode()&os.ModeSymlink == 0 {
			// don't overwrite regular files
			return errFileExists
		} else {
			// only overwrite symlinks that point into the store
			target, err := os.Readlink(dst)
			if err != nil {
				return fmt.Errorf("failed to read existing symlink: %w", err)
			}
			if !filepath.IsAbs(target) {
				target = filepath.Join(filepath.Dir(dst), target)
			}
			if !strings.HasPrefix(filepath.Clean(target), s.store.StorePath()+string(filepath.Separator)) {
				return errFileExists
			}
			if err := os.Remove(dst); err != nil {
				return fmt.Errorf("failed to remove existing symlink: %w", err)
			}
		}
	}
}

func (s *Server) linkArtifact(installID, dst, src string) (string, *errorInstall) {
	digest, err := s.store.Put(src)
	if err != nil {
		return "", &errorInstall{err, "failed to add file to store", pb.ErrorCategory_ENVIRONMENT}
	}

	if err := s.store.CreateRoot(installID, dst, digest); err != nil {
		return "", &errorInstall{err, "failed to log gc root", pb.ErrorCategory_TIER_0}
	}

	objectPath := s.store.ObjectPath(digest)
	if err := s.createSymlink(dst, objectPath); err != nil {
		res := errorInstall{err, "failed to create symlink", pb.ErrorCategory_ENVIRONMENT}
		if errors.Is(err, errFileExists) {
			res.category = pb.ErrorCategory_INPUT
		}
		return "", &res
	}

	return digest, nil
}

// FileReady implements /install.Installer/FileReady.
func (s *Server) FileReady(
	ctx context.Context, req *pb.FileReadyRequest,
) (*pb.FileResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installID := req.GetInstallId()
	name := req.GetName()
	path := req.GetPath()

	ctx = withLogAttrs(
		ctx,
		slog.String("rpc.install.id", installID),
		slog.String("rpc.install.destination", name),
		slog.String("rpc.install.source", path),
	)

	var err error
	state, ok := s.installs[installID]
	if !ok {
		err = errNotFound
	} else {
		if _, ok := state.pending[name]; !ok {
			err = errNotFound
		}
	}
	if err != nil {
		slog.ErrorContext(ctx, "bad request", "exception", err)
		return nil, status.Error(codes.NotFound, err.Error())
	}

	res := pb.FileResponse{InstallId: installID, Name: name, Path: path}

	dst, err := expandName(name)
	if err != nil {
		res.ErrorDetail = &pb.ErrorDetail{
			Message:  fmt.Sprintf("failed to expand destination name: %v", err),
			Category: pb.ErrorCategory_INPUT,
		}
		slog.ErrorContext(ctx, "failed to expand destination name", "exception", err)
		return &res, nil
	}

	digest, linkErr := s.linkArtifact(installID, dst, path)
	if linkErr != nil {
		res.ErrorDetail = &pb.ErrorDetail{
			Message:  linkErr.Error(),
			Category: linkErr.category,
		}
		slog.ErrorContext(ctx, linkErr.message, "exception", linkErr.Unwrap())
		return &res, nil
	}

	state.objects[name] = digest
	delete(state.pending, name)
	slog.InfoContext(ctx, "file linked", "rpc.install.digest", digest)

	if len(state.pending) == 0 {
		if err := s.store.CommitInstall(installID, state.objects); err != nil {
			res.ErrorDetail = &pb.ErrorDetail{
				Message:  fmt.Sprintf("failed to log install: %v", err),
				Category: pb.ErrorCategory_TIER_0,
			}
			slog.ErrorContext(ctx, "failed to log install", "exception", err)
		} else {
			delete(s.installs, installID)
			slog.InfoContext(ctx, "install completed")
		}
	}

	return &res, nil
}

// ShutdownServer implements /install.Installer/ShutdownServer.
func (s *Server) ShutdownServer(ctx context.Context, req *pb.ShutdownRequest) (*pb.ShutdownResponse, error) {
	close(s.done)

	slog.InfoContext(ctx, "shutting down")

	return &pb.ShutdownResponse{}, nil
}

func loggingInterceptor(
	ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler,
) (any, error) {
	ctx = withLogAttrs(ctx, slog.String("rpc.method", info.FullMethod))
	return handler(ctx, req)
}

// Serve serves the gRPC server over a [net.Listener].
func (s *Server) Serve(ctx context.Context, l net.Listener) error {
	gs := grpc.NewServer(grpc.UnaryInterceptor(loggingInterceptor))
	pb.RegisterInstallerServer(gs, s)

	server := make(chan error)
	go func() { server <- gs.Serve(l) }()

	select {
	case <-ctx.Done():
	case <-s.done:
	case err := <-server:
		return err
	}

	gs.GracefulStop()
	return nil
}
