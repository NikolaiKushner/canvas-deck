#!/bin/sh
# Builds a Release Canvas Station and launches it. Signing is stable, so the
# Screen Recording and Accessibility permissions survive rebuilds.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project CanvasStation.xcodeproj -scheme CanvasStation -configuration Release \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackagePluginValidation -skipMacroValidation build -quiet
pkill -x CanvasStation 2>/dev/null || true
open build/Build/Products/Release/CanvasStation.app
