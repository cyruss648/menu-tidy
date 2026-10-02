#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x MenuTidy >/dev/null; then
  echo '请先在 Menu Tidy 设置中退出应用，再执行安装。' >&2
  exit 1
fi
install_parent="${MENU_TIDY_INSTALL_DIR-/Applications}"
case "$install_parent" in
  /*) ;;
  *) echo 'MENU_TIDY_INSTALL_DIR 必须是非空的绝对目录路径。' >&2; exit 2;;
esac
install_target="$install_parent/Menu Tidy.app"
if ! mkdir -p "$install_parent"; then
  printf '无法创建安装目录：%s。请检查该目录的写入权限；脚本不会提权或改装到其他目录。\n' "$install_parent" >&2
  exit 1
fi
if [ ! -w "$install_parent" ] || [ ! -x "$install_parent" ]; then
  printf '安装目录不可写：%s。请检查该目录的写入权限；脚本不会提权或改装到其他目录。\n' "$install_parent" >&2
  exit 1
fi
if [ -e "$install_target" ] && [ ! -w "$install_target" ]; then
  printf '现有应用不可写：%s。请检查该应用的写入权限；脚本不会提权或改装到其他目录。\n' "$install_target" >&2
  exit 1
fi
./scripts/build.sh release
exec python3 scripts/install-bundle.py 'dist/Menu Tidy.app' "$install_parent"
