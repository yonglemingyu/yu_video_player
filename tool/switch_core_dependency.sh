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
    # 7 级对应 Flutter 的软链接位置（ephemeral/Packages/.packages/<包名>）；example 等其他场景用 CORE_LOCAL_PATH
    if [ -n "${CORE_LOCAL_PATH:-}" ]; then
      CORE_PATH="$CORE_LOCAL_PATH"
    else
      CORE_PATH="../../../../../../../yu_video_player_ios"
      [ -d "$ROOT/../yu_video_player_ios" ] || echo "提示: 同级目录没有 yu_video_player_ios，可用 CORE_LOCAL_PATH 覆盖" >&2
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
