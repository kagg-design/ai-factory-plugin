@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%CLAUDE_FACTORY_PLUGIN_ROOT%\scripts\codex-git-proxy.ps1" %*
exit /b %ERRORLEVEL%
