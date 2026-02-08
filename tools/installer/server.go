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

	pb "tools/installer/third-party/buckproto/install"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var (
	errNotFound   = errors.New("file not found in pending installs")
	errFileExists = errors.New("file already exists at destination")
)

type Server struct {
	pb.UnimplementedInstallerServer

	mu       sync.Mutex
	installs map[string]map[string]struct{}
	done     chan struct{}
}

// NewServer creates a new installer server.
func NewServer() *Server {
	return &Server{
		installs: make(map[string]map[string]struct{}),
		done:     make(chan struct{}),
	}
}

// Install implements /install.Installer/Install.
func (s *Server) Install(
	ctx context.Context, req *pb.InstallInfoRequest,
) (*pb.InstallResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	installId := req.GetInstallId()
	filesMap := req.GetFiles()

	files := make(map[string]struct{})
	for dest := range filesMap {
		files[dest] = struct{}{}
	}
	s.installs[installId] = files

	slog.InfoContext(
		ctx,
		"registered install task",
		"rpc.install.id", installId,
		"rpc.install.pending", len(files),
	)

	return &pb.InstallResponse{InstallId: installId}, nil
}

func createSymlink(dest, source string) error {
	if strings.HasPrefix(dest, "~/") {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("failed to get home directory: %w", err)
		}
		dest = filepath.Join(homeDir, dest[2:])
	}

	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return fmt.Errorf("failed to create parent directories: %w", err)
	}

	for {
		if err := os.Symlink(source, dest); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrExist) {
			return fmt.Errorf("failed to create symlink: %w", err)
		}

		info, err := os.Lstat(dest)
		if err != nil {
			return fmt.Errorf("failed to stat destination: %w", err)
		} else if info.Mode()&os.ModeSymlink == 0 {
			return errFileExists
		} else if err := os.Remove(dest); err != nil {
			return fmt.Errorf("failed to remove existing symlink: %w", err)
		}
	}
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

	files := s.installs[installID]
	if _, ok := files[name]; !ok {
		slog.ErrorContext(ctx, "bad request", "exception", errNotFound.Error())
		return nil, status.Error(codes.NotFound, errNotFound.Error())
	}

	res := &pb.FileResponse{InstallId: installID, Name: name, Path: path}
	if err := createSymlink(name, path); err != nil {
		res.ErrorDetail = &pb.ErrorDetail{
			Message:  err.Error(),
			Category: pb.ErrorCategory_ENVIRONMENT,
		}
		if errors.Is(err, errFileExists) {
			res.ErrorDetail.Category = pb.ErrorCategory_INPUT
		}
		slog.ErrorContext(ctx, "failed to create symlink", "exception", err.Error())
	} else {
		delete(files, name)
		slog.InfoContext(ctx, "created symlink", "rpc.install.pending", len(files))
	}

	return res, nil
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
