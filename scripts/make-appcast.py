#!/usr/bin/env python3
import os
import plistlib
import re
import subprocess
import sys
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import quoteattr, escape

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = 'https://github.com/morajabi/acc'
SIGN_UPDATE = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'


def signature(archive, key):
    output = subprocess.run([str(SIGN_UPDATE), '--ed-key-file', '-', str(archive)],
        input=key, capture_output=True, text=True, check=True).stdout
    match = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', output)
    if not match:
        raise SystemExit('sign_update did not return a signature.')
    return match.group(1), match.group(2)


def appcast(info, tag, edsignature, length):
    version = info['CFBundleShortVersionString']
    item = f'''    <item>
      <title>{escape(f"Acc {version}")}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(info["CFBundleVersion"])}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(info["LSMinimumSystemVersion"])}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(f"{REPOSITORY}/releases/tag/{tag}")}</sparkle:fullReleaseNotesLink>
      <enclosure url={quoteattr(f"{REPOSITORY}/releases/download/{tag}/Acc-macOS.zip")} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(edsignature)}/>
    </item>'''
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Acc</title>
    <link>{REPOSITORY}</link>
{item}
  </channel>
</rss>
'''


def main():
    key = os.environ.get('SPARKLE_PRIVATE_KEY', '').strip()
    if not key:
        raise SystemExit('SPARKLE_PRIVATE_KEY is required to sign the update feed.')
    tag = os.environ['ACC_RELEASE_TAG']
    release = ROOT / 'dist/release'
    archive = release / 'Acc-macOS.zip'
    info = plistlib.loads((ROOT / 'dist/Acc.app/Contents/Info.plist').read_bytes())
    if tag != f'v{info["CFBundleShortVersionString"]}':
        raise SystemExit('Release tag must match the app version.')
    edsignature, length = signature(archive, key)
    if int(length) != archive.stat().st_size:
        raise SystemExit('Signed length does not match the archive.')
    (release / 'appcast.xml').write_text(appcast(info, tag, edsignature, length))
    print(release / 'appcast.xml')


if __name__ == '__main__':
    sys.exit(main())
