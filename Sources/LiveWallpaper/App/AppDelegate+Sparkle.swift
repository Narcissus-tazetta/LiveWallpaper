#if canImport(Sparkle)
    import AppKit
    import Sparkle

    extension AppDelegate {
        func setupSparkleUpdater() {
            guard let publicEDKey = Self.sparklePublicEDKeyValue(), !publicEDKey.isEmpty else {
                AppLog.sparkle.error("publicEDKey is empty")
                return
            }
            guard let feedURL = Self.sparkleFeedURLValue(), !feedURL.isEmpty else {
                AppLog.sparkle.error("feedURL is empty")
                return
            }
            AppLog.sparkle.debug("feedURL=\(feedURL, privacy: .public)")

            let updaterController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            self.updaterController = updaterController

            let updater = updaterController.updater
            let canUseAutomaticUpdates = autoUpdateEnabled
                && currentUpdateEnvironmentIssues().isEmpty
            updater.automaticallyChecksForUpdates = canUseAutomaticUpdates
            updater.automaticallyDownloadsUpdates = canUseAutomaticUpdates

            do {
                try updater.start()
                sparkleStarted = true
                AppLog.sparkle.debug("updater.start() succeeded")
                if canUseAutomaticUpdates {
                    updater.checkForUpdatesInBackground()
                    AppLog.sparkle.debug("checkForUpdatesInBackground() requested")
                } else {
                    AppLog.sparkle.debug("automatic updates are disabled due to update prerequisites")
                }
            } catch {
                Self.reportSparkleError(error)
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = self.localized("アップデータ初期化に失敗しました")
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }

        nonisolated static func reportSparkleError(_ error: Error) {
            AppLog.sparkle.error("\(error.localizedDescription, privacy: .public)")
        }

        nonisolated static func sparkleFeedURLValue() -> String? {
            if let value: String = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
               !value.isEmpty
            {
                return value
            }
            return AppConfig.sparkleAppcastURL
        }

        nonisolated static func sparklePublicEDKeyValue() -> String? {
            if let value: String = Bundle.main
                .object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                !value.isEmpty
            {
                return value
            }
            if !AppConfig.sparklePublicEDKey.isEmpty {
                return AppConfig.sparklePublicEDKey
            }
            return nil
        }

        @objc func checkForUpdates() {
            guard ensureUpdateEnvironmentOrNotify(
                title: localized("アップデートを確認する前に移動が必要です")
            ) else {
                manualUpdateCheckPending = false
                return
            }

            syncLaunchAtLoginState()
            settingsWindowController?.showWindow(nil)
            settingsWindowController?.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            AppLog.sparkle.debug("manual checkForUpdates() requested")
            manualUpdateCheckPending = true
            guard let updater = updaterController?.updater else {
                AppLog.sparkle.error("updaterController is nil")
                manualUpdateCheckPending = false
                return
            }

            if !sparkleStarted {
                do {
                    try updater.start()
                    sparkleStarted = true
                    AppLog.sparkle.debug("updater.start() succeeded from manual check")
                } catch {
                    Self.reportSparkleError(error)
                    manualUpdateCheckPending = false
                    let alert = NSAlert()
                    alert.messageText = localized("アップデータ初期化に失敗しました")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
            }

            updaterController?.checkForUpdates(nil)
        }
    }

    extension AppDelegate: SPUUpdaterDelegate {
        nonisolated func feedURLString(for _: SPUUpdater) -> String? {
            Self.sparkleFeedURLValue()
        }

        nonisolated func publicEDKey(for _: SPUUpdater) -> String? {
            Self.sparklePublicEDKeyValue()
        }

        nonisolated func updater(_: SPUUpdater, didAbortWithError error: Error) {
            Task { @MainActor in
                self.manualUpdateCheckPending = false
            }
            Self.reportSparkleError(error)
        }

        nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
            Task { @MainActor in
                if self.manualUpdateCheckPending {
                    self.manualUpdateCheckPending = false
                }
            }
        }
    }
#endif
