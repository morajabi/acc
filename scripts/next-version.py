#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

VERSION_FILE = Path(__file__).resolve().parent.parent / 'Sources/AccCore/Version.swift'
PATTERN = re.compile(r'(\d+)\.(\d+)\.(\d+)')


def parse(text):
    match = PATTERN.fullmatch(text)
    if not match:
        raise SystemExit(f'Not a stable version: {text}')
    return tuple(int(part) for part in match.groups())


def floor():
    match = re.search(r'current = "([^"]+)"', VERSION_FILE.read_text())
    if not match:
        raise SystemExit(f'No version in {VERSION_FILE}')
    return parse(match.group(1))


def released():
    tags = subprocess.check_output(['git', 'tag', '--list', 'v*'], text=True).split()
    return [parse(tag[1:]) for tag in tags if PATTERN.fullmatch(tag[1:])]


def next_version():
    versions = released()
    if not versions:
        return floor()
    major, minor, patch = max(versions)
    return max(floor(), (major, minor, patch + 1))


def stamp(version):
    text = VERSION_FILE.read_text()
    VERSION_FILE.write_text(re.sub(r'current = "[^"]+"', f'current = "{version}"', text))


if __name__ == '__main__':
    version = '.'.join(map(str, next_version()))
    if '--stamp' in sys.argv[1:]:
        stamp(version)
    print(version)
