"""예전 음표 뽑기와 새 모델(보컬 GAME, 피아노 ByteDance)을 같은 트랙으로 비교한다.

  .venv/bin/python scripts/compare_notes.py <곡 폴더 복사본> vocals|piano [출력 폴더]

곡 폴더는 복사본을 쓴다 (이 스크립트는 읽기만 하지만, 모델 파일은 models/ 에 받는다).
출력 폴더에 old.mid / new.mid 와 사인파로 다시 연주한 old.wav / new.wav, 숫자 요약 summary.json을 쓴다.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402

import audiofile  # noqa: E402
import transcribe as tr  # noqa: E402


def stats(notes, curve=None):
    notes = [n[:4] for n in notes]
    lens = np.array([e - s for s, e, *_ in notes]) if notes else np.zeros(1)
    out = {"notes": len(notes), "median_len": round(float(np.median(lens)), 3),
           "short_under_150ms": round(float((lens < 0.15).mean()), 3)}
    if curve is not None:
        # 원래 목소리의 음높이 선(10ms)과 비교: 소리 나는 프레임 중 음표가 덮는 비율, 그중 반음 안쪽으로 맞는 비율
        voiced = np.array([c is not None for c in curve])
        cv = np.array([c if c is not None else np.nan for c in curve], float)
        pitch = np.full(len(curve), np.nan)
        for s, e, p, _ in notes:
            pitch[int(s * 100):int(e * 100)] = p
        covered = voiced & ~np.isnan(pitch)
        out["covered"] = round(float(covered.sum() / max(1, voiced.sum())), 3)
        out["within_half_semitone"] = round(float((np.abs(pitch[covered] - cv[covered]) <= 0.5).mean()), 3) \
            if covered.any() else 0.0
        out["notes_per_voiced_sec"] = round(len(notes) / max(0.01, voiced.sum() / 100), 2)
    return out


def main():
    folder, stem = Path(sys.argv[1]), sys.argv[2]
    out = Path(sys.argv[3] if len(sys.argv) > 3 else "/tmp/notes-compare")
    out.mkdir(parents=True, exist_ok=True)
    y = audiofile.read(folder, stem)
    print(f"{stem}: {len(y) / tr.SR:.1f}초")
    curve = None
    t = time.time()
    if stem == "vocals":
        curve = []
        old = tr.mono_notes(y, fmin=60, fmax=1100, curve=curve)
    else:
        old = tr.poly_notes(y)
    t_old = time.time() - t
    t = time.time()
    new = tr.game_notes(y, step=print) if stem == "vocals" else tr.piano_notes(y, step=print)
    t_new = time.time() - t
    if new is None:
        sys.exit("새 모델을 못 찾았어요 (GAME_URL / models/game 확인)")
    tempo = tr.detect_tempo(y)
    summary = {"seconds": round(len(y) / tr.SR, 1),
               "old": {**stats(old, curve), "time": round(t_old, 1)},
               "new": {**stats(new, curve), "time": round(t_new, 1)}}
    for name, notes in (("old", old), ("new", new)):
        tr.write_midi([list(n) for n in notes], out / f"{name}.mid", tempo, "piano")
        sf.write(out / f"{name}.wav", tr.synth(notes, len(y), "sine" if stem == "vocals" else "piano"), tr.SR)
        (out / f"{name}.json").write_text(json.dumps(notes))
    (out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
