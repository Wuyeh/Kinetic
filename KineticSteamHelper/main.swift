import Foundation

/// Kinetic Steam 小助手（1.0 Module 9）：不带沙盒的 XPC 服务，只负责下载、解压与运行 Kinetic 自己的 SteamCMD。
/// 只有包含它的 Kinetic.app 能连接（XPC 服务的可见范围由 launchd 限定在所在的 App 内）。
let delegate = SteamHelperListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
