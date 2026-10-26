cask "agent-handler" do
  version "0.1.0"
  sha256 "4487858f04b05ca9a9fefeb24767efde44956b0671628f9b52ad46fcdc661579"

  url "https://github.com/gbettineschi/agent-handler/releases/download/v#{version}/AgentHandler.zip"
  name "Agent Handler"
  desc "Agent questions and approvals from the menu bar or notch"
  homepage "https://github.com/gbettineschi/agent-handler"

  depends_on macos: :sonoma

  app "Agent Handler.app"

  uninstall quit: "dev.gbettineschi.agent-handler"

  caveats <<~EOS
    This personal build is ad-hoc signed and not notarized. If macOS blocks it,
    approve it in System Settings > Privacy & Security after trying to open it.
    Quit Agent Handler before upgrading.
  EOS
end
