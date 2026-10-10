#!/bin/zsh
# Module 62：构建一份 Kinetic 发行包（发布候选或正式版）。
#
# 用法：Tools/UpdateRelease/build_release.sh <输出目录> [--feed https://…/appcast.xml] [--developer-id] [--notary-profile 名称] [--derived-data 路径]
#   --feed            写进 App 的更新地址（构建设置 KINETIC_UPDATE_FEED_URL），并在输出目录生成 appcast.xml。
#   --developer-id    用钥匙串里的「Developer ID Application」证书签名（需要 Apple Developer Program 会员）。
#   --notary-profile  用 `xcrun notarytool store-credentials <名称>` 预先保存的凭据提交公证并装订（staple）。
#                     凭据由你自己在终端里保存；这个脚本不读取、也不要求输入密码。
# 输出：Kinetic.app、Kinetic-<版本>-<构建号>.zip、Kinetic-<版本>-<构建号>.dmg、manifest.txt（SHA256、EdDSA 签名）、
# release-check.txt；有 --feed 时还有 feed/appcast.xml。私钥默认读 ~/Library/Application Support/Kinetic Release/update_ed25519.key。
# 默认复用项目 .build/DerivedData-Merged，不在每个发行目录里重新生成整份构建缓存。
set -euo pipefail

(( $# >= 1 )) || { print -u2 "用法：$0 <输出目录> [--feed URL] [--developer-id] [--notary-profile 名称] [--derived-data 路径]"; exit 64; }
out="${1:A}"; shift
root="${0:A:h:h:h}"
feed=""; developer_id=0; notary_profile=""; derived="$root/.build/DerivedData-Merged"
while (( $# )); do
    case "$1" in
        --feed|--notary-profile|--derived-data)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || { print -u2 -- "$1 缺少参数"; exit 64; }
            case "$1" in
                --feed) feed="$2" ;;
                --notary-profile) notary_profile="$2" ;;
                --derived-data) derived="${2:A}" ;;
            esac
            shift 2 ;;
        --developer-id) developer_id=1; shift ;;
        *) print -u2 "未知参数：$1"; exit 64 ;;
    esac
done
[[ -z "$feed" || "$feed" == https://* ]] || { print -u2 "更新地址必须是 https：$feed"; exit 64; }
[[ -z "$notary_profile" || $developer_id -eq 1 ]] || { print -u2 "公证需要 --developer-id"; exit 64; }

key="$HOME/Library/Application Support/Kinetic Release/update_ed25519.key"
[[ -z "$feed" || -f "$key" ]] || { print -u2 "生成更新源需要已有的更新签名私钥；请先按发布说明配置。"; exit 66; }
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
build=$(date +%Y%m%d%H%M)
mkdir -p "$out"

signing=(CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if (( developer_id )); then signing+=("CODE_SIGN_IDENTITY=Developer ID Application" "OTHER_CODE_SIGN_FLAGS=--timestamp"); fi
print "构建 Release（构建号 $build）…"
xcodebuild -project "$root/Kinetic.xcodeproj" -scheme Kinetic -configuration Release \
    -destination platform=macOS,arch=arm64 -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CURRENT_PROJECT_VERSION="$build" KINETIC_UPDATE_FEED_URL="$feed" "${signing[@]}" build > "$out/build.log" 2>&1 \
    || { print -u2 "构建失败，见 $out/build.log"; exit 1; }
built="$derived/Build/Products/Release/Kinetic.app"
rm -rf "$out/Kinetic.app"; ditto "$built" "$out/Kinetic.app"
# 构建产物不留在 LaunchServices 里，免得系统重新打开 Kinetic 时挑中这一份。
"$lsregister" -u "$built" 2>/dev/null || true
"$lsregister" -u "$out/Kinetic.app" 2>/dev/null || true
app="$out/Kinetic.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
name="Kinetic-$version-$build"

"$root/Tools/release_check.sh" "$app" "$version" | tee "$out/release-check.txt"
(( ${pipestatus[1]} == 0 )) || { print -u2 "发布前检查有失败项"; exit 1; }

if [[ -n "$notary_profile" ]]; then
    print "提交公证…"
    ditto -c -k --keepParent "$app" "$out/notarize.zip"
    xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$notary_profile" --wait --output-format json > "$out/notarize.json"
    python3 -I -c 'import json,sys; result=json.load(open(sys.argv[1])); print("公证状态：", result.get("status", "unknown")); sys.exit(0 if result.get("status") == "Accepted" else 1)' "$out/notarize.json" \
        || { print -u2 "公证未获通过，停止打包；见 $out/notarize.json"; exit 1; }
    xcrun stapler staple "$app"
    spctl -a -vv -t exec "$app" 2>&1 | tee -a "$out/notarize.log"
    rm -f "$out/notarize.zip"
    "$root/Tools/release_check.sh" "$app" "$version" > "$out/release-check.txt"
fi

rm -f "$out/$name.zip" "$out/$name.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$name.zip"
staging="$out/dmg-staging"; rm -rf "$staging"; mkdir -p "$staging"
ditto "$app" "$staging/Kinetic.app"; ln -s /Applications "$staging/Applications"
"$lsregister" -u "$staging/Kinetic.app" 2>/dev/null || true
hdiutil create -volname "Kinetic $version" -srcfolder "$staging" -format UDZO -ov "$out/$name.dmg" > /dev/null
rm -rf "$staging"

signer=$(find "$root/.build" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)
{
    print "Kinetic $version ($build)"
    print "签名：$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    print "更新地址：${feed:-（无）}"
    for file in "$out/$name.zip" "$out/$name.dmg"; do print "SHA256 ${file:t}: $(shasum -a 256 "$file" | cut -d' ' -f1)"; done
    if [[ -n "$signer" && -f "$key" ]]; then print "Sparkle（$name.zip）：$("$signer" --ed-key-file "$key" "$out/$name.zip")"; fi
} | tee "$out/manifest.txt"

if [[ -n "$feed" ]]; then
    "$root/Tools/UpdateRelease/make_update_release.sh" "$app" "$out/feed" "${feed%/*}/" "$key"
fi
print "完成：$out"
