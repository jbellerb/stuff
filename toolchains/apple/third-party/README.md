This directory contains modified bits of the prelude for building with the OSS
verson of Buck2. Based on revision `e9737f0bfbce5c0d47e5bc2ff361bda2b7a08c31`.

### Local Modifications

- `apple/apple_test.bzl`: rewrite `_get_test_info` to use the internal test
  runner instead of TPX
- `apple/tools/bundling/`: point dependency on `code_signing:lib` to modified
  version. Script source needed because of target visibility
- `apple/tools/code_signing/`: remove dependency on Meta-internal platform
  configuration
