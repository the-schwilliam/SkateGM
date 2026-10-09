"""Download vgmstream into gm_skategm/prebuilt/vgmstream/.

    python tools/fetch_vgmstream.py

The installer decodes Skate 3's own skateboard sounds from the player's
game with it (exporter/tools/asset_pipeline/skate3_sounds.py); it isn't installed into Garry's Mod.
Pinned release, checked by SHA-256.
"""
import hashlib
import io
import os
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'gm_skategm', 'prebuilt', 'vgmstream')

TAG = 'r2117'
ZIP = 'https://github.com/vgmstream/vgmstream/releases/download/%s/vgmstream-win64.zip' % TAG
ZIP_SHA = '6c4a8a3813864fefed081bbd337dbc0ad93bf88e0b92f5db98d7ab258b22dc6c'


def main():
    data = urllib.request.urlopen(ZIP, timeout=120).read()
    if hashlib.sha256(data).hexdigest() != ZIP_SHA:
        raise SystemExit('%s: checksum mismatch' % ZIP)
    os.makedirs(OUT, exist_ok=True)
    zipfile.ZipFile(io.BytesIO(data)).extractall(OUT)
    print('vgmstream %s in %s' % (TAG, OUT))


if __name__ == '__main__':
    main()
