"""곡 폴더의 트랙 파일 (vocals, vocals_midi, user/vocals …).

새로 만드는 트랙은 FLAC(24비트)으로 저장한다: 소리는 wav와 똑같고 크기는 60% 정도.
예전에 wav로 저장한 곡도 그대로 읽고, "공간 줄이기"로 FLAC으로 바꿀 수 있다.
"""
import os
import threading
import uuid
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 44100
# 트랙 파일을 쓰는 곳(다시 연주 · 내 녹음)과 FLAC으로 바꾸는 작업이 같은 파일을 동시에 건드리지 않게.
lock = threading.RLock()


def path(folder, base):
    """읽을 파일: FLAC이 있으면 그것, 없으면 예전 wav."""
    flac = Path(folder) / f"{base}.flac"
    return flac if flac.exists() else Path(folder) / f"{base}.wav"


def exists(folder, base):
    return path(folder, base).exists()


def frames(folder, base):
    return sf.info(path(folder, base)).frames


def read(folder, base, **kw):
    return sf.read(path(folder, base), dtype="float32", always_2d=True, **kw)[0]


def write(folder, base, data, sr=SR):
    """FLAC(24비트)으로 저장하고 예전 wav는 지운다. 다른 곳(앱의 재생)이 옛 파일을 읽고 있어도
    반쯤 쓴 파일을 보지 않게 임시 파일에 다 쓴 뒤 한 번에 바꾼다."""
    folder = Path(folder)
    tmp = folder / f".{base}-{uuid.uuid4().hex[:8]}.tmp.flac"
    try:
        sf.write(tmp, data, sr, subtype="PCM_24", format="FLAC")
        with lock:
            os.replace(tmp, folder / f"{base}.flac")
            try:
                (folder / f"{base}.wav").unlink(missing_ok=True)
            except OSError:  # Windows: 다른 곳에서 열고 있으면 못 지운다. FLAC을 먼저 읽으니 괜찮고, 공간 줄이기가 나중에 지운다
                pass
    finally:
        tmp.unlink(missing_ok=True)
    return folder / f"{base}.flac"


def remove(folder, base):
    with lock:
        for ext in (".flac", ".wav"):
            (Path(folder) / f"{base}{ext}").unlink(missing_ok=True)


# ---------------------------------------------------------------- 예전 wav → FLAC
def convertible(song_folder, stems):
    """FLAC으로 바꿀 수 있는 wav: 나눈 트랙, 음정 트랙(_midi), 내 녹음(user/). 내가 넣은 원본 파일(*.src.*)은 그대로."""
    song_folder = Path(song_folder)
    names = [f"{s}.wav" for s in stems] + [f"{s}_midi.wav" for s in stems] + [f"user/{s}.wav" for s in stems]
    return [song_folder / n for n in names if (song_folder / n).is_file()]


BLOCK = SR * 30


def to_flac(wav):
    """wav 하나를 FLAC으로 바꾼다. 다시 읽어서 샘플이 하나도 다르지 않을 때만 wav를 지운다.
    반환: 줄어든 바이트 (바꾸지 않았으면 None)."""
    wav = Path(wav)
    flac = wav.with_suffix(".flac")
    tmp = wav.with_name(f".{wav.stem}-{uuid.uuid4().hex[:8]}.tmp.flac")
    with lock:  # 바꾸는 동안 이 트랙을 새로 쓰지 않게 (한 파일에 몇 초)
        if not wav.exists():
            return None
        before = wav.stat()
        if flac.exists():
            # 새로 쓴 FLAC 옆에 못 지운 옛 wav: FLAC이 진짜라서 wav만 지운다 (덮어쓰면 새 소리가 사라진다)
            wav.unlink()
            return before.st_size if before.st_nlink == 1 else 0
        info = sf.info(wav)
        if info.subtype not in ("PCM_16", "PCM_24") or info.samplerate > 655350:
            return None  # float wav 같은 건 FLAC에 그대로 못 담는다
        dtype = "int16" if info.subtype == "PCM_16" else "int32"
        try:
            with sf.SoundFile(wav) as src, sf.SoundFile(tmp, "w", info.samplerate, info.channels,
                                                        subtype=info.subtype, format="FLAC") as dst:
                for block in src.blocks(BLOCK, dtype=dtype, always_2d=True):
                    dst.write(block)
            with sf.SoundFile(wav) as a, sf.SoundFile(tmp) as b:
                if a.frames != b.frames:
                    return None
                while True:
                    x = a.read(BLOCK, dtype=dtype, always_2d=True)
                    y = b.read(BLOCK, dtype=dtype, always_2d=True)
                    if not np.array_equal(x, y):
                        return None
                    if not len(x):
                        break
            now = wav.stat()
            if (now.st_mtime_ns, now.st_size) != (before.st_mtime_ns, before.st_size):
                return None  # 바꾸는 사이에 새로 쓰였다: 다음에 다시
            os.replace(tmp, flac)
            wav.unlink()
            # 다른 곳(앱의 끌어놓기 임시 폴더)에 같은 파일이 연결돼 있으면 지워도 공간이 안 비워진다
            return before.st_size - flac.stat().st_size if before.st_nlink == 1 else -flac.stat().st_size
        finally:
            tmp.unlink(missing_ok=True)
