import SwiftUI

extension View {
    /// 壁紙・編集・Store タブで内容を区切るカードの共通背景。設定タブの grouped Form の
    /// セクションと同じ濃さに揃え、ライトモードでも輪郭が消えないよう細い縁を付ける。
    func settingsCardBackground(cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}
