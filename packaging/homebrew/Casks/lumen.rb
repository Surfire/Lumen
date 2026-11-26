cask "lumen" do
  # Release template: replace the version and digest from lumen-update.json before publishing.
  version "0.5.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Surfire/Lumen/releases/download/v#{version}/Lumen-macos-arm64.zip"
  name "Lumen"
  desc "Local search launcher for files, apps, and system actions"
  homepage "https://github.com/Surfire/Lumen"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Lumen.app"

  uninstall quit: "io.github.surfire.lumen"

  zap trash: [
    "~/Library/Application Support/Lumen",
    "~/Library/Preferences/io.github.surfire.lumen.plist",
  ]
end
