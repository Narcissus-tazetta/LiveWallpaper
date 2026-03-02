import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: WallpaperModel

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
