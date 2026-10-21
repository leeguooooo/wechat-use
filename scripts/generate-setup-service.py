#!/usr/bin/env python3
"""Generate the versioned helper from the independent canonical service source.

The SDK-only installer deliberately has no service-repair functions. This
producer must never fall back to old installer functions or a generated helper.
"""
import argparse
import base64
import os
from pathlib import Path
import re
import stat

TOKEN = '@WECHAT_SETUP_VERSION@'
MARKER = '# wechat-use/setup-service-source/v1\n'


def generate(source, version):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('invalid release version')
    before = source.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > 65536:
        raise ValueError('canonical service source required')
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        raw = stream.read(65537)
        after = os.fstat(stream.fileno())
    stamp = lambda m: (m.st_dev, m.st_ino, m.st_size, m.st_mtime_ns, m.st_ctime_ns, m.st_nlink)
    if stamp(before) != stamp(after) or stamp(before) != stamp(source.lstat()):
        raise ValueError('canonical service source changed')
    text = raw.decode('utf-8')
    if (len(raw) > 65536 or '\0' in text or not text.startswith('#!/bin/bash\n' + MARKER)
            or text.count(TOKEN) != 1
            or "readonly WECHAT_SETUP_VERSION='" + TOKEN + "'\n" not in text):
        raise ValueError('canonical service source schema refused')
    installer = source.parent / 'install.sh'
    if not installer.exists(): installer = source.parent.parent / 'install.sh'
    raw_installer = installer.read_bytes()
    library = raw_installer.split(b"<<'PYINSTALL'\n", 1)[1].split(b'\nPYINSTALL', 1)[0]
    if text.count('@SDK_INSTALLER_SOURCE_BASE64@') != 1 or text.count('@WECHAT_SETUP_VERSION_RUNTIME@') != 1:
        raise ValueError('service runtime template missing')
    return (text.replace(TOKEN, version).replace('@WECHAT_SETUP_VERSION_RUNTIME@', version)
            .replace('@SDK_INSTALLER_SOURCE_BASE64@', base64.b64encode(library).decode('ascii')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='scripts/setup-service-source.sh.in from the release commit')
    parser.add_argument('output', type=Path)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    try:
        helper = generate(args.source, args.version)
        if args.output.is_symlink():
            raise ValueError('helper output symlink refused')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(helper)
        args.output.chmod(0o755)
    except (OSError, ValueError, UnicodeError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
