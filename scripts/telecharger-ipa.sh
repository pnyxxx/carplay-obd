#!/bin/sh
# Télécharge la dernière IPA compilée par GitHub Actions (à installer ensuite avec iloader).
set -e
REPO="${REPO:-pnyxxx/carplay-obd}"
DEST="${1:-$HOME/Téléchargements}"
mkdir -p "$DEST"
curl -fL --progress-bar -o "$DEST/TrackData-unsigned.ipa" \
  "https://github.com/$REPO/releases/download/latest/TrackData-unsigned.ipa"
echo "IPA téléchargée : $DEST/TrackData-unsigned.ipa"
