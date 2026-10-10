import Foundation
import CoreGraphics

enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemOverview, cpu, memory, gpu, network, disk, power, processes, agentSession, aneMemory, weather
    var id: String { rawValue }
    var title: String { NSLocalizedString("widgets.kind." + rawValue, comment: "") }
    var symbol: String {
        switch self {
        case .systemOverview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory, .aneMemory: return "memorychip"
        case .gpu: return "square.3.layers.3d"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .power: return "bolt"
        case .processes: return "list.bullet"
        case .agentSession: return "terminal"
        case .weather: return "cloud.sun"
        }
    }
}

enum WidgetSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    /// Grid cells covered, like Apple's desktop widgets: small 1×1, medium 2×1, large 2×2.
    var span: (columns: Int, rows: Int) {
        switch self {
        case .small: return (1, 1)
        case .medium: return (2, 1)
        case .large: return (2, 2)
        }
    }
    /// Whole cells plus the gaps they cover, so every size lines up with the grid.
    var dimensions: CGSize {
        CGSize(width: CGFloat(span.columns) * WidgetGrid.cell + CGFloat(span.columns - 1) * WidgetGrid.spacing,
               height: CGFloat(span.rows) * WidgetGrid.cell + CGFloat(span.rows - 1) * WidgetGrid.spacing)
    }
    var title: String { NSLocalizedString("widgets.size." + rawValue, comment: "") }
}

struct WidgetPosition: Codable, Equatable, Sendable { var x = 0.0; var y = 0.0 }

struct WidgetConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: WidgetKind
    var size: WidgetSize = .small
    /// Kept so older layouts still decode; widgets now always draw at their grid size (user, 2026-10-08).
    var scale = 1.0
    /// Fractions of the grid's travel for this size; origin is top-left. `WidgetGrid` snaps them to cells.
    var position = WidgetPosition()
    var showsTitle = true
    var opacity = 1.0
    var customTitle = ""
    var title: String { customTitle.isEmpty ? kind.title : customTitle }
    func validated() throws -> Self {
        guard scale.isFinite, (0.5...2).contains(scale), opacity.isFinite, (0.25...1).contains(opacity),
              position.x.isFinite, (0...1).contains(position.x), position.y.isFinite, (0...1).contains(position.y),
              customTitle.utf8.count <= 256, !customTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WidgetBoardError.invalidLayout
        }
        return self
    }
}

struct WidgetBoardLayout: Codable, Equatable, Sendable {
    var version = 1
    var widgets: [WidgetConfiguration] = []
    static let maximumWidgets = 32
    static let maximumBytes = 128 * 1_024
    func validated() throws -> Self {
        guard version == 1, widgets.count <= Self.maximumWidgets, Set(widgets.map(\.id)).count == widgets.count else {
            throw WidgetBoardError.invalidLayout
        }
        for widget in widgets { _ = try widget.validated() }
        return self
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(validated())
        guard data.count <= Self.maximumBytes else { throw WidgetBoardError.invalidLayout }; return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw WidgetBoardError.invalidLayout }
        do { return try JSONDecoder().decode(Self.self, from: data).validated() }
        catch { throw WidgetBoardError.invalidLayout }
    }
}

struct WidgetBoardReference: Equatable, Sendable {
    let layoutID: UUID
    init(configuration: OverlayConfiguration) throws {
        _ = try configuration.validated()
        guard configuration.kind == .widgets, Set(configuration.parameters.keys) == ["widgetLayout", "widgetVersion"],
              configuration.parameters["widgetVersion"] == .number(1),
              case .text(let id) = configuration.parameters["widgetLayout"], let uuid = UUID(uuidString: id) else {
            throw WidgetBoardError.invalidLayout
        }
        layoutID = uuid
    }
    static func applying(_ id: UUID, to configuration: OverlayConfiguration) throws -> OverlayConfiguration {
        guard configuration.kind == .widgets else { throw WidgetBoardError.invalidLayout }
        var value = configuration; value.parameters = ["widgetLayout": .text(id.uuidString), "widgetVersion": .number(1)]
        return try value.validated()
    }
}

/// Apple-style desktop widget grid (user, 2026-10-08): fixed cells, no overlap, every widget snaps to a cell.
/// Positions stay stored as fractions, so a layout follows its display through resolution changes;
/// `arrange` turns them into cells in layout order and moves a widget whose cells are taken to the nearest free ones.
enum WidgetGrid {
    static let cell: CGFloat = 160
    static let spacing: CGFloat = 16
    static var pitch: CGFloat { cell + spacing }
    /// Clear of the menu bar (up to 38 pt beside a camera housing) with a small margin below it.
    static let topInset: CGFloat = 48
    static let sideInset: CGFloat = 16

    struct Cell: Hashable, Sendable { var column: Int; var row: Int }

    struct Metrics: Equatable, Sendable {
        let origin: CGPoint
        let columns: Int
        let rows: Int
        /// The grid is centred in the area below the menu bar; nil when not even one cell fits.
        init?(canvas: CGSize) {
            guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return nil }
            let width = canvas.width - 2 * WidgetGrid.sideInset, height = canvas.height - WidgetGrid.topInset - WidgetGrid.sideInset
            let columns = Int(((width + WidgetGrid.spacing) / WidgetGrid.pitch).rounded(.down))
            let rows = Int(((height + WidgetGrid.spacing) / WidgetGrid.pitch).rounded(.down))
            guard columns >= 1, rows >= 1 else { return nil }
            self.columns = columns; self.rows = rows
            let gridWidth = CGFloat(columns) * WidgetGrid.pitch - WidgetGrid.spacing
            let gridHeight = CGFloat(rows) * WidgetGrid.pitch - WidgetGrid.spacing
            origin = CGPoint(x: WidgetGrid.sideInset + (width - gridWidth) / 2, y: WidgetGrid.topInset + (height - gridHeight) / 2)
        }
        func fits(_ cell: Cell, _ size: WidgetSize) -> Bool {
            cell.column >= 0 && cell.row >= 0 && cell.column + size.span.columns <= columns && cell.row + size.span.rows <= rows
        }
        func frame(_ cell: Cell, _ size: WidgetSize) -> CGRect {
            CGRect(origin: CGPoint(x: origin.x + CGFloat(cell.column) * WidgetGrid.pitch,
                                   y: origin.y + CGFloat(cell.row) * WidgetGrid.pitch), size: size.dimensions)
        }
        /// The cell whose frame origin is nearest `point`, kept on the grid for this size.
        func cell(nearest point: CGPoint, _ size: WidgetSize) -> Cell {
            let column = point.x.isFinite ? Int(((point.x - origin.x) / WidgetGrid.pitch).rounded()) : 0
            let row = point.y.isFinite ? Int(((point.y - origin.y) / WidgetGrid.pitch).rounded()) : 0
            return Cell(column: max(0, min(columns - size.span.columns, column)), row: max(0, min(rows - size.span.rows, row)))
        }
        func desiredCell(_ position: WidgetPosition, _ size: WidgetSize) -> Cell {
            let columnTravel = max(0, columns - size.span.columns), rowTravel = max(0, rows - size.span.rows)
            let x = position.x.isFinite ? max(0, min(1, position.x)) : 0, y = position.y.isFinite ? max(0, min(1, position.y)) : 0
            return Cell(column: Int((x * Double(columnTravel)).rounded()), row: Int((y * Double(rowTravel)).rounded()))
        }
        func position(_ cell: Cell, _ size: WidgetSize) -> WidgetPosition {
            let columnTravel = columns - size.span.columns, rowTravel = rows - size.span.rows
            return WidgetPosition(x: columnTravel > 0 ? max(0, min(1, Double(cell.column) / Double(columnTravel))) : 0,
                                  y: rowTravel > 0 ? max(0, min(1, Double(cell.row) / Double(rowTravel))) : 0)
        }
        func cells(_ cell: Cell, _ size: WidgetSize) -> [Cell] {
            (0..<size.span.rows).flatMap { row in (0..<size.span.columns).map { Cell(column: cell.column + $0, row: cell.row + row) } }
        }
        /// The free spot for `size` closest to `desired`; ties go to the upper, then the leading one.
        func nearestFree(to desired: Cell, _ size: WidgetSize, occupied: Set<Cell>) -> Cell? {
            guard size.span.columns <= columns, size.span.rows <= rows else { return nil }
            var best: (cell: Cell, distance: Int)?
            for row in 0...(rows - size.span.rows) {
                for column in 0...(columns - size.span.columns) {
                    let candidate = Cell(column: column, row: row)
                    let distance = (column - desired.column) * (column - desired.column) + (row - desired.row) * (row - desired.row)
                    guard best.map({ distance < $0.distance }) ?? true,
                          cells(candidate, size).allSatisfy({ !occupied.contains($0) }) else { continue }
                    best = (candidate, distance)
                }
            }
            return best?.cell
        }
    }

    /// Cells in layout order. A widget with no free room is left out (not shown) rather than overlapping.
    static func arrange(_ widgets: [WidgetConfiguration], in metrics: Metrics) -> [UUID: Cell] {
        var placed: [UUID: Cell] = [:], occupied = Set<Cell>()
        for widget in widgets {
            guard let cell = metrics.nearestFree(to: metrics.desiredCell(widget.position, widget.size), widget.size, occupied: occupied) else { continue }
            placed[widget.id] = cell; occupied.formUnion(metrics.cells(cell, widget.size))
        }
        return placed
    }
    static func frames(_ widgets: [WidgetConfiguration], in canvas: CGSize) -> [UUID: CGRect] {
        guard let metrics = Metrics(canvas: canvas) else { return [:] }
        let sizes = Dictionary(widgets.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        return arrange(widgets, in: metrics).reduce(into: [:]) { result, item in
            if let size = sizes[item.key] { result[item.key] = metrics.frame(item.value, size) }
        }
    }
    /// Stores every placed widget at its cell exactly and clears the retired scale, so the saved layout
    /// is what the grid shows. Widgets without room keep their stored values.
    static func normalized(_ layout: WidgetBoardLayout, in canvas: CGSize) -> WidgetBoardLayout {
        guard let metrics = Metrics(canvas: canvas) else { return layout }
        let cells = arrange(layout.widgets, in: metrics)
        var value = layout
        for index in value.widgets.indices {
            value.widgets[index].scale = 1
            if let cell = cells[value.widgets[index].id] { value.widgets[index].position = metrics.position(cell, value.widgets[index].size) }
        }
        return value
    }
    /// Occupied cells of every placed widget except `excluding`.
    static func occupied(_ widgets: [WidgetConfiguration], in metrics: Metrics, excluding: UUID? = nil) -> Set<Cell> {
        let others = widgets.filter { $0.id != excluding }
        let cells = arrange(others, in: metrics)
        return Set(others.flatMap { widget in cells[widget.id].map { metrics.cells($0, widget.size) } ?? [] })
    }
    /// Where a widget dragged to `origin` (canvas points, top-left) lands: the nearest free spot. Nil if none.
    static func dropCell(for id: UUID, at origin: CGPoint, in layout: WidgetBoardLayout, canvas: CGSize) -> Cell? {
        guard let metrics = Metrics(canvas: canvas), let widget = layout.widgets.first(where: { $0.id == id }) else { return nil }
        return metrics.nearestFree(to: metrics.cell(nearest: origin, widget.size), widget.size,
                                   occupied: occupied(layout.widgets, in: metrics, excluding: id))
    }
    /// The layout with `id` placed at `cell`; the others keep their places.
    static func placing(_ id: UUID, at cell: Cell, in layout: WidgetBoardLayout, canvas: CGSize) -> WidgetBoardLayout {
        guard let metrics = Metrics(canvas: canvas), let index = layout.widgets.firstIndex(where: { $0.id == id }) else { return layout }
        var value = normalized(layout, in: canvas)
        value.widgets[index].position = metrics.position(cell, value.widgets[index].size)
        // The moved widget claims its cells first; the rest are already on free cells, so they stay.
        let moved = value.widgets.remove(at: index); value.widgets.insert(moved, at: 0)
        var arranged = normalized(value, in: canvas)
        let restored = arranged.widgets.remove(at: 0); arranged.widgets.insert(restored, at: index)
        return arranged
    }
    /// Room for one more widget of `size`: down the leading edge first, then the next column.
    static func firstFree(_ size: WidgetSize, in layout: WidgetBoardLayout, canvas: CGSize) -> WidgetPosition? {
        guard let metrics = Metrics(canvas: canvas), size.span.columns <= metrics.columns, size.span.rows <= metrics.rows else { return nil }
        let occupied = occupied(layout.widgets, in: metrics)
        for column in 0...(metrics.columns - size.span.columns) {
            for row in 0...(metrics.rows - size.span.rows) {
                let cell = Cell(column: column, row: row)
                if metrics.cells(cell, size).allSatisfy({ !occupied.contains($0) }) { return metrics.position(cell, size) }
            }
        }
        return nil
    }
}

enum WidgetBoardError: LocalizedError {
    case invalidLayout, unreadableLayout, storageFull, noRoom
    var errorDescription: String? {
        switch self {
        case .noRoom: return NSLocalizedString("widgets.error.noRoom", comment: "")
        case .invalidLayout: return NSLocalizedString("widgets.error.invalid", comment: "")
        case .unreadableLayout: return NSLocalizedString("widgets.error.unreadable", comment: "")
        case .storageFull: return NSLocalizedString("widgets.error.storageFull", comment: "")
        }
    }
}
