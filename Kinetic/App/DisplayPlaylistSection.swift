import SwiftUI

/// Module 46：显示器页控制台的「壁纸列表轮播」。选列表、间隔与随机是草稿，和其他参数一起点「应用」才生效；
/// 选中列表时缩略图先显示它要播放的那一张。上一张 / 下一张立即切换（与菜单栏相同）。
/// 「播放顺序」拖动就是调整这个壁纸列表本身的顺序。
@MainActor
struct DisplayPlaylistSection: View {
    let displayID: DisplayID
    @ObservedObject var player: WallpaperPlaylistPlayer
    @ObservedObject var lists: LocalOrganizationStore
    @ObservedObject var editor: DisplayWallpaperEditor
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var runtime: WallpaperRuntimeManager
    @State var showsOrder = false
    /// 选列表时为预览放进草稿的那一张；改回「不轮播」时只撤回它，不动用户自己选的壁纸。
    @State private var previewedWallpaperID: Wallpaper.ID?

    private var draft: WallpaperPlaylistPlayer.Draft { player.draft(on: displayID) }
    private var entry: WallpaperPlaylistPlayer.Entry? { player.entries[displayID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("壁纸列表轮播")
                Picker("壁纸列表轮播", selection: listSelection) {
                    Text("不轮播").tag(UUID?.none)
                    ForEach(lists.lists) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                if lists.lists.isEmpty {
                    Text("在侧栏辅助点按「壁纸列表」新建列表后，可以在这里轮播。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let listID = draft.listID {
                intervalRow
                Toggle("随机播放", isOn: binding(\.shuffle))
                if player.members(of: listID).isEmpty {
                    Text("这个壁纸列表里没有可以播放的壁纸。").font(.caption).foregroundStyle(.secondary)
                }
                if player.isActive(on: displayID), entry?.configuration.listID == listID { stepControls }
                if let list = lists.lists.first(where: { $0.id == listID }) { order(of: list) }
            }
            if stopsOnApply {
                Text("已选择另一张壁纸，点「应用」后这块屏幕停止轮播。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 行

    private var intervalRow: some View {
        HStack(spacing: 6) {
            Text("切换间隔")
            Spacer(minLength: 8)
            TextField("切换间隔", value: binding(\.intervalMinutes), format: .number)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64)
                .accessibilityLabel("切换间隔（分钟）")
            Text("分钟").foregroundStyle(.secondary)
            Stepper("切换间隔", value: binding(\.intervalMinutes), in: DisplayPlaylistConfiguration.intervalRange)
                .labelsHidden()
        }
        .help("1–1440 分钟；只在这块屏幕播放时计时，暂停时不计时。")
    }

    private var stepControls: some View {
        HStack(spacing: 8) {
            // Text-only, like the console's other buttons.
            Button("上一张") { player.step(.previous, on: displayID) }.kineticGlassButton()
            Button("下一张") { player.step(.next, on: displayID) }.kineticGlassButton()
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Text(remainingText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var remainingText: String {
        guard runtime.state(of: displayID)?.playbackState == .playing else { return "暂停中，不计时" }
        guard let remaining = player.remaining(on: displayID) else { return "" }
        let minutes = Int((remaining / 60).rounded(.up))
        return minutes <= 1 ? "1 分钟内切换" : "约 \(minutes) 分钟后切换"
    }

    private func order(of list: WallpaperList) -> some View {
        let items = list.wallpaperIDs.compactMap { library.wallpaper(id: $0) }
        let current = entry?.configuration.listID == list.id ? entry?.cursor.currentWallpaperID : nil
        return DisclosureGroup(isExpanded: $showsOrder) {
            List {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        DisplayPickerPoster(wallpaper: item)
                        Text(item.name).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(WallpaperCardVisualState.isPlayable(item) ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.id == current {
                            Text("正在显示").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                        }
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .padding(.vertical, 2)
                    .accessibilityLabel(item.name + (item.id == current ? "，正在显示" : ""))
                }
                .onMove { source, destination in
                    let order = DisplayPlaylistOrder.moving(source, to: destination, visible: items.map(\.id), in: list.wallpaperIDs)
                    try? lists.reorder(list.id, to: order)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(240, CGFloat(max(items.count, 1)) * 46 + 4))
        } label: {
            Text("播放顺序（\(items.count) 张）")
        }
        .help("拖动调整顺序；这也是这个壁纸列表本身的顺序。")
    }

    // MARK: - 草稿

    /// 换了列表时缩略图先显示它要播放的那一张；回到正在轮播的列表时回到正在显示的壁纸。
    private var listSelection: Binding<UUID?> {
        Binding(get: { draft.listID }, set: { id in
            player.edit(on: displayID) { $0.listID = id }
            if id != nil, id == entry?.configuration.listID, let active = runtime.activeWallpaper(on: displayID) {
                editor.select(active, on: displayID)
                previewedWallpaperID = nil
            } else if id != nil, let first = player.previewWallpaper(for: player.draft(on: displayID)),
                      let wallpaper = library.wallpaper(id: first) {
                editor.select(wallpaper, on: displayID)
                previewedWallpaperID = first
            } else if id == nil, let previewed = previewedWallpaperID,
                      editor.draft(on: displayID).wallpaperID == previewed {
                if let active = runtime.activeWallpaper(on: displayID) { editor.select(active, on: displayID) }
                previewedWallpaperID = nil
            }
        })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WallpaperPlaylistPlayer.Draft, Value>) -> Binding<Value> {
        Binding(get: { player.draft(on: displayID)[keyPath: keyPath] },
                set: { value in player.edit(on: displayID) { $0[keyPath: keyPath] = value } })
    }

    /// 正在轮播时在选择器里选了别的壁纸：应用后会停止轮播（手动选择优先）。
    private var stopsOnApply: Bool {
        guard let entry, !player.isDirty(on: displayID), let chosen = editor.draft(on: displayID).wallpaperID else { return false }
        return chosen != entry.cursor.currentWallpaperID && chosen != runtime.activeWallpaper(on: displayID)?.id
    }
}

enum DisplayPlaylistOrder {
    /// 拖动只看得到资料库里还在的成员；把它们的新顺序放回原来的位置，其他引用保持在原处。
    static func moving(_ source: IndexSet, to destination: Int, visible: [Wallpaper.ID],
                       in full: [Wallpaper.ID]) -> [Wallpaper.ID] {
        var moved = visible
        moved.move(fromOffsets: source, toOffset: destination)
        let visibleSet = Set(visible)
        var next = moved.makeIterator()
        return full.map { visibleSet.contains($0) ? (next.next() ?? $0) : $0 }
    }
}

/// 让只在有轮播 / 定时时存在的按钮跟随它们的草稿刷新。
struct ObservingObject<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}
