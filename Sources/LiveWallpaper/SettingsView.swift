import AVFoundation
import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  private enum SettingsTab: Hashable {
    case wallpaper
    case settings
  }

  private enum HelpTopic: Hashable {
    case frameRate
    case decode
    case desktopLevel
    case fullScreenAuxiliary
  }

  @ObservedObject var model: WallpaperModel
  @State private var selectedTab: SettingsTab = .settings
  @State private var isAdvancedExpanded: Bool = false
  @State private var volumeInput: String = ""
  @State private var expandedHelpTopics: Set<HelpTopic> = []
  @State private var hoveredHelpTopic: HelpTopic?
  @State private var wallpaperThumbnails: [String: NSImage] = [:]
  @State private var thumbnailGenerationInFlight: Set<String> = []
  @State private var editingWallpaperPath: String?
  @State private var editingWallpaperNameInput: String = ""
  @FocusState private var isVolumeInputFocused: Bool
  @FocusState private var focusedWallpaperPath: String?
  // even more compact grid for wallpapers
  private let wallpaperColumns: [GridItem] = [
    GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 6)
  ]

  var body: some View {
    Form {
      Section {
        HStack(spacing: 10) {
          tabButton(.settings, title: "設定", systemImage: "gearshape")
          tabButton(.wallpaper, title: "壁紙を変更", systemImage: "photo.on.rectangle")
          Spacer(minLength: 0)
        }
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.12))
        )
      }

      if selectedTab == .wallpaper {
        Section(header: Label("壁紙を変更", systemImage: "photo.on.rectangle")) {
          HStack(spacing: 12) {
            Text(
              model.currentVideoPath.map { model.registeredVideoDisplayName(for: $0) } ?? "(選択なし)"
            )
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("動画を追加") {
              NotificationCenter.default.post(name: .chooseVideo, object: nil)
            }
            .buttonStyle(.borderedProminent)
          }

          if model.registeredVideoPaths.isEmpty {
            Text("登録済みの壁紙はありません")
              .font(.caption)
              .foregroundColor(.secondary)
          } else {
            ScrollView {
              LazyVGrid(columns: wallpaperColumns, alignment: .leading, spacing: 12) {
                ForEach(model.registeredVideoPaths, id: \.self) { path in
                  wallpaperCard(path: path)
                }
              }
              .padding(.vertical, 2)
            }
            .frame(minHeight: 160, maxHeight: 200)
          }
        }
      }

      if selectedTab == .settings {
        Section(header: Label("動画", systemImage: "film")) {
          Toggle(
            "クリック貫通を有効にする",
            isOn: Binding(
              get: { model.clickThrough },
              set: { model.setClickThrough($0) }
            ))
          Toggle(
            "ログイン時に自動起動する",
            isOn: Binding(
              get: { UserDefaults.standard.bool(forKey: "launchAtLogin") },
              set: { NotificationCenter.default.post(name: .toggleLaunchAtLogin, object: $0) }
            ))
          Toggle(
            "音声を再生する",
            isOn: Binding(
              get: { model.audioEnabled },
              set: { value in withAnimation { model.setAudioEnabled(value) } }
            ))
          HStack(spacing: 10) {
            Text("音量")
              .frame(width: 150, alignment: .leading)

            Slider(
              value: Binding(
                get: { Double(model.audioVolume) },
                set: { model.setAudioVolume(Float($0)) }
              ),
              in: 0...1
            )
            .disabled(!model.audioEnabled)
            .frame(minWidth: 180, maxWidth: .infinity)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
              TextField("", text: $volumeInput)
                .frame(width: 48)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
                .disabled(!model.audioEnabled)
                .focused($isVolumeInputFocused)
                .onSubmit {
                  commitVolumeInput()
                }
                .onChange(of: volumeInput) { newValue in
                  let filtered = String(newValue.filter(\.isNumber).prefix(3))
                  if filtered != newValue {
                    volumeInput = filtered
                  }
                }
              Text("%")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            }
          }
        }
        Section(header: Label("表示", systemImage: "display.2")) {
          HStack(spacing: 16) {
            Text("壁紙の表示先")
              .frame(width: 130, alignment: .leading)
            Picker(
              "",
              selection: Binding(
                get: { model.displayMode },
                set: { model.setDisplayMode($0) }
              )
            ) {
              Text("メインのみ").tag(DisplayMode.mainOnly)
              Text("全ディスプレイ").tag(DisplayMode.allScreens)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240, alignment: .leading)
          }
          HStack(spacing: 16) {
            Text("動画のフィット")
              .frame(width: 130, alignment: .leading)
            Picker(
              "",
              selection: Binding(
                get: { model.fitMode },
                set: { model.setFitMode($0) }
              )
            ) {
              Text("拡大").tag(VideoFitMode.fill)
              Text("全体").tag(VideoFitMode.fit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240, alignment: .leading)
          }
          Toggle(
            "再生の軽量モード（省電力）",
            isOn: Binding(
              get: { model.lightweightMode },
              set: { model.setLightweightMode($0) }
            ))
          Toggle(
            "他のアプリが前面にあるとき再生を停止",
            isOn: Binding(
              get: { model.suspendWhenOtherAppFullScreen },
              set: { value in
                _ = model.setSuspendWhenOtherAppFullScreen(value)
              }
            ))
          if model.suspendWhenOtherAppFullScreen {
            VStack(alignment: .leading, spacing: 12) {
              HStack(alignment: .center) {
                Text("停止対象から除外するアプリ")
                  .font(.caption)
                  .foregroundColor(.secondary)
                Spacer()
                Button("アプリを選択して追加") {
                  selectAppForSuspendExclusion()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
              .padding(.vertical, 2)

              if model.suspendExclusionBundleIDs.isEmpty {
                Text("除外アプリは未設定です")
                  .font(.caption)
                  .foregroundColor(.secondary)
              } else {
                VStack(alignment: .leading, spacing: 8) {
                  ForEach(model.suspendExclusionBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 12) {
                      Text(bundleID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                      Button("削除") {
                        model.removeSuspendExclusionBundleID(bundleID)
                      }
                      .buttonStyle(.bordered)
                      .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                  }
                }
                .padding(.top, 4)
              }
            }
            .padding(.vertical, 6)
          }

          VStack(alignment: .leading, spacing: 0) {
            Button(action: { isAdvancedExpanded.toggle() }) {
              HStack(spacing: 8) {
                Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
                  .font(.caption.weight(.semibold))
                Text("詳細設定")
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)

            if isAdvancedExpanded {
              VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                  HStack {
                    Text("フレームレート")
                      .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: { toggleHelp(.frameRate) }) {
                      Image(
                        systemName: expandedHelpTopics.contains(.frameRate)
                          || hoveredHelpTopic == .frameRate
                          ? "questionmark.circle.fill" : "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .onHover { over in
                      hoveredHelpTopic = over ? .frameRate : nil
                    }
                  }
                  .frame(width: 150, alignment: .leading)
                  Picker(
                    "",
                    selection: Binding(
                      get: { model.frameRateLimit },
                      set: { model.setFrameRateLimit($0) }
                    )
                  ) {
                    Text("制限なし").tag(FrameRateLimit.off)
                    Text("30").tag(FrameRateLimit.fps30)
                    Text("60").tag(FrameRateLimit.fps60)
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
                  .frame(width: 240, alignment: .leading)
                }
                if expandedHelpTopics.contains(.frameRate) {
                  Text("動画の再生上限を選べます。制限なしは滑らかさ優先、30/60 はCPUと電力を抑えやすくなります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 24) {
                  HStack {
                    Text("デコード")
                      .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: { toggleHelp(.decode) }) {
                      Image(
                        systemName: expandedHelpTopics.contains(.decode)
                          || hoveredHelpTopic == .decode
                          ? "questionmark.circle.fill" : "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .onHover { over in
                      hoveredHelpTopic = over ? .decode : nil
                    }
                  }
                  .frame(width: 150, alignment: .leading)
                  Picker(
                    "",
                    selection: Binding(
                      get: { model.decodeMode },
                      set: { model.setDecodeMode($0) }
                    )
                  ) {
                    Text("自動").tag(DecodeMode.automatic)
                    Text("標準").tag(DecodeMode.balanced)
                    Text("省電力").tag(DecodeMode.efficiency)
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
                  .frame(width: 240, alignment: .leading)
                }
                if expandedHelpTopics.contains(.decode) {
                  Text(
                    "動画データのデコード方法を切り替えます。自動はハードウェア/ソフトウェアを状況に応じて選び、標準はGPUハードウェア優先で滑らかさを保ちます。省電力はソフトウェア再生を多用し、CPU負荷と消費電力を低く抑えますが再生品質が落ちる場合があります。"
                  )
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 24) {
                  HStack {
                    Text("デスクトップレベル")
                      .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: { toggleHelp(.desktopLevel) }) {
                      Image(
                        systemName: expandedHelpTopics.contains(.desktopLevel)
                          || hoveredHelpTopic == .desktopLevel
                          ? "questionmark.circle.fill" : "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .onHover { over in
                      hoveredHelpTopic = over ? .desktopLevel : nil
                    }
                  }
                  .frame(width: 150, alignment: .leading)
                  Picker(
                    "",
                    selection: Binding(
                      get: { model.desktopLevelOffset },
                      set: { model.setDesktopLevelOffset($0) }
                    )
                  ) {
                    Text("-1").tag(DesktopLevelOffset.minusOne)
                    Text("0").tag(DesktopLevelOffset.zero)
                    Text("+1").tag(DesktopLevelOffset.plusOne)
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
                  .frame(width: 240, alignment: .leading)
                }
                if expandedHelpTopics.contains(.desktopLevel) {
                  Text(
                    "壁紙用のウィンドウがデスクトップのどの層に置かれるかを切り替えます。-1だとほかのアプリのウィンドウより後ろ、0は一般的なデスクトップレベル、+1だとほかのウィンドウより前面に表示されます。前面にするとアイコンを隠しやすいですが、背面にするとほかのウィンドウ操作が妨げられにくくなります。"
                  )
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(
                  isOn: Binding(
                    get: { model.useFullScreenAuxiliary },
                    set: { model.setFullScreenAuxiliary($0) }
                  )
                ) {
                  HStack(spacing: 6) {
                    Text("fullScreenAuxiliary を有効化")
                    Button(action: { toggleHelp(.fullScreenAuxiliary) }) {
                      Image(
                        systemName: expandedHelpTopics.contains(.fullScreenAuxiliary)
                          || hoveredHelpTopic == .fullScreenAuxiliary
                          ? "questionmark.circle.fill" : "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .onHover { over in
                      hoveredHelpTopic = over ? .fullScreenAuxiliary : nil
                    }
                  }
                }
                if expandedHelpTopics.contains(.fullScreenAuxiliary) {
                  Text("フルスクリーン空間でも壁紙を維持しやすくします。環境によっては表示が不安定になる場合があります。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
              .padding(.top, 6)
              .padding(.leading, 20)
            }
          }
        }
        Section(header: Label("キャッシュ", systemImage: "externaldrive")) {
          HStack(spacing: 10) {
            Button("保存先を開く") {
              NotificationCenter.default.post(name: .openCacheFolder, object: nil)
            }
            .buttonStyle(.bordered)
            Button("キャッシュ削除") {
              NotificationCenter.default.post(name: .clearCache, object: nil)
            }
            .buttonStyle(.bordered)
            Spacer()
          }
        }
        Section(header: Label("アップデート", systemImage: "arrow.triangle.2.circlepath")) {
          Toggle(
            "アップデートを自動で確認する（起動時にも通知）",
            isOn: Binding(
              get: { UserDefaults.standard.bool(forKey: "autoUpdateEnabled") },
              set: { NotificationCenter.default.post(name: .toggleAutoUpdate, object: $0) }
            ))
          HStack {
            Button("今すぐ確認") {
              NotificationCenter.default.post(name: .checkUpdatesNow, object: nil)
            }
            .buttonStyle(.bordered)
            Spacer()
          }
        }
      }
      Section {
        Text("©︎Narcissus-tazetta 2026  •  v\(model.currentAppVersion())")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .onTapGesture {
      NSApp.keyWindow?.makeFirstResponder(nil)
    }
    .font(.system(size: 14, weight: .medium))
    .tint(.accentColor)
    .formStyle(.grouped)
    .frame(minWidth: 760, idealWidth: 760, minHeight: 460, idealHeight: 460)
    .onAppear {
      syncVolumeInputWithModel()
      pruneMissingWallpaperThumbnails()
    }
    .onChange(of: model.audioVolume) { _ in
      if !isVolumeInputFocused {
        syncVolumeInputWithModel()
      }
    }
    .onChange(of: model.registeredVideoPaths) { _ in
      pruneMissingWallpaperThumbnails()
    }
    .onChange(of: isVolumeInputFocused) { focused in
      if !focused {
        commitVolumeInput()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openWallpaperTab)) { _ in
      selectedTab = .wallpaper
    }
    .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { _ in
      selectedTab = .settings
    }
  }

  private func wallpaperCard(path: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        model.selectRegisteredVideo(path: path)
        selectedTab = .wallpaper
      } label: {
        Group {
          if let image = wallpaperThumbnails[path] {
            Image(nsImage: image)
              .resizable()
              .scaledToFill()
          } else {
            ZStack {
              Rectangle().fill(Color.secondary.opacity(0.15))
              Image(systemName: "film")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
            }
            .task {
              requestWallpaperThumbnail(path: path)
            }
          }
        }
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)

      if editingWallpaperPath == path {
        HStack(spacing: 4) {
          TextField(
            "名前",
            text: $editingWallpaperNameInput
          )
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .font(.system(size: 10))
          .focused($focusedWallpaperPath, equals: path)
          .onSubmit {
            commitWallpaperNameEdit(path: path)
          }

          Button {
            commitWallpaperNameEdit(path: path)
          } label: {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .semibold))
          }
          .controlSize(.mini)
          .buttonStyle(.borderless)

          Button {
            cancelWallpaperNameEdit()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 10, weight: .semibold))
          }
          .controlSize(.mini)
          .buttonStyle(.borderless)
        }
      } else {
        HStack(spacing: 2) {
          Text(model.registeredVideoDisplayName(for: path))
            .font(.system(size: 9))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

          Button {
            startWallpaperNameEdit(path: path)
          } label: {
            Image(systemName: "pencil")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.secondary.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          model.currentVideoPath == path ? Color.accentColor : Color.clear,
          lineWidth: 1.5
        )
    )
    .contextMenu {
      Button("この壁紙に切り替え") {
        model.selectRegisteredVideo(path: path)
      }
      Button("名前を編集") {
        startWallpaperNameEdit(path: path)
      }
      Button("登録から削除") {
        model.removeRegisteredVideo(path: path)
      }
    }
  }

  private func requestWallpaperThumbnail(path: String) {
    guard wallpaperThumbnails[path] == nil else {
      return
    }
    guard !thumbnailGenerationInFlight.contains(path) else {
      return
    }
    guard FileManager.default.fileExists(atPath: path) else {
      return
    }

    thumbnailGenerationInFlight.insert(path)

    let url = URL(fileURLWithPath: path)
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: 480, height: 270),
      scale: NSScreen.main?.backingScaleFactor ?? 2,
      representationTypes: .all
    )

    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
      if let cgImage = representation?.cgImage {
        let image = NSImage(
          cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        DispatchQueue.main.async {
          wallpaperThumbnails[path] = image
          thumbnailGenerationInFlight.remove(path)
        }
        return
      }

      DispatchQueue.global(qos: .userInitiated).async {
        let image = generateWallpaperThumbnail(path: path)
        DispatchQueue.main.async {
          if let image {
            wallpaperThumbnails[path] = image
          }
          thumbnailGenerationInFlight.remove(path)
        }
      }
    }
  }

  private func generateWallpaperThumbnail(path: String) -> NSImage? {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 420, height: 236)

    let times: [CMTime] = [
      CMTime(seconds: 0.2, preferredTimescale: 600), CMTime(seconds: 1.0, preferredTimescale: 600),
    ]
    for time in times {
      if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
      }
    }
    return nil
  }

  private func pruneMissingWallpaperThumbnails() {
    let valid = Set(model.registeredVideoPaths)
    wallpaperThumbnails = wallpaperThumbnails.filter { valid.contains($0.key) }
    thumbnailGenerationInFlight = thumbnailGenerationInFlight.filter { valid.contains($0) }
    if let editingPath = editingWallpaperPath, !valid.contains(editingPath) {
      cancelWallpaperNameEdit()
    }
  }

  private func startWallpaperNameEdit(path: String) {
    editingWallpaperPath = path
    editingWallpaperNameInput = model.registeredVideoDisplayName(for: path)
    focusedWallpaperPath = path
  }

  private func commitWallpaperNameEdit(path: String) {
    model.setRegisteredVideoDisplayName(editingWallpaperNameInput, for: path)
    cancelWallpaperNameEdit()
  }

  private func cancelWallpaperNameEdit() {
    editingWallpaperPath = nil
    editingWallpaperNameInput = ""
    focusedWallpaperPath = nil
  }

  private func tabButton(_ tab: SettingsTab, title: String, systemImage: String) -> some View {
    Button {
      selectedTab = tab
    } label: {
      Label(title, systemImage: systemImage)
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 130)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
        )
        .foregroundColor(selectedTab == tab ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }

  private func syncVolumeInputWithModel() {
    let percent = Int((model.audioVolume * 100).rounded())
    volumeInput = String(percent)
  }

  private func commitVolumeInput() {
    guard !volumeInput.isEmpty else {
      syncVolumeInputWithModel()
      return
    }
    let percent = min(max(Int(volumeInput) ?? 0, 0), 100)
    model.setAudioVolume(Float(percent) / 100)
    volumeInput = String(percent)
  }

  private func toggleHelp(_ topic: HelpTopic) {
    if expandedHelpTopics.contains(topic) {
      expandedHelpTopics.remove(topic)
    } else {
      expandedHelpTopics.insert(topic)
    }
  }

  private func selectAppForSuspendExclusion() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.canCreateDirectories = false
    if #available(macOS 12.0, *) {
      panel.allowedContentTypes = [.applicationBundle]
    } else {
      panel.allowedFileTypes = ["app"]
    }
    panel.allowsOtherFileTypes = false
    panel.treatsFilePackagesAsDirectories = false
    panel.prompt = "追加"

    if panel.runModal() == .OK,
      let url = panel.url
    {
      _ = model.addSuspendExclusionFromAppURL(url)
    }
  }
}

extension Notification.Name {
  static let chooseVideo = Notification.Name("ChooseVideo")
  static let openWallpaperTab = Notification.Name("OpenWallpaperTab")
  static let openSettingsTab = Notification.Name("OpenSettingsTab")
  static let toggleLaunchAtLogin = Notification.Name("ToggleLaunchAtLogin")
  static let openCacheFolder = Notification.Name("OpenCacheFolder")
  static let clearCache = Notification.Name("ClearCache")
  static let toggleAutoUpdate = Notification.Name("ToggleAutoUpdate")
  static let checkUpdatesNow = Notification.Name("CheckUpdatesNow")
}
