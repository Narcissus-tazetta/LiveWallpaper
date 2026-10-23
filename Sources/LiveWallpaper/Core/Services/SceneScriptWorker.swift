import Foundation

final class SceneScriptWorker {
    private let queue = DispatchQueue(label: "com.sakana.livewallpaper.script", qos: .userInteractive)
    private let evaluator = SceneFrameEvaluator()

    func evaluate(_ document: SceneDocument, input: SceneFrameInput, timeOfDay: SceneTimeOfDay, storage: SceneScriptStorage.Session = .scratch(),
                  completion: @escaping @MainActor (Result<SceneEvaluatedFrame, Error>) -> Void) {
        queue.async { [evaluator] in
            evaluator.storage = storage
            let result = Result { try evaluator.evaluate(document, input: input, timeOfDay: timeOfDay, failOnError: false) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }
}
