"""가사 받아 적기를 곡 폴더 복사본으로 시험한다 (아무것도 저장하지 않는다).

  .venv/bin/python scripts/try_lyrics.py <곡 폴더 복사본> [auto|ko|ja|en|zh]

받아 적은 말과, 그 곡의 보컬 음표(midi/vocals.json)에 붙인 결과 앞부분을 보여 준다.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import audiofile  # noqa: E402
import lyrics as ly  # noqa: E402

folder = Path(sys.argv[1])
language = sys.argv[2] if len(sys.argv) > 2 else "auto"
y = audiofile.read(folder, "vocals")
t = time.time()
lang, words = ly.words(y, ly.LANGUAGES[language], step=print)
print(f"언어 {lang} · 말 {len(words)}개 · {time.time() - t:.1f}초 (노래 {len(y) / 44100:.0f}초)")
print(" ".join(w for _, _, w in words)[:1500])
midi = folder / "midi" / "vocals.json"
if midi.exists():
    d = json.loads(midi.read_text())
    notes = d.get("notes") or d["raw"]
    out, placed, dropped = ly.fit(notes, words, lang)
    print(f"음표 {len(notes)}개 → {len(out)}개, 가사 붙은 음표 {placed}개, 못 붙인 음절 {dropped}개")
    print(" ".join(n[4] if len(n) > 4 else "·" for n in out[:120]))
