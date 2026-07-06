cask "livewallpaper" do
  version "1.2.2"
  sha256 "5356ac77729cafc328edbca4ecd93ca22efac1253ccfe8a26f4c0c4faebf90fd"

  url "https://github.com/Narcissus-tazetta/LiveWallpaper/releases/download/v#{version}/LiveWallpaper-macos-v#{version}.zip"
  name "LiveWallpaper"
  desc "Set your favorite videos as Mac desktop wallpaper"
  homepage "https://github.com/Narcissus-tazetta/LiveWallpaper"

  depends_on macos: :ventura

  app "LiveWallpaper.app"

  zap trash: [
    "~/Library/Application Support/LiveWallpaper",
    "~/Library/Preferences/com.sakana.livewallpaper.plist",
    "~/Library/Saved Application State/com.sakana.livewallpaper.savedState",
  ]
end
