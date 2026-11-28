cask "lumen" do
  # Release template: replace version and sha256 from lumen-update.json / SHA256SUMS.txt before publishing.
  version "0.6.4"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Surfire/Lumen/releases/download/v#{version}/Lumen-macos-arm64.zip"
  name "Lumen"
  desc "Native macOS fast file, pinyin, and offline semantic search launcher"
  homepage "https://github.com/Surfire/Lumen"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Lumen.app"

  caveats <<~EOS
    Community ad-hoc builds (without Apple Developer ID notarization) may trigger
    macOS Gatekeeper on first launch. If blocked, run once:
      xattr -dr com.apple.quarantine "/Applications/Lumen.app"
  EOS

  uninstall quit: "io.github.surfire.lumen"

  zap trash: [
    "~/Library/Application Support/Lumen",
    "~/Library/Preferences/io.github.surfire.lumen.plist",
  ]
end
