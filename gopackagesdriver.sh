#!/usr/bin/env sh

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
export PATH=$SCRIPT_DIR/buck2/bin:$PATH

exec buck2 run prelude//go/tools/gopackagesdriver:gopackagesdriver -- "$@"
