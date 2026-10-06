/// v0.1 的来源分类（本地 / Steam）。Kinetic 1.0 改用 `AcquisitionOrigin` 记录来源历史，
/// 资料库分页不再依据它；只为兼容 v0.1 记录的读取与尚未迁移的界面文字保留。
enum WallpaperSource: String, Codable, CaseIterable, Sendable {
    case local
    case steam
}
