# Homebrew cask template for 256isenough.app (menu-bar app with the CLI inside).
# The release workflow fills in VERSION and SHA256. Copy the result into a tap
# (for example s546126/homebrew-tap/Casks/256isenough.rb).
cask "256isenough" do
  version "@VERSION@"
  sha256 "@SHA256_DMG@"

  url "https://github.com/s546126/256isenough/releases/download/v#{version}/256isenough-#{version}.dmg"
  name "256isenough"
  desc "Offload rarely used Mac apps to a repo and launch them on demand"
  homepage "https://github.com/s546126/256isenough"

  depends_on macos: ">= :ventura"
  conflicts_with formula: "isenough"

  app "256isenough.app"
  # The CLI and the stub launcher live in Contents/MacOS; the symlink resolves back into the app.
  binary "#{appdir}/256isenough.app/Contents/MacOS/isenough"

  uninstall quit: "io.github.s546126.256isenough"

  # Packed apps are still stubs after the app is removed. Run `isenough unpack` for
  # each one first if you want the real apps back; zap does not touch your repo.
  zap trash: [
    "~/Library/Application Support/256isenough",
    "~/Library/Caches/256isenough",
  ]

  caveats <<~EOS
    Before uninstalling, bring packed apps back with `isenough unpack APP`
    (or from the dashboard). After upgrading, run:
      isenough install-engine
      isenough stub refresh --app <bundle id>
  EOS
end
