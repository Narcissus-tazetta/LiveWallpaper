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
                Text(model.localizedString("まだ投稿がありません"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
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

    private func storeMySubmissionRow(_ submission: StoreMySubmission) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(submission.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: storeMySubmissionStatusIcon(submission.lastKnownStatus))
                        .foregroundColor(storeMySubmissionStatusColor(submission.lastKnownStatus))
                    Text(storeMySubmissionStatusLabel(submission.lastKnownStatus))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                storeMySubmissions.remove(id: submission.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(model.localizedString("リストから削除(投稿自体は削除されません)"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

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
