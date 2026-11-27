#!/usr/bin/env python3
"""Compare two offline REC bundles using the *same held-out* real ROI crops."""
import argparse
import csv
import hashlib
import json
import re
from collections import Counter
from decimal import Decimal
from pathlib import Path

NUMBER = re.compile(r"(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\Z")


def load_bundle(folder):
    import onnxruntime as ort

    cfg = json.loads((folder / 'rec.json').read_text(encoding='utf-8'))
    for file, hash_key in [('rec.onnx', 'sha256'), ('rec.dict.json', 'dictionarySha256'),
                           ('rec-upstream.yml', 'upstreamConfigSha256')]:
        if hashlib.sha256((folder / file).read_bytes()).hexdigest() != cfg[hash_key]:
            raise ValueError(f'{folder}: invalid SHA-256 for {file}')
    contract = dict(width=320, height=48, channels=3, input='BGR', resize='aspect-right-pad',
                    mean=.5, scale=.5, decoder='ctc-probabilities', blankIndex=0)
    if any(cfg.get(key) != value for key, value in contract.items()):
        raise ValueError(f'{folder}: bundle is incompatible with the Android preprocessing contract')
    dictionary = json.loads((folder / 'rec.dict.json').read_text(encoding='utf-8'))
    if cfg['classCount'] != len(dictionary) + 1:
        raise ValueError(f'{folder}: dictionary and class count differ')
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    session = ort.InferenceSession(str(folder / 'rec.onnx'), options, providers=['CPUExecutionProvider'])
    return cfg, dictionary, session


def decode(probabilities, dictionary):
    import numpy as np

    if probabilities.ndim != 2 or probabilities.shape[-1] != len(dictionary) + 1:
        raise ValueError('invalid REC output shape')
    if not np.isfinite(probabilities).all() or np.any((probabilities < 0) | (probabilities > 1)):
        raise ValueError('invalid REC output probabilities')
    previous = 0
    text, confidence = [], []
    for row in probabilities:
        token = int(row.argmax())
        if token != 0 and token != previous:
            text.append(dictionary[token - 1])
            confidence.append(float(row[token]))
        previous = token
    return ''.join(text).strip(), sum(confidence) / len(confidence) if confidence else 0.


def predict(bundle, image_path):
    import math
    import numpy as np
    from PIL import Image

    cfg, dictionary, session = bundle
    with Image.open(image_path) as original:
        rgb = original.convert('RGB')
        w = min(cfg['width'], max(1, math.ceil(cfg['height'] * rgb.width / rgb.height)))
        pixels = np.asarray(rgb.resize((w, cfg['height']), Image.Resampling.BILINEAR))
        tensor = np.zeros((1, 3, cfg['height'], cfg['width']), dtype=np.float32)
        tensor[0, :, :, :w] = (pixels[:, :, ::-1].transpose(2, 0, 1).astype('float32') / 255. - .5) / .5
    (probabilities,) = session.run(None, {session.get_inputs()[0].name: tensor})
    return decode(probabilities[0], dictionary)


def verdict(text, confidence, truth, low):
    if NUMBER.fullmatch(text) is None or confidence < low:
        return 'failed'
    if text == truth:
        return 'exact'
    return 'format_only' if Decimal(text) == Decimal(truth) else 'wrong'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('samples', type=Path, help='UTF-8 CSV: image,truth (preserve leading zeros)')
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', type=Path)
    parser.add_argument('--out', required=True, type=Path, help='Per-image comparison CSV')
    parser.add_argument('--low', type=float, default=.60)
    parser.add_argument('--high', type=float, default=.85)
    args = parser.parse_args()
    if not 0 <= args.low <= args.high <= 1:
        parser.error('thresholds must satisfy 0 <= low <= high <= 1')
    with args.samples.open(encoding='utf-8-sig', newline='') as source:
        samples = [(r['image'], r['truth']) for r in csv.DictReader(source)]
    if not samples or len({p for p, _ in samples}) != len(samples) or any(not p or NUMBER.fullmatch(t) is None for p, t in samples):
        parser.error('supply unique real crop files, each with a complete numeric ground-truth string')
    paths = {'baseline': args.baseline}
    if args.candidate:
        paths['candidate'] = args.candidate
    bundles = {key: load_bundle(folder) for key, folder in paths.items()}
    summary = {key: Counter() for key in bundles}
    with args.out.open('w', encoding='utf-8', newline='') as target:
        writer = csv.writer(target)
        writer.writerow(['image', 'truth', 'model', 'raw', 'confidence', 'verdict', 'automatic'])
        for image, truth in samples:
            for key, bundle in bundles.items():
                text, confidence = predict(bundle, args.samples.parent / image)
                result = verdict(text, confidence, truth, args.low)
                accepted = confidence >= args.high and result != 'failed'
                summary[key][result] += 1
                summary[key]['automatic'] += accepted
                summary[key]['automatic_numeric_correct'] += accepted and result in ('exact', 'format_only')
                writer.writerow([image, truth, key, text, f'{confidence:.6f}', result, int(accepted)])
    for key, counter in summary.items():
        n = len(samples)
        print(json.dumps(dict(model=key, sha256=bundles[key][0]['sha256'], samples=n,
                              counts=dict(counter), exact_rate=counter['exact']/n,
                              numeric_correct_rate=(counter['exact']+counter['format_only'])/n,
                              wrong_rate=counter['wrong']/n, failure_rate=counter['failed']/n,
                              automatic_coverage=counter['automatic']/n,
                              automatically_accepted_numeric_accuracy=(counter['automatic_numeric_correct']/counter['automatic']
                                                                       if counter['automatic'] else None))))


if __name__ == '__main__':
    main()
