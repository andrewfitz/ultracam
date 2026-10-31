#!/usr/bin/env python3
"""Builds the r5 mockups: real SF Symbols into icons.css, then one PNG per page.

Run with `python3 -I docs/mockups/r5/tools/build.py [page.html ...]`. No pages means all of them.
A page sets its capture size with <meta name="shot" content="1500x2200">.
Cached symbols live in /tmp, so nothing but icons.css and png/ is written here.
"""
import base64
import glob
import os
import re
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cache = '/tmp/ultracam-symbols/icons'
chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
pages = sorted(glob.glob(f'{root}/*.html'))
os.makedirs(cache, exist_ok=True)
os.makedirs(f'{root}/png', exist_ok=True)

names = set()
for page in pages:
    names |= set(re.findall(r'(?<![a-z-])s="([^"]+)"', open(page).read()))
missing = [n for n in sorted(names) if not os.path.exists(f'{cache}/{n}.png')]
if missing:
    result = subprocess.run(['swift', f'{root}/tools/symbols.swift', cache, *missing], capture_output=True, text=True)
    print(result.stdout.strip() or result.stderr.strip())
bad = [n for n in sorted(names) if not os.path.exists(f'{cache}/{n}.png')]
if bad:
    sys.exit(f'Unknown SF Symbols: {bad}')

rules = []
for name in sorted(names):
    data = base64.b64encode(open(f'{cache}/{name}.png', 'rb').read()).decode()
    rules.append(f'.ic[s="{name}"]{{-webkit-mask-image:url(data:image/png;base64,{data});}}')
open(f'{root}/icons.css', 'w').write('\n'.join(rules) + '\n')

targets = [os.path.join(root, os.path.basename(a)) for a in sys.argv[1:]] or pages
for page in targets:
    base = os.path.splitext(os.path.basename(page))[0]
    if base == 'index':
        continue
    shot = re.search(r'name="shot" content="(\d+)x(\d+)"', open(page).read())
    width, height = shot.groups() if shot else ('1500', '2000')
    subprocess.run([chrome, '--headless=new', '--disable-gpu', '--hide-scrollbars',
        f'--user-data-dir=/tmp/ultracam-mock-chrome-{base}', '--force-device-scale-factor=1.5',
        f'--window-size={width},{height}', f'--screenshot={root}/png/{base}.png', f'file://{page}'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f'png/{base}.png  {width}x{height}')
