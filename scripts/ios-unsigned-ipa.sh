#!/usr/bin/env bash
# 产出「未签名」的 arm64 iPhone 设备包（IPA），供 SideStore / AltStore / Sideloadly 用你自己的
# Apple ID 重签。CI 与本地 Mac 都可用。
#
# 为什么不直接用 `tauri ios build`：
#   它会走 archive + export，必须有已登录的 Apple 账号和 provisioning profile；而侧载工具本来
#   就会重新签名，所以 IPA 自身不需要签名。这里用 CODE_SIGNING_ALLOWED=NO 链接设备包再打包。
#
# 两个关键点（缺一不可）：
#   1. Rust 侧必须带 `tauri/custom-protocol` 特性编译，否则 Tauri 走 dev 分支、内嵌空资源，
#      真机上会白屏。脚本在打包前后各校验一次前端资源是否真的进了二进制。
#   2. 生成的 Xcode 工程里有 "Build Rust Code" 阶段，它通过本地 WebSocket 回调 Tauri CLI，
#      只在那条 CLI 驱动构建时可用。这里先把它临时替换成 no-op，结束后（trap）还原工程文件。
#
# 用法：
#   pnpm tauri ios init --ci     # 只需一次
#   ./scripts/ios-unsigned-ipa.sh
#   IPA_OUT=/tmp/hg.ipa ./scripts/ios-unsigned-ipa.sh
#
# 环境变量：
#   IPA_OUT               输出路径，默认 ./HGhub-unsigned.ipa
#   HG_IOS_NO_SWIFT_SHIM=1  跳过 SwiftPM 沙箱兼容 shim

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAURI_DIR="$ROOT/src-tauri"
GEN="$TAURI_DIR/gen/apple"
OUT="${IPA_OUT:-$ROOT/HGhub-unsigned.ipa}"
TMP="${TMPDIR:-/tmp}"
SHIM_DIR="$TMP/hghub-ios-bin"
DD="$TMP/hghub-ios-dd"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 环境检查 ----------
[ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上构建 iOS 包"
command -v xcodebuild >/dev/null 2>&1 || die "找不到 xcodebuild，请安装完整 Xcode"
[ -d "$GEN" ] || die "$GEN 不存在，先运行: pnpm tauri ios init --ci"

PROJECT="$(find "$GEN" -maxdepth 1 -name '*.xcodeproj' -print -quit)"
[ -n "$PROJECT" ] || die "在 $GEN 下没找到 .xcodeproj，初始化可能失败了"
PBX="$PROJECT/project.pbxproj"
[ -f "$PBX" ] || die "缺少 $PBX"

for cmd in pnpm cargo rustup python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "PATH 里没有 $cmd"
done

# ---------- SwiftPM 沙箱 shim ----------
# 部分 Xcode/SwiftPM 组合无法套用沙箱 profile（sandbox_apply: Operation not permitted）。
# swift-rs 在构建脚本里调用 `swift build`，这个 shim 只给 SwiftPM 子命令补 --disable-sandbox。
if [ "${HG_IOS_NO_SWIFT_SHIM:-0}" != "1" ]; then
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/swift" <<'SHIM'
#!/bin/bash
REAL_SWIFT="$(xcrun --find swift)"
for a in "$@"; do
  if [ "$a" = "--disable-sandbox" ]; then exec "$REAL_SWIFT" "$@"; fi
done
case "$1" in
  build|package|test|run) exec "$REAL_SWIFT" "$@" --disable-sandbox ;;
  *) exec "$REAL_SWIFT" "$@" ;;
esac
SHIM
  chmod +x "$SHIM_DIR/swift"
  export PATH="$SHIM_DIR:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
else
  export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

rustup target list --installed | grep -qx aarch64-apple-ios || rustup target add aarch64-apple-ios

# ---------- 工程参数探测 ----------
SCHEME="$(python3 - "$PROJECT" <<'PY'
import json, subprocess, sys
proj = sys.argv[1]
r = subprocess.run(["xcodebuild", "-list", "-json", "-project", proj],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.stderr.write(r.stdout + r.stderr)
    sys.exit(1)
schemes = json.loads(r.stdout).get("project", {}).get("schemes", [])
ios = [s for s in schemes if s.endswith("_iOS")]
pick = (ios or schemes or [""])[0]
if not pick:
    sys.exit("Xcode 工程里没有任何 scheme")
print(pick)
PY
)"
[ -n "$SCHEME" ] || die "无法确定 scheme"
log "工程: $(basename "$PROJECT")  scheme: $SCHEME"

LIBNAME="$(python3 - "$TAURI_DIR/Cargo.toml" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^\[lib\][^\[]*?^name\s*=\s*"([^"]+)"', src, re.M | re.S)
print(m.group(1) if m else "app")
PY
)"
ASSET_DIR="$GEN/Externals/arm64/release"
STATIC_LIB="$TAURI_DIR/target/aarch64-apple-ios/release/lib${LIBNAME}.a"

has_assets() { grep -aq "/assets/index-" "$1" 2>/dev/null; }

# ---------- 前端 ----------
log "构建前端 (pnpm build)"
(cd "$ROOT" && pnpm build)

# ---------- Rust 设备静态库 ----------
log "编译 Rust 设备库 (aarch64-apple-ios / release / tauri+custom-protocol)"
(
  cd "$TAURI_DIR"
  cargo build --target aarch64-apple-ios --release --lib --features tauri/custom-protocol
)
[ -f "$STATIC_LIB" ] || die "没有产出 $STATIC_LIB"

mkdir -p "$ASSET_DIR"
# 生成工程里链接的目标名在不同 Tauri 版本下可能是 libapp.a 或 lib<libname>.a，两个都放。
cp "$STATIC_LIB" "$ASSET_DIR/libapp.a"
cp "$STATIC_LIB" "$ASSET_DIR/lib${LIBNAME}.a"
has_assets "$ASSET_DIR/libapp.a" || die "静态库里没有前端资源（custom-protocol 未生效），会白屏"

# ---------- 临时停用 CLI 驱动的 Rust 构建阶段 ----------
BACKUP="$PBX.ipa-backup"
cp "$PBX" "$BACKUP"
trap 'mv -f "$BACKUP" "$PBX"' EXIT

python3 - "$PBX" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
new, n = re.subn(
    r'(?m)^(\s*shellScript = ).*tauri ios xcode-script.*$',
    r'\1"echo Using prebuilt device libapp.a";',
    src,
)
if n != 1:
    sys.exit(f"预期恰好 1 处 Build Rust Code 脚本，实际找到 {n} 处")
open(path, "w", encoding="utf-8").write(new)
PY

# ---------- 链接（不签名） ----------
log "xcodebuild 链接未签名设备包"
rm -rf "$DD"
LOG="$TMP/hghub-ios-xcodebuild.log"
if ! ( cd "$GEN" && xcodebuild \
        -project "$(basename "$PROJECT")" \
        -scheme "$SCHEME" \
        -configuration release \
        -sdk iphoneos \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DD" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual \
        ENABLE_DEBUG_DYLIB=NO \
        build ) >"$LOG" 2>&1; then
  tail -40 "$LOG" >&2
  die "xcodebuild 失败，完整日志见 $LOG"
fi
tail -5 "$LOG"

APP="$(find "$DD/Build/Products/release-iphoneos" -maxdepth 1 -name '*.app' -print -quit)"
[ -n "$APP" ] || die "没有生成 .app（检查 $LOG）"
[ -f "$APP/$(basename "$APP" .app)" ] || die "app 里没有可执行文件"
has_assets "$APP/$(basename "$APP" .app)" || die "最终二进制里没有前端资源"

# ---------- 打包 IPA ----------
log "打包 IPA"
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
find "$WORK" -name '.DS_Store' -delete
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
( cd "$WORK" && zip -qry "$OUT" Payload )
rm -rf "$WORK"

[ -s "$OUT" ] || die "IPA 打包失败"
echo
log "完成: $OUT ($(du -h "$OUT" | cut -f1))"
lipo -info "$APP/$(basename "$APP" .app)" 2>/dev/null || true
echo "未签名产物 —— 交给 SideStore / AltStore / Sideloadly 用你的 Apple ID 重签。"
