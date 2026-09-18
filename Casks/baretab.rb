# Homebrew cask for BareTab. Lives in a tap repo named `homebrew-tap` under the same GitHub
# account, at Casks/baretab.rb. Update `version` and `sha256` for each release; the sha is
# printed by scripts/release.sh and attached to the GitHub Release as a .sha256 file.
cask "baretab" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

  url "https://github.com/marcusmalloc/alt-tab-macos-but-free/releases/download/v#{version}/BareTab-#{version}.zip"
  name "BareTab"
  desc "Minimal native Command-Tab window switcher"
  homepage "https://github.com/marcusmalloc/alt-tab-macos-but-free"

  depends_on macos: ">= :ventura"

  app "BareTab.app"

  # The app is ad-hoc signed (no Apple Developer ID), so Gatekeeper would refuse to open it.
  # Clearing the quarantine flag lets it launch normally.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/BareTab.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.marcusmalloc.baretab.plist",
  ]

  caveats <<~EOS
    BareTab needs Accessibility access to take over Command-Tab:
      System Settings > Privacy & Security > Accessibility > enable BareTab
    Because the app is not notarized, macOS may ask you to grant this again after an upgrade.
  EOS
end
