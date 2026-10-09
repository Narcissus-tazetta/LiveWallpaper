import SwiftUI

extension SettingsView {
    var storeMySubmissionsList: some View {
        Group {
            if let errorMessage = storeMySubmissions.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if storeMySubmissions.submissions.isEmpty {
                storeMySubmissionsInvite
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(storeMySubmissions.submissions) { submission in
                            storeMySubmissionRow(submission)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 320, maxHeight: 560)
            }
        }
    }

    private var storeMySubmissionsInvite: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text(model.localizedString("まだ投稿がありません"))
                .font(.headline)
            Text(model.localizedString("Store には誰でも壁紙を投稿できます。アカウント登録は不要で、審査のあと「みんなの投稿」に公開されます。"))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isStoreSharePickerPresented = true
            } label: {
                Label(model.localizedString("動画を共有"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.allRegisteredVideoPaths.isEmpty)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    private func storeMySubmissionRow(_ submission: StoreMySubmission) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(submission.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    let status = storeMySubmissionEffectiveStatus(submission)
                    Image(systemName: storeMySubmissionStatusIcon(status))
                        .foregroundColor(storeMySubmissionStatusColor(status))
                    Text(storeMySubmissionStatusLabel(status))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if submission.withdrawToken != nil {
                Button(role: .destructive) {
                    storeWithdrawTargetSubmission = submission
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .iconHelp(model.localizedString("取り下げる"))
            } else {
                Button {
                    storeMySubmissions.remove(id: submission.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .iconHelp(model.localizedString("リストから削除(投稿自体は削除されません)"))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// サーバーが "requested" のまま48時間応答がない投稿は、UI上は却下扱いにする。
    /// サーバー側のcron(scheduled())も同じ48時間基準で自動却下するが、次回の
    /// 実行までタイムラグがあるため、こちらは表示上のみなし(次回refreshAllで
    /// 実際のステータスが取得できればそちらを優先する)。
    private static let submissionReviewTimeout: TimeInterval = 48 * 60 * 60

    private func storeMySubmissionEffectiveStatus(_ submission: StoreMySubmission) -> String {
        guard submission.lastKnownStatus == "requested",
              let createdAt = Self.submissionDateFormatter.date(from: submission.createdAt)
                ?? Self.submissionDateFormatterNoFraction.date(from: submission.createdAt)
        else {
            return submission.lastKnownStatus
        }
        return Date().timeIntervalSince(createdAt) >= Self.submissionReviewTimeout
            ? "rejected"
            : submission.lastKnownStatus
    }

    private static let submissionDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let submissionDateFormatterNoFraction = ISO8601DateFormatter()

    private func storeMySubmissionStatusLabel(_ status: String) -> String {
        switch status {
        case "requested":
            return model.localizedString("審査中")
        case "published":
            return model.localizedString("公開済み")
        case "rejected":
            return model.localizedString("却下されました")
        default:
            return status
        }
    }

    private func storeMySubmissionStatusIcon(_ status: String) -> String {
        switch status {
        case "published":
            return "checkmark.circle.fill"
        case "rejected":
            return "xmark.circle.fill"
        default:
            return "clock.fill"
        }
    }

    private func storeMySubmissionStatusColor(_ status: String) -> Color {
        switch status {
        case "published":
            return .green
        case "rejected":
            return .red
        default:
            return .secondary
        }
    }
}
