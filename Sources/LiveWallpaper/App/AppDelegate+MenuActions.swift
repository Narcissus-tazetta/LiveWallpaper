import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
  @objc func openSettings() {
    syncLaunchAtLoginState()
    refreshSpacesForSettingsUI()
    settingsWindowController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .openSettingsTab, object: nil)
  }

  @objc func openWallpaperTab() {
    syncLaunchAtLoginState()
    refreshSpacesForSettingsUI()
    settingsWindowController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .openWallpaperTab, object: nil)
  }

  @objc func openWallpaperFitTab() {
    syncLaunchAtLoginState()
    refreshSpacesForSettingsUI()
    settingsWindowController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .openWallpaperFitTab, object: nil)
  }

  /// 設定UIのデスクトップ一覧・「(現在)」表示をウィンドウ表示時点の状態に更新する。
  private func refreshSpacesForSettingsUI() {
    if wallpaperModel.spaceWallpaperFeatureEnabled {
      wallpaperModel.refreshSpacesSnapshot()
    }
  }

  func setAudioEnabled(_ enabled: Bool) {
    wallpaperModel.setAudioEnabled(enabled)
    if let toggleItem = statusItem?.menu?.item(withTag: MenuTag.audioToggle) {
      toggleItem.title = audioMenuTitle(enabled)
      toggleItem.image = audioMenuIcon(enabled)
    }
  }

  @objc func toggleAudioEnabled() {
    setAudioEnabled(!wallpaperModel.audioEnabled)
  }

  @objc func togglePlaylistPlayback() {
    wallpaperModel.setPlaylistPlaybackEnabled(!wallpaperModel.playlistPlaybackEnabled)
  }

  @objc func togglePinCurrentVideo() {
    guard wallpaperModel.canPinCurrentVideo else {
      return
    }
    wallpaperModel.setPinCurrentVideo(!wallpaperModel.pinCurrentVideo)
  }

  @objc func toggleShufflePlayback() {
    wallpaperModel.setShufflePlaybackEnabled(!wallpaperModel.shufflePlaybackEnabled)
  }

  /// 今メインディスプレイに実際に表示されている壁紙を、いま見ているデスクトップ
  /// (Space)に固定/解除する。メインディスプレイがディスプレイ別/Space別オーバー
  /// ライドで専用プレイヤー担当になっている場合、共有プレイヤーの currentVideoPath
  /// は無関係(別の動画)なので、必ず resolvedOverridePath を優先して実際に見えて
  /// いる動画を取得する。
  @objc func toggleAssignToCurrentSpace() {
    guard let uuid = wallpaperModel.currentSpaceUUIDForMainDisplay,
      let path = wallpaperModel.currentlyVisiblePathForMainDisplay
    else {
      return
    }
    if wallpaperModel.spaceVideo(forSpaceUUID: uuid) == path {
      wallpaperModel.setSpaceVideo(path: nil, forSpaceUUID: uuid)
    } else {
      wallpaperModel.setSpaceVideo(path: path, forSpaceUUID: uuid)
    }
    refreshPlaybackMenuState()
  }

  @objc func playPreviousVideo() {
    wallpaperModel.playPreviousVideo()
  }

  @objc func playNextVideo() {
    wallpaperModel.playNextVideo()
  }

  @objc func refreshPlaybackState() {
    wallpaperModel.refreshPlaybackState()
  }

  @objc func exportPackage() {
    openWallpaperTab()
    NotificationCenter.default.post(name: .openWallpaperShareSheet, object: nil)
  }

  @objc func importPackage() {
    let panel = NSOpenPanel()
    panel.title = localized("壁紙を読み込む")
    if #available(macOS 11.0, *) {
      panel.allowedContentTypes = [UTType(filenameExtension: "lwpkg") ?? .data]
    } else {
      panel.allowedFileTypes = ["lwpkg"]
    }
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK, let url = panel.urls.first else { return }

    let importer = PackageImporter()

    func showImportSucceededAlert() {
      let alert = NSAlert()
      alert.messageText = localized("インポート完了")
      alert.informativeText = localized("パッケージが正常にインポートされました。")
      alert.alertStyle = .informational
      alert.runModal()
    }

    func showImportFailedAlert(_ message: String) {
      let alert = NSAlert()
      alert.messageText = localized("インポートに失敗")
      alert.informativeText = message
      alert.alertStyle = .critical
      alert.runModal()
    }

    func importWithResolution(_ resolution: PackageImporter.DuplicateResolution) {
      Task {
        do {
          try await importer.importPackage(
            from: url,
            into: wallpaperModel,
            duplicateResolution: resolution
          )
          showImportSucceededAlert()
        } catch let PackageImporter.ImportError.duplicateVideo(name) {
          let duplicateAlert = NSAlert()
          duplicateAlert.messageText = localized("重複するビデオが見つかりました")
          duplicateAlert.informativeText = "\(name) " + localized("は既に存在します。置き換えますか？")
          duplicateAlert.alertStyle = .warning
          duplicateAlert.addButton(withTitle: localized("中止"))
          duplicateAlert.addButton(withTitle: localized("置き換える"))

          if duplicateAlert.runModal() == .alertSecondButtonReturn {
            importWithResolution(.replace)
          }
        } catch {
          showImportFailedAlert(error.localizedDescription)
        }
      }
    }

    importWithResolution(.abort)
  }

  @objc func openReleasePage() {
    guard let url = URL(string: "https://github.com/Narcissus-tazetta/LiveWallpaper/releases")
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc func quitApp() {
    NSApp.terminate(nil)
  }
}
