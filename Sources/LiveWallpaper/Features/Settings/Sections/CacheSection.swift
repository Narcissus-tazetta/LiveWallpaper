import SwiftUI

extension SettingsView {
  static let cacheSearchKeywords: [String] = [
    "ストレージ",
    "容量",
    "キャッシュ",
    "保存先を開く",
    "キャッシュ削除",
    "動画とシーン",
    "作者設定バックアップ",
    "Aerialバックアップ",
    "外部シーン",
    "サムネイルキャッシュ",
    "未使用の動画を削除",
    "古いバックアップを削除",
    "Aerialバックアップを削除",
  ]

  var cacheSettingsSection: some View {
    StorageSettingsSection(model: model)
  }
}

struct StorageSettingsSection: View {
  @ObservedObject var model: WallpaperModel
  @State private var breakdown: StorageUsage.StorageBreakdown?
  @State private var orphanVideos: [StorageUsage.OrphanVideoItem] = []
  @State private var expiredBackups: [StorageUsage.BackupItem] = []
  @State private var aerialBackups: [StorageUsage.BackupItem] = []
  @State private var isScanning: Bool = false
  @State private var isConfirmingOrphanDeletion: Bool = false
  @State private var isConfirmingBackupDeletion: Bool = false
  @State private var isConfirmingAerialDeletion: Bool = false
  @State private var isConfirmingClearCache: Bool = false
  @State private var deletionError: String?

  private var orphanVideosTotalBytes: Int64 {
    orphanVideos.reduce(0) { $0 + $1.totalAllocatedBytes }
  }

  private var expiredBackupsTotalBytes: Int64 {
    expiredBackups.reduce(0) { $0 + $1.totalAllocatedBytes }
  }

  private var aerialBackupsTotalBytes: Int64 {
    aerialBackups.reduce(0) { $0 + $1.totalAllocatedBytes }
  }

  private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  private func refreshStorage() async {
    isScanning = true
    let referenced = model.allReferencedVideoPaths()
    let protectedText = model.preferencesProtectedText()
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let result = await Task.detached(priority: .userInitiated) {
      let b = StorageUsage.currentBreakdown()
      var orphans: [StorageUsage.OrphanVideoItem] = []
      var expired: [StorageUsage.BackupItem] = []
      var aerial: [StorageUsage.BackupItem] = []
      if let base = appSupport?.appendingPathComponent("LiveWallpaper", isDirectory: true) {
        orphans = StorageUsage.findOrphanVideos(
          in: base.appendingPathComponent("Videos", isDirectory: true),
          referencedVideoPaths: referenced,
          protectedText: protectedText
        )
        expired = StorageUsage.findExpiredAuthorSettingsBackups(
          in: base.appendingPathComponent("AuthorSettingsBackups", isDirectory: true)
        )
        aerial = StorageUsage.findBackups(
          in: base.appendingPathComponent("AerialBackups", isDirectory: true)
        )
      }
      return (b, orphans, expired, aerial)
    }.value

    breakdown = result.0
    orphanVideos = result.1
    expiredBackups = result.2
    aerialBackups = result.3
    isScanning = false
  }

  var body: some View {
    Section(header: SettingsSectionHeader(title: model.localizedString("ストレージ"))) {
      if let breakdown {
        LabeledContent(model.localizedString("動画とシーン"), value: formatBytes(breakdown.videosBytes))
        LabeledContent(model.localizedString("作者設定バックアップ"), value: formatBytes(breakdown.authorSettingsBackupsBytes))
        LabeledContent(model.localizedString("Aerialバックアップ"), value: formatBytes(breakdown.aerialBackupsBytes))
        LabeledContent(model.localizedString("外部シーン"), value: formatBytes(breakdown.externalScenesBytes))
        LabeledContent(model.localizedString("サムネイルキャッシュ"), value: formatBytes(breakdown.thumbnailCacheBytes))
      } else {
        HStack {
          ProgressView().controlSize(.small)
          Text(model.localizedString("計算中…"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 10) {
        Button(model.localizedString("保存先を開く")) {
          model.openCacheFolder()
        }
        .buttonStyle(.bordered)

        Button(model.localizedString("未使用の動画を削除")) {
          isConfirmingOrphanDeletion = true
        }
        .buttonStyle(.bordered)
        .disabled(orphanVideos.isEmpty)
        .confirmationDialog(
          model.localizedString("未使用の動画の削除"),
          isPresented: $isConfirmingOrphanDeletion,
          titleVisibility: .visible
        ) {
          Button(model.localizedString("削除"), role: .destructive) {
            runDeletion { try StorageUsage.deleteOrphans(orphanVideos) }
          }
          Button(model.localizedString("キャンセル"), role: .cancel) {}
        } message: {
          Text(String(
            format: model.localizedString("ライブラリ未登録の動画 %d件（%@）を削除しますか？"),
            orphanVideos.count,
            formatBytes(orphanVideosTotalBytes)
          ))
        }

        Button(model.localizedString("古いバックアップを削除")) {
          isConfirmingBackupDeletion = true
        }
        .buttonStyle(.bordered)
        .disabled(expiredBackups.isEmpty)
        .confirmationDialog(
          model.localizedString("古いバックアップの削除"),
          isPresented: $isConfirmingBackupDeletion,
          titleVisibility: .visible
        ) {
          Button(model.localizedString("削除"), role: .destructive) {
            runDeletion { try StorageUsage.deleteBackups(expiredBackups) }
          }
          Button(model.localizedString("キャンセル"), role: .cancel) {}
        } message: {
          Text(String(
            format: model.localizedString("古い作者設定バックアップ %d件（%@）を削除しますか？"),
            expiredBackups.count,
            formatBytes(expiredBackupsTotalBytes)
          ))
        }

        Spacer()
      }

      if !aerialBackups.isEmpty {
        HStack(spacing: 10) {
          Button(model.localizedString("Aerialバックアップを削除")) {
            isConfirmingAerialDeletion = true
          }
          .buttonStyle(.bordered)
          .disabled(model.lockScreenSyncService.hasActiveLease)
          .confirmationDialog(
            model.localizedString("Aerialバックアップの削除"),
            isPresented: $isConfirmingAerialDeletion,
            titleVisibility: .visible
          ) {
            Button(model.localizedString("削除"), role: .destructive) {
              guard !model.lockScreenSyncService.hasActiveLease else { return }
              runDeletion { try StorageUsage.deleteBackups(aerialBackups) }
            }
            Button(model.localizedString("キャンセル"), role: .cancel) {}
          } message: {
            Text(String(
              format: model.localizedString("Aerialバックアップ %d件（%@）を削除しますか？"),
              aerialBackups.count,
              formatBytes(aerialBackupsTotalBytes)
            ))
          }

          if model.lockScreenSyncService.hasActiveLease {
            Text(model.localizedString("現在ロック画面で使用中のため削除できません"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
      }

      HStack(spacing: 10) {
        Button(model.localizedString("キャッシュ削除"), role: .destructive) {
          isConfirmingClearCache = true
        }
        .buttonStyle(.bordered)
        .confirmationDialog(
          model.localizedString("キャッシュ削除"),
          isPresented: $isConfirmingClearCache,
          titleVisibility: .visible
        ) {
          Button(model.localizedString("削除"), role: .destructive) {
            NotificationCenter.default.post(name: .clearCache, object: nil)
            Task {
              await refreshStorage()
            }
          }
          Button(model.localizedString("キャンセル"), role: .cancel) {}
        } message: {
          Text(model.localizedString("登録された壁紙やサムネイルのキャッシュをすべて削除します。"))
        }

        Spacer()
      }
    }
    .task {
      await refreshStorage()
    }
    .alert(
      model.localizedString("ストレージ"),
      isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })
    ) {
      Button(model.localizedString("閉じる"), role: .cancel) {}
    } message: {
      Text(deletionError ?? "")
    }
  }

  /// A partial failure still frees what it could, so the list is refreshed either way.
  private func runDeletion(_ work: @escaping () throws -> Int64) {
    Task {
      do {
        _ = try work()
      } catch {
        deletionError = error.localizedDescription
      }
      await refreshStorage()
    }
  }
}
