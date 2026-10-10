"""트랙의 음정을 읽어서 음표(MIDI)로 만들고, 깔끔한 소리로 다시 연주한다.

- 한 음씩 나오는 파트(보컬, 베이스): torchcrepe로 음 높이를 10ms마다 읽고 음표로 나눈다.
- 화음 파트(피아노, 기타, 나머지): Spotify basic-pitch (ONNX).
- 다시 연주는 내장 신스(피아노풍 · 신스 리드 · 사인 · 스트링)로 해서 사운드폰트가 필요 없다.
"""
import json
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 44100
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
def mono_notes(y, progress=lambda p: None, fmin=50.0, fmax=1100.0, decoder="argmax"):
    """f0를 읽어서 (시작초, 끝초, MIDI 음, 세기 0~1) 목록으로."""
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
    for s, e, p, _ in notes:
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
    for s, e, p, v in notes:
        if p % 12 not in sc:
            p = p - 1 if (p - 1) % 12 in sc else p + 1
        out.append((s, e, p, v))
    return out


def detect_tempo(mix):
    import librosa

    tempo, _ = librosa.beat.beat_track(y=mix.mean(axis=1)[: SR * 120], sr=SR)
    return float(np.atleast_1d(tempo)[0]) or 120.0


# ---------------------------------------------------------------- 저장 · 다시 연주
def write_midi(notes, path, tempo, sound):
    import pretty_midi

    pm = pretty_midi.PrettyMIDI(initial_tempo=tempo)
    inst = pretty_midi.Instrument(program=GM_PROGRAM.get(sound, 0))
    for s, e, p, v in notes:
        if 0 <= p <= 127:
            inst.notes.append(pretty_midi.Note(velocity=int(30 + 90 * v), pitch=p, start=s, end=e))
    pm.instruments.append(inst)
    pm.write(str(path))


def synth(notes, n_frames, sound="piano"):
    """내장 신스로 음표를 연주한 스테레오 float 배열."""
    out = np.zeros(n_frames, np.float32)
    for s, e, p, v in notes:
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


def transcribe(y, stem, progress=lambda p: None):
    if stem in MONO_STEMS:
        # CREPE covers about 32.7 Hz (C1) and up; asking for lower returns nothing.
        return mono_notes(y, progress, fmin=33 if stem == "bass" else 60, fmax=400 if stem == "bass" else 1100)
    return poly_notes(y, progress, bass=False)


def render(folder, stem, sound, transpose, snap, tempo=None):
    """저장해 둔 음표(raw)로 MIDI 파일과 다시 연주한 트랙을 만든다. 음 바꾸기는 다시 읽지 않고 여기서."""
    data = json.loads((folder / "midi" / f"{stem}.json").read_text())
    if tempo:
        data["tempo"] = float(tempo)
    notes = [tuple(n) for n in data["raw"]]
    tonic, mode = data["key"]
    if snap:
        notes = snap_to_key(notes, tonic, mode)
    notes = [(s, e, p + transpose, v) for s, e, p, v in notes]
    n_frames = sf.info(folder / f"{stem}.wav").frames
    sf.write(folder / f"{stem}_midi.wav", synth(notes, n_frames, sound), SR, subtype="PCM_24")
    write_midi(notes, folder / "midi" / f"{stem}.mid", data["tempo"], sound)
    data["notes"] = notes
    (folder / "midi" / f"{stem}.json").write_text(json.dumps(data))
    return len(notes)
