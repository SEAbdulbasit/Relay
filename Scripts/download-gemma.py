#!/usr/bin/env python3
"""Download the pinned public Gemma 4 E2B LiteRT model; verify bytes before installation."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.request

REVISION = '1caa527c1e88b55f046fcd8d2b4265606680663d'
URL = f'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/{REVISION}/gemma-4-E2B-it.litertlm'
SIZE = 2588147712
SHA = '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c'
ROOT = Path.home() / 'Library/Application Support/Relay/Models'
ROOT.mkdir(parents=True, exist_ok=True)
DEST = ROOT / 'gemma-4-E2B-it.litertlm'
PARTIAL = Path(str(DEST) + '.download')
WORKERS = 6
CHUNK = (SIZE + WORKERS - 1) // WORKERS
if DEST.exists():
    existing = hashlib.sha256()
    with DEST.open('rb') as source:
        for block in iter(lambda: source.read(4*1024*1024), b''):
            existing.update(block)
    if DEST.stat().st_size != SIZE or existing.hexdigest() != SHA:
        raise RuntimeError('An existing model does not match the pinned checksum. It was not overwritten; inspect it before retrying.')
    print(f'Existing model checksum verified: {DEST}', flush=True)
    raise SystemExit(0)
if PARTIAL.exists() and PARTIAL.stat().st_size <= CHUNK and not Path(str(DEST)+'.part0').exists():
    PARTIAL.rename(Path(str(DEST)+'.part0'))

def download(i):
    start = i * CHUNK
    end = min(SIZE, (i+1)*CHUNK)-1
    target = Path(str(DEST)+f'.part{i}')
    expected = end-start+1
    for attempt in range(4):
        have = target.stat().st_size if target.exists() else 0
        if have == expected:
            return target
        if have > expected:
            raise RuntimeError(f'Unexpected partial size for part {i}; remove {target} and retry.')
        offset = start+have
        request = urllib.request.Request(URL, headers={'Range': f'bytes={offset}-{end}', 'User-Agent':'Relay-model-setup/0.1'})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                if response.status != 206 or response.headers.get('Content-Range','').split('/')[0] != f'bytes {offset}-{end}':
                    raise RuntimeError('Server did not honor the requested byte range.')
                with target.open('ab') as out:
                    while True:
                        block = response.read(1024*1024)
                        if not block:
                            break
                        out.write(block)
            if target.stat().st_size == expected:
                return target
        except Exception:
            if attempt == 3:
                raise
            time.sleep(1+attempt)
    raise RuntimeError(f'Incomplete model part {i}')

print('Downloading pinned Gemma 4 E2B (2.59 GB); six bounded connections; resumable partial files.', flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
    futures = [pool.submit(download,i) for i in range(WORKERS)]
    while not all(f.done() for f in futures):
        total = sum(p.stat().st_size for p in ROOT.glob(DEST.name+'.part*'))
        print(f'{total/SIZE:.1%} ({total//1048576} / {SIZE//1048576} MiB)',flush=True)
        time.sleep(10)
    parts = [f.result() for f in futures]
print('Assembling and checking SHA-256…',flush=True)
digest = hashlib.sha256()
with PARTIAL.open('wb') as out:
    for part in parts:
        with part.open('rb') as source:
            for block in iter(lambda: source.read(4*1024*1024),b''):
                out.write(block)
                digest.update(block)
if PARTIAL.stat().st_size != SIZE or digest.hexdigest() != SHA:
    raise RuntimeError('Integrity check failed; unverified package was not installed.')
os.replace(PARTIAL,DEST)
for part in parts:
    part.unlink()
(ROOT / 'gemma-4-E2B-it.provenance.json').write_text(json.dumps({'repository':'litert-community/gemma-4-E2B-it-litert-lm','revision':REVISION,'filename':DEST.name,'sha256':SHA,'size':SIZE,'license':'Apache-2.0','url':URL},indent=2))
print(f'Verified and installed: {DEST}',flush=True)
