#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?version required}"
ZIP_PATH="${2:?zip path required}"
DOWNLOAD_URL="${3:?download url required}"
ED_SIGNATURE="${4:-${SPARKLE_ED_SIGNATURE:-}}"
OUTPUT_PATH="${5:-docs/appcast.xml}"
RELEASE_NOTES_URL="${6:-https://github.com/Narcissus-tazetta/LiveWallpaper/releases}"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "zip not found: $ZIP_PATH" >&2
  exit 1
fi

if [[ -z "$ED_SIGNATURE" ]]; then
  echo "Sparkle edSignature is required as arg4 or SPARKLE_ED_SIGNATURE env" >&2
  exit 1
fi

if [[ "$ED_SIGNATURE" == *"BEGIN PUBLIC KEY"* ]] || [[ "$ED_SIGNATURE" == *"END PUBLIC KEY"* ]]; then
  echo "edSignature looks like a public key PEM. Provide ZIP signature, not public key." >&2
  exit 1
fi

if [[ ${#ED_SIGNATURE} -lt 80 ]]; then
  echo "edSignature is too short. It may be a public key or invalid value." >&2
  exit 1
fi

LENGTH=$(stat -f%z "$ZIP_PATH")
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S %z")

mkdir -p "$(dirname "$OUTPUT_PATH")"

cat > "$OUTPUT_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
  xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
  xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>LiveWallpaper Updates</title>
    <link>https://github.com/Narcissus-tazetta/LiveWallpaper/releases</link>
    <description>LiveWallpaper updates</description>
    <language>ja</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${ED_SIGNATURE}"
        sparkle:version="${VERSION}"
        sparkle:shortVersionString="${VERSION}"
        length="${LENGTH}"
        type="application/octet-stream"/>
      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>
    </item>
  </channel>
</rss>
XML

echo "Generated: $OUTPUT_PATH"
