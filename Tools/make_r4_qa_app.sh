#!/bin/sh
# R4 验收：把最新 Debug 产品复制为独立 bundle ID 的 App（不共享正式 Kinetic 的偏好设置 / 登录项 / 钥匙串身份），
# 用原 entitlements 重新临时签名。用法：Tools/make_r4_qa_app.sh  → .build/R4/Kinetic-R4-QA.app
set -e
cd "$(dirname "$0")/.."
SRC=.build/DerivedData-Dev/KineticDev/Build/Products/Debug/Kinetic.app
DST=.build/R4/Kinetic-R4-QA.app
rm -rf "$DST"
mkdir -p .build/R4
cp -R "$SRC" "$DST"
codesign -d --entitlements :- "$SRC" > .build/R4/qa-entitlements.plist 2>/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kinetic.r4qa" "$DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Kinetic R4 QA" "$DST/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - --entitlements .build/R4/qa-entitlements.plist "$DST"
echo "$DST"
