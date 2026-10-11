"""트랙의 음정을 읽어서 음표(MIDI)로 만들고, 깔끔한 소리로 다시 연주한다.

- 보컬: GAME (OpenVPI, ONNX) — 분리된 노래를 악보로 만드는 전용 모델. 못 쓰면 아래 torchcrepe 방식.
- 베이스: torchcrepe로 음 높이를 10ms마다 읽고 음표로 나눈다.
- 피아노: ByteDance 피아노 채보 모델 (Kong et al. 2021).
- 나머지 화음 파트(기타, 나머지): Spotify basic-pitch (ONNX).
- 다시 연주는 내장 신스(피아노풍 · 신스 리드 · 사인 · 스트링)로 해서 사운드폰트가 필요 없다.
"""
import json
import math
import subprocess
import sys
import tempfile
import traceback
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 44100
MODEL_DIR = Path(__file__).parent / "models"
MONO_STEMS = ("vocals", "bass")
PITCH_MODEL = "tiny"  # torchcrepe tiny: 테스트에서 full보다 빠르고 정확했다. "fcpe"는 더 빠르지만 다른 소리가 섞이면 덜 정확
SOUNDS = ("piano", "lead", "sine", "strings")
GM_PROGRAM = {"piano": 0, "lead": 81, "sine": 80, "strings": 48}
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]


def _device():
    import torch
    return "mps" if torch.backends.mps.is_available() else "cpu"


# ---------------------------------------------------------------- 한 음씩 (보컬, 베이스)
def _track_pitch(y, progress, fmin, fmax, decoder):
    """10ms마다 음 높이(MIDI, 소수점까지)와 소리가 나는지, 크기(dB)."""
    import torch
    import torchaudio
    import torchcrepe

    x = torch.from_numpy(y.mean(axis=1).astype(np.float32))[None]
    x16 = torchaudio.functional.resample(x, SR, 16000)
    hop = 160  # 10 ms
    f0s, pers = [], []
    chunk = 16000 * 30  # 30초씩 (메모리)
    total = x16.shape[1]
    if PITCH_MODEL == "fcpe":
        global _fcpe
        try:
            _fcpe
        except NameError:
            from torchfcpe import spawn_bundled_infer_model
            _fcpe = spawn_bundled_infer_model(device=_device())
        for i in range(0, total, chunk):
            part = x16[:, i:i + chunk]
            if part.shape[1] < hop * 2:
                break
            n_out = part.shape[1] // hop
            f0 = _fcpe.infer(part[..., None].to(_device()), sr=16000, decoder_mode="local_argmax",
                             threshold=0.006, f0_min=fmin, f0_max=fmax, interp_uv=False,
                             output_interp_target_length=n_out)
            f0 = f0.squeeze().cpu().numpy().astype(np.float32)
            f0s.append(f0); pers.append((f0 > 0).astype(np.float32))
            progress(min(0.95, (i + chunk) / total))
        total = 0  # skip the crepe loop below
    for i in range(0, total, chunk):
        part = x16[:, i:i + chunk]
        if part.shape[1] < hop * 2:
            break
        dec = torchcrepe.decode.viterbi if decoder == "viterbi" else torchcrepe.decode.weighted_argmax
        f0, per = torchcrepe.predict(part, 16000, hop, fmin, fmax, PITCH_MODEL, return_periodicity=True,
                                     batch_size=2048, device=_device(), decoder=dec)
        f0s.append(f0[0].cpu().numpy()); pers.append(per[0].cpu().numpy())
        progress(min(0.95, (i + chunk) / total))
    f0 = np.concatenate(f0s); per = np.concatenate(pers)
    from scipy.ndimage import median_filter

    per = median_filter(per, 3)
    # Loudness per 10 ms frame, to drop quiet bleed that the pitch tracker still "hears".
    m = y.mean(axis=1)
    n = len(f0)
    frame = int(SR * 0.01)
    mp = np.pad(m, (0, max(0, n * frame - len(m))))[: n * frame]  # the last pitch frame can run past the audio
    rms = np.sqrt((mp.reshape(n, frame) ** 2).mean(axis=1) + 1e-12)
    db = 20 * np.log10(rms + 1e-9)
    voiced = (per > 0.45) & (db > max(-50, db.max() - 40))
    midi = 69 + 12 * np.log2(np.maximum(f0, 1e-3) / 440)
    midi = median_filter(midi, 5)
    return midi, voiced, db, m, n, frame


def curve_list(midi, voiced):
    """편집 화면에 그릴 음높이 선: 10ms마다 MIDI 음 (소리가 없으면 None)."""
    return [round(float(v), 2) if ok and math.isfinite(v) else None for v, ok in zip(midi, voiced)]


def pitch_range(stem):
    # CREPE covers about 32.7 Hz (C1) and up; asking for lower returns nothing.
    return (33, 400) if stem == "bass" else (60, 1100)


def pitch_curve(y, stem, progress=lambda p: None):
    fmin, fmax = pitch_range(stem)
    midi, voiced, *_ = _track_pitch(y, progress, fmin, fmax, "argmax")
    progress(1.0)
    return curve_list(midi, voiced)


def mono_notes(y, progress=lambda p: None, fmin=50.0, fmax=1100.0, decoder="argmax", curve=None):
    """f0를 읽어서 (시작초, 끝초, MIDI 음, 세기 0~1) 목록으로. curve(list)를 주면 음높이 선도 채운다."""
    midi, voiced, db, m, n, frame = _track_pitch(y, progress, fmin, fmax, decoder)
    if curve is not None:
        curve[:] = curve_list(midi, voiced)
    q = np.where(voiced, np.round(midi), -1).astype(int)
    # Note starts from loudness jumps, so a repeated note at the same pitch is split in two.
    import librosa

    onset_env = librosa.onset.onset_strength(y=m, sr=SR, hop_length=frame)
    found = librosa.onset.onset_detect(onset_envelope=onset_env, sr=SR, hop_length=frame,
                                       backtrack=False, delta=0.08)
    # Keep only real attacks: loudness jumps at least 6 dB (vibrato wobbles far less).
    onsets = {int(o) for o in found if o < n and db[o:o + 4].max() - db[max(0, o - 8):max(1, o - 1)].min() > 6}

    # Run-length runs of the same semitone.
    runs, start = [], 0
    for i in range(1, n + 1):
        if i == n or q[i] != q[start]:
            runs.append([start, i, q[start]])
            start = i
    # Short wobbles (vibrato, slides) shorter than 60 ms join the note before them.
    merged = []
    for r in runs:
        if merged and r[2] != -1 and merged[-1][2] != -1 and r[1] - r[0] < 6:
            merged[-1][1] = r[1]
            continue
        if merged and merged[-1][2] == r[2]:
            merged[-1][1] = r[1]
            continue
        merged.append(r)
    # Same note across a gap under 40 ms is one note, unless a new attack starts there.
    notes = []
    for s, e, p in merged:
        if p == -1:
            continue
        if notes and notes[-1][2] == p and s - notes[-1][1] < 4 and not any(o in onsets for o in range(s - 2, s + 3)):
            notes[-1][1] = e
        else:
            notes.append([s, e, p])
    # Split a long same-pitch note where a clear new attack happens inside it.
    split = []
    for s, e, p in notes:
        cuts = [o for o in sorted(onsets) if s + 8 <= o <= e - 8]
        for c in cuts:
            split.append([s, c, p]); s = c
        split.append([s, e, p])
    notes = split
    out = []
    for s, e, p in notes:
        if e - s < 8:  # under 80 ms: not a real note
            continue
        pitch = int(np.round(np.median(midi[s:e][voiced[s:e]]))) if voiced[s:e].any() else p
        vel = float(np.clip(np.nan_to_num((db[s:e].mean() - db.max() + 40) / 40, nan=0.5), 0.2, 1.0))
        out.append((s / 100, e / 100, pitch, vel))
    progress(1.0)
    return out


# ---------------------------------------------------------------- 화음 (피아노, 기타 …)
def poly_notes(y, progress=lambda p: None, bass=False):
    import warnings

    warnings.filterwarnings("ignore")
    from basic_pitch import FilenameSuffix, build_icassp_2022_model_path
    from basic_pitch.inference import Model, predict

    global _bp_model
    try:
        _bp_model
    except NameError:
        _bp_model = Model(build_icassp_2022_model_path(FilenameSuffix.onnx))
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "in.wav"
        sf.write(path, y.mean(axis=1), SR)
        progress(0.1)
        _, _, events = predict(str(path), _bp_model, onset_threshold=0.7, frame_threshold=0.4,
                               minimum_note_length=80, minimum_frequency=30 if bass else 50,
                               maximum_frequency=400 if bass else 4200, melodia_trick=False)
    progress(1.0)
    return sorted((float(s), float(e), int(p), float(np.clip(a, 0.15, 1.0))) for s, e, p, a, *_ in events)


# ---------------------------------------------------------------- 조성 · 빠르기
def detect_key(notes):
    hist = np.zeros(12)
    for s, e, p, *_ in notes:
        hist[p % 12] += e - s
    if hist.sum() == 0:
        return 0, "major"
    best = max(((np.corrcoef(hist, np.roll(prof, k))[0, 1], k, mode)
                for prof, mode in ((MAJOR, "major"), (MINOR, "minor")) for k in range(12)))
    return best[1], best[2]


def key_name(tonic, mode):
    return f"{NOTE_NAMES[tonic]} {'장조' if mode == 'major' else '단조'}"


def scale(tonic, mode):
    steps = [0, 2, 4, 5, 7, 9, 11] if mode == "major" else [0, 2, 3, 5, 7, 8, 10]
    return {(tonic + s) % 12 for s in steps}


def snap_to_key(notes, tonic, mode):
    sc = scale(tonic, mode)
    out = []
    for s, e, p, v, *lyric in notes:
        if p % 12 not in sc:
            p = p - 1 if (p - 1) % 12 in sc else p + 1
        out.append((s, e, p, v, *lyric))
    return out


def detect_tempo(mix):
    import librosa

    tempo, _ = librosa.beat.beat_track(y=mix.mean(axis=1)[: SR * 120], sr=SR)
    return float(np.atleast_1d(tempo)[0]) or 120.0


# ---------------------------------------------------------------- 가사
# 음표는 (시작초, 끝초, MIDI 음, 세기) 또는 가사가 있으면 (…, 가사). 가사는 편집 화면에서 넣는다.
def lyric_of(note):
    return note[4] if len(note) > 4 and note[4] else None


def _midi_text_out(text):
    # MIDI 가사는 바이트로 저장된다. mido는 latin-1로만 쓰니 UTF-8 바이트를 그대로 넘긴다 (요즘 프로그램은 UTF-8로 읽음).
    return text.encode("utf-8").decode("latin-1")


def _midi_text_encoding(texts):
    """MIDI 가사의 글자 인코딩을 파일 하나에 한 번 고른다. 옛 한국 노래방 파일(cp949)의 바이트 중에는
    Shift-JIS로도 읽히는 것(반각 가타카나)이 있어서, 한 글자씩 고르면 한글과 가타카나가 섞인다."""
    raws = [t.encode("latin-1", errors="ignore") for t in texts]

    def decoded(enc):  # 가사 하나하나가 다 읽혀야 (이어 붙이면 두 가사의 바이트가 한 글자로 읽힐 수 있다)
        try:
            return "\n".join(r.decode(enc) for r in raws)
        except UnicodeDecodeError:
            return None
    if decoded("utf-8") is not None:
        return "utf-8"
    kr, jp = decoded("cp949"), decoded("shift_jis")
    if kr is not None and jp is not None:
        hangul = any("\uac00" <= c <= "\ud7a3" for c in kr)
        halfwidth = any("\uff61" <= c <= "\uff9f" for c in jp)
        japanese = any("\u3040" <= c <= "\u30ff" or "\u4e00" <= c <= "\u9fff" for c in jp)
        return "cp949" if hangul and (halfwidth or not japanese) else "shift_jis"
    return "cp949" if kr is not None else "shift_jis" if jp is not None else None


def _midi_text_in(text, enc=None):
    raw = text.encode("latin-1", errors="ignore")
    for e in ([enc] if enc else []) + ["utf-8", "shift_jis", "cp949"]:
        try:
            return raw.decode(e)
        except UnicodeDecodeError:
            pass
    return text


# ---------------------------------------------------------------- 저장 · 다시 연주
def write_midi(notes, path, tempo, sound):
    import pretty_midi

    pm = pretty_midi.PrettyMIDI(initial_tempo=tempo)
    inst = pretty_midi.Instrument(program=GM_PROGRAM.get(sound, 0))
    for n in notes:
        s, e, p, v = n[:4]
        if 0 <= p <= 127:
            inst.notes.append(pretty_midi.Note(velocity=int(30 + 90 * v), pitch=p, start=s, end=e))
            if lyric_of(n):
                pm.lyrics.append(pretty_midi.Lyric(_midi_text_out(lyric_of(n)), s))
    pm.instruments.append(inst)
    pm.write(str(path))


def synth(notes, n_frames, sound="piano"):
    """내장 신스로 음표를 연주한 스테레오 float 배열."""
    out = np.zeros(n_frames, np.float32)
    for s, e, p, v, *_ in notes:
        f = 440 * 2 ** ((p - 69) / 12)
        release = 0.25 if sound != "piano" else 0.4
        i0 = int(s * SR)
        n = int((e - s + release) * SR)
        if i0 >= n_frames or n <= 0:
            continue
        n = min(n, n_frames - i0)
        t = np.arange(n, dtype=np.float32) / SR
        dur = e - s
        if sound == "sine":
            wave = np.sin(2 * np.pi * f * t)
            env = np.minimum(1, t / 0.01) * np.where(t < dur, 1, np.exp(-(t - dur) / 0.06))
        elif sound == "lead":
            k = np.arange(1, max(2, min(30, int(9000 / f))) + 1)[:, None]
            wave = (np.sin(2 * np.pi * f * k * t) / k).sum(0) * 0.6
            env = np.minimum(1, t / 0.01) * np.where(t < dur, 0.85, 0.85 * np.exp(-(t - dur) / 0.08))
        elif sound == "strings":
            wave = 0
            for det in (-0.08, 0.0, 0.07):
                fd = f * 2 ** (det / 12)
                k = np.arange(1, max(2, min(20, int(7000 / fd))) + 1)[:, None]
                wave = wave + (np.sin(2 * np.pi * fd * k * t + det * 10) / k).sum(0)
            wave *= 0.3
            env = np.minimum(1, t / 0.12) * np.where(t < dur, 1, np.exp(-(t - dur) / 0.15))
        else:  # piano-like: decaying harmonics, higher ones fade faster
            k = np.arange(1, max(2, min(12, int(8000 / f))) + 1)[:, None]
            decay = np.exp(-t[None] * (1.2 + 0.6 * k) * (1 + (p - 48) / 60))
            wave = (np.sin(2 * np.pi * f * k * t) / k ** 1.3 * decay).sum(0)
            env = np.minimum(1, t / 0.004) * np.where(t < dur, 1, np.exp(-(t - dur) / 0.12))
        out[i0:i0 + n] += (wave * env * (0.25 + 0.55 * v)).astype(np.float32)
    peak = np.abs(out).max()
    if peak > 0:
        out *= 0.7 / peak
    return np.stack([out, out], axis=1)


# ---------------------------------------------------------------- 모델 받기
def _download(url, dest, progress=lambda p: None):
    """처음 한 번 모델 파일을 받는다. 다 받은 뒤에 이름을 바꿔서, 중간에 끊겨도 반쪽 파일이 남지 않게."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f".{dest.name}.part")
    try:
        with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done = 0
            while chunk := r.read(1 << 20):
                f.write(chunk)
                done += len(chunk)
                if total:
                    progress(done / total)
        tmp.replace(dest)
    finally:
        tmp.unlink(missing_ok=True)
    return dest


def _need(*packages):
    """예전에 설치한 앱에는 없는 파이썬 패키지를 그 자리에서 설치한다 (처음 한 번)."""
    import importlib
    import importlib.util

    missing = [pip for mod, pip in packages if importlib.util.find_spec(mod) is None]
    if missing:
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", *missing], check=True)
        importlib.invalidate_caches()


# ---------------------------------------------------------------- 보컬: GAME (OpenVPI)
# https://github.com/openvpi/GAME — 분리된 노래를 악보로 만드는 전용 모델 (MIT). ONNX로 돌려서 onnxruntime만 있으면 된다.
GAME_DIR = MODEL_DIR / "game"
GAME_URL = "https://github.com/openvpi/GAME/releases/download/v1.0.3/GAME-1.0.3-medium-onnx.zip"  # 180MB, 공식 ONNX 묶음
GAME_FILES = ("config.json", "encoder.onnx", "segmenter.onnx", "estimator.onnx", "bd2dur.onnx")


def _game_dir():
    if GAME_DIR.exists():
        for c in sorted(GAME_DIR.rglob("config.json")):
            if all((c.parent / f).is_file() for f in GAME_FILES):
                return c.parent
    return None


def game_ready():
    return _game_dir() is not None or bool(GAME_URL)


class _Game:
    def __init__(self, folder):
        import onnxruntime as ort

        self.config = json.loads((folder / "config.json").read_text())
        opts = ort.SessionOptions()
        opts.log_severity_level = 3

        def load(name):
            return ort.InferenceSession(str(folder / name), opts, providers=["CPUExecutionProvider"])

        self.encoder, self.segmenter = load("encoder.onnx"), load("segmenter.onnx")
        self.estimator, self.bd2dur = load("estimator.onnx"), load("bd2dur.onnx")
        self.sr = int(self.config.get("samplerate", SR))
        self.timestep = float(self.config.get("timestep", 0.01))
        self.loop = bool(self.config.get("loop"))
        self.seg_inputs = {i.name for i in self.segmenter.get_inputs()}

    def run(self, wav, language=0, steps=8, seg_threshold=0.2, radius=0.02, est_threshold=0.2):
        """wav(모노 float32, self.sr) 한 조각 → [(시작초, 길이초, MIDI 음(소수))] 소리 나는 음표만."""
        x_seg, x_est, mask = self.encoder.run(None, {
            "waveform": wav[None].astype(np.float32), "duration": np.array([len(wav) / self.sr], np.float32)})
        known = np.zeros(mask.shape, bool)
        feeds = {"x_seg": x_seg, "known_boundaries": known, "maskT": mask,
                 "threshold": np.array(seg_threshold, np.float32),
                 "radius": np.array(round(radius / self.timestep), np.int64),
                 "language": np.array([language], np.int64)}
        bounds = known
        # D3PM: 경계를 몇 번에 걸쳐 다듬는다 (t = 0, 1/8, … 7/8; GAME 기본값)
        for t in ([i / steps for i in range(steps)] if self.loop else [None]):
            if t is not None:
                feeds.update(prev_boundaries=bounds, t=np.array([t], np.float32))
            bounds = self.segmenter.run(None, {k: v for k, v in feeds.items() if k in self.seg_inputs})[0]
        durations, mask_n = self.bd2dur.run(None, {"boundaries": bounds, "maskT": mask})
        presence, scores = self.estimator.run(None, {
            "x_est": x_est, "boundaries": bounds, "maskT": mask, "maskN": mask_n,
            "threshold": np.array(est_threshold, np.float32)})
        out, t = [], 0.0
        for d, ok, s, valid in zip(durations[0], presence[0], scores[0], mask_n[0]):
            if not valid:
                break
            if ok:
                out.append((t, float(d), float(s)))
            t += float(d)
        return out


def _get_game(step=lambda text: None, progress=lambda p: None):
    global _game
    try:
        return _game
    except NameError:
        pass
    folder = _game_dir()
    if folder is None and GAME_URL:
        step("노래 음표 AI 모델 받는 중 (처음 한 번)")
        z = _download(GAME_URL, MODEL_DIR / "game.zip", progress)
        try:
            with zipfile.ZipFile(z) as f:
                f.extractall(GAME_DIR)
        finally:
            z.unlink(missing_ok=True)
        folder = _game_dir()
    if folder is None:
        return None
    _need(("onnxruntime", "onnxruntime"))
    _game = _Game(folder)
    return _game


def _sing_chunks(m, sr, max_len=30.0):
    """노래를 쉬는 곳(0.2초 넘게 -40dB 아래)에서 조각낸다: [(시작 샘플, 끝 샘플)]. GAME도 이렇게 잘라서 읽는다.
    한 조각이 max_len초를 넘으면 그 안에서 가장 조용한 곳에서 한 번 더 자른다."""
    hop = sr // 100
    n = len(m) // hop
    if n == 0:
        return []
    rms = np.sqrt((m[: n * hop].reshape(n, hop) ** 2).mean(axis=1))
    loud = rms >= 10 ** (-40 / 20)
    # 소리 나는 구간을 찾고, 0.2초보다 짧게 쉬는 곳은 이어 붙인다
    spans, i = [], 0
    while i < n:
        if not loud[i]:
            i += 1
            continue
        j = i
        while j < n and loud[j]:
            j += 1
        if spans and i - spans[-1][1] < 20:
            spans[-1][1] = j
        else:
            spans.append([i, j])
        i = j
    out = []
    for a, b in spans:
        a, b = max(0, a - 10), min(n, b + 10)  # 앞뒤로 0.1초 여유
        if out and a < out[-1][1]:
            out[-1][1] = b
            continue
        out.append([a, b])
    # 1초도 안 되는 조각은 다음 조각과 붙인다 (너무 짧으면 음 경계를 잘 못 찾는다)
    merged = []
    for a, b in out:
        if merged and merged[-1][1] - merged[-1][0] < 100 and b - merged[-1][0] <= max_len * 100:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    limit = int(max_len * 100)
    final = []
    for a, b in merged:
        while b - a > limit:
            lo = a + limit // 2
            cut = lo + int(np.argmin(rms[lo:a + limit]))
            final.append((a * hop, cut * hop))
            a = cut
        final.append((a * hop, min(len(m), b * hop)))
    return final


def game_notes(y, progress=lambda p: None, step=lambda text: None):
    """GAME으로 보컬 음표: (시작초, 끝초, MIDI 음, 세기 0~1). 모델이 없으면 None."""
    g = _get_game(step, lambda p: progress(0.3 * p))
    if g is None:
        return None
    step("노래 음표 읽는 중 (GAME)")
    m = y.mean(axis=1).astype(np.float32)
    if g.sr != SR:
        import librosa
        m = librosa.resample(m, orig_sr=SR, target_sr=g.sr)
    language = 0  # 0 = 언어 구분 없이 (한국어는 모델이 따로 알지 못한다)
    chunks = _sing_chunks(m, g.sr)
    total = sum(b - a for a, b in chunks) or 1
    done, raw = 0, []
    for a, b in chunks:
        for s, d, p in g.run(m[a:b], language):
            raw.append((a / g.sr + s, a / g.sr + s + d, p))
        done += b - a
        progress(0.3 + 0.7 * done / total)
    # 세기: 그 음표 구간의 소리 크기 (가장 큰 소리보다 40dB 작으면 0.2)
    frame = g.sr // 100
    n = len(m) // frame
    db = 20 * np.log10(np.sqrt((m[: n * frame].reshape(n, frame) ** 2).mean(axis=1)) + 1e-9) if n else np.zeros(1)
    top = db.max()
    out = []
    for s, e, p in raw:
        if e - s < 0.05 or not math.isfinite(p):
            continue
        seg = db[int(s * 100):max(int(s * 100) + 1, int(e * 100))]
        vel = float(np.clip((seg.mean() - top + 40) / 40 if len(seg) else 0.5, 0.2, 1.0))
        out.append((round(s, 3), round(e, 3), int(np.clip(round(p), 0, 127)), round(vel, 3)))
    progress(1.0)
    return out


# ---------------------------------------------------------------- 피아노: ByteDance 피아노 채보
# Kong et al., "High-resolution Piano Transcription with Pedals by Regressing Onset and Offset Times" (MIT)
PIANO_CKPT = MODEL_DIR / "piano_note_pedal.pth"
PIANO_URL = "https://zenodo.org/record/4034264/files/CRNN_note_F1%3D0.9677_pedal_F1%3D0.9186.pth?download=1"


def piano_notes(y, progress=lambda p: None, step=lambda text: None):
    import os

    os.environ.setdefault("MPLBACKEND", "Agg")  # 모델 코드가 matplotlib을 불러온다 (창은 안 띄운다)
    import torch
    import torchaudio

    _need(("piano_transcription_inference", "piano_transcription_inference"), ("torchlibrosa", "torchlibrosa"),
          ("matplotlib", "matplotlib"), ("mido", "mido"))
    from piano_transcription_inference.models import Note_pedal
    from piano_transcription_inference.utilities import RegressionPostProcessor

    global _piano
    try:
        _piano
    except NameError:
        if not PIANO_CKPT.exists() or PIANO_CKPT.stat().st_size < 1.6e8:
            step("피아노 AI 모델 받는 중 (처음 한 번, 165MB)")
            _download(PIANO_URL, PIANO_CKPT, lambda p: progress(0.3 * p))
        model = Note_pedal(frames_per_second=100, classes_num=88)
        model.load_state_dict(torch.load(PIANO_CKPT, map_location="cpu", weights_only=True)["model"], strict=False)
        model.eval()
        _piano = model
    step("피아노 음표 읽는 중")
    model = _piano
    x = torch.from_numpy(y.mean(axis=1).astype(np.float32))[None]
    audio = torchaudio.functional.resample(x, SR, 16000)[0].numpy()
    seg = 16000 * 10  # 10초 조각을 5초씩 겹쳐서 (원래 코드와 같게)
    n = len(audio)
    audio = np.pad(audio, (0, int(np.ceil(max(n, 1) / seg)) * seg - n))
    starts = list(range(0, len(audio) - seg + 1, seg // 2))
    outs = {}
    with torch.no_grad():
        for k, i in enumerate(starts):
            o = model(torch.from_numpy(audio[None, i:i + seg]))
            for key, v in o.items():
                outs.setdefault(key, []).append(v[0].numpy())
            progress(0.3 + 0.65 * (k + 1) / len(starts))
    joined = {}
    for key, parts in outs.items():
        if len(parts) == 1:
            joined[key] = parts[0][:n // 160 + 1]
            continue
        parts = [p[:-1] for p in parts]  # 조각 끝의 한 프레임은 덧붙은 것
        L = parts[0].shape[0]
        pieces = [parts[0][:int(L * 0.75)]] + [p[int(L * 0.25):int(L * 0.75)] for p in parts[1:-1]] + \
                 [parts[-1][int(L * 0.25):]]
        joined[key] = np.concatenate(pieces)[:n // 160 + 1]
    post = RegressionPostProcessor(100, classes_num=88, onset_threshold=0.3, offset_threshold=0.3,
                                   frame_threshold=0.1, pedal_offset_threshold=0.2)
    notes, _pedal = post.output_dict_to_midi_events(joined)
    progress(1.0)
    return sorted((round(float(e["onset_time"]), 3), round(float(e["offset_time"]), 3), int(e["midi_note"]),
                   float(np.clip(e["velocity"] / 127, 0.15, 1.0))) for e in notes
                  if e["offset_time"] - e["onset_time"] >= 0.03)


def transcribe(y, stem, progress=lambda p: None, curve=None, step=lambda text: None):
    if stem == "vocals":
        try:
            notes = game_notes(y, lambda p: progress(0.6 * p if curve is not None else p), step)
            if notes is not None:
                if curve is not None:  # 편집 화면의 음높이 선도 같이 (예전 방식은 음표 뽑으며 채웠다)
                    step("음 높이를 읽는 중")
                    curve.extend(pitch_curve(y, stem, lambda p: progress(0.6 + 0.4 * p)))
                return notes
        except Exception:  # 모델을 못 받거나 못 돌리면 예전 방식으로
            traceback.print_exc()
        step("음 높이를 읽는 중")
    if stem == "piano":
        try:
            return piano_notes(y, progress, step)
        except Exception:
            traceback.print_exc()
            step("화음을 읽는 중 (basic-pitch)")
    if stem in MONO_STEMS:
        fmin, fmax = pitch_range(stem)
        return mono_notes(y, progress, fmin=fmin, fmax=fmax, curve=curve)
    return poly_notes(y, progress, bass=False)


def render(folder, stem, sound, transpose, snap, tempo=None):
    """저장해 둔 음표(raw)로 MIDI 파일과 다시 연주한 트랙을 만든다. 음 바꾸기는 다시 읽지 않고 여기서."""
    data = json.loads((folder / "midi" / f"{stem}.json").read_text())
    if tempo:
        data["tempo"] = float(tempo)
    # 앱에서 고친 음표가 있으면 그걸로 (AI가 뽑은 raw는 "AI 음표로 되돌리기"용으로 남겨 둔다).
    notes = [tuple(n) for n in (data["edited"] if "edited" in data else data["raw"])]
    tonic, mode = data["key"]
    if snap:
        notes = snap_to_key(notes, tonic, mode)
    notes = [(s, e, p + transpose, v, *lyric) for s, e, p, v, *lyric in notes]
    import audiofile

    audiofile.write(folder, f"{stem}_midi", synth(notes, audiofile.frames(folder, stem), sound))
    write_midi(notes, folder / "midi" / f"{stem}.mid", data["tempo"], sound)
    data["notes"] = notes
    (folder / "midi" / f"{stem}.json").write_text(json.dumps(data))
    return len(notes)


# ---------------------------------------------------------------- 다른 곳에서 만든 음표 가져오기
def clean_input(notes):
    """편집기 · 파일에서 온 음표를 (시작초, 끝초, MIDI 음, 세기[, 가사]) 목록으로 정리."""
    out = []
    for n in notes:
        s, e, v = float(n[0]), float(n[1]), float(n[3]) if len(n) > 3 and n[3] is not None else 0.8
        if not all(map(math.isfinite, (s, e, v, float(n[2])))):  # Infinity · NaN은 버린다
            continue
        p = int(round(float(n[2])))
        lyric = " ".join(n[4].split())[:32] if len(n) > 4 and isinstance(n[4], str) else ""  # 줄바꿈 없이 한 줄
        if e - s >= 0.01 and 0 <= p <= 127 and e > 0:
            out.append((round(max(0.0, s), 4), round(e, 4), p, float(np.clip(v, 0.05, 1.0)), *([lyric] if lyric else [])))
    return sorted(out)


def _midi_tracks(path):
    import pretty_midi

    pm = pretty_midi.PrettyMIDI(str(path))
    _, tempi = pm.get_tempo_changes()
    enc = _midi_text_encoding([ly.text for ly in pm.lyrics])
    lyrics = [(ly.time, _midi_text_in(ly.text, enc).strip()) for ly in pm.lyrics]
    lyrics = [(t, x) for t, x in lyrics if x]
    tracks = []
    for i, inst in enumerate(pm.instruments):
        if not inst.notes:
            continue
        name = inst.name.strip() or ("드럼" if inst.is_drum else pretty_midi.program_to_instrument_name(inst.program))
        notes = [[n.start, n.end, n.pitch, (n.velocity - 30) / 90] for n in sorted(inst.notes, key=lambda n: n.start)]
        if lyrics and not inst.is_drum:  # 가사는 파일 전체에 하나: 시작이 거의 같은 음표에 붙인다
            starts = np.array([n[0] for n in notes])
            for t, text in lyrics:
                k = int(np.argmin(np.abs(starts - t)))
                if abs(starts[k] - t) < 0.06 and len(notes[k]) == 4:
                    notes[k].append(text)
        tracks.append({"name": name or f"트랙 {i + 1}", "drum": bool(inst.is_drum), "notes": clean_input(notes)})
    return tracks, float(tempi[0]) if len(tempi) else 120.0


def _tick_to_sec(tempos):
    """[(틱, BPM)] 템포 지도 → 틱을 초로 바꾸는 함수."""
    tempos = sorted(tempos) or [(0, 120.0)]
    if tempos[0][0] > 0:
        tempos.insert(0, (0, tempos[0][1]))
    marks, sec = [], 0.0
    for i, (tick, bpm) in enumerate(tempos):
        if i:
            sec += (tick - tempos[i - 1][0]) / TICKS * 60 / tempos[i - 1][1]
        marks.append((tick, sec, bpm))

    def conv(tick):
        t0, s0, bpm = next(m for m in reversed(marks) if m[0] <= tick) if tick >= 0 else marks[0]
        return s0 + (tick - t0) / TICKS * 60 / bpm
    return conv


def _ustx_tracks(path):
    import yaml

    proj = yaml.safe_load(Path(path).read_text(encoding="utf-8-sig")) or {}
    tempos = [(int(t.get("position", 0)), float(t["bpm"])) for t in proj.get("tempos") or []] or [(0, float(proj.get("bpm", 120)))]
    conv = _tick_to_sec(tempos)
    names = [t.get("track_name") or f"트랙 {i + 1}" for i, t in enumerate(proj.get("tracks") or [])]
    by_track = {}
    for part in proj.get("voice_parts") or []:
        off = int(part.get("position", 0))
        for n in part.get("notes") or []:
            a = off + int(n["position"])
            by_track.setdefault(int(part.get("track_no", 0)), []).append(
                (conv(a), conv(a + int(n["duration"])), int(n["tone"]), 0.8, str(n.get("lyric") or "")))
    tracks = [{"name": names[k] if k < len(names) else f"트랙 {k + 1}", "drum": False, "notes": clean_input(v)}
              for k, v in sorted(by_track.items())]
    return tracks, tempos[0][1]


def _ust_tracks(path):
    raw = Path(path).read_bytes()
    text = raw.decode("utf-8") if b"Charset=UTF-8" in raw[:400] else raw.decode("shift_jis", errors="replace")
    sections, cur = [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[#"):
            cur = {"_": line}
            sections.append(cur)
        elif cur is not None and "=" in line:
            k, v = line.split("=", 1)
            cur[k] = v
    setting = next((s for s in sections if s["_"] == "[#SETTING]"), {})
    bpm = float(setting.get("Tempo", "120").replace(",", ".") or 120)
    first_bpm, tick, sec, notes = bpm, 0, 0.0, []
    for s in sections:
        if not s["_"][2:-1].isdigit():
            continue
        if s.get("Tempo"):
            bpm = float(s["Tempo"].replace(",", "."))
        length = int(float(s.get("Length", 0)))
        dur = length / TICKS * 60 / bpm
        lyric = s.get("Lyric", "R").strip()
        if lyric not in ("R", "r", "") and s.get("NoteNum"):
            notes.append((sec, sec + dur, int(s["NoteNum"]), 0.8, lyric))
        tick += length
        sec += dur
    return [{"name": setting.get("ProjectName") or Path(path).stem, "drum": False, "notes": clean_input(notes)}], first_bpm


def read_notes_file(path):
    """MIDI(.mid) · OpenUtau(.ustx) · UTAU(.ust) 파일 → {"tracks": [{name, drum, notes}], "tempo"}. 시작 = 곡 0초."""
    suffix = Path(path).suffix.lower()
    if suffix in (".mid", ".midi", ".smf", ".kar"):
        tracks, tempo = _midi_tracks(path)
    elif suffix == ".ustx":
        tracks, tempo = _ustx_tracks(path)
    elif suffix == ".ust":
        tracks, tempo = _ust_tracks(path)
    else:
        raise ValueError("MIDI(.mid), OpenUtau(.ustx), UTAU(.ust) 파일만 가져올 수 있어요")
    return {"tracks": [t for t in tracks if t["notes"]], "tempo": round(tempo, 3)}


# ---------------------------------------------------------------- OpenUtau / UTAU로 내보내기
TICKS = 480  # OpenUtau and UTAU both use 480 ticks per quarter note


def clean_notes(notes, tempo, quantize=False):
    """한 음씩 부르는 파트로 정리: 겹치는 음 자르기, 아주 짧은 음 합치기, (선택) 16분음표 격자에 맞추기."""
    notes = sorted(notes)
    out = []
    for s, e, p, v, *lyric in notes:
        if out and s < out[-1][1]:  # overlap: end the previous note here
            out[-1][1] = s
        if out and out[-1][1] - out[-1][0] < 0.06:
            out.pop()
        out.append([s, e, p, v, *lyric])
    out = [n for n in out if n[1] - n[0] >= 0.06]
    if quantize:
        step = 60 / tempo / 4
        q = []
        for s, e, p, v, *lyric in out:
            s2, e2 = round(s / step) * step, round(e / step) * step
            if e2 <= s2:
                e2 = s2 + step
            if q and s2 < q[-1][1]:
                s2 = q[-1][1]
            if e2 > s2:
                q.append([s2, e2, p, v, *lyric])
        out = q
    return [tuple(n) for n in out]


def to_ticks(sec, tempo):
    return int(round(sec * tempo / 60 * TICKS))


def find_openutau_singer(prefer=("テト", "Teto", "teto")):
    """이 Mac의 OpenUtau Singers 폴더에서 가수를 찾는다 (예: 重音テト). 없으면 (None, None).
    OpenUtau의 가수 id는 Singers 폴더 기준 상대 경로라서 폴더 이름을 그대로 쓴다."""
    root = Path.home() / "Library" / "OpenUtau" / "Singers"
    if not root.exists():
        return None, None
    found = [c.parent for c in root.rglob("character.txt") if c.parent.parent == root or c.parent == root]
    found.sort(key=lambda d: (not any(k in d.name for k in prefer), d.name))
    if not found:
        return None, None
    singer = found[0]
    phonemizer = "OpenUtau.Core.DefaultPhonemizer"
    cfg = singer / "character.yaml"
    if cfg.exists():
        import yaml
        try:
            phonemizer = (yaml.safe_load(cfg.read_text(encoding="utf-8-sig")) or {}).get("default_phonemizer") or phonemizer
        except Exception:
            pass
    return str(singer.relative_to(root)), phonemizer


def write_ustx(path, notes, tempo, name, waves, lyric="ら"):
    """OpenUtau 프로젝트 (ustx 0.6 형식; OpenUtau가 열 때 최신 형식으로 올려 준다).
    waves = [(트랙 이름, 파일 이름, 길이 ms, 음소거 여부)] — 반주 · 원래 보컬을 같이 넣어서 맞춰 가며 조율."""
    import yaml

    vnotes = []
    for n in notes:
        s, e, p, v = n[:4]
        a, b = to_ticks(s, tempo), to_ticks(e, tempo)
        if b <= a:
            continue
        vnotes.append({
            "position": a, "duration": b - a, "tone": int(p), "lyric": lyric_of(n) or lyric,
            "pitch": {"data": [{"x": -25, "y": 0, "shape": "io"}, {"x": 25, "y": 0, "shape": "io"}], "snap_first": True},
            "vibrato": {"length": 0, "period": 175, "depth": 25, "in": 10, "out": 10, "shift": 0, "drift": 0, "vol_link": 0},
            "phoneme_expressions": [], "phoneme_overrides": [],
        })
    end = max((n["position"] + n["duration"] for n in vnotes), default=TICKS * 4)
    singer, phonemizer = find_openutau_singer()
    tracks = [{"singer": singer or "", "phonemizer": phonemizer or "OpenUtau.Core.DefaultPhonemizer",
               "renderer_settings": {"renderer": "CLASSIC", "resampler": "worldline"},
               "track_name": name, "track_color": "Pink", "mute": False, "solo": False, "volume": 0, "pan": 0}]
    wave_parts = []
    for i, (track_name, file, ms, mute) in enumerate(waves, start=1):
        tracks.append({"singer": None, "phonemizer": None, "track_name": track_name, "track_color": "Blue",
                       "mute": mute, "solo": False, "volume": -6 if not mute else 0, "pan": 0})
        wave_parts.append({"name": track_name, "comment": "", "track_no": i, "position": 0,
                           "relative_path": file, "file_duration_ms": float(ms),
                           "skip": 0, "trim": 0, "fadein": 0, "fadeout": 0})
    project = {
        "name": name, "comment": "StemMixer에서 내보냄. 1마디 첫 박 = 곡 시작 (0초)",
        "output_dir": "Vocal", "cache_dir": "UCache", "ustx_version": "0.6",
        "key": 0,
        "time_signatures": [{"bar_position": 0, "beat_per_bar": 4, "beat_unit": 4}],
        "tempos": [{"position": 0, "bpm": float(round(tempo, 3))}],
        "tracks": tracks,
        "voice_parts": [{"name": name, "comment": "", "track_no": 0, "position": 0,
                         "duration": end + TICKS, "notes": vnotes, "curves": []}],
        "wave_parts": wave_parts,
    }
    Path(path).write_text(yaml.safe_dump(project, allow_unicode=True, sort_keys=False), encoding="utf-8")
    return len(vnotes)


_VOWELS = {v: row for row, chars in {
    "あ": "あかさたなはまやらわがざだばぱぁゃゎ", "い": "いきしちにひみりぎじぢびぴぃ",
    "う": "うくすつぬふむゆるぐずづぶぷぅゅゔ", "え": "えけせてねへめれげぜでべぺぇ",
    "お": "おこそとのほもよろをごぞどぼぽぉょ"}.items() for v in chars}


def _vowel(text):
    """늘여 부를 때 쓸 앞 음절의 모음: 가나면 あいうえお 중 하나, 아니면 앞 음절 그대로 (ん은 ん)."""
    last = text[-1:] if text else ""
    return "ん" if last == "ん" else _VOWELS.get(last, text or "ら")


def write_ust(path, notes, tempo, name, lyric="ら"):
    """UTAU용 .ust (쉼표는 R 음표로 채운다). Shift-JIS로 저장 (UTAU 기본).
    한글처럼 Shift-JIS에 없는 글자가 있으면 UTF-8로 (OpenUtau · 새 UTAU는 Charset=UTF-8을 읽는다)."""
    lines = ["[#VERSION]", "UST Version1.2", "[#SETTING]", f"Tempo={tempo:.2f}", "Tracks=1",
             f"ProjectName={name}", "VoiceDir=%VOICE%", "OutFile=", "CacheDir=", "Tool1=wavtool.exe",
             "Tool2=resampler.exe", "Mode2=True"]
    cursor, idx = 0, 0

    def note(length, lyric_, num):
        nonlocal idx
        lines.extend([f"[#{idx:04d}]", f"Length={length}", f"Lyric={lyric_}", f"NoteNum={num}",
                      "PreUtterance=", "Intensity=100", "Modulation=0"])
        idx += 1

    prev = lyric
    for n in notes:
        s, e, p, v = n[:4]
        a, b = to_ticks(s, tempo), to_ticks(e, tempo)
        if b <= a:
            continue
        if a > cursor:
            note(a - cursor, "R", 60)
        elif a < cursor:  # rounding overlap
            a = cursor
            if b <= a:
                continue
        text = lyric_of(n) or lyric
        if text.startswith("+"):  # OpenUtau의 "늘여 부르기"는 UTAU에 없다: 앞 음절의 모음으로 (か → あ)
            text = _vowel(prev)
        note(b - a, text, int(p))
        prev = text
        cursor = b
    lines.append("[#TRACKEND]")
    text = "\r\n".join(lines) + "\r\n"
    try:  # 가사가 전부 Shift-JIS에 있으면 예전처럼 (프로젝트 이름의 한글은 ?로)
        for n in notes:
            (lyric_of(n) or "").encode("shift_jis")
        data = text.encode("shift_jis", errors="replace")
    except UnicodeEncodeError:
        data = text.replace("UST Version1.2", "UST Version1.2\r\nCharset=UTF-8", 1).encode("utf-8")
    Path(path).write_bytes(data)
    return idx
