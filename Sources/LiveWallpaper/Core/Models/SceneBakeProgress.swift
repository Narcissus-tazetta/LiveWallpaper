import Combine

@MainActor
final class SceneBakeProgress: ObservableObject {
    @Published var values: [String: Double] = [:]
}
