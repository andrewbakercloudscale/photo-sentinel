#!/bin/bash
# Publishes install.sh as the public installer download, then proves what is served.
#
#   bash scripts/publish-installer.sh
#
# Same bucket and pattern as the WordPress plugins' backup-s3.sh: the bucket is private,
# this one object is public-read. "upload: ... to s3://" proves a transfer, not what is
# served, so the script fetches the public URL and compares it byte for byte.
set -euo pipefail

BUCKET="andrewninjawordpress"
REGION="af-south-1"
KEY="photo-sentinel-install.sh"
URL="https://$BUCKET.s3.$REGION.amazonaws.com/$KEY"
SRC="$(cd "$(dirname "$0")/.." && pwd)/install.sh"

command -v aws >/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }
[ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }
bash -n "$SRC" || { echo "ERROR: $SRC has a syntax error" >&2; exit 1; }

AWS_ARGS=( --region "$REGION" )
if aws configure list-profiles 2>/dev/null | grep -qx "personal"; then AWS_ARGS+=( --profile personal ); fi

echo "Uploading $SRC to s3://$BUCKET/$KEY ..."
aws s3 cp "$SRC" "s3://$BUCKET/$KEY" "${AWS_ARGS[@]}" --acl public-read \
  --content-type "text/plain; charset=utf-8" --cache-control "max-age=300" --only-show-errors

SERVED="$(mktemp "${TMPDIR:-/tmp}/ps-installer.XXXXXX")"
trap 'rm -f "$SERVED"' EXIT
curl -fsSL "$URL?nc=$RANDOM" -o "$SERVED"
if ! cmp -s "$SRC" "$SERVED"; then
  echo "ERROR: $URL does not serve the file just uploaded" >&2
  exit 1
fi
echo "Done. $URL serves install.sh ($(wc -c < "$SRC" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$SRC" | cut -c1-12))."
