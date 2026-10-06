import Foundation

/// Read-only identification for import. Rendering compatibility is checked by prepare(),
/// so a package can be kept in the library even when one of its effects is unsupported.
public struct SceneImportMetadata: Sendable {
    public let title: String?
    public let entry: String
    public let preview: String?

    public static func identifiesScene(root: URL, limits: SceneLimits = .init()) throws -> Bool {
        // Import classification examines the explicit folder manifest first.
        // A corrupt scene.pkg must not hide its type and admit index.html as Web.
        let assets = try SceneAssetResolver(root: root, limits: limits, includePackages: false)
        let project = try SceneJSON.parse(assets.readSceneOwned("project.json", maximumBytes: limits.maximumJSONBytes), limits: limits)
        return project["type"].string?.lowercased() == "scene"
    }

    public static func inspect(root: URL, limits: SceneLimits = .init()) throws -> Self {
        let assets = try SceneAssetResolver(root: root, limits: limits)
        let project = try SceneJSON.parse(assets.readSceneOwned("project.json", maximumBytes: limits.maximumJSONBytes), limits: limits)
        guard project["type"].string?.lowercased() == "scene", let rawEntry = project["file"].string else {
            throw SceneRuntimeError.malformed("project.json is not a Scene project")
        }
        let entry = try ScenePath.canonical(rawEntry)
        let document = try SceneJSON.parse(assets.readSceneOwned(entry, maximumBytes: limits.maximumJSONBytes), limits: limits)
        guard document.object != nil, let objects = document["objects"].array else {
            throw SceneRuntimeError.malformed("scene objects")
        }
        guard objects.count <= limits.maximumObjects else { throw SceneRuntimeError.budgetExceeded("scene objects") }
        let title = project["title"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = try project["preview"].string.map(ScenePath.canonical)
        return Self(title: title?.isEmpty == false ? title : nil, entry: entry, preview: preview)
    }
}
