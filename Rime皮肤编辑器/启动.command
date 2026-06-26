#!/bin/zsh
cd "$(dirname "$0")/.." || exit 1

if [ -x /usr/bin/python3 ] && /usr/bin/python3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
  /usr/bin/python3 "Rime皮肤编辑器/local/local_server.py" --root "$PWD"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
  python3 "Rime皮肤编辑器/local/local_server.py" --root "$PWD"
elif command -v node >/dev/null 2>&1; then
  node "Rime皮肤编辑器/local/local_server.mjs" --root "$PWD"
else
  echo "未找到 Python 3 或 Node.js，无法启动本地服务。"
  echo "请继续使用 Chrome/Edge 的“选择 Rime 配置文件夹”模式。"
  read -r "unused?按回车关闭..."
fi
