#!/usr/bin/env python3
"""Build a deterministic offline lexicon from pinned, MIT-licensed data only."""
import argparse, hashlib, json, re, unicodedata, urllib.request
from pathlib import Path

SOURCES = [
    ("mozillazg/pinyin-data", "fe29ad32bdf352b31a02b9936e537f575432e9a6", "pinyin.txt", "characters", "2342a6f98c85dbc3c8d26aef31744876a36326c6466e51e9a0f16898c36c2011"),
    ("mozillazg/phrase-pinyin-data", "4afa3226ce53c9138b939e83c3bb294dbe0da511", "large_pinyin.txt", "phrases", "7e34c0e09ad398a7a07c0964bebb9677ace2114ed9d1c2ccdfce939102db2134"),
    ("fxsjy/jieba", "67fa2e36e72f69d9134b8a1037b83fbb070b9775", "jieba/dict.txt", "frequency", "7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8"),
]
def plain(value):
    value = re.sub(r'u[\u0304\u0301\u030c\u0300]*\u0308', 'v', unicodedata.normalize('NFD', value))
    value = value.replace('u\u0308', 'v')
    return ''.join(c for c in value if not unicodedata.combining(c)).lower()

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args(); args.cache.mkdir(parents=True, exist_ok=True)
    contents = {}
    notices = ['Offline Pinyin data sources. Derived lexicon retains the licenses below.\n']
    for repo, sha, filename, name, expected in SOURCES:
        path = args.cache / (name + '.txt')
        base = f'https://raw.githubusercontent.com/{repo}/{sha}/'
        if not path.exists(): path.write_bytes(urllib.request.urlopen(base + filename, timeout=45).read())
        data = path.read_bytes(); assert hashlib.sha256(data).hexdigest() == expected, name
        contents[name] = data.decode('utf-8')
        notice_path = args.cache / (name + '-LICENSE.txt')
        if not notice_path.exists(): notice_path.write_bytes(urllib.request.urlopen(base + 'LICENSE', timeout=30).read())
        notices.append(f'\nSource: https://github.com/{repo}\nCommit: {sha}\nSHA-256 ({filename}): {expected}\n\n' + notice_path.read_text())
    frequency = {}
    for line in contents['frequency'].splitlines():
        word, count, *_ = line.split(); frequency[word] = int(count)
    rows = {}
    for line in contents['characters'].splitlines():
        if not line.startswith('U+'): continue
        code, readings = line.split('#')[0].split(':')
        char = chr(int(code[2:], 16))
        for reading in readings.strip().split(','):
            pinyin = plain(reading)
            if re.fullmatch('[a-z]+', pinyin): rows[(pinyin, char)] = frequency.get(char, 0)
    words = []
    for line in contents['phrases'].splitlines():
        if line.startswith('#') or ': ' not in line: continue
        word, reading = line.split(': ', 1)
        pinyin = plain(reading.strip())
        if 2 <= len(word) <= 8 and re.fullmatch('[a-z]+(?: [a-z]+)+', pinyin) and word in frequency:
            words.append((frequency[word], word, pinyin))
    for count, word, pinyin in sorted(words, reverse=True)[:80000]: rows[(pinyin, word)] = count
    # Finance terms are valid spellings, not a restriction on what can be typed.
    extra = {'支付宝':'zhi fu bao','微信':'wei xin','零钱':'ling qian','花呗':'hua bei','停车费':'ting che fei','网约车':'wang yue che','物业费':'wu ye fei','工作报销':'gong zuo bao xiao'}
    for word, pinyin in extra.items(): rows.setdefault((pinyin, word), max(100, frequency.get(word, 0)))
    root = Path(__file__).resolve().parents[1] / 'Sources/ReceiptCore/Resources'
    root.mkdir(parents=True, exist_ok=True)
    output = ''.join(f'{pinyin}\t{word}\t{count}\n' for (pinyin, word), count in sorted(rows.items()))
    (root / 'pinyin.tsv').write_text(output, encoding='utf-8')
    (root / 'Pinyin-LICENSES.txt').write_text('\n'.join(notices), encoding='utf-8')
    print(json.dumps({'entries':len(rows),'bytes':len(output.encode()),'sha256':hashlib.sha256(output.encode()).hexdigest()}))

if __name__ == '__main__': main()
