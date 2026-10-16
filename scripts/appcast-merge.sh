#!/bin/bash
# Prepend one release's <item> to a Sparkle appcast.
#
# Usage: scripts/appcast-merge.sh <existing appcast.xml | ""> <appcast-item.xml> > appcast.xml
#
# <existing> is the live feed (the release workflow fetches it from
# rcam.strawdynamics.com). Pass "" or an empty or missing file to start a new
# feed, e.g. for the very first release. <appcast-item.xml> is the item
# scripts/release.sh writes to build/release/.
#
# Newest first is only convention -- Sparkle picks the highest sparkle:version
# whatever the order -- but it keeps the feed readable. Old items stay, so a
# copy several versions behind still finds the latest.
#
# Line-based on purpose: the feed is only ever written by this script and the
# seed in site/, so every <item> and </channel> starts its own line. The output
# is checked with xmllint before it's printed, so a feed this can't parse fails
# here rather than on users' Macs.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $(basename "$0") <existing appcast.xml | \"\"> <appcast-item.xml> > appcast.xml" >&2
  exit 2
fi
EXISTING="$1"
ITEM="$2"

if [[ ! -s "$ITEM" ]]; then
  echo "error: item file '$ITEM' is missing or empty (scripts/release.sh writes it)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "$EXISTING" && -s "$EXISTING" ]]; then
  cp "$EXISTING" "$work/base.xml"
else
  cat > "$work/base.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>RCam</title>
    <link>https://rcam.strawdynamics.com/appcast.xml</link>
    <description>Updates for RCam.</description>
    <language>en</language>
  </channel>
</rss>
XML
fi

if ! grep -q 'xmlns:sparkle=' "$work/base.xml"; then
  echo "error: '$EXISTING' doesn't declare xmlns:sparkle; is it a Sparkle appcast?" >&2
  exit 1
fi

# Re-running a release must not list the same build twice: Sparkle would offer
# whichever entry it read last, and both point at the same tag.
version="$(sed -n 's:.*<sparkle\:version>\([^<]*\)</sparkle\:version>.*:\1:p' "$ITEM" | head -n 1)"
if [[ -z "$version" ]]; then
  echo "error: '$ITEM' has no <sparkle:version>" >&2
  exit 1
fi
if grep -qF "<sparkle:version>$version</sparkle:version>" "$work/base.xml"; then
  echo "error: '$EXISTING' already has an item for sparkle:version $version" >&2
  exit 1
fi

# Insert before the first existing item, or before </channel> in a feed with
# none yet.
awk -v item="$ITEM" '
  !done && /^[[:space:]]*(<item[[:space:]>]|<\/channel>)/ {
    while ((getline line < item) > 0) print line
    done = 1
  }
  { print }
  END { if (!done) exit 3 }
' "$work/base.xml" > "$work/merged.xml" || {
  echo "error: found neither an <item> nor </channel> line in '$EXISTING' to insert before" >&2
  exit 1
}

if ! xmllint --noout "$work/merged.xml"; then
  echo "error: the merged appcast is not well-formed XML (see xmllint above)" >&2
  exit 1
fi

cat "$work/merged.xml"
