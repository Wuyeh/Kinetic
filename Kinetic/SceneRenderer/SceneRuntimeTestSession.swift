#if DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI

/// Explicit isolated scene acceptance. No real library, assignments, Steam, login service,
/// or user wallpaper files are read or changed. Desktop mode needs an explicit button.
@MainActor
final class SceneRuntimeTestSession {
    private var window: NSWindow?
    private var model: SceneAcceptanceModel?
    func start(fixtureSet: SceneAcceptanceFixtureSet = .bounded) {
        do {
            let model = try SceneAcceptanceModel(fixtureSet: fixtureSet)
            self.model = model
            let window = NSWindow(contentRect: .init(x: 100, y: 220, width: 960, height: 610),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = fixtureSet.windowTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SceneAcceptancePanel(model: model))
            self.window = window
            window.makeKeyAndOrderFront(nil)
            model.applyFirst()
        } catch { NSLog("Scene acceptance setup: %@", error.localizedDescription) }
    }
    func stop() { model?.stop(); window?.close(); window = nil; model = nil }
}

/// Module 28 acceptance fixture sets (all self-generated, bundled in Debug only).
enum SceneAcceptanceFixtureSet {
    /// Kinetic's bounded runtime (`scene-sample`).
    case bounded
    /// Ported render graph / GLSL / named FBO (`scene-graph-sample`).
    case graph
    /// Module 28.3 complete engine: SceneScript through JavaScriptCore, built-in effects, particles (`scene-full-sample`).
    case full

    var folder: String {
        switch self { case .bounded: "scene-sample"; case .graph: "scene-graph-sample"; case .full: "scene-full-sample" }
    }
    var windowTitle: String {
        switch self {
        case .bounded: "Kinetic — 独立 Scene Runtime 验收"
        case .graph: "Kinetic — Scene Render Graph 验收"
        case .full: "Kinetic — 完整 Scene 引擎验收"
        }
    }
    var loopingButton: String {
        switch self { case .bounded: "脚本超时 A"; case .graph: "拒绝扩展脚本 A"; case .full: "失控脚本 A" }
    }
    var note: String {
        switch self {
        case .bounded: "自生成图片 / 文字 / 粒子 / Puppet / 隔离脚本；复杂 Scene 兼容性仍在补齐。"
        case .graph: "移植 Render Graph / GLSL / 命名 FBO：实时生成，两屏独立；复杂对象仍在接入。"
        case .full: "完整引擎：SceneScript（JavaScriptCore）/ 内置效果 / 粒子；两屏独立，缺失资源保留旧壁纸。"
        }
    }
}

@MainActor
private final class SceneAcceptanceModel: ObservableObject {
    let a = DisplayID("scene-acceptance-A"), b = DisplayID("scene-acceptance-B")
    let runtime = WallpaperRuntimeManager(makeRenderer: { SceneRenderer(wallpaper: $0) })
    let first = SceneAcceptanceHost(), second = SceneAcceptanceHost()
    let warm: Wallpaper, cool: Wallpaper, invalid: Wallpaper, looping: Wallpaper
    let root: URL
    let fixtureSet: SceneAcceptanceFixtureSet
    @Published var desktopStatus = "实际桌面未启用"
    private var liveRuntime: WallpaperRuntimeManager?
    private var subscriptions = Set<AnyCancellable>()
    init(fixtureSet: SceneAcceptanceFixtureSet) throws {
        self.fixtureSet = fixtureSet
        guard let fixtures = Bundle.main.url(forResource: fixtureSet.folder, withExtension: nil, subdirectory: "Fixtures") else {
            throw NSError(domain: "SceneAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing generated Scene fixtures"])
        }
        root = fixtures
        let files = SceneAcceptanceFixtures.Projects(warm: root.appendingPathComponent("warm"),
            cool: root.appendingPathComponent("cool"), invalid: root.appendingPathComponent("invalid"))
        warm = Wallpaper(name: "自包含暖色 Scene", type: .scene, source: .local, resourceURL: files.warm)
        cool = Wallpaper(name: "自包含冷色 Scene", type: .scene, source: .local, resourceURL: files.cool)
        invalid = Wallpaper(name: "缺少引擎资源 Scene", type: .scene, source: .local, resourceURL: files.invalid)
        looping = Wallpaper(name: "无限循环脚本 Scene", type: .scene, source: .local, resourceURL: root.appendingPathComponent("looping"))
        runtime.addDisplay(a, name: "模拟显示器 A", host: CrossfadeDesktopHost(desktop: first))
        runtime.addDisplay(b, name: "模拟显示器 B", host: CrossfadeDesktopHost(desktop: second))
        runtime.$summary.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    func applyFirst() { runtime.apply(warm, to: a); runtime.apply(cool, to: b) }
    func startDesktop() {
        guard liveRuntime == nil, let display = DisplayRegistry.systemDisplays().first else { return }
        let desktop = DesktopWindowRuntime(identifier: .init("Kinetic.SceneAcceptance.Desktop"), primaryDisplay: { display.desktop })
        let runtime = WallpaperRuntimeManager(makeRenderer: { SceneRenderer(wallpaper: $0) })
        liveRuntime = runtime
        runtime.addDisplay(display.id, name: display.name, host: CrossfadeDesktopHost(desktop: desktop))
        runtime.$summary.sink { [weak self] summary in
            self?.desktopStatus = "实际桌面：" + (summary.displays.first?.runtime.playbackState.rawValue ?? "—")
        }.store(in: &subscriptions)
        runtime.apply(warm, to: display.id)
    }
    func pauseDesktop() { liveRuntime?.pause(.allDisplays) }
    func resumeDesktop() { liveRuntime?.resume(.allDisplays) }
    func stopDesktop() { liveRuntime?.shutdown(); liveRuntime = nil; desktopStatus = "实际桌面已停止" }
    func stop() {
        stopDesktop(); runtime.shutdown(); subscriptions.removeAll()
    }
    func state(_ id: DisplayID) -> String { runtime.state(of: id)?.playbackState.rawValue ?? "—" }
}

@MainActor
private struct SceneAcceptancePanel: View {
    @ObservedObject var model: SceneAcceptanceModel
    var body: some View {
        VStack(spacing: 18) {
            Text("自生成 Scene / 原逐屏 Session / 原 Crossfade；无资料库写入")
            HStack(spacing: 20) {
                VStack { Text("显示器 A"); SceneAcceptanceHostView(host: model.first).frame(width: 420, height: 240); Text(model.state(model.a)) }
                VStack { Text("显示器 B"); SceneAcceptanceHostView(host: model.second).frame(width: 420, height: 240); Text(model.state(model.b)) }
            }
            HStack {
                Button("冷色应用 A") { model.runtime.apply(model.cool, to: model.a) }
                Button("暖色应用 A") { model.runtime.apply(model.warm, to: model.a) }
                Button("暂停 A") { model.runtime.pause(.display(model.a)) }
                Button("继续 A") { model.runtime.resume(.display(model.a)) }
                Button("失败场景应用 A") { model.runtime.apply(model.invalid, to: model.a) }
                Button(model.fixtureSet.loopingButton) { model.runtime.apply(model.looping, to: model.a) }
            }
            HStack {
                Button("停止 A") { model.runtime.stop(.display(model.a)) }
                Button("重新启用 A") { model.runtime.reenable(.display(model.a)) }
                Button("停止全部") { model.runtime.stop(.allDisplays) }
            }
            Text(model.runtime.lastFailure?.message ?? "无失败").foregroundStyle(.secondary)
            Divider()
            Text(model.desktopStatus)
            HStack {
                Button("启用实际桌面 Scene") { model.startDesktop() }
                Button("暂停桌面") { model.pauseDesktop() }
                Button("继续桌面") { model.resumeDesktop() }
                Button("停止桌面") { model.stopDesktop() }
            }
            Text(model.fixtureSet.note)
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
}

@MainActor
private final class SceneAcceptanceHost: DesktopContentHost {
    let view = NSView()
    func present(_ contentView: NSView) -> Bool {
        view.subviews.forEach { $0.removeFromSuperview() }
        contentView.frame = view.bounds; contentView.autoresizingMask = [.width, .height]
        view.addSubview(contentView); return true
    }
    func stop() { view.subviews.forEach { $0.removeFromSuperview() } }
}
private struct SceneAcceptanceHostView: NSViewRepresentable {
    let host: SceneAcceptanceHost
    func makeNSView(context: Context) -> NSView { host.view }
    func updateNSView(_ view: NSView, context: Context) {}
}

enum SceneAcceptanceFixtures {
    struct Projects { let warm: URL; let cool: URL; let invalid: URL }
    static func create(in root: URL) throws -> Projects {
        let warm = root.appendingPathComponent("warm"), cool = root.appendingPathComponent("cool"), invalid = root.appendingPathComponent("invalid")
        for (folder, color, name) in [(warm, "0.92 0.35 0.12", "KINETIC · SCENE"), (cool, "0.12 0.5 0.82", "独立 Scene Runtime"), (invalid, "0 0 0", "invalid")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func write(_ path: String, _ value: Any) throws {
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: folder.appendingPathComponent(path))
            }
            try write("project.json", ["type": "scene", "file": "scene.json"])
            let image = folder == invalid ? "materials/missing-engine-resource.json" : "material.json"
            var objects: [[String: Any]] = [["id": 1, "image": image, "origin": "480 270 0", "size": "960 540 0"],
                ["id": 2, "text": name, "font": "Helvetica", "pointsize": 45,
                 "origin": ["value": "480 270 0", "script": "export function update(value){value.x=480+80*Math.sin(engine.runtime);return value;}"], "size": "780 80 0"]]
            if folder != invalid {
                objects.append(["id": 3, "particle": "particles.json", "origin": "480 150 0"])
                objects.append(["id": 4, "image": "puppet.mdl", "origin": "480 140 0", "scale": "3 3 1",
                                "animationlayers": [["id": 1, "animation": 1, "rate": 1]]])
            }
            try write("scene.json", ["general": ["orthogonalprojection": ["width": 960, "height": 540], "clearcolor": "0.03 0.05 0.08"], "objects": objects])
            try write("sprite-material.json", ["passes": [["shader": "genericimage", "textures": ["pixel.tex"]]]])
            try write("particles.json", ["material": "sprite-material.json", "maxcount": 128,
                "emitter": [["name": "sphererandom", "rate": 12]],
                "initializer": [["name": "lifetime", "value": 2], ["name": "velocityrandom", "min": "-64 24 0", "max": "64 80 0"],
                                ["name": "sizerandom", "min": 3, "max": 7]],
                "operator": [["name": "alphafade", "fadeintime": 0.2, "fadeouttime": 0.4]]])
            try puppetFixture().write(to: folder.appendingPathComponent("puppet.mdl"))
            try write("material.json", ["passes": [["shader": "pulse", "textures": ["pixel.tex"]]]])
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("shaders"), withIntermediateDirectories: true)
            let components = color.components(separatedBy: " ").joined(separator: ",")
            let shader = "uniform float g_Time; void main(){float pulse=0.82+0.18*sin(g_Time);gl_FragColor=vec4(vec3(\(components))*pulse,1.0);}"
            try Data(shader.utf8).write(to: folder.appendingPathComponent("shaders/pulse.frag"))
            var tex = Data("TEXV0005\0TEXI0001\0".utf8)
            func append(_ number: UInt32) { var number = number.littleEndian; withUnsafeBytes(of: &number) { tex.append(contentsOf: $0) } }
            for value: UInt32 in [0, 2, 1, 1, 1, 1, 0] { append(value) }
            tex += Data("TEXB0001\0".utf8)
            for value: UInt32 in [1, 1, 1, 1, 4] { append(value) }
            tex += Data([255, 255, 255, 255]); try tex.write(to: folder.appendingPathComponent("pixel.tex"))
        }
        let looping = root.appendingPathComponent("looping")
        try FileManager.default.copyItem(at: warm, to: looping)
        let loopingURL = looping.appendingPathComponent("scene.json")
        var scene = try JSONSerialization.jsonObject(with: Data(contentsOf: loopingURL)) as! [String: Any]
        var objects = scene["objects"] as! [[String: Any]]
        objects[1]["origin"] = ["value": "480 270 0", "script": "export function update(v){while(true){}}"]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: loopingURL)
        return .init(warm: warm, cool: cool, invalid: invalid)
    }

    private static func puppetFixture() -> Data {
        func word(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        func half(_ value: UInt16) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        func floats(_ values: [Float]) -> Data { values.reduce(into: Data()) { $0 += word($1.bitPattern) } }
        func string(_ value: String) -> Data { Data(value.utf8) + Data([0]) }
        var data = string("MDLV0017") + word(0) + word(1) + word(1)
        data += string("sprite-material.json") + word(0) + floats([-16,-16,0,16,16,0]) + word(0x1800008)
        var vertices = Data()
        for point: [Float] in [[-16,-16,0], [16,-16,0], [0,16,0]] {
            vertices += floats(point) + word(0) + word(0) + word(0) + word(0) + floats([1,0,0,0,0.5,0.5])
        }
        data += word(UInt32(vertices.count)) + vertices + word(6) + half(0) + half(1) + half(2)
        let skeletonStart = data.count
        var skeleton = string("MDLS0001") + word(0) + half(1) + half(0)
        skeleton += string("root") + word(0) + word(UInt32.max) + word(64) +
            floats([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]) + string("")
        skeleton.replaceSubrange(9..<13, with: word(UInt32(skeletonStart + skeleton.count)))
        data += skeleton
        let animationStart = data.count
        var block = string("MDLA0001") + word(0) + word(1)
        block += word(1) + word(0) + string("move") + string("loop") + floats([1]) + word(2) + word(0) + word(1)
        block += word(0) + word(108)
        for translation: Float in [0,24,0] { block += floats([translation,0,0,0,0,0,1,1,1]) }
        block += word(0)
        block.replaceSubrange(9..<13, with: word(UInt32(animationStart + block.count)))
        return data + block
    }
}
#endif
