# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch", "numpy", "scipy", "num2words"]
# ///
"""Offline Russian TTS for `speak --local`. Reads text from stdin.

Silero reads only Cyrillic, so English words and digits are rewritten
into Russian first. Nothing leaves the machine after the one-time model download.
"""

import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import wave

import warnings

import numpy as np
import torch
from num2words import num2words

warnings.filterwarnings("ignore", category=UserWarning)

HOME = os.path.expanduser("~/.local/share/speak")
MODEL_URL = "https://models.silero.ai/models/tts/ru/v5_ru.pt"
MODEL_PATH = os.path.join(HOME, "v5_ru.pt")
SPEAKER = os.environ.get("SPEAK_LOCAL_VOICE", "aidar")  # aidar, eugene, baya, kseniya, xenia
RATE = 48000

# Words a rule-based transliteration gets wrong. Extend freely.
WORDS = {
    "api": "эй-пи-ай", "pr": "пи-ар", "prs": "пи-ары", "ci": "си-ай", "cli": "си-эл-ай",
    "ui": "ю-ай", "url": "ю-эр-эл", "json": "джейсон", "yaml": "ямл", "sql": "эс-кью-эл",
    "mysql": "май-эс-кью-эл", "http": "эйч-ти-ти-пи", "id": "ай-ди", "ok": "окей",
    "ai": "эй-ай", "tts": "ти-ти-эс", "mp3": "эм-пи-три", "ssml": "эс-эс-эм-эл",
    "kubernetes": "кубернетис", "k8s": "кубернетис", "jira": "джира", "slack": "слэк",
    "github": "гитхаб", "git": "гит", "temporal": "темпорал", "workflow": "воркфлоу",
    "workflows": "воркфлоу", "deploy": "деплой", "review": "ревью", "code": "код",
    "kafka": "кафка", "scala": "скала", "ruby": "руби", "rails": "рейлс", "go": "гоу",
    "python": "пайтон", "docker": "докер", "grafana": "графана", "vinted": "винтед",
    "claude": "клод", "microsoft": "майкрософт", "edge": "эдж", "google": "гугл",
    "the": "зе", "and": "энд", "of": "оф", "to": "ту", "for": "фор", "with": "уиз",
    "is": "из", "it": "ит", "on": "он", "in": "ин", "you": "ю", "we": "уи",
    "user": "юзер", "users": "юзеры", "task": "таск", "tasks": "таски", "branch": "бранч",
    "merge": "мёрж", "commit": "коммит", "push": "пуш", "test": "тест", "tests": "тесты",
    "service": "сервис", "server": "сервер", "shipment": "шипмент", "order": "ордер",
    "support": "саппорт", "team": "тим", "feature": "фича", "flag": "флаг",
}
LETTERS = {
    "a": "эй", "b": "би", "c": "си", "d": "ди", "e": "и", "f": "эф", "g": "джи", "h": "эйч",
    "i": "ай", "j": "джей", "k": "кей", "l": "эл", "m": "эм", "n": "эн", "o": "оу", "p": "пи",
    "q": "кью", "r": "ар", "s": "эс", "t": "ти", "u": "ю", "v": "ви", "w": "дабл-ю", "x": "экс",
    "y": "уай", "z": "зед",
}
COMBOS = [
    ("tion", "шн"), ("sion", "жн"), ("ight", "айт"), ("ough", "оу"), ("sh", "ш"), ("ch", "ч"),
    ("th", "з"), ("ph", "ф"), ("ck", "к"), ("qu", "кв"), ("oo", "у"), ("ee", "и"), ("ea", "и"),
    ("ay", "ей"), ("ey", "ей"), ("ow", "оу"), ("ou", "ау"), ("ai", "ей"), ("oa", "оу"),
    ("wh", "у"), ("ng", "нг"), ("ss", "с"), ("ll", "л"), ("tt", "т"), ("pp", "п"), ("ff", "ф"),
]
SINGLE = {
    "a": "а", "b": "б", "c": "к", "d": "д", "e": "е", "f": "ф", "g": "г", "h": "х", "i": "и",
    "k": "к", "l": "л", "m": "м", "n": "н", "o": "о", "p": "п", "q": "к", "r": "р", "s": "с",
    "t": "т", "u": "у", "v": "в", "w": "в", "z": "з",
}


def translit(word: str) -> str:
    low = word.lower()
    if low in WORDS:
        return WORDS[low]
    if word.isupper() and len(word) <= 5:  # acronym: spell it
        return "-".join(LETTERS.get(c, c) for c in low)
    out, i = "", 0
    while i < len(low):
        for src, dst in COMBOS:
            if low.startswith(src, i):
                out += dst
                i += len(src)
                break
        else:
            ch = low[i]
            if ch == "e" and i == len(low) - 1 and len(low) > 3:
                pass  # silent final e
            elif ch == "y":
                out += "й" if i == 0 else "и"
            elif ch == "j":
                out += "дж"
            elif ch == "x":
                out += "кс"
            else:
                out += SINGLE.get(ch, ch)
            i += 1
    return out


def normalize(text: str) -> str:
    text = re.sub(r"(\d+)\s*%", lambda m: num2words(int(m.group(1)), lang="ru") + " процентов", text)
    text = re.sub(r"\d+(?:[.,]\d+)?", lambda m: num2words(float(m.group(0).replace(",", ".")) if re.search(r"[.,]", m.group(0)) else int(m.group(0)), lang="ru"), text)
    text = re.sub(r"[A-Za-z][A-Za-z']*", lambda m: translit(m.group(0)), text)
    text = text.replace("&", " и ").replace("+", " плюс ").replace("/", " ")
    text = re.sub(r"[^\w\s.,!?:;\-ёЁ]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def chunks(text: str, limit: int = 800):
    buf = ""
    for sent in re.split(r"(?<=[.!?])\s+", text):
        if buf and len(buf) + len(sent) > limit:
            yield buf
            buf = ""
        buf = f"{buf} {sent}".strip()
    if buf:
        yield buf


def load_model():
    if not os.path.exists(MODEL_PATH):
        print("speak: downloading Silero model (one time)...", file=sys.stderr)
        urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)
    torch.set_num_threads(os.cpu_count() or 4)
    model = torch.package.PackageImporter(MODEL_PATH).load_pickle("tts_models", "model")
    model.to(torch.device("cpu"))
    return model


def main():
    text = normalize(sys.stdin.read())
    if not text:
        return
    model = load_model()
    out = os.environ.get("SPEAK_OUT")  # write one wav instead of playing (for tests)
    collected = []
    for part in chunks(text):
        audio = model.apply_tts(text=part, speaker=SPEAKER, sample_rate=RATE, put_accent=True, put_yo=True)
        pcm = (np.clip(audio.numpy(), -1, 1) * 32767).astype(np.int16)
        if out:
            collected.append(pcm)
            continue
        fd, path = tempfile.mkstemp(suffix=".wav", prefix="speak-")
        os.close(fd)
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm.tobytes())
        try:
            subprocess.run(["afplay", path])
        finally:
            os.unlink(path)
    if out:
        with wave.open(out, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(np.concatenate(collected).tobytes())


if __name__ == "__main__":
    main()
