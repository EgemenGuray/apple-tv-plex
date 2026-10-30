#!/bin/sh
# Generates PlexHDR.xcodeproj from project.yml and opens it in Xcode.
set -e
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
open PlexHDR.xcodeproj
