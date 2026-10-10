import SwiftUI

/// Module 47：显示器页控制台的「定时切换」。每条时段选早晨 / 中午 / 下午 / 傍晚 / 夜间或自定义起止，
/// 内容是一张壁纸或一个壁纸列表（列表按这里的间隔 / 随机轮播）。时间重叠标红、不能应用；点「应用」才保存，
/// 当前时段的内容立即生效。
@MainActor
struct DisplayScheduleSection: View {
    let displayID: DisplayID
    @ObservedObject var scheduler: WallpaperScheduler
    @ObservedObject var lists: LocalOrganizationStore
    @ObservedObject var library: WallpaperLibrary
    /// Module 48: bookmarks can be scheduled too.
    @ObservedObject var bookmarks: SetupStore

    private var draft: DisplaySchedule { scheduler.draft(on: displayID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("定时切换", isOn: enabledBinding)
            if draft.isEnabled {
                let problems = draft.problems
                ForEach(draft.slots) { slot in
                    slotEditor(slot, problem: problems[slot.id])
                }
                if draft.slots.count < DisplaySchedule.maximumSlots {
                    Button("添加时段") { addSlot() }.kineticGlassButton()
                }
                if let active = scheduler.activeSlot(on: displayID), !scheduler.isDirty(on: displayID) {
                    Text("现在是「\(active.period.title)」时段（\(active.start.scheduleClockText)–\(active.end.scheduleClockText)）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("手动暂停或停止时不切换，继续后补上当前时段；时段中途手动换的壁纸在本时段内保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 一条时段

    private func slotEditor(_ slot: ScheduleSlot, problem: ScheduleProblem?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("时段", selection: periodBinding(slot.id)) {
                    ForEach(SchedulePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Spacer(minLength: 0)
                if slot.period == .custom {
                    timeField(slot.id, \.start, label: "开始")
                    Text("–").foregroundStyle(.secondary)
                    timeField(slot.id, \.end, label: "结束")
                } else {
                    Text("\(slot.start.scheduleClockText)–\(slot.end.scheduleClockText)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Button { remove(slot.id) } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("删除这个时段").accessibilityLabel("删除\(slot.period.title)时段")
            }
            Picker("内容", selection: contentBinding(slot.id)) {
                Text("选择壁纸或壁纸列表").tag(ScheduleContent?.none)
                if !bookmarks.bookmarks.isEmpty {
                    Section("书签") {
                        ForEach(bookmarks.bookmarks) { bookmark in
                            Text(bookmark.name).tag(Optional(ScheduleContent.bookmark(bookmark.id)))
                        }
                    }
                }
                if !lists.lists.isEmpty {
                    Section("壁纸列表") {
                        ForEach(lists.lists) { list in
                            Text(list.name).tag(Optional(listContent(list.id, keeping: slot.content)))
                        }
                    }
                }
                Section("壁纸") {
                    ForEach(DisplayControlPresentation.pickerWallpapers(library.wallpapers)) { wallpaper in
                        Text(wallpaper.name).tag(Optional(ScheduleContent.wallpaper(wallpaper.id)))
                    }
                }
            }
            .labelsHidden()
            if case .list(_, let minutes, let shuffle) = slot.content {
                HStack(spacing: 6) {
                    Text("每").foregroundStyle(.secondary)
                    TextField("间隔", value: listOption(slot.id, minutes: minutes, shuffle: shuffle, keyPath: \.minutes), format: .number)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                        .accessibilityLabel("轮播间隔（分钟）")
                    Text("分钟换一张").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Toggle("随机", isOn: listOption(slot.id, minutes: minutes, shuffle: shuffle, keyPath: \.shuffle))
                }
            }
            if let problem { Text(message(problem)).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func timeField(_ id: UUID, _ keyPath: WritableKeyPath<ScheduleSlot, Int>, label: String) -> some View {
        DatePicker(label, selection: Binding(get: {
            let minutes = draft.slots.first { $0.id == id }?[keyPath: keyPath] ?? 0
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            update(id) { $0[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
        }), displayedComponents: .hourAndMinute)
        .labelsHidden().datePickerStyle(.field).fixedSize()
        .accessibilityLabel(label)
    }

    private func message(_ problem: ScheduleProblem) -> String {
        switch problem {
        case .emptyRange: return "开始和结束不能相同。"
        case .noContent: return "选择这个时段要显示的壁纸或壁纸列表。"
        case .overlaps(let others):
            let names = others.compactMap { id in draft.slots.first { $0.id == id }?.period.title }
            return "与「" + names.joined(separator: "」「") + "」时间重叠，改好后才能应用。"
        }
    }

    // MARK: - 草稿

    /// Turning it on with no slots starts with one, so there is something to fill in.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { draft.isEnabled }, set: { on in
            scheduler.edit(on: displayID) { schedule in
                schedule.isEnabled = on
                if on, schedule.slots.isEmpty { schedule.slots.append(ScheduleSlot(period: .morning)) }
            }
        })
    }

    private func update(_ id: UUID, _ change: (inout ScheduleSlot) -> Void) {
        scheduler.edit(on: displayID) { schedule in
            guard let index = schedule.slots.firstIndex(where: { $0.id == id }) else { return }
            change(&schedule.slots[index])
        }
    }

    private func periodBinding(_ id: UUID) -> Binding<SchedulePeriod> {
        Binding(get: { draft.slots.first { $0.id == id }?.period ?? .custom }, set: { period in
            update(id) { slot in
                slot.period = period
                if let range = period.defaultRange { slot.start = range.start; slot.end = range.end }
            }
        })
    }

    private func contentBinding(_ id: UUID) -> Binding<ScheduleContent?> {
        Binding(get: { draft.slots.first { $0.id == id }?.content }, set: { content in update(id) { $0.content = content } })
    }

    /// The list's tag keeps the interval and shuffle already set for this slot, so the menu shows it as selected.
    private func listContent(_ listID: UUID, keeping current: ScheduleContent?) -> ScheduleContent {
        if case .list(let id, let minutes, let shuffle) = current, id == listID { return .list(id, intervalMinutes: minutes, shuffle: shuffle) }
        return .list(listID, intervalMinutes: DisplayPlaylistConfiguration.defaultIntervalMinutes, shuffle: false)
    }

    private struct ListOptions { var minutes: Int; var shuffle: Bool }
    private func listOption<Value>(_ id: UUID, minutes: Int, shuffle: Bool,
                                   keyPath: WritableKeyPath<ListOptions, Value>) -> Binding<Value> {
        Binding(get: { ListOptions(minutes: minutes, shuffle: shuffle)[keyPath: keyPath] }, set: { value in
            update(id) { slot in
                guard case .list(let listID, let minutes, let shuffle) = slot.content else { return }
                var options = ListOptions(minutes: minutes, shuffle: shuffle)
                options[keyPath: keyPath] = value
                slot.content = .list(listID, intervalMinutes: DisplayPlaylistConfiguration.clamped(options.minutes), shuffle: options.shuffle)
            }
        })
    }

    /// A new slot takes the first named period not used yet, else a custom range.
    private func addSlot() {
        scheduler.edit(on: displayID) { schedule in
            let used = Set(schedule.slots.map(\.period))
            let period = SchedulePeriod.allCases.first { $0 != .custom && !used.contains($0) } ?? .custom
            schedule.slots.append(ScheduleSlot(period: period))
        }
    }

    private func remove(_ id: UUID) {
        scheduler.edit(on: displayID) { $0.slots.removeAll { $0.id == id } }
    }
}
