#!/bin/bash
#
# 九州异兽记 · iOS 出包脚本
#
# 三种模式：
#   1) 离线大包·无签名（资源全内置，约 900MB，玩家自己签名）
#        bash build_ios.sh unsigned
#      产出 build/Jiuzhou-unsigned.ipa
#
#   2) 联网小包·无签名（App 只几 MB，首次运行从服务器加载）
#        bash build_ios.sh lite
#      产出 build/Jiuzhou-lite-unsigned.ipa
#
#   3) 签名包（要 ¥688 的苹果开发者账号，发 TestFlight 用）
#        export TEAM_ID=你的10位团队ID
#        bash build_ios.sh
#      产出 build/ipa/Jiuzhou.ipa
#
# 前置：离线包要把 game_web.tar 解压到本目录，确认 web/wz.html 存在。
#       联网小包不需要资源，工程里那堆 .swift 就够。
#
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-signed}"
SPEC="project.yml"
NEED_WEB=1
case "$MODE" in
  unsigned)      SPEC="project.yml";      NEED_WEB=1 ;;
  lite|unsigned-lite) MODE="unsigned-lite"; SPEC="project-lite.yml"; NEED_WEB=0 ;;
  *)             MODE="signed"; SPEC="project.yml"; NEED_WEB=1 ;;
esac

echo "=================================================="
case "$MODE" in
  unsigned)      echo "  九州异兽记 iOS 出包（离线大包 · 无签名）" ;;
  unsigned-lite) echo "  九州异兽记 iOS 出包（联网小包 · 无签名）" ;;
  signed)        echo "  九州异兽记 iOS 出包（签名 · TestFlight）" ;;
esac
echo "=================================================="

# ---------- 1. Xcode ----------
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "❌ 没有可用的 Xcode。请先安装 Xcode 并执行 sudo xcodebuild -license accept"
  exit 1
fi
xcodebuild -version | head -2

# ---------- 2. xcodegen ----------
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "→ 正在获取 xcodegen（用于生成 Xcode 工程）..."
  mkdir -p .tools
  if curl -fsSL --max-time 180 -o .tools/xcodegen.zip \
      https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip \
      && unzip -oq .tools/xcodegen.zip -d .tools; then
    export PATH="$PWD/.tools/xcodegen/bin:$PATH"
  fi
fi
if ! command -v xcodegen >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  echo "→ 下载失败，改用 Homebrew 安装..."
  brew install xcodegen
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "❌ xcodegen 装不上（网络问题）。两种办法："
  echo "   1) 手动下载 https://github.com/yonaskolb/XcodeGen/releases 解压后放到 .tools/ 下"
  echo "   2) 把这一段报错发我，我给一套纯 GUI 建工程的步骤"
  exit 1
fi

# ---------- 3. 资源 ----------
if [ "$NEED_WEB" = "1" ]; then
  if [ ! -f web/wz.html ]; then
    echo "❌ 找不到 web/wz.html"
    echo "   先解压资源：tar -xf ~/Downloads/game_web.tar"
    echo "   如果只想出个能跑的小包测试，改用：bash build_ios.sh lite"
    exit 1
  fi
  WEB_FILES=$(find web -type f | wc -l | tr -d ' ')
  echo "→ web/ 共 ${WEB_FILES} 个文件，$(du -sh web | cut -f1)"
  if [ "$WEB_FILES" -lt 20000 ]; then
    echo "⚠️  文件数偏少，确认资源是否解压完整（应约 30951 个）"
  fi
else
  echo "→ 联网版：不打包 web/ 资源（App 内置服务器地址）"
fi

# ---------- 4. 生成工程 ----------
rm -rf Jiuzhou.xcodeproj build
xcodegen generate --spec "$SPEC"
echo "→ 工程已生成：Jiuzhou.xcodeproj（$(basename "$SPEC")）"

# ================================================================
#  无签名 IPA（离线大包 / 联网小包共用）
# ================================================================
if [ "$MODE" = "unsigned" ] || [ "$MODE" = "unsigned-lite" ]; then
  echo ""
  if [ "$MODE" = "unsigned" ]; then
    echo "→ 开始编译（无签名，不需要任何苹果账号）..."
    echo "   资源约 1GB，首次 3-8 分钟，别关窗口"
  else
    echo "→ 开始编译（联网小包，无签名）..."
    echo "   没有资源拷贝，通常 1-2 分钟"
  fi
  xcodebuild \
    -project Jiuzhou.xcodeproj \
    -scheme Jiuzhou \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    build 2>&1 | tee build_unsigned.log | tail -30

  APP="build/dd/Build/Products/Release-iphoneos/Jiuzhou.app"
  if [ ! -d "$APP" ]; then
    echo ""
    echo "❌ 编译失败，完整日志见 build_unsigned.log，把最后 30 行发我"
    exit 1
  fi

  if [ "$MODE" = "unsigned" ]; then
    IPA_NAME="Jiuzhou-unsigned.ipa"
    echo "→ 打包成 IPA（900MB 压缩，2-5 分钟）..."
  else
    IPA_NAME="Jiuzhou-lite-unsigned.ipa"
    echo "→ 打包成 IPA..."
  fi
  mkdir -p build/Payload
  cp -R "$APP" build/Payload/
  # -X 去掉扩展属性，避免 mac 打出来的 zip 里混进 __MACOSX 目录，
  # 有些签名平台会因为这个拒绝包
  ( cd build && zip -qrX "$IPA_NAME" Payload -x "*.DS_Store" )

  # 自检：结构 + Bundle ID
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist" 2>/dev/null || echo "读取失败")
  echo "→ Bundle ID: $BUNDLE_ID"
  if [ "$BUNDLE_ID" != "com.jinlin.jiuzhou" ]; then
    echo "⚠️  Bundle ID 和预期不一致，签名后可能影响存档延续，确认一下 $SPEC"
  fi
  if unzip -l "build/$IPA_NAME" | grep -q "__MACOSX"; then
    echo "⚠️  ipa 里混进了 __MACOSX，部分签名平台可能拒收"
  fi
  if [ "$MODE" = "unsigned-lite" ]; then
    echo "→ 内置地址：$(grep -o 'http://[0-9.]*:[0-9]*/wz.html' Sources/GameViewController.swift | head -1)"
  fi

  echo ""
  echo "=================================================="
  echo "✅ 出包完成（无签名）"
  echo "   IPA: $(pwd)/build/$IPA_NAME"
  echo "   体积: $(du -h "build/$IPA_NAME" | cut -f1)"
  echo "=================================================="
  echo "下一步：把这个 ipa 发给玩家，让他们按《玩家签名指南》自己签。"
  echo "注意：iOS 强制签名，没有签名文件装在手机上打不开，这是苹果的限制。"
  echo "★ 这个包是「未签名」状态——玩家用全能签/轻松签/Sideloadly/爱思签完就能装，"
  echo "  也可以上传给超级签/企业签服务商代签。不要自己改名或解压重压。"
  exit 0
fi

# ================================================================
#  模式二：签名 IPA（TestFlight）
# ================================================================
if [ -z "${TEAM_ID:-}" ]; then
  echo ""
  echo "❌ 没设置 TEAM_ID"
  echo "   登录 https://developer.apple.com/account → Membership 可看到 10 位 Team ID"
  echo "   然后：export TEAM_ID=ABCD123456"
  echo "   （如果不想交 ¥688，改用：bash build_ios.sh unsigned）"
  exit 1
fi
echo "→ Team ID: $TEAM_ID"

echo ""
echo "→ 开始 Archive（资源约 1GB，首次 3-8 分钟）..."
xcodebuild \
  -project Jiuzhou.xcodeproj \
  -scheme Jiuzhou \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Jiuzhou.xcarchive \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  archive 2>&1 | tee build_archive.log | tail -40

if [ ! -d build/Jiuzhou.xcarchive ]; then
  echo ""
  echo "❌ Archive 失败，完整日志见 build_archive.log"
  echo "   常见原因："
  echo "   1) 没在 Xcode 里登录 Apple 账号（Settings → Accounts）"
  echo "   2) Bundle ID 被占用：改 project.yml 里的 PRODUCT_BUNDLE_IDENTIFIER"
  echo "   3) 免费账号不支持 App Store 分发，必须是付费开发者账号"
  exit 1
fi

sed "s/YOURTEAMID/$TEAM_ID/" Support/ExportOptions.plist > build/ExportOptions.plist
xcodebuild \
  -exportArchive \
  -archivePath build/Jiuzhou.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist build/ExportOptions.plist \
  -allowProvisioningUpdates 2>&1 | tail -20

IPA=$(find build/ipa -name "*.ipa" | head -1 || true)
if [ -z "$IPA" ]; then
  echo "❌ 导出 IPA 失败。可直接用 Xcode 打开工程做 GUI 导出："
  echo "   open Jiuzhou.xcodeproj → Product → Archive → Organizer → Distribute App"
  exit 1
fi

echo ""
echo "=================================================="
echo "✅ 出包完成"
echo "   IPA: $IPA"
echo "   体积: $(du -h "$IPA" | cut -f1)"
echo "=================================================="
echo "上传到 TestFlight："
echo "  Xcode → Window → Organizers → Distribute App → App Store Connect → Upload"
