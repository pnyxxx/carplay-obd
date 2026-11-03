#!/bin/sh
# Télécharge la dernière IPA compilée par GitHub Actions (à installer ensuite avec iloader).
set -e
REPO="${REPO:-pnyxxx/carplay-obd}"
DEST="${1:-$HOME/Téléchargements}"
mkdir -p "$DEST"
curl -fL --progress-bar -o "$DEST/TrackGauge-unsigned.ipa" \
  "https://github.com/$REPO/releases/download/latest/TrackGauge-unsigned.ipa"
echo "IPA téléchargée : $DEST/TrackGauge-unsigned.ipa"
