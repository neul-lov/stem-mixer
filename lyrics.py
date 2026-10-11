"""노래(분리한 보컬)에서 가사를 받아 적고, 음표마다 한 음절씩 나눠 붙인다.

- 받아 적기: Whisper large-v3-turbo. Apple 실리콘 Mac은 mlx-whisper(빠름), 그 밖에는 faster-whisper.
  노래하는 부분만 30초 이하 조각으로 잘라서 읽는다 (쉬는 곳에서 없는 말을 지어내지 않게).
- 일본어는 한자를 히라가나로 바꾼다 (fugashi + unidic-lite): OpenUtau 일본어 가수는 가나를 읽는다.
- 한 음절 = 한국어 한 글자, 일본어 가나 한 글자(きゃ처럼 작은 글자는 앞 글자와 함께), 중국어 한 글자, 그 밖은 단어 하나.
- 한 음절을 여러 음표에 걸쳐 부르면 뒤 음표는 "+" (OpenUtau에서 앞 음절을 늘여 부르기).
"""
import platform
import re
import sys

import numpy as np

SR = 44100
LANGUAGES = {"auto": None, "ko": "ko", "ja": "ja", "en": "en", "zh": "zh"}
EXTEND = "+"
MIN_NOTE = 0.06  # transcribe.clean_notes(내보내기)가 이보다 짧은 음표를 뺀다
# 아무 소리 없는 곳에서 Whisper가 자주 지어내는 말 (방송 자막에서 배운 것)
_HALLUCINATIONS = re.compile(
    r"ご視聴|チャンネル登録|字幕|시청해\s*주셔서|구독과\s*좋아요|MBC|KBS|SBS|뉴스|Thank(s| you) for watching|"
    r"Subtitles|請不吝|點贊|订阅", re.I)


# ---------------------------------------------------------------- 받아 적기
def _use_mlx():
    return sys.platform == "darwin" and platform.machine() == "arm64"


def _model(step):
    import transcribe as tr

    global _whisper
    try:
        return _whisper
    except NameError:
        pass
    step("가사 AI 모델 받는 중 (처음 한 번, 1.5GB 정도)")
    if _use_mlx():
        tr._need(("mlx_whisper", "mlx-whisper"))
        import mlx_whisper
        from huggingface_hub import snapshot_download

        path = snapshot_download("mlx-community/whisper-large-v3-turbo", cache_dir=str(tr.MODEL_DIR / "whisper"))

        def run(audio, language):
            r = mlx_whisper.transcribe(audio, path_or_hf_repo=path, language=language, word_timestamps=True,
                                       condition_on_previous_text=False, verbose=None, fp16=True)
            return r.get("language"), [s.get("words") or [] for s in r.get("segments", [])]
    else:
        tr._need(("faster_whisper", "faster-whisper"))
        from faster_whisper import WhisperModel

        model = WhisperModel("large-v3-turbo", device="cpu", compute_type="int8",
                             download_root=str(tr.MODEL_DIR / "whisper"))

        def run(audio, language):
            segs, info = model.transcribe(audio, language=language, word_timestamps=True,
                                          condition_on_previous_text=False, vad_filter=False, beam_size=5)
            segments = [[{"word": w.word, "start": w.start, "end": w.end} for w in (s.words or [])] for s in segs]
            return info.language, segments
    _whisper = run
    return run


def words(y, language=None, progress=lambda p: None, step=lambda text: None):
    """보컬 트랙(스테레오 float, 44.1kHz) → (언어, [(시작초, 끝초, 말)])."""
    import torch
    import torchaudio

    import transcribe as tr

    run = _model(step)
    step("가사 받아 적는 중")
    m = y.mean(axis=1).astype(np.float32)
    a16 = torchaudio.functional.resample(torch.from_numpy(m)[None], SR, 16000)[0].numpy()
    chunks = tr._sing_chunks(a16, 16000)
    if not chunks:
        return language or "ko", []
    order = list(range(len(chunks)))
    if language is None:  # 가장 긴 조각으로 언어를 정하고 나머지도 그 언어로 (조각마다 바뀌지 않게)
        longest = max(order, key=lambda i: chunks[i][1] - chunks[i][0])
        order.remove(longest)
        order.insert(0, longest)
    total = sum(b - a for a, b in chunks) or 1
    done, out = 0, []
    for i in order:
        a, b = chunks[i]
        lang, segments = run(a16[a:b], language)
        language = language or lang
        for seg in segments:
            # 지어낸 줄(방송 자막 인사 등)은 그 줄을 통째로 뺀다. 말을 띄어 붙이고 띄어쓰기 없이도 본다 (시청해 / 주셔서)
            joined = " ".join((w.get("word") or "").strip() for w in seg)
            if _HALLUCINATIONS.search(joined) or _HALLUCINATIONS.search(joined.replace(" ", "")):
                continue
            for w in seg:
                text = (w.get("word") or "").strip()
                if not text or w.get("start") is None or w.get("end") is None:
                    continue
                out.append((a / 16000 + float(w["start"]), a / 16000 + float(w["end"]), text))
        done += b - a
        progress(done / total)
    out.sort()
    return language or "ko", out


# ---------------------------------------------------------------- 음절 나누기
_SMALL = set("ぁぃぅぇぉゃゅょゎゕゖ")
_NOT_NOTES = set("っッーゝゞヽヾ・゛゜々")


def _hira(text):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in text)


def _is_kana(c):  # 히라가나 ぁ–ゖ, 가타카나 ァ–ヺ (・ 같은 기호와 ゛゜는 빼고)
    return "\u3041" <= c <= "\u3096" or "\u30a1" <= c <= "\u30fa"


def _is_syllable_char(c):
    v = ord(c)
    return (_is_kana(c) or 0xAC00 <= v <= 0xD7A3 or 0x3400 <= v <= 0x9FFF or 0xF900 <= v <= 0xFAFF
            or 0x20000 <= v <= 0x2FFFF)


def _tagger():
    import transcribe as tr

    global _ja
    try:
        return _ja
    except NameError:
        tr._need(("fugashi", "fugashi"), ("unidic_lite", "unidic-lite"))
        import fugashi

        _ja = fugashi.Tagger()
        return _ja


def _reading(w):
    """fugashi 낱말 하나의 히라가나 읽기 (조사 は · へ · を는 소리 나는 대로 わ · え · お)."""
    surface, f = w.surface, w.feature
    if not any("\u3400" <= c <= "\u9fff" or "ァ" <= c <= "ヶ" or "ぁ" <= c <= "ゖ" for c in surface):
        return surface  # 영어 · 숫자 · 기호는 그대로
    reading = getattr(f, "pron", None) if getattr(f, "pos1", "") == "助詞" else getattr(f, "kana", None)
    return _hira(reading) if reading and reading != "*" else _hira(surface)


def to_kana(text):
    """일본어 문장의 한자를 히라가나로."""
    return "".join(w.white_space + _reading(w) for w in _tagger()(text))


def syllables(text, language, kana=False):
    """말 하나(단어)를 음표 하나씩 부를 조각으로. kana=True면 이미 가나로 바꾼 글."""
    if language == "ja" and not kana:
        text = to_kana(text)
    out, word = [], ""
    for c in text:
        if not _is_syllable_char(c) and (c.isalnum() or c in "'’") and c not in _NOT_NOTES:
            word += c
            continue
        if word:
            out.append(word)
            word = ""
        if not _is_syllable_char(c) or c in _NOT_NOTES:  # 띄어쓰기 · 문장부호 · 작은 っ · 길게 늘이는 ー는 음표가 아니다
            continue
        c = _hira(c) if language == "ja" else c
        if c in _SMALL and out and _is_kana(out[-1][-1]) and out[-1][-1] not in _SMALL:
            out[-1] += c
        else:
            out.append(c)
    if word:
        out.append(word)
    return out


def word_units(ws, language):
    """받아 적은 말 [(시작, 끝, 말)] → [(시작, 끝, [음절…])].
    일본어는 Whisper가 한자 낱말을 쪼개서 줄 때가 많아서(東 / 京), 문장 전체를 읽은 뒤 음절을 말 조각에 다시 나눠 준다."""
    if language != "ja":
        return [(s, e, syllables(t, language)) for s, e, t in ws]
    out = [[s, e, []] for s, e, _ in ws]
    # 1초 넘게 쉬지 않는 말끼리를 한 문장으로
    groups, start = [], 0
    for i in range(1, len(ws) + 1):
        if i == len(ws) or ws[i][0] - ws[i - 1][1] > 1.0:
            groups.append(range(start, i))
            start = i
    for g in groups:
        text, owner = "", []
        for i in g:
            t = ws[i][2].strip()
            if text and t and text[-1].isascii() and text[-1].isalnum() and t[0].isascii() and t[0].isalnum():
                text += " "  # 영어 단어끼리는 띄어야 한 낱말로 붙지 않는다 (I love you)
                owner.append(i)
            text += t
            owner += [i] * len(t)
        pos = 0
        for w in _tagger()(text):
            a = text.find(w.surface, pos)
            if a < 0:
                continue
            b = pos = a + len(w.surface)
            units = syllables(_reading(w), "ja", kana=True)
            covered = list(dict.fromkeys(owner[a:b]))
            if not units or not covered:
                continue
            # 낱말의 음절을 그 낱말이 걸친 말 조각들에 나눠 준다. 가나로 된 조각은 제 음절 수만큼(思 / い / 出 / す →
            # おも / い / だ / す), 남는 음절은 한자 조각들에 글자 수만큼
            parts = ["".join(c for c, o in zip(text[a:b], owner[a:b]) if o == i) for i in covered]
            fixed = [len(syllables(_hira(p), "ja", kana=True)) if p and all(_is_kana(c) or c in _NOT_NOTES for c in p)
                     else None for p in parts]
            rest = len(units) - sum(n for n in fixed if n is not None)
            free = [j for j, n in enumerate(fixed) if n is None]
            if rest < len(free) or (not free and rest):  # 맞지 않으면 글자 수만큼
                fixed, free, rest = [None] * len(parts), list(range(len(parts))), len(units)
            sizes = {j: len(parts[j]) for j in free}
            total, given = sum(sizes.values()) or 1, 0
            for k, j in enumerate(free):
                fixed[j] = rest - given if k == len(free) - 1 else max(1, round(rest * sizes[j] / total))
                given += fixed[j]
            u = 0
            for j, i in enumerate(covered):
                take = len(units) - u if j == len(covered) - 1 else fixed[j]
                out[i][2] += units[u:u + take]
                u += take
    return [tuple(x) for x in out]


# ---------------------------------------------------------------- 음표에 붙이기
def fit(notes, ws, language):
    """음표 목록(시작초, 끝초, 음, 세기[, 가사])에 받아 적은 말을 시간 순서대로 붙인다.
    한 말에 걸친 음표가 음절보다 많으면 남는 음표는 "+"(늘여 부르기), 적으면 긴 음표를 나눈다.
    반환: (가사를 붙인 새 음표 목록, 가사를 붙인 음표 수, 못 붙인 음절 수)."""
    # 같은 때 시작하는 음표는 내보낼 때 남는 쪽(늦게 끝나는 쪽, 같으면 높은 쪽)이 앞에 오게
    notes = sorted([list(n[:4]) for n in notes], key=lambda n: (n[0], -n[1], -n[2]))
    lyric = [None] * len(notes)
    splits = {}  # 음표 번호 → 나눌 음절들
    cursor, dropped = 0, 0
    for s, e, units in word_units(ws, language):
        if not units:
            continue
        # OpenUtau로 내보낼 때 빠지는 60ms보다 짧은 음표에는 붙이지 않는다
        cands = [i for i in range(cursor, len(notes))
                 if notes[i][0] < e - 0.02 and notes[i][1] > s + 0.02 and notes[i][1] - notes[i][0] >= MIN_NOTE]
        # 같은 때 시작하는 화음은 맨 위 음 하나만
        cands = [i for k, i in enumerate(cands) if k == 0 or notes[i][0] - notes[cands[k - 1]][0] > 0.01]
        if not cands:
            near = next((i for i in range(cursor, len(notes)) if notes[i][0] < e + 0.3 and notes[i][1] > s - 0.3
                         and notes[i][1] - notes[i][0] >= MIN_NOTE), None)
            if near is None:
                dropped += len(units)
                continue
            cands = [near]
        k, m = len(units), len(cands)
        if m >= k:
            for j, i in enumerate(cands):
                u = j * k // m
                lyric[i] = units[u] if (j == 0 or (j - 1) * k // m != u) else EXTEND
        else:
            # 음표마다 적어도 한 음절, 남는 음절은 긴 음표부터 나눠 맡는다
            count = [1] * m
            lengths = [notes[i][1] - notes[i][0] for i in cands]
            for _ in range(k - m):
                j = max(range(m), key=lambda j: lengths[j] / (count[j] + 1))
                count[j] += 1
            u = 0
            for j, i in enumerate(cands):
                part = units[u:u + count[j]]
                u += count[j]
                if len(part) == 1:
                    lyric[i] = part[0]
                else:
                    splits[i] = part
        cursor = cands[-1] + 1
    out, placed = [], 0
    for i, (s, e, p, v) in enumerate(notes):
        if i in splits:
            part = splits[i]
            pieces = max(1, min(len(part), int((e - s) / 0.065)))  # 내보낼 때 빠지지 않게 65ms보다 짧게는 안 나눈다
            if pieces < len(part):  # 너무 짧으면 남는 음절은 마지막 조각에 이어 붙인다
                part = part[:pieces - 1] + ["".join(part[pieces - 1:])]
            step = (e - s) / len(part)
            for j, text in enumerate(part):
                out.append((round(s + j * step, 4), round(s + (j + 1) * step, 4), p, v, text[:32]))
                placed += 1
        elif lyric[i]:
            out.append((s, e, p, v, lyric[i][:32]))
            placed += lyric[i] != EXTEND
        else:
            out.append((s, e, p, v))
    return out, placed, dropped
