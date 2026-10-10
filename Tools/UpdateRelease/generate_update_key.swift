// Module 54：生成 Kinetic 更新包签名用的 EdDSA (Ed25519) 密钥。
//
// 用法：swift Tools/UpdateRelease/generate_update_key.swift <私钥文件>
// 私钥文件写入 base64 的 32 字节种子（与 Sparkle `sign_update --ed-key-file` / `generate_appcast --ed-key-file` 的格式相同），
// 权限 0600；已存在时拒绝覆盖。标准输出打印公钥，填进 Kinetic/Info.plist 的 `SUPublicEDKey`。
// 私钥不要放进仓库；丢失后，已安装的 Kinetic 无法再接受新签名的更新。
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("用法：swift generate_update_key.swift <私钥文件>\n".data(using: .utf8)!)
    exit(64)
}
let url = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
guard !FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write("\(url.path) 已存在，不覆盖。\n".data(using: .utf8)!)
    exit(73)
}
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
let key = Curve25519.Signing.PrivateKey()
let secret = key.rawRepresentation.base64EncodedString()
guard FileManager.default.createFile(atPath: url.path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600]) else {
    FileHandle.standardError.write("无法写入 \(url.path)\n".data(using: .utf8)!)
    exit(73)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
