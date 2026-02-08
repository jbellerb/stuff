// Package thirdparty is a stub package listing all required third party
// dependencies.
//
// This package exists so the go tool can automatically collect dependencies,
// instead of needing to resolve them by hand.
package thirdparty

import (
	_ "github.com/zeebo/blake3"
	_ "golang.org/x/sys/unix"
	_ "google.golang.org/grpc"
	_ "google.golang.org/grpc/codes"
	_ "google.golang.org/grpc/status"
	_ "google.golang.org/protobuf/reflect/protoreflect"
	_ "google.golang.org/protobuf/runtime/protoimpl"
)
