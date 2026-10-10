#!/bin/zsh
# Module 62：发布前检查一份 Kinetic.app。全部通过时退出码 0；有失败时 1；只有提醒时 0 并打印「提醒」。
#
# 用法：Tools/release_check.sh <Kinetic.app> [期望的版本号，默认 1.0.0]
# 检查：签名（strict / deep、Hardened Runtime、团队）、entitlements 与源文件一致且没有 get-task-allow、
# Info.plist（版本、最低系统、隐私说明、Sparkle 设置）、架构、包内容（没有测试素材 / 测试包，有演示与许可）、
# 正式构建里没有 Debug 验收入口、内嵌的 Sparkle 与 Steam 小助手同一团队签名。
set -u
(( $# >= 1 )) || { print -u2 "用法：$0 <Kinetic.app> [期望版本，默认 1.0.0]"; exit 64; }
app="${1:A}"
expected_version="${2:-1.0.0}"
root="${0:A:h:h}"
failures=0
warnings=0
pass() { print "通过  $1"; }
fail() { print "失败  $1"; failures=$((failures + 1)); }
warn() { print "提醒  $1"; warnings=$((warnings + 1)); }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null; }

[[ -d "$app" ]] || { print "不是 App：$app"; exit 66; }
binary="$app/Contents/MacOS/$(plist CFBundleExecutable)"

# 签名
codesign --verify --deep --strict "$app" 2>/dev/null && pass "签名校验（deep / strict）" || fail "签名校验（deep / strict）"
details=$(codesign -dv "$app" 2>&1)
[[ "$details" == *"(runtime)"* ]] && pass "Hardened Runtime" || fail "Hardened Runtime 未开启"
team=$(print -r -- "$details" | sed -n 's/^TeamIdentifier=//p')
[[ -n "$team" && "$team" != "not set" ]] && pass "团队签名：$team" || fail "没有团队签名（ad-hoc）"
authority=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [[ "$authority" == "Developer ID Application"* ]]; then pass "Developer ID 签名"
else warn "签名身份是「${authority%%:*}」，不是 Developer ID：只能在本机或已信任的 Mac 上打开，发行前需要 Developer ID 签名与公证"; fi
for nested in "$app/Contents/Frameworks/Sparkle.framework" "$app/Contents/XPCServices/KineticSteamHelper.xpc"; do
    name="${nested:t}"
    [[ -e "$nested" ]] || { fail "缺少 $name"; continue; }
    nested_team=$(codesign -dv "$nested" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [[ "$nested_team" == "$team" ]] && pass "$name 同一团队签名" || fail "$name 的团队是「$nested_team」"
done

# Entitlements：与源文件一致（构建变量展开后），没有 get-task-allow
actual=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)
bundle_id=$(plist CFBundleIdentifier)
source_json=$(sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_id/g" "$root/Kinetic/Kinetic.entitlements" | plutil -convert json -o - - 2>/dev/null)
if [[ -n "$actual" && "$(print -r -- "$actual" | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')" == \
      "$(print -r -- "$source_json" | python3 -I -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')" ]]; then
    pass "Entitlements 与 Kinetic.entitlements 一致"
else
    fail "Entitlements 与 Kinetic.entitlements 不一致"
fi
[[ "$actual" == *"get-task-allow"* ]] && fail "带有 get-task-allow（调试权限）" || pass "没有 get-task-allow"

# Info.plist
version=$(plist CFBundleShortVersionString); build=$(plist CFBundleVersion)
[[ "$version" == "$expected_version" ]] && pass "版本号 $version" || fail "版本号是 $version，期望 $expected_version"
[[ "$build" == <-> && ${#build} -ge 8 ]] && pass "构建号 $build" || fail "构建号「$build」不是递增的数字"
[[ "$(plist LSMinimumSystemVersion)" == "13.0" ]] && pass "最低系统 macOS 13.0" || fail "最低系统是 $(plist LSMinimumSystemVersion)"
for key in NSAppleEventsUsageDescription NSLocationUsageDescription NSLocationWhenInUseUsageDescription; do
    [[ -n "$(plist $key)" ]] && pass "隐私说明 $key" || fail "缺少隐私说明 $key"
done
[[ "$(plist SUEnableInstallerLauncherService)" == "true" ]] && pass "Sparkle 沙盒安装服务" || fail "SUEnableInstallerLauncherService 未开启"
key=$(plist SUPublicEDKey)
[[ $(print -n -- "$key" | base64 -D 2>/dev/null | wc -c) -eq 32 ]] && pass "Sparkle 公钥" || fail "SUPublicEDKey 无效"
feed=$(plist KineticUpdateFeedURL)
if [[ "$feed" == https://* ]]; then pass "更新地址 $feed"
elif [[ -z "$feed" ]]; then warn "没有更新地址：这个版本不会检查更新（发行版需要 https 地址）"
else warn "更新地址不是 https：$feed"; fi

# 架构
archs=$(lipo -archs "$binary" 2>/dev/null)
[[ "$archs" == "arm64" ]] && pass "架构 arm64" || fail "架构必须是 arm64，实际：${archs:-无法读取}"

# 包内容
[[ -d "$app/Contents/Resources/Demos" ]] && pass "演示壁纸" || fail "缺少 Demos"
[[ -f "$app/Contents/Resources/Acknowledgements/Sparkle-LICENSE.txt" && -f "$app/Contents/Resources/Acknowledgements/SceneEngine-LICENSE.txt" ]] \
    && pass "第三方许可原文" || fail "缺少 Acknowledgements 许可原文"
stray=$(find "$app" \( -name "Fixtures" -o -name "*.xctest" -o -name "*Tests*" \) 2>/dev/null | head -3)
[[ -z "$stray" ]] && pass "没有测试素材 / 测试包" || fail "包里有测试内容：$stray"
debug=$(strings "$binary" | grep -E -- '--[a-z][a-z0-9-]*-test|SteamStoreDemo|CardStatesDemoLibrary' | head -3)
[[ -z "$debug" ]] && pass "没有 Debug 验收入口" || fail "正式构建里有 Debug 验收入口：$debug"

print ""
print "结果：$failures 项失败，$warnings 项提醒。"
(( failures == 0 ))
