"""노래 분리 믹서 서버.

유튜브 링크나 오디오 파일을 받아 보컬 / 베이스 / 드럼 / 기타 트랙으로 나누고,
브라우저 화면(static/index.html)에서 트랙별 음량을 조절할 수 있게 해 줍니다.
실행: python server.py  →  http://localhost:8000
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import threading
import time
import traceback
import urllib.request
import uuid
import webbrowser
from pathlib import Path

import imageio_ffmpeg
import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from scipy.signal import butter, sosfiltfilt

import audiofile

ROOT = Path(__file__).parent
LIBRARY = ROOT / "library"  # 분리된 곡이 쌓이는 곳 (곡마다 폴더 하나)
LIBRARY.mkdir(exist_ok=True)
SOURCES = LIBRARY / "_sources"  # 원본 오디오 (다른 방식으로 다시 분리할 때 다시 받지 않도록 보관)
SOURCES.mkdir(exist_ok=True)
FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()  # ffmpeg 따로 설치할 필요 없음
# audio-separator는 PATH에서 "ffmpeg"를 찾는다. 앱(Finder)으로 켜면 PATH가 짧아서 못 찾으니
# 같이 받은 ffmpeg를 .bin/ffmpeg로 연결해서 PATH 앞에 넣는다.
_BIN = ROOT / ".bin"
_BIN.mkdir(exist_ok=True)
_FF = _BIN / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
if _FF.is_symlink() and not _FF.exists():  # 가리키던 ffmpeg가 업데이트로 바뀌어 끊긴 링크
    _FF.unlink()
if not _FF.exists():
    try:
        _FF.symlink_to(FFMPEG)
    except OSError:  # Windows는 관리자 권한 없이는 링크를 못 만들어서 복사
        shutil.copyfile(FFMPEG, _FF)
os.environ["PATH"] = f"{_BIN}{os.pathsep}{os.environ.get('PATH', '')}"
SR = 44100
STEMS = ["vocals", "bass", "drums", "other"]
STEMS_6 = ["vocals", "bass", "drums", "guitar", "piano", "other"]  # ai6 모드 (기타·피아노 추가)
MODELS = {"ai": "htdemucs", "ai6": "htdemucs_6s"}  # 빠른 AI (Demucs만)
MODES = ("hq", "hq6", "max", "max6", "ai", "ai6", "eq")  # hq/hq6 = 고음질, max/max6 = 보컬 모델을 하나 더 섞은 최고 음질 (두 배 느림)

app = FastAPI()
LOCAL_HOSTS = {"127.0.0.1", "localhost", "[::1]"}


@app.middleware("http")
async def only_this_computer(request, call_next):
    """다른 웹사이트가 이 서버를 몰래 쓰지 못하게 막는다.
    - 주소(Host)가 이 컴퓨터가 아니면 거절: DNS rebinding으로 곡 목록을 읽거나 곡을 지우는 것 막기.
    - 브라우저가 보낸 요청(Origin)은 이 서버 화면에서 보낸 것만: 다른 사이트의 몰래 보내는 폼(CSRF) 막기.
    Mac 앱의 요청에는 Origin이 없어서 그대로 된다."""
    host = request.headers.get("host", "")
    name = host if host.endswith("]") else host.rsplit(":", 1)[0]
    origin = request.headers.get("origin")
    if name not in LOCAL_HOSTS or (origin is not None and origin != f"http://{host}"):
        return JSONResponse({"detail": "이 컴퓨터의 StemMixer에서 보낸 요청만 받아요"}, status_code=403)
    return await call_next(request)


jobs = {}  # job_id -> {"status", "step", "progress", "song_id", "error"}
work_lock = threading.Lock()  # 분리는 한 번에 한 곡씩 (메모리 보호)
_models = {}  # 모드 -> 불러온 Demucs 모델


# ---------------------------------------------------------------- 입력 받기
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")


# 유튜브는 자바스크립트 실행기가 있어야 잘 받아진다. 앱으로 켜면 PATH가 짧아서 직접 찾는다.
NODE = shutil.which("node") or next(
    (p for p in ("/opt/homebrew/bin/node", "/usr/local/bin/node") if Path(p).exists()), None)
YDL_BASE = {"quiet": True, "noplaylist": True, **({"js_runtimes": {"node": {"path": NODE}}} if NODE else {})}


class UserError(Exception):
    """사용자에게 그대로 보여 줄 메시지."""


def youtube_id(url):
    m = re.search(r"(?:v=|youtu\.be/|shorts/|embed/)([\w-]{11})", url)
    return m.group(1) if m else None


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "ko,en;q=0.8"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.read().decode("utf-8", "replace")


def spotify_track(url):
    """스포티파이 곡 링크 → (아티스트, 제목, 길이초). 음원은 DRM이라 정보만 가져온다."""
    m = re.search(r"open\.spotify\.com/(?:intl-\w+/)?(\w+)/(\w{22})", url)
    if not m:
        raise UserError("스포티파이 링크를 읽지 못했어요.")
    kind, tid = m.groups()
    if kind != "track":
        raise UserError("스포티파이는 곡 링크만 돼요 (앨범·플레이리스트 말고 곡 하나의 '공유 → 링크 복사').")
    try:
        html = _get(f"https://open.spotify.com/embed/track/{tid}")
        data = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S).group(1)
        e = json.loads(data)["props"]["pageProps"]["state"]["data"]["entity"]
        artist = ", ".join(a["name"] for a in e.get("artists", []))
        return artist, e.get("name") or e.get("title"), (e.get("duration") or 0) / 1000, f"sp-{tid}"
    except Exception:
        o = json.loads(_get(f"https://open.spotify.com/oembed?url=https://open.spotify.com/track/{tid}"))
        return "", o["title"], 0, f"sp-{tid}"


def apple_track(url):
    """애플뮤직 곡 링크 → (아티스트, 제목, 길이초). iTunes 검색 API 사용."""
    m = re.search(r"[?&]i=(\d+)", url) or re.search(r"/song/(?:[^/]+/)?(\d+)", url)
    if not m:
        raise UserError("애플뮤직은 곡 링크만 돼요 (곡 옆 ··· → 공유 → 링크 복사).")
    cc = re.search(r"music\.apple\.com/(\w\w)/", url)
    q = f"https://itunes.apple.com/lookup?id={m.group(1)}&country={cc.group(1) if cc else 'kr'}"
    res = [t for t in json.loads(_get(q)).get("results") or [] if t.get("kind") == "song"]
    if not res:
        raise UserError("애플뮤직에서 곡 정보를 찾지 못했어요.")
    t = res[0]
    return t["artistName"], t["trackName"], (t.get("trackTimeMillis") or 0) / 1000, f"am-{m.group(1)}"


def find_on_youtube(artist, title, duration, job):
    """제목·가수로 유튜브를 검색해서 길이가 가장 비슷한 영상을 고른다."""
    import yt_dlp

    job["step"] = f"유튜브에서 '{artist + ' - ' if artist else ''}{title}' 찾는 중"
    query = f"{artist} {title} audio".strip()
    with yt_dlp.YoutubeDL({**YDL_BASE, "extract_flat": True}) as ydl:
        entries = [e for e in (ydl.extract_info(f"ytsearch6:{query}", download=False).get("entries") or [])
                   if e.get("id")]
    if not entries:
        raise UserError("유튜브에서 이 곡을 찾지 못했어요.")
    if duration:
        close = [e for e in entries if e.get("duration") and abs(e["duration"] - duration) <= 8]
        best = close[0] if close else min(
            entries, key=lambda e: abs((e.get("duration") or 1e9) - duration))
    else:
        best = entries[0]
    return f"https://www.youtube.com/watch?v={best['id']}"


def resolve(text, job):
    """입력(링크나 검색어)을 → (yt-dlp로 받을 주소, 보여 줄 제목, 캐시 키, 출처, 원래 정보)."""
    low = text.lower()
    if "spotify.com" in low or "spotify.link" in low:
        if "spotify.link" in low:  # 짧은 링크는 펼친다
            text = urllib.request.urlopen(urllib.request.Request(text, headers={"User-Agent": UA}), timeout=15).url
        job["step"] = "스포티파이에서 곡 정보 읽는 중"
        artist, title, dur, key = spotify_track(text)
        return find_on_youtube(artist, title, dur, job), " - ".join(filter(None, [artist, title])), key, "spotify"
    if "music.apple.com" in low or "itunes.apple.com" in low:
        job["step"] = "애플뮤직에서 곡 정보 읽는 중"
        artist, title, dur, key = apple_track(text)
        return find_on_youtube(artist, title, dur, job), f"{artist} - {title}", key, "apple"
    if re.match(r"https?://", low):
        yid = youtube_id(text)
        if yid:
            return text, None, yid, "youtube"
        src = "soundcloud" if "soundcloud.com" in low else "web"
        return text, None, hashlib.sha1(text.encode()).hexdigest()[:11], src
    # 링크가 아니면 곡 제목으로 검색
    url = find_on_youtube("", text, 0, job)
    return url, None, youtube_id(url), "search"


def download(url, dest, job):
    import yt_dlp

    def hook(d):
        total = d.get("total_bytes") or d.get("total_bytes_estimate")
        if d.get("status") == "downloading" and total:
            job["progress"] = d["downloaded_bytes"] / total

    # YouTube blocks some player clients for some videos (HTTP 403, "format not available",
    # "page needs to be reloaded"). Try the default first, then other clients, until one works.
    clients = [None, "default,-web", "web_safari", "mweb", "tv", "android_vr", "ios"]
    last = None
    for i, client in enumerate(clients):
        for f in dest.glob("source.*"):
            f.unlink()
        opts = {
            **YDL_BASE,
            "format": "bestaudio/best",
            "outtmpl": str(dest / "source.%(ext)s"),
            "ffmpeg_location": FFMPEG,
            "progress_hooks": [hook],
        }
        if client:
            opts["extractor_args"] = {"youtube": {"player_client": client.split(",")}}
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url, download=True)
            src = next((f for f in dest.glob("source.*") if not f.name.endswith((".part", ".ytdl"))), None)
            if src and src.stat().st_size > 0:
                return src, info.get("title") or "제목 없음", info.get("webpage_url") or url
            last = RuntimeError("받은 파일이 비어 있어요")
        except yt_dlp.utils.DownloadError as e:
            last = e
            low = str(e).lower()
            retryable = ("403" in low or "forbidden" in low or "format is not available" in low
                         or "page needs to be reloaded" in low or "no video formats" in low)
            if not ("youtube" in url or "youtu.be" in url) or not retryable:
                raise
            if i + 1 < len(clients):
                job["step"] = f"유튜브가 막아서 다른 방법으로 다시 받는 중 ({i + 2}/{len(clients)})"
    raise last


def decode(path):
    """어떤 포맷이든 44.1kHz 스테레오 float 배열로."""
    # 유튜브 음원은 48kHz라 바꿔야 한다. 정밀한 리샘플러 설정으로 고음이 깎이지 않게.
    cmd = [FFMPEG, "-v", "error", "-i", str(path), "-af",
           f"aresample={SR}:filter_size=128:phase_shift=10:cutoff=0.99",
           "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"]
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)


# ---------------------------------------------------------------- 분리
DEVICE = None


def _device():
    global DEVICE
    if DEVICE is None:
        import torch
        DEVICE = "cuda" if torch.cuda.is_available() else (
            "mps" if torch.backends.mps.is_available() else "cpu")
    return DEVICE


def demucs_split(x, job, model_name, p0=0.0, p1=1.0, step="AI가 악기를 나누는 중"):
    """Demucs로 나누기. 진행률은 p0~p1 구간에 표시."""
    import torch
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    if model_name not in _models:
        job["step"] = "AI 모델 불러오는 중 (처음 한 번은 다운로드)"
        _models[model_name] = get_model(model_name)
        _models[model_name].eval()
    model = _models[model_name]
    job["step"] = step
    job["progress"] = p0
    wav = torch.from_numpy(x.T.copy()).float()
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    total = wav.shape[-1]
    # get_model gives a BagOfModels; htdemucs_ft runs four models one after another.
    inner = getattr(model, "models", [model])
    seg = int(float(getattr(model, "segment", None) or inner[0].segment) * SR)

    def cb(d):
        if d.get("state") == "end":
            done = (d.get("model_idx_in_bag", 0) + min(1, (d["segment_offset"] + seg) / total)) / len(inner)
            job["progress"] = p0 + (p1 - p0) * min(0.99, done)

    with torch.no_grad():
        out = apply_model(model, ((wav - mean) / std)[None], device=_device(),
                          split=True, overlap=0.25, callback=cb)[0]
    out = (out * std + mean).cpu().numpy()
    return {name: out[i].T for i, name in enumerate(model.sources)}


def separate_ai(x, job, mode="ai"):
    return demucs_split(x, job, MODELS[mode])


VOCAL_MODEL = "vocals_mel_band_roformer.ckpt"  # MelBand RoFormer (Kimberley Jensen)
MODEL_DIR = ROOT / "models"


_separators = {}  # 모델 파일 이름 -> 불러 둔 audio-separator


def run_separator(model_file, x, job, p0, p1, sec_per_sec, step, loading):
    """audio-separator 모델로 나누기 → {"vocals": …, "drums": …} (파일 이름의 (Stem)으로 구분).
    진행률 콜백이 없어서 곡 길이로 시간을 어림잡아 p0~p1 사이를 채운다."""
    import logging
    import re as _re
    import tempfile
    import time
    from audio_separator.separator import Separator

    tmp = Path(tempfile.mkdtemp(prefix="stem-", dir=LIBRARY))
    try:
        if model_file not in _separators:
            job["step"] = loading
            sep = Separator(output_dir=str(tmp), model_file_dir=str(MODEL_DIR),
                            log_level=logging.WARNING, output_format="WAV")
            sep.load_model(model_filename=model_file)
            _separators[model_file] = sep
        sep = _separators[model_file]
        sep.output_dir = str(tmp)
        if getattr(sep, "model_instance", None) is not None:
            sep.model_instance.output_dir = str(tmp)
        src = tmp / "in.wav"
        sf.write(src, x, SR, subtype="FLOAT")
        job["step"] = step
        expected, t0, stop = max(10.0, len(x) / SR * sec_per_sec), time.time(), threading.Event()

        def tick():
            while not stop.wait(0.5):
                job["progress"] = p0 + (p1 - p0) * min(0.95, (time.time() - t0) / expected)

        threading.Thread(target=tick, daemon=True).start()
        try:
            files = sep.separate(str(src))
        finally:
            stop.set()
        out = {}
        for f in files:
            path = Path(f) if Path(f).is_absolute() else tmp / f
            m = _re.search(r"\((\w+)\)", path.name)
            y, _ = sf.read(path, dtype="float32", always_2d=True)
            y = y[: len(x)]
            if len(y) < len(x):
                y = np.pad(y, ((0, len(x) - len(y)), (0, 0)))
            out[m.group(1).lower() if m else path.stem] = y
        job["progress"] = p1
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def roformer_vocals(x, job, p0, p1):
    """보컬만 MelBand RoFormer로 뽑는다."""
    out = run_separator(VOCAL_MODEL, x, job, p0, p1, 0.4, "보컬을 고음질로 뽑는 중",
                        "보컬 AI 모델 불러오는 중" if (MODEL_DIR / VOCAL_MODEL).exists()
                        else "보컬 AI 모델 받는 중 (처음 한 번만 약 900MB)")
    return out["vocals"]


SW_MODEL = "BS-Roformer-SW.ckpt"  # 6개 악기를 한 번에 (MVSEP 기본 모델)
BEST_VOCAL_MODEL = "bs_roformer_vocals_revive_v2_unwa.ckpt"  # 최고 음질: 보컬을 한 번 더 (unwa)


def separate_hq(x, job, six=False, best=False):
    """최고 품질 조합 (MUSDB18 테스트 12곡 평균 SDR 9.59, best=True면 9.82):
    1) BS-Roformer SW로 보컬 · 드럼 · 베이스 · 기타 · 피아노 · 나머지를 한 번에 나누고
    2) "나머지 악기"에 남은 목소리를 MelBand RoFormer로 한 번 더 뽑아 보컬로 옮기고
    3) (best) 보컬을 BS-Roformer revive v2 보컬과 섞고 (보컬 12.01 → 12.79, 시간은 두 배)
    4) 드럼 · 베이스는 SW와 htdemucs_ft를 섞는다 (드럼 10.45 → 10.57, 베이스 8.70 → 9.06).
    나머지는 원곡에서 다른 트랙을 뺀 소리라서 트랙을 모두 더하면 원곡 그대로다."""
    a = 0.45 if best else 0.55  # SW가 끝나는 진행률
    o = run_separator(SW_MODEL, x, job, 0.0, a, 0.85, "악기 6개로 나누는 중 (BS-Roformer SW)",
                      "분리 AI 모델 불러오는 중" if (MODEL_DIR / SW_MODEL).exists()
                      else "분리 AI 모델 받는 중 (처음 한 번만 약 700MB)")
    # SW가 놓친 목소리는 주로 나머지 악기에, 곡에 따라 기타에도 남는다 (실제 곡에서 기타 트랙의 18%가 목소리).
    # 그 트랙들에서 한 번 더 뽑아 보컬로 옮긴다. 4트랙은 셋을 합친 소리에서 한 번에.
    vocals = o["vocals"]
    b = a + (0.82 - a) * (0.5 if best else 1.0)  # 남은 목소리 뽑기가 끝나는 진행률
    if six:
        cleaned = {}
        for i, st in enumerate(("other", "guitar")):
            job["step"] = "남은 목소리를 한 번 더 뽑는 중"
            left = roformer_vocals(o[st], job, a + (b - a) * i / 2, a + (b - a) * (i + 1) / 2)
            vocals, cleaned[st] = vocals + left, o[st] - left
        guitar = cleaned["guitar"]
    else:
        job["step"] = "남은 목소리를 한 번 더 뽑는 중"
        vocals = vocals + roformer_vocals(o["other"] + o["guitar"] + o["piano"], job, a, b)
    if best:
        rv = run_separator(BEST_VOCAL_MODEL, x, job, b, 0.82, 1.5, "보컬을 한 번 더 뽑아 섞는 중",
                           "보컬 AI 모델 불러오는 중" if (MODEL_DIR / BEST_VOCAL_MODEL).exists()
                           else "보컬 AI 모델 받는 중 (처음 한 번만 약 700MB)")
        vocals = 0.4 * vocals + 0.6 * rv["vocals"]
    ft = demucs_split(x - vocals, job, "htdemucs_ft", 0.82, 1.0, "드럼 · 베이스를 다듬는 중")
    drums = 0.85 * o["drums"] + 0.15 * ft["drums"]
    bass = 0.35 * o["bass"] + 0.65 * ft["bass"]
    out = {"vocals": vocals, "drums": drums, "bass": bass}
    if six:
        out.update(guitar=guitar, piano=o["piano"])
    out["other"] = x - sum(out.values())
    return out


def _band(x, lo, hi):
    if lo and hi:
        sos = butter(6, [lo, hi], btype="bandpass", fs=SR, output="sos")
    elif lo:
        sos = butter(6, lo, btype="highpass", fs=SR, output="sos")
    else:
        sos = butter(6, hi, btype="lowpass", fs=SR, output="sos")
    return sosfiltfilt(sos, x, axis=0)


def separate_eq(x, job):
    """빠른 모드: 주파수 대역만으로 자름. 몇 초면 끝나지만 소리가 섞임."""
    job["step"] = "주파수 대역으로 나누는 중"
    mid = x.mean(axis=1, keepdims=True).repeat(2, axis=1)
    return {
        "vocals": _band(mid, 300, 3400),
        "bass": _band(x, 40, 250),
        "drums": _band(x, None, 100) + _band(x, 5000, None),
        "other": _band(x, 250, 6000),
    }


# ---------------------------------------------------------------- 작업 실행
def save_meta(folder, meta):
    """meta.json을 한 번에 바꾼다 (쓰는 도중에 다른 요청이 읽어도 반쯤 쓴 파일을 보지 않게)."""
    tmp = folder / f".meta-{uuid.uuid4().hex}.tmp"
    tmp.write_text(json.dumps(meta, ensure_ascii=False))
    os.replace(tmp, folder / "meta.json")


def kept_source(key):
    return next(iter(sorted(SOURCES.glob(f"{key}.*"))), None)


def mix_stems(folder, dest):
    """원본이 없을 때: 이미 나눈 트랙을 다시 합쳐서 원곡을 만든다 (AI 트랙은 합치면 거의 원곡)."""
    meta = json.loads((folder / "meta.json").read_text())
    total = sum(audiofile.read(folder, n) for n in meta["stems"])
    sf.write(dest, np.clip(total, -1, 1), SR, subtype="PCM_16")
    return dest


def run_job(job_id, mode, text=None, upload_path=None, title=None, resplit=None, force=False):
    import musiccheck

    job = jobs[job_id]
    try:
        with work_lock:
            source, matched, link = "file", None, None
            sure = True  # 노래가 확실한지 (아니면 받은 뒤 소리로 확인)
            redo = bool(resplit) and resplit.rsplit("-", 1)[1] == mode  # 같은 방식으로 다시 (새 품질 반영)
            if resplit:  # 라이브러리에 있는 곡을 다른 방식으로 다시 분리
                old = json.loads((LIBRARY / resplit / "meta.json").read_text())
                key = resplit.rsplit("-", 1)[0]
                title, source = old["title"], old.get("source") or "file"
                matched, link, text = old.get("matched"), old.get("link"), old.get("input")
            elif text:
                job["step"] = "링크 확인 중"
                url, title, key, source = resolve(text, job)
                # 곡 정보로 찾은 것(스포티파이 · 애플뮤직 · 검색)과 사운드클라우드는 노래로 본다.
                # 그 밖의 영상 링크는 받기 전에 정보를 보고, 모르면 받은 뒤 소리로 확인한다.
                if not force and source in ("youtube", "web") and not (LIBRARY / f"{key}-{mode}" / "meta.json").exists():
                    sure = musiccheck.check_info(musiccheck.probe(url, YDL_BASE))
            else:
                key = hashlib.sha1(upload_path.read_bytes()).hexdigest()[:11]
            song_id = f"{key}-{mode}"
            folder = LIBRARY / song_id
            if (folder / "meta.json").exists() and not redo:  # 이미 분리한 곡이면 바로 열기
                if upload_path:
                    upload_path.unlink(missing_ok=True)
                (folder / "meta.json").touch()
                job.update(status="done", song_id=song_id, progress=1.0)
                return
            folder.mkdir(parents=True, exist_ok=True)
            kept = kept_source(key)
            if resplit and kept:
                src = folder / ("source" + kept.suffix)
                shutil.copyfile(kept, src)
            elif resplit and not (link or (text and source != "file")):
                job.update(step="이미 나눈 트랙으로 원곡을 다시 만드는 중", progress=0.0)
                src = mix_stems(LIBRARY / resplit, folder / "source.wav")
            elif resplit:
                job.update(step="원본 오디오 다시 받는 중", progress=0.0)
                src, _, _ = download(link or text, folder, job)
            elif text and kept and force:  # "그래도 나누기": 노래인지 확인하느라 받아 둔 것을 다시 쓴다
                src = folder / ("source" + kept.suffix)
                shutil.copyfile(kept, src)
                link = url
                title = title or (musiccheck.probe(url, YDL_BASE) or {}).get("title") or "제목 없음"
            elif text:
                job.update(step="오디오 받는 중", progress=0.0)
                src, matched, link = download(url, folder, job)
                title = title or matched
                if source == "youtube" or source == "search":
                    matched = None  # 받은 영상 제목이 곧 곡 제목
            else:
                src = folder / ("source" + upload_path.suffix)
                shutil.move(upload_path, src)
            job.update(step="오디오 읽는 중", progress=0.0)
            x = decode(src)
            if text and not resplit and not force and not sure:
                try:
                    musiccheck.check_audio(x, lambda t: job.update(step=t))
                except musiccheck.NotSong:
                    if not kept_source(key):  # "그래도 나누기"를 누르면 다시 받지 않게
                        shutil.move(src, SOURCES / f"{key}{src.suffix.lower()}")
                    raise
                except Exception:  # 확인하는 모델을 못 받거나 못 돌리면 막지 않고 그냥 나눈다
                    traceback.print_exc()
            if mode in ("hq", "hq6", "max", "max6"):
                stems = separate_hq(x, job, six=mode.endswith("6"), best=mode.startswith("max"))
            elif mode in MODELS:
                stems = separate_ai(x, job, mode)
            else:
                stems = separate_eq(x, job)
            names = STEMS_6 if mode in ("ai6", "hq6", "max6") else STEMS
            job.update(step="저장 중", progress=0.99)
            peak = max(float(np.abs(s).max()) for s in stems.values())
            scale = 0.99 / peak if peak > 0.99 else 1.0
            for name in names:  # FLAC: 소리는 wav와 똑같고 크기는 60% 정도
                audiofile.write(folder, name, stems[name] * scale)
            shutil.rmtree(folder / "pitch", ignore_errors=True)  # 다시 나눴으면 음높이 선도 다시
            shutil.rmtree(folder / "lyrics", ignore_errors=True)  # 받아 적은 가사도
            if not kept_source(key):  # 다음에 다른 방식으로 나눌 때 쓰도록 원본 보관
                shutil.move(src, SOURCES / f"{key}{src.suffix.lower()}")
            src.unlink(missing_ok=True)
            meta = {"id": song_id, "title": title, "mode": mode, "duration": len(x) / SR,
                    "stems": names, "source": source, "matched": matched, "link": link,
                    "input": text}
            if redo:  # 내 녹음 · MIDI 트랙은 그대로 둔다 (나누는 동안 새로 만든 것까지: 지금 meta에서)
                try:
                    old = json.loads((folder / "meta.json").read_text())
                except (OSError, ValueError):
                    pass
                for k in ("replaced", "extras"):
                    if old.get(k):
                        meta[k] = old[k]
            save_meta(folder, meta)
            job.update(status="done", song_id=song_id, progress=1.0)
    except Exception as e:
        traceback.print_exc()
        msg = str(e).replace("ERROR: ", "").split("\n")[0]
        low = msg.lower()
        if isinstance(e, (UserError, musiccheck.NotSong)):
            pass
        elif "403" in low or "forbidden" in low:
            msg = "유튜브가 이 영상 다운로드를 막았어요 (403). 잠시 뒤 다시 시도하거나, 같은 곡의 다른 영상 링크를 넣어 주세요."
        elif "not a bot" in low or "page needs to be reloaded" in low:
            msg = "유튜브가 자동 다운로드로 의심해서 막았어요. 잠시 뒤 다시 시도해 주세요."
        elif "format is not available" in low or "no video formats" in low:
            msg = "이 영상에서 받을 수 있는 오디오를 찾지 못했어요. 다른 영상 링크를 넣어 주세요."
        elif "age" in low and ("confirm" in low or "restricted" in low):
            msg = "연령 제한이 있는 영상이라 받을 수 없어요."
        elif "live" in low and ("event" in low or "premiere" in low):
            msg = "아직 시작하지 않은 라이브·최초 공개 영상이에요."
        elif "drm" in low:
            msg = "DRM으로 보호된 음원이라 받을 수 없어요."
        elif "sign in" in low or "private" in low or "members-only" in low:
            msg = "이 영상은 로그인이 필요하거나 비공개라 받을 수 없어요."
        elif "unsupported url" in low or "not a valid url" in low or "incomplete youtube id" in low:
            msg = "지원하지 않는 링크예요. 유튜브·스포티파이·애플뮤직·사운드클라우드 링크나 곡 제목을 넣어 주세요."
        elif "unable to connect" in low or "unable to download" in low or "timed out" in low:
            msg = "인터넷에 연결하지 못했어요. 연결을 확인하고 다시 시도해 주세요."
        elif "unavailable" in low:
            msg = "볼 수 없는 영상이에요 (삭제됐거나 지역 제한)."
        elif "ffmpeg" in low or "invalid data" in low:
            msg = "오디오 파일을 읽지 못했어요. 다른 형식(mp3, wav)으로 시도해 주세요."
        job.update(status="error", error=msg, not_song=isinstance(e, musiccheck.NotSong))
        if "folder" in locals() and not (folder / "meta.json").exists():
            shutil.rmtree(folder, ignore_errors=True)


# ---------------------------------------------------------------- API
@app.post("/api/jobs")
async def create_job(mode: str = Form("ai"), url: str = Form(None), path: str = Form(None),
                     file: UploadFile = File(None), force: int = Form(0)):
    if mode not in MODES:
        raise HTTPException(400, "mode")
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "running", "step": "대기 중", "progress": 0.0}
    if url and url.strip():
        args = dict(text=url.strip(), force=bool(force))  # force: 노래가 아닌 것 같아도 나누기
    elif path:  # 같은 컴퓨터의 앱이 보내는 파일 경로
        p = Path(path).expanduser()
        if not p.is_file():
            raise HTTPException(400, "파일을 찾지 못했어요")
        tmp = LIBRARY / f"_upload_{job_id}{p.suffix.lower()}"
        shutil.copyfile(p, tmp)
        args = dict(upload_path=tmp, title=p.stem)
    elif file is not None:
        tmp = LIBRARY / f"_upload_{job_id}{Path(file.filename).suffix.lower()}"
        tmp.write_bytes(await file.read())
        args = dict(upload_path=tmp, title=Path(file.filename).stem)
    else:
        raise HTTPException(400, "링크나 파일을 넣어 주세요")
    threading.Thread(target=run_job, args=(job_id, mode), kwargs=args, daemon=True).start()
    return {"job_id": job_id}


@app.post("/api/songs/{song_id}/resplit")
def resplit_song(song_id: str, mode: str = Form(...)):
    if mode not in MODES or not (LIBRARY / song_id / "meta.json").exists():
        raise HTTPException(400, "다시 분리할 곡을 찾지 못했어요")
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "running", "step": "대기 중", "progress": 0.0}
    threading.Thread(target=run_job, args=(job_id, mode), kwargs=dict(resplit=song_id), daemon=True).start()
    return {"job_id": job_id}


@app.get("/api/jobs/{job_id}")
def job_status(job_id: str):
    if job_id not in jobs:
        raise HTTPException(404)
    return jobs[job_id]


@app.get("/api/songs")
def list_songs():
    metas = []
    for p in LIBRARY.glob("*/meta.json"):
        try:
            m = json.loads(p.read_text())
            m["size"] = folder_size(p.parent)
            m["created"] = p.stat().st_mtime
        except (OSError, ValueError):  # 망가진 곡 하나 때문에 목록 전체가 안 뜨지 않게
            traceback.print_exc()
            continue
        metas.append(m)
    metas.sort(key=lambda m: m["created"], reverse=True)
    return metas


# ---------------------------------------------------------------- 저장 공간
def folder_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def _size(f):
    try:
        return f.stat().st_size
    except OSError:
        return 0


def _leftovers():
    """지워도 되는 것: 버전이 하나도 안 남은 곡의 원본, 끝난 작업이 남긴 임시 파일."""
    busy = any(j.get("status") == "running" for j in jobs.values())
    keys = {p.parent.name.rsplit("-", 1)[0] for p in LIBRARY.glob("*/meta.json")}
    orphans = [f for f in SOURCES.iterdir() if f.is_file() and f.stem not in keys]
    temp = [] if busy else [d for d in LIBRARY.iterdir()
                            if d.name.startswith(("stem-", "_upload_")) or
                            (d.is_dir() and d.name not in ("_sources",) and not (d / "meta.json").exists())]
    if not busy:  # 꺼지는 바람에 곡 폴더 안에 남은 반쯤 쓴 파일 (.vocals-1a2b3c4d.tmp.flac 등)
        now = time.time()
        for meta in LIBRARY.glob("*/meta.json"):  # 곡 폴더만 (meta.json 없는 폴더는 위에서 통째로)
            for pat in (".*.tmp.flac", "user/.*.tmp.flac", "pitch/.*.tmp", "lyrics/.*.tmp"):
                for f in meta.parent.glob(pat):
                    try:
                        if now - f.stat().st_mtime > 600:
                            temp.append(f)
                    except OSError:
                        pass
    return orphans, temp, busy


@app.get("/api/storage")
def storage():
    orphans, temp, busy = _leftovers()
    songs = sum(folder_size(p.parent) for p in LIBRARY.glob("*/meta.json"))
    return {
        "songs": songs,
        "sources": folder_size(SOURCES),
        "leftovers": sum(f.stat().st_size for f in orphans) + sum(folder_size(d) if d.is_dir() else _size(d) for d in temp),
        "models": folder_size(MODEL_DIR) if MODEL_DIR.exists() else 0,
        "wav": sum(os.path.getsize(f) for f in _wav_tracks() if f.exists()),
        "busy": busy,
    }


@app.post("/api/cleanup")
def cleanup():
    """남은 원본 · 임시 파일만 지운다. 분리 중이면 임시 파일은 건드리지 않는다."""
    orphans, temp, busy = _leftovers()
    freed = 0
    for f in orphans:
        freed += f.stat().st_size
        f.unlink()
    for d in temp:
        freed += folder_size(d) if d.is_dir() else _size(d)
        shutil.rmtree(d, ignore_errors=True) if d.is_dir() else d.unlink(missing_ok=True)
    return {"freed": freed, "skipped_temp_because_busy": busy}


def _wav_tracks():
    """예전에 wav로 저장한 트랙 (FLAC으로 바꾸면 40% 가까이 줄어든다)."""
    out = []
    for p in LIBRARY.glob("*/meta.json"):
        try:
            stems = json.loads(p.read_text())["stems"]
        except (OSError, ValueError, KeyError):
            continue
        out += audiofile.convertible(p.parent, stems)
    return out


def run_compact(job_id):
    job = jobs[job_id]
    try:
        with work_lock:  # 분리 · 음정 뽑기와 겹치지 않게
            files = _wav_tracks()
            freed, done, skipped = 0, 0, 0
            for i, f in enumerate(files):
                job.update(step=f"FLAC으로 바꾸는 중 ({i + 1}/{len(files)})", progress=i / max(1, len(files)))
                try:
                    got = audiofile.to_flac(f)
                except Exception:
                    traceback.print_exc()
                    got = None
                if got is None:
                    skipped += 1
                else:
                    freed += got
                    done += 1
            job.update(status="done", progress=1.0, freed=freed, converted=done, skipped=skipped)
    except Exception as e:
        traceback.print_exc()
        job.update(status="error", error=f"바꾸지 못했어요: {e}")


@app.post("/api/compact")
def compact():
    """예전 wav 트랙을 소리 손실 없는 FLAC으로 바꿔서 공간을 줄인다 (샘플이 똑같은지 확인한 뒤에만 wav를 지운다)."""
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "running", "step": "대기 중", "progress": 0.0}
    threading.Thread(target=run_compact, args=(job_id,), daemon=True).start()
    return {"job_id": job_id}


@app.post("/api/songs/delete-many")
def delete_many(ids: str = Form(...)):
    """여러 곡 한 번에 지우기 (ids: 쉼표로 구분)."""
    freed, done = 0, []
    for sid in [i for i in ids.split(",") if i]:
        folder = (LIBRARY / sid).resolve()
        if folder.parent != LIBRARY.resolve() or not (folder / "meta.json").exists():
            continue
        freed += folder_size(folder)
        delete_song(sid)
        done.append(sid)
    return {"deleted": done, "freed": freed}


@app.get("/api/songs/{song_id}")
def song_meta(song_id: str):
    p = LIBRARY / song_id / "meta.json"
    if not p.exists():
        raise HTTPException(404)
    return json.loads(p.read_text())


@app.delete("/api/songs/{song_id}")
def delete_song(song_id: str):
    folder = song_folder(song_id)  # 곡 폴더만 (meta.json이 있는 곳). _sources 같은 폴더는 안 됨
    shutil.rmtree(folder)
    key = song_id.rsplit("-", 1)[0]
    if not any(LIBRARY.glob(f"{key}-*/meta.json")):  # 이 곡의 다른 버전이 없으면 원본도 지움
        for f in SOURCES.glob(f"{key}.*"):
            f.unlink()
    return {"ok": True}


@app.get("/api/songs/{song_id}/{stem}.wav")
def stem_file(song_id: str, stem: str, original: int = 0, wav: int = 0):
    """트랙 소리. 저장된 그대로(FLAC 또는 예전 wav) 보낸다. wav=1이면 wav로 풀어서 (다른 앱에 넣을 파일 받기)."""
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    user = (meta.get("replaced") or {}).get(stem)
    p = audiofile.path(folder / "user" if user and user.get("use") and not original else folder, stem)
    allowed = set(STEMS_6) | {x["id"] for x in meta.get("extras") or []}
    if stem not in allowed or not p.exists():
        raise HTTPException(404)
    if p.suffix == ".flac" and wav:
        info = sf.info(p)
        buf = io.BytesIO()
        with sf.SoundFile(p) as src, sf.SoundFile(buf, "w", info.samplerate, info.channels,
                                                  subtype=info.subtype, format="WAV") as dst:
            for block in src.blocks(SR * 30, dtype="int32", always_2d=True):
                dst.write(block)
        return Response(buf.getvalue(), media_type="audio/wav")
    return FileResponse(p, media_type="audio/flac" if p.suffix == ".flac" else "audio/wav")


# ---------------------------------------------------------------- 음정 뽑기 (MIDI)
MIDI_LABEL = {"vocals": "보컬 멜로디", "bass": "베이스 라인", "guitar": "기타", "piano": "피아노",
              "other": "나머지 악기", "drums": "드럼"}


def run_transcribe(job_id, song_id, stem, sound, snap):
    import transcribe as tr

    job = jobs[job_id]
    try:
        with work_lock:
            folder = song_folder(song_id)
            meta = json.loads((folder / "meta.json").read_text())
            mine = ((meta.get("replaced") or {}).get(stem) or {}).get("use")
            job.update(step="트랙 읽는 중", progress=0.0)
            y = audiofile.read(folder / "user" if mine else folder, stem)
            job["step"] = ("음 높이를 읽는 중" if stem in tr.MONO_STEMS else "화음을 읽는 중 (basic-pitch)")
            curve = []
            raw = tr.transcribe(y, stem, lambda p: job.update(progress=0.05 + 0.75 * p), curve=curve,
                                step=lambda text: job.update(step=text))
            if curve:  # 편집 화면의 음높이 선 (한 번 읽은 김에)
                save_pitch(folder, meta, stem, curve)
            job.update(step="조성과 빠르기 찾는 중", progress=0.85)
            mix = sum(audiofile.read(folder, n) for n in meta["stems"])
            tempo = tr.detect_tempo(mix)
            tonic, mode = tr.detect_key(raw)
            (folder / "midi").mkdir(exist_ok=True)
            (folder / "midi" / f"{stem}.json").write_text(json.dumps(
                {"raw": raw, "key": [tonic, mode], "tempo": tempo}))
            job.update(step="깔끔한 소리로 다시 연주하는 중", progress=0.92)
            count = tr.render(folder, stem, sound, 0, snap)
            meta = json.loads((folder / "meta.json").read_text())  # 읽는 동안 바뀐 것(녹음 · 다른 음표)을 지우지 않게
            extras = [x for x in meta.get("extras") or [] if x["id"] != f"{stem}_midi"]
            extras.append({"id": f"{stem}_midi", "source": stem, "label": f"{MIDI_LABEL.get(stem, stem)} (MIDI)",
                           "sound": sound, "snap": snap, "transpose": 0, "notes": count,
                           "key": tr.key_name(tonic, mode), "tempo": round(tempo)})
            meta["extras"] = extras
            save_meta(folder, meta)
            job.update(status="done", song_id=song_id, progress=1.0)
    except Exception as e:
        traceback.print_exc()
        job.update(status="error", error=f"음정을 뽑지 못했어요: {str(e).splitlines()[0] if str(e) else type(e).__name__}")


@app.post("/api/songs/{song_id}/transcribe")
def transcribe_stem(song_id: str, stem: str = Form(...), sound: str = Form("piano"), snap: int = Form(0)):
    import transcribe as tr

    meta = json.loads((song_folder(song_id) / "meta.json").read_text())
    if stem not in meta["stems"] or stem == "drums" or sound not in tr.SOUNDS:
        raise HTTPException(400, "이 트랙은 음정을 뽑을 수 없어요")
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "running", "step": "대기 중", "progress": 0.0}
    threading.Thread(target=run_transcribe, args=(job_id, song_id, stem, sound, bool(snap)), daemon=True).start()
    return {"job_id": job_id}


# ---------------------------------------------------------------- 원래 목소리의 음높이 선 (편집 화면 배경)
def pitch_source(meta, stem):
    """음높이 선이 어떤 소리에서 읽은 것인지: 원래 트랙, 또는 내 녹음(바꾸거나 싱크를 옮기면 다시 읽는다)."""
    user = (meta.get("replaced") or {}).get(stem) or {}
    if user.get("use"):
        return f"user:{user.get('id') or user.get('name')}:{round(user.get('base', 0) + user.get('nudge', 0), 4)}"
    return "stem"


def pitch_file(folder, meta, stem):
    # 원래 트랙과 내 녹음은 따로 둔다 (켜고 끌 때마다 다시 읽지 않게)
    return folder / "pitch" / (f"{stem}.json" if pitch_source(meta, stem) == "stem" else f"{stem}.user.json")


def save_pitch(folder, meta, stem, curve):
    (folder / "pitch").mkdir(exist_ok=True)
    tmp = folder / "pitch" / f".{stem}-{uuid.uuid4().hex[:8]}.tmp"
    tmp.write_text(json.dumps({"hop": 0.01, "source": pitch_source(meta, stem), "midi": curve}))
    os.replace(tmp, pitch_file(folder, meta, stem))


@app.get("/api/songs/{song_id}/pitch/{stem}")
def get_pitch(song_id: str, stem: str):
    """10ms마다 음 높이 (MIDI, 소리 없으면 null). 아직 안 읽었거나 트랙이 바뀌었으면 404."""
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    if stem not in meta["stems"]:
        raise HTTPException(404, "그 트랙이 없어요")
    p = pitch_file(folder, meta, stem)
    if not p.exists():
        raise HTTPException(404, "아직 음높이를 읽지 않았어요")
    d = json.loads(p.read_text())
    if d.get("source") != pitch_source(meta, stem):
        raise HTTPException(404, "트랙이 바뀌어서 다시 읽어야 해요")
    return {"hop": d["hop"], "midi": d["midi"]}


def run_pitch(job_id, song_id, stem):
    import transcribe as tr

    job = jobs[job_id]
    try:
        with work_lock:
            folder = song_folder(song_id)
            meta = json.loads((folder / "meta.json").read_text())
            p = pitch_file(folder, meta, stem)
            if p.exists() and json.loads(p.read_text()).get("source") == pitch_source(meta, stem):
                job.update(status="done", song_id=song_id, progress=1.0)  # 기다리는 사이에 다른 작업이 이미 읽었다
                return
            mine = ((meta.get("replaced") or {}).get(stem) or {}).get("use")
            job.update(step="음 높이를 읽는 중", progress=0.0)
            y = audiofile.read(folder / "user" if mine else folder, stem)
            curve = tr.pitch_curve(y, stem, lambda p: job.update(progress=0.95 * p))
            save_pitch(folder, meta, stem, curve)
            job.update(status="done", song_id=song_id, progress=1.0)
    except Exception as e:
        traceback.print_exc()
        job.update(status="error", error=f"음 높이를 읽지 못했어요: {str(e).splitlines()[0] if str(e) else type(e).__name__}")


@app.post("/api/songs/{song_id}/pitch/{stem}")
def start_pitch(song_id: str, stem: str):
    """음높이 선을 (다시) 읽는다. 보컬 · 베이스처럼 한 음씩 나오는 트랙만."""
    import transcribe as tr

    meta = json.loads((song_folder(song_id) / "meta.json").read_text())
    if stem not in meta["stems"] or stem not in tr.MONO_STEMS:
        raise HTTPException(400, "보컬 · 베이스 트랙만 음높이 선을 그릴 수 있어요")
    key = [song_id, stem, pitch_source(meta, stem)]
    for jid, j in list(jobs.items()):  # 같은 소리를 이미 읽는 중(또는 차례를 기다리는 중)이면 그 작업을 알려 준다
        if j.get("pitch") == key and j["status"] == "running":
            return {"job_id": jid}
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "running", "step": "대기 중", "progress": 0.0, "pitch": key}
    threading.Thread(target=run_pitch, args=(job_id, song_id, stem), daemon=True).start()
    return {"job_id": job_id}


# ---------------------------------------------------------------- 가사 받아 적기 (AI)
def run_lyrics(job_id, song_id, stem, notes, language):
    import lyrics as ly

    job = jobs[job_id]
    try:
        with work_lock:
            folder = song_folder(song_id)
            meta = json.loads((folder / "meta.json").read_text())
            source = pitch_source(meta, stem)
            cache = folder / "lyrics" / f"{stem}.json"
            saved = json.loads(cache.read_text()) if cache.exists() else {}
            # 같은 소리를 같은 언어 설정으로 이미 받아 적었으면 다시 듣지 않는다 (음표만 다시 맞춘다)
            if saved.get("source") == source and saved.get("asked") == language:
                lang, words = saved["language"], [tuple(w) for w in saved["words"]]
            else:
                mine = ((meta.get("replaced") or {}).get(stem) or {}).get("use")
                job.update(step="트랙 읽는 중", progress=0.0)
                y = audiofile.read(folder / "user" if mine else folder, stem)
                lang, words = ly.words(y, ly.LANGUAGES.get(language), lambda p: job.update(progress=0.9 * p),
                                       lambda text: job.update(step=text))
                cache.parent.mkdir(exist_ok=True)
                tmp = cache.with_name(f".{stem}-{uuid.uuid4().hex[:8]}.tmp")
                tmp.write_text(json.dumps({"source": source, "asked": language, "language": lang,
                                           "words": [[round(a, 3), round(b, 3), t] for a, b, t in words]},
                                          ensure_ascii=False))
                os.replace(tmp, cache)
            job.update(step="음표에 가사 붙이는 중", progress=0.95)
            fitted, placed, dropped = ly.fit(notes, words, lang)
            job["result"] = {"notes": fitted, "language": lang, "placed": placed, "dropped": dropped,
                             "text": " ".join(t for _, _, t in words)[:4000]}
            job.update(status="done", song_id=song_id, progress=1.0)
    except Exception as e:
        traceback.print_exc()
        job.update(status="error", error=f"가사를 받아 적지 못했어요: {str(e).splitlines()[0] if str(e) else type(e).__name__}")


@app.post("/api/songs/{song_id}/lyrics/{stem}")
def start_lyrics(song_id: str, stem: str, notes: str = Form(...), language: str = Form("auto")):
    """노래를 듣고 가사를 받아 적어서, 보낸 음표(편집 중인 음표)에 한 음절씩 붙여 돌려준다. 저장은 하지 않는다."""
    import lyrics as ly
    import transcribe as tr

    meta = json.loads((song_folder(song_id) / "meta.json").read_text())
    if stem not in meta["stems"] or stem == "drums":
        raise HTTPException(400, "이 트랙은 가사를 받아 적을 수 없어요")
    if language not in ly.LANGUAGES:
        raise HTTPException(400, "모르는 언어예요")
    try:
        clean = tr.clean_input(json.loads(notes))
    except Exception:
        raise HTTPException(400, "음표를 읽지 못했어요")
    if not clean:
        raise HTTPException(400, "가사를 붙일 음표가 없어요. 먼저 음정을 뽑아 주세요")
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "running", "step": "대기 중", "progress": 0.0}
    threading.Thread(target=run_lyrics, args=(job_id, song_id, stem, clean, language), daemon=True).start()
    return {"job_id": job_id}


@app.post("/api/songs/{song_id}/midi/{stem}")
def rerender_midi(song_id: str, stem: str, sound: str = Form(None), transpose: int = Form(None), snap: int = Form(None),
                  tempo: float = Form(None)):
    """소리 · 조옮김 · 키 맞추기만 바꿔서 다시 연주 (음정을 다시 읽지 않아 빠름)."""
    import transcribe as tr

    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    extra = next((x for x in meta.get("extras") or [] if x["source"] == stem), None)
    if not extra:
        raise HTTPException(404, "먼저 음정을 뽑아 주세요")
    if sound in tr.SOUNDS:
        extra["sound"] = sound
    if transpose is not None:
        extra["transpose"] = max(-24, min(24, transpose))
    if snap is not None:
        extra["snap"] = bool(snap)
    if tempo:
        extra["tempo"] = round(max(30.0, min(300.0, tempo)), 1)
    extra["notes"] = tr.render(folder, stem, extra["sound"], extra["transpose"], extra["snap"], extra.get("tempo"))
    save_meta(folder, meta)
    return meta


@app.post("/api/songs/{song_id}/utau-export")
def utau_export(song_id: str, stem: str = Form("vocals"), dest: str = Form(...), quantize: int = Form(0)):
    """뽑은 멜로디를 OpenUtau(.ustx) · UTAU(.ust) 프로젝트로. 반주(이 트랙만 뺀 소리)와 원래 트랙도 같이 넣어서
    그 위에서 조율할 수 있게. 프로젝트 시작(0틱) = 곡 시작(0초)이라 렌더한 wav를 그대로 넣으면 맞는다."""
    import transcribe as tr

    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    extra = next((x for x in meta.get("extras") or [] if x["source"] == stem), None)
    if not extra:
        raise HTTPException(400, "먼저 이 트랙의 음정을 뽑아 주세요")
    data = json.loads((folder / "midi" / f"{stem}.json").read_text())
    tempo = float(extra.get("tempo") or data["tempo"])
    notes = tr.clean_notes(data.get("notes", data["raw"]), tempo, bool(quantize))
    label = MIDI_LABEL.get(stem, stem)
    safe = re.sub(r'[/:\\]', "-", meta["title"])[:80]
    out = Path(dest).expanduser() / f"{safe} - {label} (OpenUtau)"
    out.mkdir(parents=True, exist_ok=True)
    replaced = meta.get("replaced") or {}

    def active(n):
        return audiofile.read(folder / "user" if (replaced.get(n) or {}).get("use") else folder, n)

    rest = [n for n in meta["stems"] if n != stem]
    backing = sum(active(n) for n in rest)
    peak = float(np.abs(backing).max())
    sf.write(out / "backing.wav", backing / peak * 0.95 if peak > 0.95 else backing, SR, subtype="PCM_16")
    guide = active(stem)
    sf.write(out / f"guide_{stem}.wav", guide, SR, subtype="PCM_16")
    ms = len(backing) / SR * 1000
    n = tr.write_ustx(out / "project.ustx", notes, tempo, f"{label}",
                      [("반주 (이 파트 뺀 소리)", "backing.wav", ms, False), (f"원래 {label} (참고용)", f"guide_{stem}.wav", ms, True)])
    tr.write_ust(out / "project.ust", notes, tempo, label)
    shutil.copyfile(folder / "midi" / f"{stem}.mid", out / "melody.mid")
    (out / "읽어 주세요.txt").write_text(
        f"{meta['title']} · {label}\n\n"
        f"- project.ustx: OpenUtau로 열기. 첫 트랙에 원하는 가수(예: 重音テト)를 고르고 조율하세요.\n"
        f"  '반주' 트랙이 같이 들어 있어요. '원래 {label}' 트랙은 음소거돼 있으니 참고할 때 켜세요.\n"
        f"- project.ust: UTAU용 (같은 음표). melody.mid: 다른 보컬 신스용.\n"
        f"- 빠르기 {tempo:g} BPM, 1마디 첫 박 = 곡 시작(0초). 음표 {n}개. 편집 화면에서 넣은 가사가 들어 있고, 가사 없는 음표는 'ら'.\n"
        f"  가사 '+'는 앞 음절을 늘여 부르기(OpenUtau). UTAU용 .ust에서는 앞 음절의 모음으로 바꿔 두었어요.\n"
        f"- 다 되면 OpenUtau에서 보컬 트랙을 wav로 내보내고(처음부터), StemMixer의 {label} 트랙에 끌어다 놓으세요.\n"
        f"  0초부터 시작하는 wav면 싱크가 그대로 맞아요.\n", encoding="utf-8")
    return {"folder": str(out), "notes": n, "tempo": tempo}


@app.get("/api/songs/{song_id}/midi/{stem}.json")
def midi_notes(song_id: str, stem: str):
    p = song_folder(song_id) / "midi" / f"{stem}.json"
    if not p.exists():
        raise HTTPException(404)
    d = json.loads(p.read_text())
    return {"notes": d.get("notes", d["raw"]), "tempo": d["tempo"], "edited": "edited" in d,
            "ai": d["raw"] if "edited" in d and not d.get("imported") else None, "from": d.get("from")}


# ---------------------------------------------------------------- 음표 편집 · 가져오기
@app.post("/api/notes-file")
def notes_file(path: str = Form(...)):
    """MIDI · OpenUtau · UTAU 파일의 음표를 읽기만 한다 (편집기에 불러온 뒤 '적용'해야 저장)."""
    import transcribe as tr

    f = Path(path).expanduser()
    if not f.is_file():
        raise HTTPException(400, "파일을 찾지 못했어요")
    try:
        out = tr.read_notes_file(f)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(400, f"이 파일을 읽지 못했어요 ({type(e).__name__})")
    if not out["tracks"]:
        raise HTTPException(400, "이 파일에는 음표가 없어요")
    return {**out, "name": f.name}


@app.get("/api/songs/{song_id}/tempo")
def song_tempo(song_id: str):
    """곡 빠르기 (음정을 아직 안 뽑은 트랙에 빈 악보로 시작할 때 박자선용). 한 번 재면 meta에 기억."""
    import transcribe as tr

    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    if not meta.get("tempo"):
        mix = sum(audiofile.read(folder, n) for n in meta["stems"])
        meta["tempo"] = round(tr.detect_tempo(mix), 2)
        save_meta(folder, meta)
    return {"tempo": meta["tempo"]}


@app.post("/api/songs/{song_id}/midi/{stem}/notes")
def save_notes(song_id: str, stem: str, notes: str = Form(...), tempo: float = Form(None),
               sound: str = Form(None), origin: str = Form(None)):
    """편집기에서 고친 음표를 저장하고 음정 트랙을 다시 연주. 음정 트랙이 없으면 새로 만든다 (빈 악보 · 가져온 파일).
    보이는 그대로 들리도록 조옮김 · 키 맞추기는 음표에 이미 들어 있는 것으로 보고 0으로 돌린다."""
    import transcribe as tr

    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    if stem not in meta["stems"]:
        raise HTTPException(400, "그 트랙이 없어요")
    try:
        clean = tr.clean_input(json.loads(notes))
    except Exception:
        raise HTTPException(400, "음표를 읽지 못했어요")
    (folder / "midi").mkdir(exist_ok=True)
    p = folder / "midi" / f"{stem}.json"
    data = json.loads(p.read_text()) if p.exists() else None
    if data is None:  # AI로 뽑은 적 없는 트랙: 이 음표가 곧 원본
        if not tempo and not meta.get("tempo"):
            mix = sum(audiofile.read(folder, n) for n in meta["stems"])
            meta["tempo"] = round(tr.detect_tempo(mix), 2)
        data = {"raw": clean, "imported": True, "tempo": float(tempo or meta["tempo"])}
    elif tempo:
        data["tempo"] = float(tempo)
    data["edited"] = clean
    if origin:
        data["from"] = origin
    tonic, mode = tr.detect_key(clean) if clean else data.get("key", (0, "major"))
    data["key"] = [tonic, mode]
    p.write_text(json.dumps(data))
    extras = meta.get("extras") or []
    extra = next((x for x in extras if x["source"] == stem), None)
    if not extra:
        extra = {"id": f"{stem}_midi", "source": stem, "sound": "piano",
                 "label": f"{MIDI_LABEL.get(stem, stem)} ({'가져옴' if origin else '내 음표'})"}
        extras.append(extra)
    if sound in tr.SOUNDS:
        extra["sound"] = sound
    extra.update(transpose=0, snap=False, edited=True, key=tr.key_name(tonic, mode), tempo=round(data["tempo"], 1))
    extra["notes"] = tr.render(folder, stem, extra["sound"], 0, False)
    meta["extras"] = extras
    save_meta(folder, meta)
    return meta


@app.post("/api/songs/{song_id}/midi/{stem}/reset")
def reset_notes(song_id: str, stem: str):
    """고친 음표를 버리고 AI가 뽑은 (또는 처음 가져온) 음표로 되돌린다."""
    import transcribe as tr

    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    extra = next((x for x in meta.get("extras") or [] if x["source"] == stem), None)
    p = folder / "midi" / f"{stem}.json"
    if not extra or not p.exists():
        raise HTTPException(404, "음정 트랙이 없어요")
    data = json.loads(p.read_text())
    data.pop("edited", None)
    tonic, mode = tr.detect_key(data["raw"])
    data["key"] = [tonic, mode]
    p.write_text(json.dumps(data))
    extra.update(transpose=0, snap=False, edited=False, key=tr.key_name(tonic, mode))
    extra["notes"] = tr.render(folder, stem, extra["sound"], 0, False)
    save_meta(folder, meta)
    return meta


@app.delete("/api/songs/{song_id}/midi/{stem}")
def delete_midi(song_id: str, stem: str):
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    if stem not in meta["stems"]:  # "*" 같은 이름으로 다른 파일까지 지우지 않게
        raise HTTPException(400, "그 트랙이 없어요")
    meta["extras"] = [x for x in meta.get("extras") or [] if x["source"] != stem]
    audiofile.remove(folder, f"{stem}_midi")
    for f in (folder / "midi").glob(f"{stem}.*") if (folder / "midi").exists() else []:
        f.unlink(missing_ok=True)
    save_meta(folder, meta)
    return meta


# ---------------------------------------------------------------- 내 트랙으로 바꾸기
def song_folder(song_id):
    folder = (LIBRARY / song_id).resolve()
    if folder.parent != LIBRARY.resolve() or not (folder / "meta.json").exists():
        raise HTTPException(404, "곡을 찾지 못했어요")
    return folder


def render_user_track(folder, stem, offset):
    """보관한 내 파일을 곡과 같은 형식·길이로 바꾼다. offset(초)만큼 늦게 (음수면 앞을 잘라) 시작."""
    src = next((folder / "user").glob(f"{stem}.src.*"))
    y = decode(src)
    n = audiofile.frames(folder, stem)
    shift = int(round(offset * SR))
    y = np.concatenate([np.zeros((shift, 2), np.float32), y]) if shift > 0 else y[-shift:]
    y = y[:n] if len(y) >= n else np.concatenate([y, np.zeros((n - len(y), 2), np.float32)])
    audiofile.write(folder / "user", stem, np.clip(y, -1, 1))


@app.post("/api/songs/{song_id}/user-track")
def set_user_track(song_id: str, stem: str = Form(...), path: str = Form(None), name: str = Form(None),
                   base: float = Form(None), nudge: float = Form(None), use: int = Form(None)):
    """트랙을 내 파일(또는 앱에서 녹음한 것)로 바꾸거나, 싱크(nudge)·사용 여부를 바꾼다.
    base = 녹음이 곡의 몇 초에서 시작하는지 (파일은 보통 0), nudge = 손으로 맞춘 미세 조정(초)."""
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    if stem not in meta["stems"]:
        raise HTTPException(400, "그 트랙이 없어요")
    replaced = meta.get("replaced") or {}
    cur = replaced.get(stem) or {"name": None, "base": 0.0, "nudge": 0.0, "use": True}
    if path:
        f = Path(path).expanduser()
        if not f.is_file():
            raise HTTPException(400, "파일을 찾지 못했어요")
        (folder / "user").mkdir(exist_ok=True)
        for old in (folder / "user").glob(f"{stem}.src.*"):
            old.unlink()
        shutil.copyfile(f, folder / "user" / f"{stem}.src{f.suffix.lower() or '.wav'}")
        # id: 같은 이름의 파일을 다시 넣어도 새 소리로 알아보게 (음높이 선 다시 읽기)
        cur = {"name": name or f.stem, "base": 0.0, "nudge": 0.0, "use": True, "id": uuid.uuid4().hex[:8]}
        (folder / "pitch" / f"{stem}.user.json").unlink(missing_ok=True)
    elif stem not in replaced:
        raise HTTPException(400, "먼저 파일을 넣어 주세요")
    if base is not None:
        cur["base"] = base
    if nudge is not None:
        cur["nudge"] = max(-2.0, min(2.0, nudge))
    if use is not None:
        cur["use"] = bool(use)
    try:
        if path or base is not None or nudge is not None:
            render_user_track(folder, stem, cur["base"] + cur["nudge"])
    except subprocess.CalledProcessError:
        raise HTTPException(400, "오디오 파일을 읽지 못했어요. wav, mp3, m4a, aiff 파일을 넣어 주세요.")
    replaced[stem] = cur
    meta["replaced"] = replaced
    save_meta(folder, meta)
    return meta


@app.delete("/api/songs/{song_id}/user-track/{stem}")
def remove_user_track(song_id: str, stem: str):
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    if stem not in meta["stems"]:
        raise HTTPException(400, "그 트랙이 없어요")
    (meta.get("replaced") or {}).pop(stem, None)
    for f in (folder / "user").glob(f"{stem}.*") if (folder / "user").exists() else []:
        f.unlink()
    (folder / "pitch" / f"{stem}.user.json").unlink(missing_ok=True)
    save_meta(folder, meta)
    return meta


app.mount("/", StaticFiles(directory=ROOT / "static", html=True), name="static")

if __name__ == "__main__":
    import argparse
    import uvicorn

    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()
    if not a.no_browser:
        threading.Timer(1.5, lambda: webbrowser.open(f"http://localhost:{a.port}")).start()
    uvicorn.run(app, host="127.0.0.1", port=a.port, log_level="warning")
