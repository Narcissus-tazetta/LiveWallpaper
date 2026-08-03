import AppKit

/// フィット編集タブの静止画プレビュー(生成・キャッシュ・世代管理)。
extension FitEditorController {
    private var stillImageLimit: Int {
        10
    }

    func setPreviewMode(_ mode: FitPreviewMode) {
        guard previewMode != mode else {
            return
        }
        previewMode = mode
        prepareStillImageIfNeeded()
    }

    func prepareStillImageIfNeeded() {
        guard isActive else {
            return
        }
        guard previewMode == .still else {
            return
        }
        guard let path = resolvedVideoPath(), !path.isEmpty else {
            return
        }
        requestStillImage(path: path)
    }

    func requestStillImage(path: String) {
        guard isActive else {
            return
        }
        guard previewMode == .still else {
            return
        }
        guard path == resolvedVideoPath() else {
            return
        }
        guard stillImages[path] == nil else {
            return
        }
        guard !stillImageInFlight.contains(path) else {
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        stillImageInFlight.insert(path)

        let generation = UUID()
        stillImageGeneration[path] = generation

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let image = await FitPreviewService.generateStillImage(path: path)
            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }
                // A newer request for the same path may have superseded this one
                // (e.g. rapid A -> B -> A selection); only this generation's
                // completion may mutate the shared in-flight/task bookkeeping.
                guard stillImageGeneration[path] == generation else {
                    return
                }
                if !Task.isCancelled, let image {
                    stillImages[path] = image
                    stillImageOrder.removeAll { $0 == path }
                    stillImageOrder.append(path)
                    trimStillImagesIfNeeded()
                }
                stillImageInFlight.remove(path)
                stillImageTasks.removeValue(forKey: path)
                stillImageGeneration.removeValue(forKey: path)
            }
        }
        stillImageTasks[path] = task
    }

    private func trimStillImagesIfNeeded() {
        guard stillImageOrder.count > stillImageLimit else {
            return
        }
        let overflow = stillImageOrder.count - stillImageLimit
        for path in stillImageOrder.prefix(overflow) {
            stillImages.removeValue(forKey: path)
        }
        stillImageOrder.removeFirst(overflow)
    }

    func cancelStillGeneration(exceptPath: String?) {
        for (path, task) in stillImageTasks where path != exceptPath {
            task.cancel()
            stillImageTasks.removeValue(forKey: path)
            stillImageInFlight.remove(path)
            stillImageGeneration.removeValue(forKey: path)
        }
    }
}
