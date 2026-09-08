#!/usr/bin/env bash
# Build any spike: ./build.sh spike   ->  ./spike
set -euo pipefail
swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight "$1.swift" -o "$1"
