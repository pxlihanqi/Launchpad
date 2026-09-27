import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @State private var hotKey: Prefs.HotKeyPreset = Prefs.hotKey
    @State private var launchAtLogin: Bool = Prefs.launchAtLogin
    @State private var hideDockIcon: Bool = Prefs.hideDockIcon
    @State private var backdropStyle: BackdropStyle = Prefs.backdropStyle
    @State private var backdropOpacity: Double = Prefs.backdropOpacity
    @State private var backdropBlur: Double = Prefs.backdropBlur
    @State private var iconScale: Double = Prefs.iconScale
    @State private var gridColumns: Int = Prefs.gridColumns
    @State private var includeSystemTools: Bool = Prefs.includeSystemTools
    @State private var pinchToOpen: Bool = Prefs.pinchToOpen
    @State private var message: String?

    var body: some View {
        Form {
            Section("启动") {
                Picker("唤起快捷键", selection: $hotKey) {
                    ForEach(Prefs.HotKeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .onChange(of: hotKey) { _, value in
                    Prefs.hotKey = value
                    GlobalHotKey.shared.registerDefault()
                }
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        Prefs.launchAtLogin = value
                        updateLoginItem(enabled: value)
                    }
                Toggle("隐藏程序坞（Dock）里的图标", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, value in
                        Prefs.hideDockIcon = value
                        AppDelegate.applyDockIconVisibility()
                        message = value
                            ? "已隐藏程序坞图标：仍可从菜单栏图标或快捷键（\(Prefs.hotKey.title)）唤起，退出也走菜单栏菜单"
                            : "程序坞里会显示图标，点击直接进入启动台"
                    }
                Toggle("触控板捏合手势打开/关闭启动台", isOn: $pinchToOpen)
                    .onChange(of: pinchToOpen) { _, value in
                        Prefs.pinchToOpen = value
                        message = value
                            ? "已开启：在任意界面用拇指+三指捏合即可唤起（若无效，请在 系统设置 → 隐私与安全性 → 辅助功能 里允许启动台）"
                            : "已关闭捏合手势"
                    }
            }

            Section("外观") {
                Picker("背景方式", selection: $backdropStyle) {
                    ForEach(BackdropStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .onChange(of: backdropStyle) { _, value in
                    Prefs.backdropStyle = value
                    WallpaperProvider.shared.invalidate()
                    message = value.detail
                    OverlayCoordinator.shared.refreshBackdrops()
                }
                Text(backdropStyle.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if backdropStyle == .image {
                    HStack(spacing: 10) {
                        Button("选择图片…") { chooseBackdropImage() }
                        Button("移除图片") {
                            CustomBackdrop.remove()
                            WallpaperProvider.shared.invalidate()
                            backdropStyle = .blur
                            Prefs.backdropStyle = .blur
                            OverlayCoordinator.shared.applyAppearanceChange()
                            message = "已移除自定义背景"
                        }
                        Text(CustomBackdrop.hasImage ? CustomBackdrop.displayName : "还没有选择图片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $backdropBlur, in: 0...Prefs.maxBackdropBlur) {
                            Text("背景模糊")
                        } minimumValueLabel: {
                            Image(systemName: "photo")
                        } maximumValueLabel: {
                            Image(systemName: "drop.fill")
                        }
                        .onChange(of: backdropBlur) { _, value in
                            Prefs.backdropBlur = value
                            OverlayCoordinator.shared.applyAppearanceChange()
                        }
                        Text(backdropBlur < 1
                             ? "当前：原图不模糊"
                             : "当前 \(Int(backdropBlur))　往右更模糊（和系统壁纸约 46 的量级相当）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $backdropOpacity, in: 0.25...1.0) {
                        Text("背景不透明度")
                    } minimumValueLabel: {
                        Image(systemName: "moon.fill")
                    } maximumValueLabel: {
                        Image(systemName: "sun.max.fill")
                    }
                    .onChange(of: backdropOpacity) { _, value in
                        Prefs.backdropOpacity = value
                        OverlayCoordinator.shared.applyAppearanceChange()
                    }
                    Text("当前 \(Int(backdropOpacity * 100))%　往右更透亮，往左更暗；两种背景方式都适用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $iconScale, in: 0.7...1.35) {
                        Text("图标大小")
                    } minimumValueLabel: {
                        Image(systemName: "square.grid.3x3.fill")
                    } maximumValueLabel: {
                        Image(systemName: "square.grid.2x2.fill")
                    }
                    .onChange(of: iconScale) { _, value in
                        Prefs.iconScale = value
                        OverlayCoordinator.shared.applyAppearanceChange()
                    }
                    Text("当前 \(Int(iconScale * 100))%　名字字号会跟着图标一起缩放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("每行图标数量", selection: $gridColumns) {
                    Text("自动（按屏幕宽度）").tag(0)
                    ForEach(Prefs.minColumns...Prefs.maxColumns, id: \.self) { count in
                        Text("\(count) 个").tag(count)
                    }
                }
                .onChange(of: gridColumns) { _, value in
                    Prefs.gridColumns = value
                    OverlayCoordinator.shared.applyAppearanceChange()
                }
                Text(gridColumns == 0
                     ? "当前自动：大屏 7 列 × 5 行，小屏会自动减少列数"
                     : "当前固定 \(gridColumns) 列 × 5 行 = 每页 \(gridColumns * 5) 个；改动后图标会按顺序重新分页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("布局") {
                Toggle("显示系统工具类应用（钥匙串访问、归档实用工具等）", isOn: $includeSystemTools)
                    .onChange(of: includeSystemTools) { _, value in
                        Prefs.includeSystemTools = value
                        LaunchpadController.shared.catalog.reload()
                        LaunchpadController.shared.refreshCatalog()
                        message = value ? "已包含系统工具类应用" : "已按要求排除系统工具类应用"
                    }
                Button("重新扫描应用程序") {
                    LaunchpadController.shared.catalog.reload()
                    LaunchpadController.shared.refreshCatalog()
                    message = "已重新扫描"
                }
                Button("恢复所有隐藏的应用") {
                    LaunchpadController.shared.unhideAll()
                    message = "已恢复"
                }
                Button("从旧版启动台导入布局") {
                    if let result = LaunchpadDBImporter.importLayout(catalog: LaunchpadController.shared.catalog) {
                        LaunchpadController.shared.replaceLayout(with: result.layout)
                        message = "已导入：\(result.summary)"
                    } else {
                        message = "未找到旧数据库"
                    }
                }
                Button("重置为默认排序") {
                    LaunchpadController.shared.resetToAlphabetical()
                    message = "已重置"
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 700)
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "登录项设置失败：\(error.localizedDescription)"
        }
    }

    /// 选一张本地图片当背景：图片会被复制进应用支持目录，之后移动原图也不影响。
    private func chooseBackdropImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "用作背景"
        panel.message = "选一张图片作为启动台背景（不会修改原图）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CustomBackdrop.importImage(from: url) else {
            message = "这张图片读不出来，换一张试试"
            return
        }
        backdropStyle = .image
        Prefs.backdropStyle = .image
        WallpaperProvider.shared.invalidate()
        OverlayCoordinator.shared.applyAppearanceChange()
        message = "已把「\(url.lastPathComponent)」设为背景"
    }
}
