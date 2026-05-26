import AppKit

extension AppDelegate {
  enum UpdateEnvironmentIssue {
    case translocated
    case outsideApplications
    case notWritable
  }

  func bundleURL() -> URL {
    Bundle.main.bundleURL.resolvingSymlinksInPath()
  }

  func applicationsDirectoryURL() -> URL? {
    FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first?
      .resolvingSymlinksInPath()
  }

  func isRunningFromAppTranslocation(bundlePath: String) -> Bool {
    bundlePath.contains("/AppTranslocation/")
  }

  func isInstalledInApplications(bundleURL: URL) -> Bool {
    guard let applicationsURL = applicationsDirectoryURL() else {
      return false
    }
    let appPath = bundleURL.path
    let applicationsPath = applicationsURL.path
    return appPath == applicationsPath || appPath.hasPrefix(applicationsPath + "/")
  }

  func canWriteBundleLocation(bundleURL: URL) -> Bool {
    let bundlePath = bundleURL.path
    let parentPath = bundleURL.deletingLastPathComponent().path
    return FileManager.default.isWritableFile(atPath: bundlePath)
      || FileManager.default.isWritableFile(atPath: parentPath)
  }

  func currentUpdateEnvironmentIssues() -> [UpdateEnvironmentIssue] {
    let bundle = bundleURL()
    let path = bundle.path
    var issues: [UpdateEnvironmentIssue] = []

    if isRunningFromAppTranslocation(bundlePath: path) {
      issues.append(.translocated)
    }
    if !isInstalledInApplications(bundleURL: bundle) {
      issues.append(.outsideApplications)
    }
    if !canWriteBundleLocation(bundleURL: bundle) {
      issues.append(.notWritable)
    }
    return issues
  }

  func updateEnvironmentIssueDescription(_ issue: UpdateEnvironmentIssue) -> String {
    switch issue {
    case .translocated:
      return localized("一時実行領域（AppTranslocation）から起動されています。")
    case .outsideApplications:
      return localized("アプリが /Applications 配下にありません。")
    case .notWritable:
      return localized("現在の配置先に書き込みできません。")
    }
  }

  func showUpdateEnvironmentAlert(issues: [UpdateEnvironmentIssue], title: String) {
    guard !issues.isEmpty else {
      return
    }
    let bulletText =
      issues
      .map { "・\(updateEnvironmentIssueDescription($0))" }
      .joined(separator: "\n")

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText =
      localized("アップデートの前提条件を満たしていません。")
      + "\n\n"
      + bulletText
      + "\n\n"
      + localized("LiveWallpaper.app を /Applications に移動して再起動してから、もう一度お試しください。")
    alert.alertStyle = .warning
    alert.runModal()
  }

  func ensureUpdateEnvironmentOrNotify(title: String) -> Bool {
    let issues = currentUpdateEnvironmentIssues()
    if issues.isEmpty {
      return true
    }
    showUpdateEnvironmentAlert(issues: issues, title: title)
    return false
  }

  func verifyUpdatePrerequisites() {
    let bundlePath: String = bundleURL().path
    NSLog("[Sparkle] Bundle path: \(bundlePath)")
    let issues = currentUpdateEnvironmentIssues()
    if !issues.isEmpty {
      for issue in issues {
        NSLog(
          "[Sparkle] Update prerequisite issue: \(updateEnvironmentIssueDescription(issue))"
        )
      }
      DispatchQueue.main.async {
        self.showUpdateEnvironmentAlert(
          issues: issues,
          title: self.localized("アップデートを有効化するにはアプリをApplicationsに移動してください")
        )
      }
    }
  }
}
