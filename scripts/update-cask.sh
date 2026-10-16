#!/bin/bash
# Writes the ration cask for a release into a homebrew-tap checkout.
# Usage: scripts/update-cask.sh TAP_DIR VERSION SHA256
#
# Ration updates itself, so the cask says `auto_updates true` and `brew upgrade` leaves it alone.
set -euo pipefail
TAP="$1" VERSION="$2" SHA="$3"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/ration.rb" <<CASK
cask "ration" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/xinding33/ration/releases/download/v#{version}/Ration-#{version}.zip"
  name "Ration"
  desc "Menu bar app that shows Claude and ChatGPT subscription usage"
  homepage "https://github.com/xinding33/ration"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Ration.app"

  uninstall quit: "io.github.xinding33.ration"

  zap trash: [
    "~/Library/Application Support/Ration",
    "~/Library/LaunchAgents/io.github.xinding33.ration.plist",
    "~/Library/Preferences/io.github.xinding33.ration.plist",
  ]
end
CASK
