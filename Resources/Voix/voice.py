#!/usr/bin/env python3
"""Voix du prof (lancé avec le Python du dossier venv/). Deux commandes :
  voice.py enroll  <audio.wav 16 kHz mono> <empreinte.npy>
  voice.py label   <audio.wav 16 kHz mono> <empreinte.npy> <segments.json>   -> JSON sur la sortie
Seule l'empreinte du PROF est créée. Aucune empreinte d'élève. Tout reste sur le Mac."""
import json, sys
import numpy as np
import soundfile as sf
from resemblyzer import VoiceEncoder
from resemblyzer.audio import normalize_volume

SR = 16000
SEUIL_PROF, SEUIL_AUTRE = 0.75, 0.70


def charge(path):
    wav, sr = sf.read(path, dtype="float32")
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    if sr != SR:
        raise SystemExit(f"fréquence {sr} Hz au lieu de {SR}")
    return normalize_volume(wav, -30, increase_only=True)


def cosinus(a, b):
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9))


def main():
    cmd = sys.argv[1]
    enc = VoiceEncoder("cpu", verbose=False)
    if cmd == "enroll":
        wav = charge(sys.argv[2])
        if len(wav) < SR * 20:
            raise SystemExit("il faut au moins 20 secondes de voix du prof")
        emb = enc.embed_utterance(wav)
        np.save(sys.argv[3], emb)
        print(json.dumps({"ok": True, "secondes": round(len(wav) / SR)}))
    elif cmd == "embed":
        # une empreinte de 256 nombres par segment (null si le segment est trop court) ; rien n'est enregistré ici
        wav = charge(sys.argv[2])
        sortie = []
        for seg in json.load(open(sys.argv[3])):
            a, b = int(seg["s"] * SR), int(seg["e"] * SR)
            morceau = wav[max(0, a):min(len(wav), b)]
            sortie.append(None if len(morceau) < SR * 1.2 else [round(float(x), 5) for x in enc.embed_utterance(morceau)])
        print(json.dumps(sortie))
    elif cmd == "label":
        wav = charge(sys.argv[2])
        prof = np.load(sys.argv[3])
        out = []
        for seg in json.load(open(sys.argv[4])):
            a, b = int(seg["s"] * SR), int(seg["e"] * SR)
            morceau = wav[max(0, a):min(len(wav), b)]
            if len(morceau) < SR * 1.2:
                out.append({"qui": "?", "score": None})  # trop court pour décider
                continue
            sc = cosinus(enc.embed_utterance(morceau), prof)
            out.append({"qui": "prof" if sc >= SEUIL_PROF else ("autre" if sc <= SEUIL_AUTRE else "?"), "score": round(sc, 3)})
        print(json.dumps(out))


main()
