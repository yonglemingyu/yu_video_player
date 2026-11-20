#!/usr/bin/env bash
# 切换 yu_video_player 对 iOS 核心包（YUVideoPlayerIOS）的依赖方式。
#   ./tool/switch_core_dependency.sh local          # 本地联调（同级目录的 7 级相对路径，CORE_LOCAL_PATH 可覆盖）
#   ./tool/switch_core_dependency.sh remote <owner> # 发布前（指向 GitHub 上的核心仓库）
set -euo pipefail

MODE="${1:-}"
OWNER="${2:-${GH_OWNER:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/ios/yu_video_player/Package.swift"

case "$MODE" in
  local)
    # 本地联调，默认写 7 级相对路径。宿主工程里本包是被 Flutter 以软链接挂到
    #   <app>/ios/Flutter/ephemeral/Packages/.packages/yu_video_player
    # 的，Xcode 解析 path 依赖时不解软链接，是按软链接字面位置往上算的：
    #   .packages → Packages → ephemeral → Flutter → ios → <app> → <父目录>
    # 正好 7 级回到三个仓库的共同父目录，再接到同级核心仓库 yu_video_player_ios。
    # 只写 ../../../ 会停在 ios/Flutter/ephemeral，报
    # "cannot be accessed (... doesn't exist in file system)"。
    #
    # 代价：深度绑死在调用方位置上 —— 本包自己的 example 工程跑过 iOS 后会多一层
    # example（8 级），单独开 ios/yu_video_player 验证也不是这个深度。
    # 这些场景用 CORE_LOCAL_PATH 传绝对路径覆盖。
    #
    # 目录名必须是 yu_video_player_ios：SwiftPM 的 identity 取自路径最后一段，
    # 与 Package.swift 里 .product(package:) 的写法必须一致。
    if [ -n "${CORE_LOCAL_PATH:-}" ]; then
      CORE_PATH="$CORE_LOCAL_PATH"
    else
      CORE_PATH="../../../../../../../yu_video_player_ios"
      [ -d "$ROOT/../yu_video_player_ios" ] || echo "提示: 同级目录没有 yu_video_player_ios，宿主工程里会解析失败，可用 CORE_LOCAL_PATH 覆盖" >&2
    fi
    LINE="let coreDependency: Package.Dependency = .package(name: \"yu_video_player_ios\", path: \"$CORE_PATH\")"
    ;;
  remote)
    if [ -z "$OWNER" ]; then
      echo "remote 模式需要 GitHub 用户名：$0 remote <owner>" >&2
      exit 1
    fi
    LINE="let coreDependency: Package.Dependency = .package(url: \"https://github.com/${OWNER}/yu_video_player_ios.git\", from: \"1.0.0\")"
    ;;
  *)
    echo "用法: $0 local | remote <github-owner>" >&2
    exit 1
    ;;
esac

python3 - "$PKG" "$LINE" <<'PY'
import re, sys
path, line = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
new, count = re.subn(r"(?m)^let coreDependency.*$", line, text)
if count != 1:
    sys.exit("未找到 coreDependency 声明，Package.swift 可能被改过")
open(path, "w", encoding="utf-8").write(new)
print("已切换:", line)
PY
