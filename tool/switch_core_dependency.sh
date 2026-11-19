#!/usr/bin/env bash
# 切换 yu_video_player 对 iOS 核心包（YUVideoPlayerIOS）的依赖方式。
#   ./tool/switch_core_dependency.sh local          # 本地联调（默认同级目录的相对路径，CORE_LOCAL_PATH 可覆盖）
#   ./tool/switch_core_dependency.sh remote <owner> # 发布前（指向 GitHub 上的核心仓库）
set -euo pipefail

MODE="${1:-}"
OWNER="${2:-${GH_OWNER:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/ios/yu_video_player/Package.swift"

case "$MODE" in
  local)
    # 本地联调。默认用相对路径：核心仓库与本仓库同级，都放在同一个父目录下，
    # 这样换机器、换用户名都不用改，也不会写死某台机器的绝对路径。
    #
    # 相对路径以 Package.swift 所在目录（ios/yu_video_player/）为基准，
    # 向上三级即三个仓库的共同父目录。
    #
    # 目录名必须是 yu_video_player_ios：SwiftPM 的 identity 取自路径最后一段，
    # 与 Package.swift 里 .product(package:) 的写法必须一致。
    # 核心仓库不在同级目录时，用 CORE_LOCAL_PATH 指定绝对路径覆盖。
    CORE_PATH="${CORE_LOCAL_PATH:-../../../yu_video_player_ios}"
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
