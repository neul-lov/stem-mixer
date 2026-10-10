"""노래 분리 믹서 서버.

유튜브 링크나 오디오 파일을 받아 보컬 / 베이스 / 드럼 / 기타 트랙으로 나누고,
브라우저 화면(static/index.html)에서 트랙별 음량을 조절할 수 있게 해 줍니다.
실행: python server.py  →  http://localhost:8000
"""
import hashlib
import json
import re
import shutil
import subprocess
import threading
import traceback
import urllib.request
import uuid
import webbrowser
from pathlib import Path

import imageio_ffmpeg
import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from scipy.signal import butter, sosfiltfilt

ROOT = Path(__file__).parent
LIBRARY = ROOT / "library"  # 분리된 곡이 쌓이는 곳 (곡마다 폴더 하나)
LIBRARY.mkdir(exist_ok=True)
SOURCES = LIBRARY / "_sources"  # 원본 오디오 (다른 방식으로 다시 분리할 때 다시 받지 않도록 보관)
SOURCES.mkdir(exist_ok=True)
FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()  # ffmpeg 따로 설치할 필요 없음
SR = 44100
STEMS = ["vocals", "bass", "drums", "other"]
STEMS_6 = ["vocals", "bass", "drums", "guitar", "piano", "other"]  # ai6 모드 (기타·피아노 추가)
MODELS = {"ai": "htdemucs", "ai6": "htdemucs_6s"}  # 빠른 AI (Demucs만)
MODES = ("hq", "hq6", "ai", "ai6", "eq")  # hq/hq6 = 최고 품질 (RoFormer 보컬 + Demucs)

app = FastAPI()
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

    opts = {
        **YDL_BASE,
        "format": "bestaudio/best",
        "outtmpl": str(dest / "source.%(ext)s"),
        "ffmpeg_location": FFMPEG,
        "progress_hooks": [hook],
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=True)
    src = next(dest.glob("source.*"))
    return src, info.get("title") or "제목 없음", info.get("webpage_url") or url


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
_vocal_sep = None


def roformer_vocals(x, job, p0, p1):
    """보컬만 RoFormer로 뽑는다. 보컬 품질이 Demucs보다 훨씬 좋다 (덜 먹먹함)."""
    global _vocal_sep
    import logging
    import tempfile
    import time
    from audio_separator.separator import Separator

    tmp = Path(tempfile.mkdtemp(prefix="stem-", dir=LIBRARY))
    try:
        if _vocal_sep is None:
            job["step"] = ("보컬 AI 모델 불러오는 중" if (MODEL_DIR / VOCAL_MODEL).exists()
                           else "보컬 AI 모델 받는 중 (처음 한 번만 약 900MB)")
            _vocal_sep = Separator(output_dir=str(tmp), model_file_dir=str(MODEL_DIR),
                                   log_level=logging.WARNING, output_format="WAV")
            _vocal_sep.load_model(model_filename=VOCAL_MODEL)
        sep = _vocal_sep
        sep.output_dir = str(tmp)
        if getattr(sep, "model_instance", None) is not None:
            sep.model_instance.output_dir = str(tmp)
        src = tmp / "in.wav"
        sf.write(src, x, SR, subtype="FLOAT")
        job["step"] = "보컬을 고음질로 뽑는 중"
        # The separator has no progress callback; estimate from the song length (about 0.4 s per second).
        expected, t0, stop = max(10.0, len(x) / SR * 0.4), time.time(), threading.Event()

        def tick():
            while not stop.wait(0.5):
                job["progress"] = p0 + (p1 - p0) * min(0.95, (time.time() - t0) / expected)

        threading.Thread(target=tick, daemon=True).start()
        try:
            files = sep.separate(str(src))
        finally:
            stop.set()
        path = next(f for f in files if "(vocals)" in f.lower())
        path = path if Path(path).is_absolute() else tmp / path
        vocals, _ = sf.read(path, dtype="float32", always_2d=True)
        vocals = vocals[: len(x)]
        if len(vocals) < len(x):
            vocals = np.pad(vocals, ((0, len(x) - len(vocals)), (0, 0)))
        job["progress"] = p1
        return vocals
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def separate_hq(x, job, six=False):
    """최고 품질: 보컬은 RoFormer, 반주(원곡 - 보컬)는 모델마다 잘하는 악기만 가져온다.
    MUSDB18 테스트로 잰 결과 드럼은 htdemucs_6s, 베이스는 htdemucs_ft가 가장 좋았다.
    나머지 악기 = 반주 - (가져온 악기들) 이라서 트랙을 다 더하면 원곡과 같다."""
    vocals = roformer_vocals(x, job, 0.0, 0.5)
    inst = x - vocals
    ft = demucs_split(inst, job, "htdemucs_ft", 0.5, 0.85, "베이스를 나누는 중")
    s6 = demucs_split(inst, job, "htdemucs_6s", 0.85, 1.0, "드럼 · 기타 · 피아노를 나누는 중")
    out = {"vocals": vocals, "drums": s6["drums"], "bass": ft["bass"]}
    if six:
        out["guitar"], out["piano"] = s6["guitar"], s6["piano"]
    out["other"] = inst - sum(out[k] for k in out if k != "vocals")
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
def kept_source(key):
    return next(iter(sorted(SOURCES.glob(f"{key}.*"))), None)


def mix_stems(folder, dest):
    """원본이 없을 때: 이미 나눈 트랙을 다시 합쳐서 원곡을 만든다 (AI 트랙은 합치면 거의 원곡)."""
    meta = json.loads((folder / "meta.json").read_text())
    total = sum(sf.read(folder / f"{n}.wav", dtype="float32")[0] for n in meta["stems"])
    sf.write(dest, np.clip(total, -1, 1), SR, subtype="PCM_16")
    return dest


def run_job(job_id, mode, text=None, upload_path=None, title=None, resplit=None):
    job = jobs[job_id]
    try:
        with work_lock:
            source, matched, link = "file", None, None
            if resplit:  # 라이브러리에 있는 곡을 다른 방식으로 다시 분리
                old = json.loads((LIBRARY / resplit / "meta.json").read_text())
                key = resplit.rsplit("-", 1)[0]
                title, source = old["title"], old.get("source") or "file"
                matched, link, text = old.get("matched"), old.get("link"), old.get("input")
            elif text:
                job["step"] = "링크 확인 중"
                url, title, key, source = resolve(text, job)
            else:
                key = hashlib.sha1(upload_path.read_bytes()).hexdigest()[:11]
            song_id = f"{key}-{mode}"
            folder = LIBRARY / song_id
            if (folder / "meta.json").exists():  # 이미 분리한 곡이면 바로 열기
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
            if mode in ("hq", "hq6"):
                stems = separate_hq(x, job, six=mode == "hq6")
            elif mode in MODELS:
                stems = separate_ai(x, job, mode)
            else:
                stems = separate_eq(x, job)
            names = STEMS_6 if mode in ("ai6", "hq6") else STEMS
            job.update(step="저장 중", progress=0.99)
            peak = max(float(np.abs(s).max()) for s in stems.values())
            scale = 0.99 / peak if peak > 0.99 else 1.0
            for name in names:
                sf.write(folder / f"{name}.wav", stems[name] * scale, SR, subtype="PCM_24")
            if not kept_source(key):  # 다음에 다른 방식으로 나눌 때 쓰도록 원본 보관
                shutil.move(src, SOURCES / f"{key}{src.suffix.lower()}")
            src.unlink(missing_ok=True)
            meta = {"id": song_id, "title": title, "mode": mode, "duration": len(x) / SR,
                    "stems": names, "source": source, "matched": matched, "link": link,
                    "input": text}
            (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
            job.update(status="done", song_id=song_id, progress=1.0)
    except Exception as e:
        traceback.print_exc()
        msg = str(e).replace("ERROR: ", "").split("\n")[0]
        low = msg.lower()
        if isinstance(e, UserError):
            pass
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
        job.update(status="error", error=msg)
        if "folder" in locals() and not (folder / "meta.json").exists():
            shutil.rmtree(folder, ignore_errors=True)


# ---------------------------------------------------------------- API
@app.post("/api/jobs")
async def create_job(mode: str = Form("ai"), url: str = Form(None), path: str = Form(None),
                     file: UploadFile = File(None)):
    if mode not in MODES:
        raise HTTPException(400, "mode")
    job_id = uuid.uuid4().hex
    jobs[job_id] = {"status": "running", "step": "대기 중", "progress": 0.0}
    if url and url.strip():
        args = dict(text=url.strip())
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
    metas = [json.loads(p.read_text()) for p in LIBRARY.glob("*/meta.json")]
    metas.sort(key=lambda m: (LIBRARY / m["id"]).stat().st_mtime, reverse=True)
    return metas


@app.get("/api/songs/{song_id}")
def song_meta(song_id: str):
    p = LIBRARY / song_id / "meta.json"
    if not p.exists():
        raise HTTPException(404)
    return json.loads(p.read_text())


@app.delete("/api/songs/{song_id}")
def delete_song(song_id: str):
    folder = (LIBRARY / song_id).resolve()
    if folder.parent != LIBRARY.resolve() or not folder.exists():
        raise HTTPException(404)
    shutil.rmtree(folder)
    key = song_id.rsplit("-", 1)[0]
    if not any(LIBRARY.glob(f"{key}-*/meta.json")):  # 이 곡의 다른 버전이 없으면 원본도 지움
        for f in SOURCES.glob(f"{key}.*"):
            f.unlink()
    return {"ok": True}


@app.get("/api/songs/{song_id}/{stem}.wav")
def stem_file(song_id: str, stem: str, original: int = 0):
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    user = (meta.get("replaced") or {}).get(stem)
    p = folder / "user" / f"{stem}.wav" if user and user.get("use") and not original else folder / f"{stem}.wav"
    allowed = set(STEMS_6) | {x["id"] for x in meta.get("extras") or []}
    if stem not in allowed or not p.exists():
        raise HTTPException(404)
    return FileResponse(p, media_type="audio/wav")


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
            src = folder / "user" / f"{stem}.wav" if ((meta.get("replaced") or {}).get(stem) or {}).get("use") else folder / f"{stem}.wav"
            job.update(step="트랙 읽는 중", progress=0.0)
            y, _ = sf.read(src, dtype="float32", always_2d=True)
            job["step"] = ("음 높이를 읽는 중" if stem in tr.MONO_STEMS else "화음을 읽는 중 (basic-pitch)")
            raw = tr.transcribe(y, stem, lambda p: job.update(progress=0.05 + 0.75 * p))
            job.update(step="조성과 빠르기 찾는 중", progress=0.85)
            mix = sum(sf.read(folder / f"{n}.wav", dtype="float32", always_2d=True)[0] for n in meta["stems"])
            tempo = tr.detect_tempo(mix)
            tonic, mode = tr.detect_key(raw)
            (folder / "midi").mkdir(exist_ok=True)
            (folder / "midi" / f"{stem}.json").write_text(json.dumps(
                {"raw": raw, "key": [tonic, mode], "tempo": tempo}))
            job.update(step="깔끔한 소리로 다시 연주하는 중", progress=0.92)
            count = tr.render(folder, stem, sound, 0, snap)
            extras = [x for x in meta.get("extras") or [] if x["id"] != f"{stem}_midi"]
            extras.append({"id": f"{stem}_midi", "source": stem, "label": f"{MIDI_LABEL.get(stem, stem)} (MIDI)",
                           "sound": sound, "snap": snap, "transpose": 0, "notes": count,
                           "key": tr.key_name(tonic, mode), "tempo": round(tempo)})
            meta["extras"] = extras
            (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
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
    (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
    return meta


@app.get("/api/songs/{song_id}/midi/{stem}.json")
def midi_notes(song_id: str, stem: str):
    p = song_folder(song_id) / "midi" / f"{stem}.json"
    if not p.exists():
        raise HTTPException(404)
    d = json.loads(p.read_text())
    return {"notes": d.get("notes", d["raw"]), "tempo": d["tempo"]}


@app.delete("/api/songs/{song_id}/midi/{stem}")
def delete_midi(song_id: str, stem: str):
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    meta["extras"] = [x for x in meta.get("extras") or [] if x["source"] != stem]
    for f in [folder / f"{stem}_midi.wav", *(folder / "midi").glob(f"{stem}.*")] if (folder / "midi").exists() else []:
        Path(f).unlink(missing_ok=True)
    (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
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
    n = sf.info(folder / f"{stem}.wav").frames
    shift = int(round(offset * SR))
    y = np.concatenate([np.zeros((shift, 2), np.float32), y]) if shift > 0 else y[-shift:]
    y = y[:n] if len(y) >= n else np.concatenate([y, np.zeros((n - len(y), 2), np.float32)])
    sf.write(folder / "user" / f"{stem}.wav", np.clip(y, -1, 1), SR, subtype="PCM_24")


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
        cur = {"name": name or f.stem, "base": 0.0, "nudge": 0.0, "use": True}
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
    (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
    return meta


@app.delete("/api/songs/{song_id}/user-track/{stem}")
def remove_user_track(song_id: str, stem: str):
    folder = song_folder(song_id)
    meta = json.loads((folder / "meta.json").read_text())
    (meta.get("replaced") or {}).pop(stem, None)
    for f in (folder / "user").glob(f"{stem}.*") if (folder / "user").exists() else []:
        f.unlink()
    (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
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
