import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: WallpaperModel
  @State private var isAdvancedExpanded = false

  var body: some View {
    Form {
      Section(header: Text("動画")) {
        VStack(alignment: .leading, spacing: 6) {
          Text("選択中の動画")
            .font(.caption)
            .foregroundColor(.secondary)
          HStack(spacing: 12) {
            Text(model.currentVideoPath ?? "(選択なし)")
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button("参照") {
              NotificationCenter.default.post(name: .chooseVideo, object: nil)
            }
          }
        }
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
      }
      Section(header: Text("表示")) {
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

          if isAdvancedExpanded {
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 16) {
                HStack(spacing: 6) {
                  Text("フレームレート")
                  Image(systemName: "questionmark.circle")
                    .help("動画再生のフレームレート制限。オフは制限なし。")
                }
                .frame(width: 130, alignment: .leading)
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

              HStack(spacing: 16) {
                HStack(spacing: 6) {
                  Text("デコード")
                  Image(systemName: "questionmark.circle")
                    .help("デコード優先モード。省電力はソフトウェア中心。")
                }
                .frame(width: 130, alignment: .leading)
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

              HStack(spacing: 16) {
                HStack(spacing: 6) {
                  Text("デスクトップレベル")
                  Image(systemName: "questionmark.circle")
                    .help("デスクトップ基準のレベルを選択します。-1 は背面、0 は標準、+1 は前面です。")
                }
                .frame(width: 130, alignment: .leading)
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

              Toggle(
                isOn: Binding(
                  get: { model.useFullScreenAuxiliary },
                  set: { model.setFullScreenAuxiliary($0) }
                )
              ) {
                HStack(spacing: 6) {
                  Text("fullScreenAuxiliary を有効化")
                  Image(systemName: "questionmark.circle")
                    .help("フルスクリーン空間でもウィンドウを維持。動作が不安定になる可能性があります。")
                }
              }
            }
            .padding(.top, 6)
            .padding(.leading, 20)
          }
        }
      }
      Section(header: Text("キャッシュ")) {
        HStack(spacing: 10) {
          Button("保存先を開く") {
            NotificationCenter.default.post(name: .openCacheFolder, object: nil)
          }
          Button("キャッシュ削除") {
            NotificationCenter.default.post(name: .clearCache, object: nil)
          }
          Spacer()
        }
      }
      Section(header: Text("アップデート")) {
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
          Spacer()
        }
      }
      Section {
        Text("v\(model.currentAppVersion())")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 760, idealWidth: 760, minHeight: 460, idealHeight: 460)
  }
}

extension Notification.Name {
  static let chooseVideo = Notification.Name("ChooseVideo")
  static let toggleLaunchAtLogin = Notification.Name("ToggleLaunchAtLogin")
  static let openCacheFolder = Notification.Name("OpenCacheFolder")
  static let clearCache = Notification.Name("ClearCache")
  static let toggleAutoUpdate = Notification.Name("ToggleAutoUpdate")
  static let checkUpdatesNow = Notification.Name("CheckUpdatesNow")
}
