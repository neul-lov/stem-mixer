#!/bin/bash
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  echo "처음 실행이라 필요한 프로그램을 설치합니다. 몇 분 걸려요..."
  python3 -m venv .venv || { echo "Python이 필요해요: https://www.python.org/downloads/"; read; exit 1; }
  .venv/bin/python -m pip install --upgrade pip
  .venv/bin/python -m pip install -r requirements.txt || { echo "설치 실패"; read; exit 1; }
  .venv/bin/python -m pip install --no-deps basic-pitch
fi
.venv/bin/python -m pip install -q --upgrade "yt-dlp[default]"
echo "브라우저에서 http://localhost:8000 이 열립니다. 끄려면 이 창을 닫으세요."
.venv/bin/python server.py
