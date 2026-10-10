#!/bin/zsh
# Module 54：把一份已签名的 Kinetic.app 打成 Sparkle 更新包，并在输出目录里生成 / 更新 appcast.xml。
#
# 用法：Tools/UpdateRelease/make_update_release.sh <Kinetic.app> <输出目录> <下载地址前缀> [私钥文件]
#   下载地址前缀：更新包对外的目录地址，例如 https://example.com/kinetic/（appcast 里的 enclosure 用它拼出下载地址）。
#   私钥文件：默认 ~/Library/Application Support/Kinetic Release/update_ed25519.key（generate_update_key.swift 生成）。
# 输出目录里已有的更新包会一并写进 appcast（新版本在前）。把整个输出目录放到更新地址指向的位置即可。
set -euo pipefail

if (( $# < 3 )); then
    print -u2 "用法：$0 <Kinetic.app> <输出目录> <下载地址前缀> [私钥文件]"
    exit 64
fi
app="${1:A}"
out="${2:A}"
prefix="$3"
key="${4:-$HOME/Library/Application Support/Kinetic Release/update_ed25519.key}"
root="${0:A:h:h:h}"

[[ -d "$app" && -f "$app/Contents/Info.plist" ]] || { print -u2 "不是 App：$app"; exit 66; }
[[ -f "$key" ]] || { print -u2 "找不到私钥：$key"; exit 66; }
codesign --verify --deep --strict "$app" || { print -u2 "App 签名校验失败：$app"; exit 65; }

tool=$(find "$root/.build" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" -type f 2>/dev/null | head -1)
[[ -n "$tool" ]] || { print -u2 "找不到 Sparkle 的 generate_appcast：先在 .build 下构建一次 Kinetic（解析 Sparkle 包）"; exit 69; }

short=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app/Contents/Info.plist")
mkdir -p "$out"
archive="$out/Kinetic-$short-$build.zip"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
"$tool" --ed-key-file "$key" --download-url-prefix "$prefix" "$out"
print "更新包：$archive"
print "appcast：$out/appcast.xml"
