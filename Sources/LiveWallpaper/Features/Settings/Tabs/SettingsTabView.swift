import SwiftUI

struct SettingsTabView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
    }
}
