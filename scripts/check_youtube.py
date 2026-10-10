"""유튜브 받기 · 읽기 점검. 서버와 같은 코드(server.download, server.decode)를 쓴다.
쓰는 법:  .venv/bin/python scripts/check_youtube.py [링크 ...]
"""
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import server  # noqa: E402

LINKS = sys.argv[1:] or [
    "https://www.youtube.com/watch?v=hT_nvWreIhg&list=RDhT_nvWreIhg&start_radio=1",  # 기본 방식이 403으로 막혔던 영상
    "https://youtu.be/fJ9rUzIMcZQ?si=abc",
    "https://www.youtube.com/shorts/aqz-KE-bpKQ",
]
failed = 0
for link in LINKS:
    job = {}
    with tempfile.TemporaryDirectory() as tmp:
        t = time.time()
        try:
            src, title, url = server.download(link, Path(tmp), job)
            x = server.decode(src)
            ok = len(x) > server.SR and abs(x).max() > 0.01
            print(f"{'OK ' if ok else 'BAD'} {time.time() - t:5.1f}s  {src.suffix}  {len(x) / server.SR:6.1f}s 오디오  {title[:50]}"
                  + (f"  ({job['step']})" if "step" in job else ""))
            failed += not ok
        except Exception as e:
            failed += 1
            print(f"ERR {time.time() - t:5.1f}s  {link}\n    {str(e).splitlines()[0][:200]}")
sys.exit(1 if failed else 0)
