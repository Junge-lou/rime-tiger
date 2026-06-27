@echo off
cd /d "%~dp0.."
where powershell >nul 2>nul
if not errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -File "Rime皮肤编辑器\local\local_server.ps1" -Root "%CD%"
  exit /b %errorlevel%
)
echo 未找到 PowerShell，无法启动本地服务。
echo 请继续使用 Chrome/Edge 的“选择 Rime 配置文件夹”模式。
pause
exit /b 1
