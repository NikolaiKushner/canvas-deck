#!/bin/sh
# Builds a Release Canvas Deck and launches it.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project CanvasDeck.xcodeproj -scheme CanvasDeck -configuration Release \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
  -skipPackagePluginValidation -skipMacroValidation build -quiet
pkill -x CanvasDeck 2>/dev/null || true
open build/Build/Products/Release/CanvasDeck.app
