# Kinetic

面向 Apple Silicon 的原生 macOS 动态壁纸应用。使用 Swift、SwiftUI、AppKit、AVFoundation、WebKit 和 Metal，最低支持 macOS 13。

## 功能

- 本地视频、网页与受支持的 Wallpaper Engine 场景壁纸；独立显示器应用、预览与交叉淡化。
- Workshop 浏览、搜索、筛选与下载，下载完成后加入本地资料库。
- 壁纸列表、定时切换、预设、书签、方案与配置备份。
- 天气、桌面组件、音乐信息及兼容场景的音频响应。
- 智能暂停、权限设置与应用更新。

场景兼容性随作者使用的特性与资源而异，尚不保证支持所有 Wallpaper Engine 项目。引擎资源和 Workshop 素材由用户提供，不随源码分发。Steam 下载使用 SteamCMD，在 Apple Silicon 上需要 Rosetta；浏览与下载需配置自己的 Steam 凭据。

## 构建与测试

安装完整 Xcode，在 Apple Silicon Mac 上打开 `Kinetic.xcodeproj`。在 Signing 设置中选择自己的签名团队和有效证书；工程内的团队配置仅用于维护者的本机构建。保持稳定签名可避免每次重建后重新授权。

```sh
xcodebuild -project Kinetic.xcodeproj -scheme Kinetic \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build test
```

测试素材是仓库中生成的短视频和合成场景，不包含用户原视频、实际下载的壁纸或凭据。桌面与网页渲染测试需要解锁且亮着的屏幕；真实音频、外部网络、双屏和长时间测试按各测试的条件执行或跳过。场景引擎有两个测试目标，使用随源码提供的工作区同时验证 XCTest 与 Swift Testing：

```sh
xcodebuild -workspace Kinetic.xcworkspace -scheme KineticSceneRuntime-Tests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData test
```

## 本地发布候选包

```sh
Tools/UpdateRelease/build_release.sh .build/ReleaseCandidate/1.0.0
python3 -I Tools/test_release_tools.py
```

脚本直接构建仓库中的工程，默认复用 `.build/DerivedData-Merged`，可用 `--derived-data 路径` 指定缓存。输出签名 App、ZIP、DMG、校验报告与 SHA256 清单。运行测试后再打开完整 Release App，避免系统选中 Debug 测试宿主。

普通开发证书构建是本地候选版，不能视为已通过 Gatekeeper 的公开发行版。正式分发需准备 Developer ID Application 证书、公证凭据，以及长期可用的 HTTPS 更新地址：

```sh
Tools/UpdateRelease/build_release.sh .build/Release/1.0.0 \
  --developer-id --notary-profile kinetic-notary \
  --feed https://example.com/kinetic/appcast.xml
```

`kinetic-notary` 是用户自行配置的 `notarytool` 钥匙串配置名称，脚本不要求输入密码。更新私钥应在本机安全保存并离线备份，禁止提交到仓库。带更新源的包需要已有更新签名私钥；更新源输出位于 `feed/appcast.xml`。当前默认更新地址为空，不检查远程更新。
