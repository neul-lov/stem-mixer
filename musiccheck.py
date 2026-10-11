"""넣은 링크가 노래인지 확인한다 (말하는 영상 · 방송 · 강의를 나누지 않게).

1. 영상 정보(받기 전): 라이브 방송, 20분이 넘는 영상은 노래 한 곡이 아니다.
   유튜브 '음악' 분류이거나 곡 정보(곡명 · 아티스트)가 있으면 노래로 본다.
   그렇지 않은데 10분이 넘으면 노래가 아니다 (배경음악만 깔린 브이로그는 소리로는 노래와 구별이 안 된다).
2. 소리(받은 뒤, 1에서 노래로 확인되지 않았을 때만): 곡 여기저기 10초씩 8곳을 PANNs(AudioSet으로 학습한
   소리 분류 모델, MIT)로 들어 보고 말소리 없이 음악이 나오는 곳이 절반이 안 되면 노래가 아니다.
   (배경음악에 말하는 영상은 음악 점수도 높아서 말소리 점수로 가른다. 노래 · 랩은 말소리 점수가 0.4를 넘지 않았다.)
"""
from pathlib import Path

import numpy as np

SR = 44100
MAX_MINUTES = 20
MAX_MINUTES_UNSURE = 10  # 음악 분류도 곡 정보도 없는 영상
CKPT_URL = "https://zenodo.org/record/3987831/files/Cnn14_mAP%3D0.431.pth?download=1"
LABELS_URL = "https://storage.googleapis.com/us_audioset/youtube_corpus/v1/csv/class_labels_indices.csv"


class NotSong(Exception):
    """노래가 아닌 것 같다 (사용자에게 그대로 보여 줄 이유)."""


# ---------------------------------------------------------------- 1. 영상 정보
def probe(url, ydl_opts):
    """받기 전에 영상 정보만 읽는다. 못 읽으면 None (그때는 소리로만 판단)."""
    import yt_dlp

    try:
        with yt_dlp.YoutubeDL({**ydl_opts, "skip_download": True}) as ydl:
            return ydl.extract_info(url, download=False)
    except Exception:
        return None


def check_info(info):
    """영상 정보로 판단: True = 노래가 확실함, False = 모름 (소리로 확인). 노래가 아니면 NotSong."""
    if not info:
        return False
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        raise NotSong("라이브 방송이라 나눌 수 없어요. 방송이 끝난 뒤 다시 넣어 주세요.")
    duration = info.get("duration") or 0
    if duration > MAX_MINUTES * 60:
        raise NotSong(f"{int(duration // 60)}분짜리 영상이라 노래 한 곡이 아닌 것 같아요.")
    categories = [c.lower() for c in info.get("categories") or []]
    if "music" in categories or info.get("track") or info.get("artist") or info.get("album"):
        return True
    if duration > MAX_MINUTES_UNSURE * 60:
        raise NotSong(f"{int(duration // 60)}분짜리 영상이라 노래 한 곡이 아닌 것 같아요.")
    return False


# ---------------------------------------------------------------- 2. 소리
def _model(step):
    import torch

    import transcribe as tr

    global _panns
    try:
        return _panns
    except NameError:
        pass
    tr._need(("panns_inference", "panns_inference"), ("torchlibrosa", "torchlibrosa"), ("matplotlib", "matplotlib"))
    # panns_inference는 불러올 때 라벨 파일을 wget으로 받으려 한다 (Mac에는 wget이 없다): 미리 받아 둔다
    labels = Path.home() / "panns_data" / "class_labels_indices.csv"
    if not labels.exists():
        tr._download(LABELS_URL, labels)
    ckpt = tr.MODEL_DIR / "panns" / "Cnn14_mAP=0.431.pth"
    if not ckpt.exists() or ckpt.stat().st_size < 3e8:
        step("노래인지 알아보는 AI 모델 받는 중 (처음 한 번, 330MB)")
        tr._download(CKPT_URL, ckpt)
    import os

    os.environ.setdefault("MPLBACKEND", "Agg")
    from panns_inference.config import lb_to_ix
    from panns_inference.models import Cnn14

    model = Cnn14(sample_rate=32000, window_size=1024, hop_size=320, mel_bins=64, fmin=50, fmax=14000, classes_num=527)
    model.load_state_dict(torch.load(ckpt, map_location="cpu", weights_only=True)["model"])
    model.eval()
    music = [lb_to_ix[k] for k in ("Music", "Singing", "Song", "Musical instrument") if k in lb_to_ix]
    _panns = (model, music, lb_to_ix["Speech"])
    return _panns


def listen(x, step=lambda text: None):
    """곡(스테레오 float, 44.1kHz)의 8곳을 10초씩 듣고 [(음악 점수, 말소리 점수)]."""
    import torch
    import torchaudio

    model, music, speech = _model(step)
    step("노래인지 확인하는 중")
    m = torch.from_numpy(x.mean(axis=1).astype(np.float32))[None]
    a = torchaudio.functional.resample(m, SR, 32000)[0].numpy()
    win = 32000 * 10
    if len(a) <= win:
        clips = [np.pad(a, (0, win - len(a)))]
    else:
        # 앞뒤 5%(인사 · 끝맺음)는 빼고 고르게 8곳
        lo, hi = int(len(a) * 0.05), max(int(len(a) * 0.95) - win, int(len(a) * 0.05) + 1)
        clips = [a[s:s + win] for s in np.linspace(lo, hi, 8).astype(int)]
    with torch.no_grad():
        out = model(torch.from_numpy(np.stack(clips)), None)["clipwise_output"].numpy()
    return [(float(o[music].max()), float(o[speech])) for o in out]


def check_audio(x, step=lambda text: None):
    """소리로 판단. 말소리 없이 음악이 나오는 곳이 절반이 안 되면 NotSong."""
    scores = listen(x, step)
    musical = sum(1 for mu, sp in scores if mu >= 0.3 and sp < 0.5)
    if musical * 2 < len(scores):
        talky = sum(1 for mu, sp in scores if sp >= 0.5)
        why = "대부분 말소리예요" if talky * 2 >= len(scores) else "음악이 거의 들리지 않아요"
        raise NotSong(f"노래가 아닌 영상 같아요 ({why}).")
    return scores
