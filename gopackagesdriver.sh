#!/usr/bin/env sh

exec buck2 run prelude//go/tools/gopackagesdriver:gopackagesdriver -- "$@"
