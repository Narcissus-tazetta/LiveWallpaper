import AppKit

/// Storeカタログのサムネイル(リモート画像)専用のメモリ+ディスクキャッシュ。
/// `DiskThumbnailCache`(ローカル動画プレビュー用)と同じ設計パターン
/// (手動LRU、pendingQueue+inFlightによる同時実行数制御)を踏襲するが、
/// キーが`entry.id`(投稿後不変なのでURLではなくIDのみで一意)である点と、
/// ソースの更新検知(mtime/size再検証)が不要な点が異なる
/// (サムネイルはcontent-addressedで投稿後に変わらない)。
@MainActor
final class RemoteThumbnailCache: ObservableObject {
  enum InitializationState {
    case idle
    case loading
    case ready
  }

  struct Entry: Codable {
    var fileName: String
    var lastAccessAt: TimeInterval
  }

  struct Metadata: Codable {
    var version: Int
    var entries: [String: Entry]
  }

  @Published var revision: Int = 0

  private let maxInMemoryCount = 120
  private let maxDiskBytes: UInt64 = 100 * 1024 * 1024
  private let maxConcurrentFetches = 3
  private let requestTimeout: TimeInterval = 15
  nonisolated static let metadataVersion = 1
  nonisolated static let metadataFileName = "metadata.json"

  private var inMemoryImages: [String: NSImage] = [:]
  private var inMemoryLastAccess: [String: TimeInterval] = [:]
  private var urlByEntryID: [String: String] = [:]
  private var visibleRefCounts: [String: Int] = [:]
  private var pendingQueue: [String] = []
  private var inFlight: Set<String> = []
  private var inFlightReads: Set<String> = []
  private var failed: Set<String> = []
  private var deferredRequests: Set<String> = []

  private var metadata = Metadata(version: RemoteThumbnailCache.metadataVersion, entries: [:])
  private var initializationState: InitializationState = .idle
  private var metadataDirty = false
  private var metadataFlushWorkItem: DispatchWorkItem?
  private let metadataFlushDelay: TimeInterval = 2.0
  private let ioQueue = DispatchQueue(label: "LiveWallpaper.remoteThumbnailCache.io", qos: .utility)
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  /// メモリキャッシュにあれば即返す。無ければディスクキャッシュからの読み込みを
  /// スケジュールしつつ`nil`を返す(呼び出し側はfilm.stackプレースホルダーに
  /// フォールバックする)。実際のネットワークフェッチの起動は`setVisible`から行う。
  func image(for entry: StoreEntry) -> NSImage? {
    ensureInitialized()

    guard let urlString = entry.thumbnailURL else {
      return nil
    }
    urlByEntryID[entry.id] = urlString

    if let cached = inMemoryImages[entry.id] {
      touch(entry.id)
      return cached
    }

    guard initializationState == .ready else {
      return nil
    }

    if let diskEntry = metadata.entries[entry.id] {
      scheduleDiskRead(entryID: entry.id, fileName: diskEntry.fileName)
    }
    return nil
  }

  /// カードが画面に出入りするたびに呼ぶ(onAppear/onDisappear)。
  /// 初めて可視になったタイミングでのみフェッチを起動し、大量のカードが
  /// スクロールで一斉に流れても同時フェッチ数を`maxConcurrentFetches`に抑える。
  func setVisible(entryID: String, isVisible: Bool) {
    ensureInitialized()

    if isVisible {
      let previous = visibleRefCounts[entryID, default: 0]
      visibleRefCounts[entryID] = previous + 1
      if previous == 0 {
        request(entryID: entryID)
      }
      return
    }

    guard let count = visibleRefCounts[entryID] else {
      return
    }
    if count <= 1 {
      visibleRefCounts.removeValue(forKey: entryID)
      if let index = pendingQueue.firstIndex(of: entryID) {
        pendingQueue.remove(at: index)
      }
    } else {
      visibleRefCounts[entryID] = count - 1
    }
  }

  private func isVisible(_ entryID: String) -> Bool {
    (visibleRefCounts[entryID] ?? 0) > 0
  }

  private func request(entryID: String) {
    guard initializationState == .ready else {
      deferredRequests.insert(entryID)
      return
    }
    guard inMemoryImages[entryID] == nil else {
      touch(entryID)
      return
    }
    guard metadata.entries[entryID] == nil else {
      // ディスクキャッシュ済みなら次の image(for:) 呼び出しで読み込まれる。
      return
    }
    guard !failed.contains(entryID) else {
      return
    }
    guard urlByEntryID[entryID] != nil else {
      return
    }
    guard !inFlight.contains(entryID), !pendingQueue.contains(entryID) else {
      return
    }

    pendingQueue.append(entryID)
    processQueue()
  }

  private func processQueue() {
    guard initializationState == .ready else {
      return
    }
    while inFlight.count < maxConcurrentFetches, !pendingQueue.isEmpty {
      let entryID = pendingQueue.removeFirst()
      guard isVisible(entryID) else {
        continue
      }
      guard inMemoryImages[entryID] == nil else {
        continue
      }
      guard let urlString = urlByEntryID[entryID], let url = URL(string: urlString) else {
        continue
      }
      inFlight.insert(entryID)
      fetch(entryID: entryID, url: url)
    }
  }

  private func fetch(entryID: String, url: URL) {
    Task {
      let request = URLRequest(url: url, timeoutInterval: requestTimeout)
      do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
          throw URLError(.badServerResponse)
        }
        guard let image = NSImage(data: data) else {
          throw URLError(.cannotDecodeContentData)
        }
        finishFetch(entryID: entryID, result: (image, data))
      } catch {
        finishFetch(entryID: entryID, result: nil)
      }
    }
  }

  private func finishFetch(entryID: String, result: (image: NSImage, data: Data)?) {
    if let result {
      inMemoryImages[entryID] = result.image
      touch(entryID)
      trimInMemoryIfNeeded()
      writeToDisk(entryID: entryID, data: result.data)
    } else {
      // セッション内は再試行しない(アプリ再起動でリセットされる)。
      failed.insert(entryID)
    }

    inFlight.remove(entryID)
    processQueue()
    bumpRevision()
  }

  private func scheduleDiskRead(entryID: String, fileName: String) {
    guard !inFlightReads.contains(entryID) else {
      return
    }
    inFlightReads.insert(entryID)
    guard let fileURL = Self.dataDirectoryURL()?.appendingPathComponent(fileName) else {
      inFlightReads.remove(entryID)
      return
    }
    ioQueue.async { [weak self] in
      let data = try? Data(contentsOf: fileURL)
      Task { @MainActor in
        guard let self else {
          return
        }
        self.inFlightReads.remove(entryID)
        guard let current = self.metadata.entries[entryID], current.fileName == fileName else {
          return
        }
        guard let data, let image = NSImage(data: data) else {
          self.metadata.entries.removeValue(forKey: entryID)
          self.persistMetadata()
          return
        }
        self.inMemoryImages[entryID] = image
        self.touch(entryID)
        self.trimInMemoryIfNeeded()
        self.bumpRevision()
      }
    }
  }

  private func writeToDisk(entryID: String, data: Data) {
    guard let dataDirectoryURL = Self.dataDirectoryURL() else {
      return
    }
    let fileName = "\(CacheKeyHashing.hashed(entryID)).jpg"
    let fileURL = dataDirectoryURL.appendingPathComponent(fileName)
    ioQueue.async { [weak self] in
      do {
        try FileManager.default.createDirectory(
          at: dataDirectoryURL,
          withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
      } catch {
        return
      }
      Task { @MainActor in
        guard let self else {
          return
        }
        self.metadata.entries[entryID] = Entry(
          fileName: fileName,
          lastAccessAt: Date().timeIntervalSince1970
        )
        self.persistMetadata()
        self.trimDiskIfNeeded()
      }
    }
  }

  /// ディスク上のlastAccessAt更新(→永続化)をスロットルする間隔。`image(for:)`は
  /// キャッシュヒット時に毎回`touch`を呼ぶため(SwiftUIのview body評価のたびに
  /// 呼ばれうる)、無条件に`persistMetadata()`すると1エントリのタイムスタンプ更新の
  /// ためだけにmetadata辞書全体のJSONエンコードが頻発する。ディスク側のLRU退避は
  /// 秒単位の精度を必要としないため、これくらいの粒度で十分。
  private let diskTouchThrottleInterval: TimeInterval = 60

  private func touch(_ entryID: String) {
    let now = Date().timeIntervalSince1970
    inMemoryLastAccess[entryID] = now
    if var entry = metadata.entries[entryID], now - entry.lastAccessAt >= diskTouchThrottleInterval {
      entry.lastAccessAt = now
      metadata.entries[entryID] = entry
      persistMetadata()
    }
  }

  private func trimInMemoryIfNeeded() {
    guard inMemoryImages.count > maxInMemoryCount else {
      return
    }
    let removeCount = inMemoryImages.count - maxInMemoryCount
    let removable = inMemoryLastAccess.keys
      .filter { !isVisible($0) }
      .sorted {
        (inMemoryLastAccess[$0] ?? .leastNormalMagnitude)
          < (inMemoryLastAccess[$1] ?? .leastNormalMagnitude)
      }
    for key in removable.prefix(removeCount) {
      inMemoryImages.removeValue(forKey: key)
      inMemoryLastAccess.removeValue(forKey: key)
    }
  }

  private func trimDiskIfNeeded() {
    let entries = metadata.entries
    let maxBytes = maxDiskBytes
    guard let dataURL = Self.dataDirectoryURL() else {
      return
    }
    ioQueue.async { [weak self] in
      let fileManager = FileManager.default
      var sized: [(entryID: String, fileName: String, bytes: UInt64, lastAccessAt: TimeInterval)] = []
      var total: UInt64 = 0

      for (entryID, entry) in entries {
        let fileURL = dataURL.appendingPathComponent(entry.fileName)
        guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
          let size = attrs[.size] as? NSNumber
        else {
          continue
        }
        total += size.uint64Value
        sized.append((entryID, entry.fileName, size.uint64Value, entry.lastAccessAt))
      }

      guard total > maxBytes else {
        return
      }

      let sorted = sized.sorted { $0.lastAccessAt < $1.lastAccessAt }
      var overflow = total - maxBytes
      var removed: [(String, String)] = []

      for item in sorted {
        if overflow == 0 {
          break
        }
        let fileURL = dataURL.appendingPathComponent(item.fileName)
        try? fileManager.removeItem(at: fileURL)
        removed.append((item.entryID, item.fileName))
        overflow = overflow > item.bytes ? overflow - item.bytes : 0
      }

      guard !removed.isEmpty else {
        return
      }

      Task { @MainActor in
        guard let self else {
          return
        }
        for (entryID, fileName) in removed {
          guard let current = self.metadata.entries[entryID], current.fileName == fileName else {
            continue
          }
          self.metadata.entries.removeValue(forKey: entryID)
          self.inMemoryImages.removeValue(forKey: entryID)
          self.inMemoryLastAccess.removeValue(forKey: entryID)
        }
        self.persistMetadata()
      }
    }
  }

  private func persistMetadata() {
    metadataDirty = true
    scheduleMetadataFlush()
  }

  private func scheduleMetadataFlush() {
    metadataFlushWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        self?.flushMetadataIfNeeded()
      }
    }
    metadataFlushWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + metadataFlushDelay, execute: workItem)
  }

  private func flushMetadataIfNeeded() {
    guard metadataDirty else {
      return
    }
    metadataDirty = false
    metadataFlushWorkItem?.cancel()
    metadataFlushWorkItem = nil

    let snapshot = metadata
    guard let metadataURL = Self.metadataFileURL() else {
      return
    }
    ioQueue.async {
      guard let data = try? JSONEncoder().encode(snapshot) else {
        return
      }
      try? data.write(to: metadataURL, options: .atomic)
    }
  }

  private func ensureInitialized() {
    guard initializationState == .idle else {
      return
    }
    initializationState = .loading

    guard let dataURL = Self.dataDirectoryURL(), let metadataURL = Self.metadataFileURL() else {
      initializationState = .ready
      bumpRevision()
      return
    }
    ioQueue.async { [weak self] in
      let fileManager = FileManager.default
      var loadedMetadata = Metadata(version: RemoteThumbnailCache.metadataVersion, entries: [:])

      try? fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

      if let data = try? Data(contentsOf: metadataURL),
        let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
        decoded.version == RemoteThumbnailCache.metadataVersion
      {
        loadedMetadata = decoded
      }

      Task { @MainActor in
        guard let self else {
          return
        }
        self.metadata = loadedMetadata
        self.initializationState = .ready
        let pending = self.deferredRequests
        self.deferredRequests.removeAll()
        for entryID in pending {
          self.request(entryID: entryID)
        }
        self.bumpRevision()
      }
    }
  }

  /// `revision`はSettingsView全体が保持する@StateObjectのpublishedプロパティなので、
  /// 1回発火するたびにカタロググリッド全体のbodyが再評価される。一斉スクロールなどで
  /// 短時間に多数のフェッチ完了が重なると、毎回同期的にbumpすると同じ再描画コストを
  /// フェッチ件数分繰り返してしまうため、同一runloopターン内の複数回呼び出しを
  /// 1回の発火にまとめる。
  private var revisionBumpScheduled = false

  private func bumpRevision() {
    guard !revisionBumpScheduled else {
      return
    }
    revisionBumpScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      self.revisionBumpScheduled = false
      self.revision += 1
    }
  }

  private nonisolated static func rootDirectoryURL() -> URL? {
    DiskCacheLayout.rootDirectoryURL(subfolder: "ThumbnailCache/remote")
  }

  private nonisolated static func dataDirectoryURL() -> URL? {
    DiskCacheLayout.dataDirectoryURL(subfolder: "ThumbnailCache/remote")
  }

  private nonisolated static func metadataFileURL() -> URL? {
    DiskCacheLayout.metadataFileURL(subfolder: "ThumbnailCache/remote", metadataFileName: metadataFileName)
  }
}
