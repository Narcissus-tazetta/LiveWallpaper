import SwiftUI

extension SettingsView {
    var storeShareSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.localizedString("Storeに共有"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(
                        model.localizedString(
                            "この動画(トリム/ループ設定を含む)をコミュニティStoreに送信します(公開には審査が必要です)"
                        )
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Button(model.localizedString("閉じる")) {
                    isStoreShareSheetPresented = false
                }
                .buttonStyle(.bordered)
                .disabled(storeShareStatus == .submitting)
            }

            Form {
                TextField(model.localizedString("タイトル"), text: $storeShareTitle)
                TextField(model.localizedString("作者名"), text: $storeShareAuthor)
                TextField(
                    model.localizedString("ライセンス(任意、例: CC-BY-4.0)"),
                    text: $storeShareLicense
                )
            }

            switch storeShareStatus {
            case .idle:
                EmptyView()
            case .submitting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.localizedString("アップロード中…"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case let .success(status):
                Label(
                    model.localizedString(
                        status == "published"
                            ? "公開しました"
                            : "申請しました。審査状況は「自分の投稿」から確認できます"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundColor(.green)
            case let .failure(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Spacer(minLength: 0)
                Button(model.localizedString("送信する")) {
                    submitCurrentVideoToStore()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    storeShareStatus == .submitting
                        || storeShareTitle.trimmingCharacters(in: .whitespaces).isEmpty
                        || storeShareAuthor.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }

    func submitCurrentVideoToStore() {
        guard let path = storeShareTargetPath else {
            return
        }
        let title = storeShareTitle.trimmingCharacters(in: .whitespaces)
        let author = storeShareAuthor.trimmingCharacters(in: .whitespaces)
        let license = storeShareLicense.trimmingCharacters(in: .whitespaces)
        storeShareStatus = .submitting
        Task {
            do {
                let client = StoreClient(packageExporter: PackageExporter())
                let result = try await client.submit(
                    model: model,
                    videoPath: path,
                    title: title,
                    author: author,
                    license: license.isEmpty ? nil : license,
                    thumbnailCache: thumbnailCache
                )
                storeShareStatus = .success(status: result.status)
                storeMySubmissions.record(
                    id: result.id,
                    title: title,
                    createdAt: result.createdAt,
                    withdrawToken: result.withdrawToken
                )
            } catch {
                storeShareStatus = .failure(message: error.localizedDescription)
            }
        }
    }
}
