#!/usr/bin/env python3
"""Turn scene photos / renders into anime-style backgrounds.

Pipeline: AnimeGANv2 "Shinkai" style transfer, then a finishing pass that restores
the original tonal range and colour, flattens shading into cel-like areas, adds soft
navy line art and an anime highlight glow.

Requirements:  pip install onnxruntime opencv-python-headless numpy
Model:         Shinkai_53.onnx from https://github.com/TachibanaYoshino/AnimeGANv2
               (pb_and_onnx_model/). AnimeGANv2 is licensed for non-commercial use only.

Usage:  python3 scripts/anime-backgrounds.py --model Shinkai_53.onnx --out OUTDIR IMAGE [IMAGE ...]
        Images whose name contains "-night" or "-dusk" get a calmer colour boost.
"""
import argparse
import os

import cv2
import numpy as np
import onnxruntime as ort


def stylise(session, image, width=1600):
    h, w = image.shape[:2]
    tw = width - width % 32
    th = int(round(h * tw / w / 32)) * 32
    x = cv2.cvtColor(cv2.resize(image, (tw, th), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    x = x.astype(np.float32) / 127.5 - 1
    y = session.run(None, {session.get_inputs()[0].name: x[None]})[0][0]
    y = cv2.cvtColor(np.clip((y + 1) * 127.5, 0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR)
    return cv2.resize(y, (w, h), interpolation=cv2.INTER_CUBIC)


def finish(raw, orig, chroma=1.22, line_strength=0.22, glow=0.28):
    raw = raw.astype(np.float32) / 255
    orig = orig.astype(np.float32) / 255
    lab_r = cv2.cvtColor(raw, cv2.COLOR_BGR2LAB)
    lab_o = cv2.cvtColor(orig, cv2.COLOR_BGR2LAB)
    L = lab_r[..., 0]
    L = (L - L.mean()) / (L.std() + 1e-6) * lab_o[..., 0].std() * 1.02 + lab_o[..., 0].mean()
    ab_o = np.dstack([cv2.bilateralFilter(np.ascontiguousarray(lab_o[..., c]), 9, 12, 7) for c in (1, 2)])
    ab = (lab_r[..., 1:] * 0.45 + ab_o * 0.55) * chroma
    img = np.clip(cv2.cvtColor(np.dstack([np.clip(L, 0, 100), ab]).astype(np.float32), cv2.COLOR_LAB2BGR), 0, 1)
    flat = cv2.edgePreservingFilter((img * 255).astype(np.uint8), flags=1, sigma_s=24, sigma_r=0.18).astype(np.float32) / 255
    img = img * 0.45 + flat * 0.55
    gray = cv2.cvtColor((flat * 255).astype(np.uint8), cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(cv2.GaussianBlur(gray, (3, 3), 0), 40, 110).astype(np.float32) / 255
    edges = cv2.GaussianBlur(edges, (3, 3), 0.7)[..., None]
    ink = np.array([0.32, 0.22, 0.18], np.float32)
    img = img * (1 - edges * line_strength) + ink * edges * line_strength
    lum = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    bright = np.clip((lum - 0.72) / 0.28, 0, 1)[..., None] * img
    bloom = cv2.GaussianBlur(bright, (0, 0), sigmaX=img.shape[1] / 90)
    img = np.clip(1 - (1 - img) * (1 - bloom * glow), 0, 1)
    img = img + (img - img ** 2) * 0.18 * np.sign(img - 0.5)
    img = img + np.clip(1 - lum[..., None] / 0.45, 0, 1) * np.array([0.025, 0.018, -0.01], np.float32)
    return (np.clip(img, 0, 1) * 255).astype(np.uint8)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("images", nargs="+")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    session = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    for path in args.images:
        orig = cv2.imread(path)
        name = os.path.basename(path)
        chroma = 1.04 if "-night" in name else 1.14 if "-dusk" in name else 1.22
        result = finish(stylise(session, orig), orig, chroma=chroma)
        cv2.imwrite(os.path.join(args.out, name), result, [cv2.IMWRITE_JPEG_QUALITY, 90])
        print("✓", name)


if __name__ == "__main__":
    main()
