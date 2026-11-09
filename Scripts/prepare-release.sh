#!/usr/bin/env bash
# Package a built app and sign its version-pinned Sparkle update feed.
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RELEASE_TAG:?Set RELEASE_TAG to the version tag, for example v1.2.2}"
: "${SPARKLE_SDK_DIR:?Set SPARKLE_SDK_DIR to the verified Sparkle SDK directory}"
[[ "$RELEASE_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Invalid stable release tag" >&2; exit 1; }
APP="$ROOT/dist/Fxxking Work.app"
SOURCE_ZIP="$ROOT/dist/Fxxking Work.zip"
OUT="$ROOT/dist/release"
NAME="Fxxking_Work-macos-universal.zip"
VERSION="${RELEASE_TAG#v}"
[ -f "$SOURCE_ZIP" ] || { echo "Build the app with --zip first" >&2; exit 1; }
if [ -z "${SPARKLE_ED_KEY_FILE:-}" ] && [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    echo "An update signing key file or CI signing secret is required" >&2; exit 1
fi
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Fxxking_Work")"
case " $ARCHS " in *" arm64 "*) ;; *) echo "Missing arm64" >&2; exit 1 ;; esac
case " $ARCHS " in *" x86_64 "*) ;; *) echo "Missing x86_64" >&2; exit 1 ;; esac
codesign --verify --deep --strict "$APP"
python3 - "$APP/Contents/Info.plist" "$VERSION" <<'PYTHON'
import base64, plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
assert info['CFBundleShortVersionString'] == sys.argv[2]
assert info['CFBundleVersion'] == sys.argv[2]
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
assert info['SUFeedURL'] == 'https://github.com/cailish-0425/Fxxking_Work/releases/latest/download/appcast.xml'
assert info['SUVerifyUpdateBeforeExtraction'] is True
assert info['SURequireSignedFeed'] is True
assert info['SUSignedFeedFailureExpirationInterval'] == 0
PYTHON
# Preserve an explicitly supplied feed before resetting our staging directory.
mkdir -p "$ROOT/.build"
if [ -n "${PREVIOUS_APPCAST:-}" ]; then
    cp "$PREVIOUS_APPCAST" "$ROOT/.build/previous-appcast-input.xml"
    PREVIOUS_APPCAST="$ROOT/.build/previous-appcast-input.xml"
fi
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$SOURCE_ZIP" "$OUT/$NAME"
ARCHIVES=("$OUT"/*.zip)
[ "${#ARCHIVES[@]}" -eq 1 ] && [ "${ARCHIVES[0]}" = "$OUT/$NAME" ] || { echo "Unexpected release archives" >&2; exit 1; }
# Reuse the previous feed when supplied, preserving older version-pinned items.
if [ -n "${PREVIOUS_APPCAST:-}" ]; then cp "$PREVIOUS_APPCAST" "$OUT/appcast.xml"; fi
python3 - "$ROOT/.github/release-notes.md" "$OUT/Fxxking_Work-macos-universal.html" <<'PYTHON'
from pathlib import Path
import html, sys
notes = Path(sys.argv[1]).read_text().split('## SHA-256')[0].strip()
Path(sys.argv[2]).write_text('<div><pre>'+html.escape(notes)+'</pre></div>')
PYTHON
with_key() {
    if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
        "$1" --ed-key-file "$SPARKLE_ED_KEY_FILE" "${@:2}"
    else
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$1" --ed-key-file - "${@:2}"
    fi
}
if [ -f "$OUT/appcast.xml" ]; then
    with_key "$SPARKLE_SDK_DIR/bin/sign_update" --verify "$OUT/appcast.xml"
    PREVIOUS_VERSIONS=()
    while IFS= read -r value; do PREVIOUS_VERSIONS+=("$value"); done < <(
        python3 - "$OUT/appcast.xml" <<'PYTHON'
import sys, xml.etree.ElementTree as ET
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
for item in ET.parse(sys.argv[1]).getroot().findall('channel/item'):
    version = item.findtext(ns+'version') or item.find('enclosure').get(ns+'version')
    if version: print(version)
PYTHON
    )
    if [ "${#PREVIOUS_VERSIONS[@]}" -gt 0 ]; then
        mkdir -p "$ROOT/.build"
        swiftc -F "$SPARKLE_SDK_DIR" -framework Sparkle \
            -Xlinker -rpath -Xlinker "$SPARKLE_SDK_DIR" \
            -o "$ROOT/.build/check-release-version" "$ROOT/Scripts/check-release-version.swift"
        "$ROOT/.build/check-release-version" "$VERSION" "${PREVIOUS_VERSIONS[@]}"
    fi
fi
with_key "$SPARKLE_SDK_DIR/bin/generate_appcast" \
    --download-url-prefix "https://github.com/cailish-0425/Fxxking_Work/releases/download/$RELEASE_TAG/" \
    --link 'https://github.com/cailish-0425/Fxxking_Work' \
    --maximum-deltas 0 --maximum-versions 0 --embed-release-notes \
    -o "$OUT/appcast.xml" "$OUT"
python3 - "$OUT/appcast.xml" "$OUT/$NAME" "$VERSION" "$APP/Contents/Info.plist" "$OUT/verification.args" <<'PYTHON'
import base64, os, plistlib, sys, xml.etree.ElementTree as ET
feed, archive, version, info_path, output = sys.argv[1:]
ns = {'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(feed).getroot().findall('channel/item')
item = next(i for i in items if i.findtext('s:version', namespaces=ns) == version)
e = item.find('enclosure')
assert e.get('url') == 'https://github.com/cailish-0425/Fxxking_Work/releases/download/v'+version+'/'+os.path.basename(archive)
assert int(e.get('length')) == os.path.getsize(archive)
sig = e.get('{'+ns['s']+'}edSignature')
assert len(base64.b64decode(sig, validate=True)) == 64
with open(info_path, 'rb') as f: key = plistlib.load(f)['SUPublicEDKey']
with open(output, 'w') as f: f.write(key+'\n'+sig+'\n')
PYTHON
PUBLIC_KEY="$(sed -n '1p' "$OUT/verification.args")"
SIGNATURE="$(sed -n '2p' "$OUT/verification.args")"
rm "$OUT/verification.args"
swift -module-cache-path "$ROOT/.build/release-module-cache" \
    "$ROOT/Scripts/verify-update-signature.swift" "$PUBLIC_KEY" "$SIGNATURE" "$OUT/$NAME"
with_key "$SPARKLE_SDK_DIR/bin/sign_update" "$OUT/appcast.xml"
with_key "$SPARKLE_SDK_DIR/bin/sign_update" --verify "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "$NAME" > SHA256SUMS)
(cd "$OUT" && shasum -a 256 -c SHA256SUMS)
unzip -tq "$OUT/$NAME"
echo "Release assets ready in $OUT"
