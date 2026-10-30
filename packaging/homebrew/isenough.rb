# Homebrew formula template for the isenough CLI.
# The release workflow fills in VERSION and SHA256 from SHA256SUMS. Copy the result
# into a tap (for example s546126/homebrew-tap/Formula/isenough.rb).
class Isenough < Formula
  desc "Offload rarely used Mac apps to a repo and launch them on demand"
  homepage "https://github.com/s546126/256isenough"
  version "@VERSION@"
  url "https://github.com/s546126/256isenough/releases/download/v#{version}/isenough-#{version}-macos-universal.tar.gz"
  sha256 "@SHA256_TARBALL@"
  license "MIT"

  depends_on :macos

  def install
    # isenough looks for isenough-stub beside itself and for the page at ../share/isenough/web.
    bin.install "bin/isenough", "bin/isenough-stub"
    (share/"isenough").install "share/isenough/web"
    doc.install "README.md", "CHANGELOG.md", "PRIVACY.md", "THIRD_PARTY_NOTICES.md"
  end

  def caveats
    <<~EOS
      Stubs exec a stable copy of the engine under
        ~/Library/Application Support/256isenough/bin/isenough
      After installing or upgrading, refresh that copy and your stubs:
        isenough install-engine
        isenough stub refresh --app <bundle id>   # once per packed app; see `isenough list`

      Replacing apps in /Applications needs App Management permission for your
      terminal (System Settings > Privacy & Security > App Management).

      The menu-bar app is a separate cask: brew install --cask 256isenough
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/isenough version")
    output = shell_output("#{bin}/isenough 2>&1", 64)
    assert_match "isenough help", output
  end
end
