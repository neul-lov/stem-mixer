@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist .venv (
  echo 처음 실행이라 필요한 프로그램을 설치합니다. 몇 분 걸려요...
  py -3 -m venv .venv || python -m venv .venv || (echo Python이 필요해요: https://www.python.org/downloads/ & pause & exit /b)
  .venv\Scripts\python -m pip install --upgrade pip
  .venv\Scripts\python -m pip install -r requirements.txt || (echo 설치 실패 & pause & exit /b)
)
.venv\Scripts\python -m pip install -q --upgrade "yt-dlp[default]"
echo 브라우저에서 http://localhost:8000 이 열립니다. 끄려면 이 창을 닫으세요.
.venv\Scripts\python server.py
pause
