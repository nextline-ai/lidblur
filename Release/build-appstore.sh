#!/bin/zsh
# Archives LidBlur for the Mac App Store and exports a signed .pkg (no upload).
# Upload afterwards with Xcode Organizer or Transporter.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
rm -rf build/LidBlur.xcarchive build/export
xcodebuild archive -project LidBlur.xcodeproj -scheme LidBlur -configuration Release \
  -archivePath build/LidBlur.xcarchive -derivedDataPath build/dd-release -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/LidBlur.xcarchive \
  -exportOptionsPlist Release/ExportOptions-AppStore.plist -exportPath build/export -allowProvisioningUpdates
echo "Package: build/export/LidBlur.pkg"
