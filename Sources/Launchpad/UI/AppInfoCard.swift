import AppKit
import SwiftUI

/// ⌥ 点图标弹出的小卡片：版本、路径、大小、最近打开时间。
struct AppInfoCardView: View {
    @ObservedObject var controller: LaunchpadController
    let card: InfoCardState
    let metrics: Metrics
    let display: DisplayContext

    private let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 56, alignment: .leading)
                        Text(row.value)
                            .font(row.mono ? .system(size: 11, design: .monospaced)
                                           : .system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(row.mono ? 2 : 3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            actions
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.11).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 22, x: 0, y: 12)
        .position(position)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch card.item {
        case .app(let bundleID):
            if let entry = controller.catalog.entry(bundleID),
               let image = IconStore.shared.icon(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        case .folder(let folderID):
            FolderIconView(appIDs: controller.layout.folders[folderID]?.apps ?? [],
                           size: 52,
                           glass: GlassCache.shared.glass(raw: display.rawWallpaper,
                                                          displaySize: metrics.size,
                                                          rect: CGRect(x: card.anchor.x - 60,
                                                                       y: card.anchor.y - 60,
                                                                       width: 120,
                                                                       height: 120)),
                           catalog: controller.catalog,
                           iconStore: IconStore.shared)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let bundleID = card.bundleID {
            HStack(spacing: 8) {
                Button("打开") { controller.launch(bundleID) }
                Button("在访达中显示") { controller.revealInFinder(bundleID) }
                Spacer(minLength: 0)
                Button("关闭") { controller.hideInfo() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11.5))
        }
    }

    /// 贴着被点的图标显示；靠边时自动翻到另一侧，保证整张卡片都在屏幕里。
    private var position: CGPoint {
        let margin: CGFloat = 14
        let estimatedHeight: CGFloat = 210
        var x = card.anchor.x + width / 2 + metrics.iconSize * 0.7
        var y = card.anchor.y
        if x + width / 2 > metrics.size.width - margin {
            x = card.anchor.x - width / 2 - metrics.iconSize * 0.7
        }
        x = min(max(width / 2 + margin, x), metrics.size.width - width / 2 - margin)
        y = min(max(estimatedHeight / 2 + margin, y), metrics.size.height - estimatedHeight / 2 - margin)
        return CGPoint(x: x, y: y)
    }
}
