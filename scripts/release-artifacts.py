#!/usr/bin/env python3
"""Offline release inventory and actual-byte build identity checks. Never installs."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

BINARIES = ('wechat', 'wechatd', 'wechat-bridge', 'wechat-mcp', 'wechat-send-mcp',
            'wechat-wechaty-gateway', 'wechat-snapshot-validator', 'wechat-native-owner')
SDK_ABI = 'wechat-use/native-context/v1'
MANIFEST = 'BUILD-MANIFEST.json'


def bound_digest(path):
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_uid not in (0, os.geteuid()) or before.st_mode & 0o022
            or not before.st_mode & 0o111 or before.st_size > 536870912):
        raise ValueError('release executable custody refused')
    stamp = lambda m: (m.st_dev, m.st_ino, m.st_size, m.st_mtime_ns, m.st_ctime_ns, m.st_mode, m.st_uid, m.st_nlink)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        if stamp(os.fstat(source.fileno())) != stamp(before): raise ValueError('release file replaced')
        h = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            block = source.read(min(65536, remaining))
            if not block: raise ValueError('release file truncated')
            remaining -= len(block)
            h.update(block)
        if source.read(1): raise ValueError('release file grew')
        if stamp(os.fstat(source.fileno())) != stamp(before) or stamp(path.lstat()) != stamp(before):
            raise ValueError('release file changed')
    return {'sha256':h.hexdigest(), 'size':before.st_size, 'mode':stat.S_IMODE(before.st_mode)}


def collect(directory, version, source):
    if not re.fullmatch('[0-9a-f]{40}', source): raise ValueError('exact source commit required')
    records = []
    for name in BINARIES:
        path = directory / name
        before = bound_digest(path)
        result = subprocess.run([str(path.resolve()), '--build-info'], stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=5, check=True)
        if result.stderr or len(result.stdout) > 4096: raise ValueError('build identity output refused')
        info = json.loads(result.stdout)
        expected = dict(schema='wechat-use/build-info/v1', binary=name, version=version,
                        sourceCommit=source, sourceDirty=False, sdkAbi=SDK_ABI, publicRelease=True)
        if (not isinstance(info, dict) or info.get('sourceDirty') is not False
                or info.get('publicRelease') is not True or info != expected): raise ValueError('release build identity mismatch: '+name)
        if bound_digest(path) != before: raise ValueError('release executable changed while queried')
        records.append(dict(name=name, **before, build=info))
    return dict(schema='wechat-use/release-manifest/v1', version=version, sourceCommit=source,
                sdkAbi=SDK_ABI, publicRelease=True, artifacts=records)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('list', 'create', 'verify'))
    p.add_argument('--directory', type=Path, default=Path('.'))
    p.add_argument('--version')
    p.add_argument('--source')
    args = p.parse_args()
    if args.command == 'list':
        print('\n'.join(BINARIES)); return
    path = args.directory / MANIFEST
    if args.command == 'create':
        if not args.version or not args.source: p.error('create requires version and source')
        value = collect(args.directory, args.version, args.source)
        fd, temporary = tempfile.mkstemp(prefix='.release-manifest-', dir=args.directory)
        try:
            with os.fdopen(fd, 'w') as output:
                output.write(json.dumps(value, sort_keys=True, indent=2)+'\n')
                output.flush(); os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    else:
        value = json.loads(path.read_bytes())
        actual = collect(args.directory, args.version or value['version'], args.source or value['sourceCommit'])
        if actual != value: raise ValueError('release manifest or artifact mismatch')


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        raise SystemExit('release artifacts refused: missing, changed or inconsistent build identity')
