#!/usr/bin/env bash
# 切换 yu_video_player 对 iOS 核心包（YUVideoPlayerIOS）的依赖方式。
#   ./tool/switch_core_dependency.sh local          # 本地联调（同级目录，脚本解析成绝对路径，CORE_LOCAL_PATH 可覆盖）
#   ./tool/switch_core_dependency.sh remote <owner> # 发布前（指向 GitHub 上的核心仓库）
set -euo pipefail

MODE="${1:-}"
OWNER="${2:-${GH_OWNER:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/ios/yu_video_player/Package.swift"

case "$MODE" in
  local)
    # 本地联调。核心仓库默认与本仓库同级（同一个父目录下），按本机实际位置
    # 解析成绝对路径写进去 —— 换机器、换用户名都不用改，脚本自己算。
    #
    # 这里必须用绝对路径，不能写相对路径：宿主工程里这个插件包是被 Flutter
    # 以软链接挂到 ios/Flutter/ephemeral/Packages/.packages/yu_video_player 的，
    # Xcode 解析 path 依赖时不会先解软链接，路径是按软链接字面位置往上算的，
    # `../../../` 只爬到 ios/Flutter/ephemeral，最终去找
    # ios/Flutter/ephemeral/yu_video_player_ios，报
    # "cannot be accessed (... doesn't exist in file system)"。
    #
    # 相对路径不是完全不行，实测要写 7 级（../../../../../../../yu_video_player_ios）
    # 才能爬回仓库父目录；但这个深度绑死在调用方的位置上 —— 宿主工程是 7 级，
    # 本包自己的 example 工程一旦也跑过 iOS，会多一层变成 8 级。一个值伺候不了
    # 两处，所以干脆用脚本算绝对路径。
    #
    # 目录名必须是 yu_video_player_ios：SwiftPM 的 identity 取自路径最后一段，
    # 与 Package.swift 里 .product(package:) 的写法必须一致。
    # 核心仓库不在同级目录时，用 CORE_LOCAL_PATH 指定绝对路径覆盖。
    if [ -n "${CORE_LOCAL_PATH:-}" ]; then
      CORE_PATH="$CORE_LOCAL_PATH"
    else
      CORE_PATH="$(cd "$ROOT/../yu_video_player_ios" && pwd)" || {
        echo "找不到同级核心仓库 $ROOT/../yu_video_player_ios，请用 CORE_LOCAL_PATH 指定" >&2
        exit 1
      }
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
