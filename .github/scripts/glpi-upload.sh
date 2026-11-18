#!/usr/bin/env bash
#
# Uploads a plugin package to GLPI as a Document, through the legacy REST API
# (the High-Level API has no endpoint to upload file contents).
#
# Usage: glpi-upload.sh <package-file> <version>
#
# Environment:
#   GLPI_URL            Base URL of the GLPI instance, without trailing slash.
#   GLPI_USER_TOKEN     API token (remote access key) of the GLPI user.
#   GLPI_APP_TOKEN      Optional application token of the API client.
#   GLPI_INSECURE_TLS   "true" to accept self-signed certificates (tests only).
#   RELEASE_URL         Optional, link to the GitHub release, stored in the document's
#                       "Web link" field (must be a valid URL, 255 characters at most).
#   NOTES_FILE          Optional, changelog entry used as the document comment.
#   NAME                Plugin display name (e.g. "More Security"); the document
#                       is named "<NAME> <version>". Defaults to the file name.

set -euo pipefail

file=${1:?package file required}
version=${2:?version required}
: "${GLPI_URL:?GLPI_URL is not set}"
: "${GLPI_USER_TOKEN:?GLPI_USER_TOKEN is not set}"

[ -s "$file" ] || { echo "::error::Package $file not found or empty"; exit 1; }

base="${GLPI_URL%/}/apirest.php"
name=$(basename "$file")

curl_opts=(--silent --show-error --max-time 120)
[ "${GLPI_INSECURE_TLS:-false}" = "true" ] && curl_opts+=(--insecure)

headers=()
[ -n "${GLPI_APP_TOKEN:-}" ] && headers+=(-H "App-Token: ${GLPI_APP_TOKEN}")

# The token must never reach the logs, even if it were echoed back.
echo "::add-mask::${GLPI_USER_TOKEN}"
[ -n "${GLPI_APP_TOKEN:-}" ] && echo "::add-mask::${GLPI_APP_TOKEN}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Opening GLPI API session on ${GLPI_URL%/}"
code=$(curl "${curl_opts[@]}" -o "$tmp/session.json" -w '%{http_code}' \
  "${headers[@]}" -H "Authorization: user_token ${GLPI_USER_TOKEN}" \
  "${base}/initSession")
if [ "$code" != "200" ]; then
  echo "::error::initSession failed (HTTP $code): $(head -c 300 "$tmp/session.json")"
  exit 1
fi
session=$(jq -r '.session_token // empty' "$tmp/session.json")
[ -n "$session" ] || { echo "::error::initSession returned no session_token"; exit 1; }
echo "::add-mask::${session}"

kill_session() {
  curl "${curl_opts[@]}" -o /dev/null "${headers[@]}" -H "Session-Token: ${session}" "${base}/killSession" || true
}
trap 'kill_session; rm -rf "$tmp"' EXIT

# Comment = changelog entry of the version.
# The comment column is TEXT (65535 bytes): an entry above the safe limit is cut
# at a line boundary and the note says the release has the full text.
max_bytes=60000
if [ -n "${NOTES_FILE:-}" ] && [ -s "$NOTES_FILE" ]; then
  comment=$(cat "$NOTES_FILE")
else
  comment="Package built by GitHub Actions."
fi
truncated=false
if [ "$(wc -c <<<"$comment")" -gt "$max_bytes" ]; then
  # Here-strings (no pipe into head): an early-closing pipe would trip pipefail.
  comment=$(sed '$d' <<<"$(head -c "$max_bytes" <<<"$comment")")
  truncated=true
  echo "::warning::Changelog entry exceeds ${max_bytes} bytes; the GLPI comment is truncated (the release has it in full)."
fi
[ "$truncated" = "true" ] && comment="${comment}"$'\n'"[...] truncated, the full text is in the GitHub release"

doc_name="${NAME:+${NAME} ${version}}"
doc_name="${doc_name:-${name%.tar.bz2}}"
manifest=$(jq -nc --arg n "$doc_name" --arg c "$comment" --arg f "$name" --arg l "${RELEASE_URL:-}" \
  '{input: ({name: $n, comment: $c, _filename: [$f]} + (if $l == "" then {} else {link: $l} end))}')

echo "Uploading ${name}"
code=$(curl "${curl_opts[@]}" -o "$tmp/doc.json" -w '%{http_code}' \
  "${headers[@]}" -H "Session-Token: ${session}" \
  -F "uploadManifest=${manifest};type=application/json" \
  -F "filename[0]=@${file}" \
  "${base}/Document")

if [ "$code" != "201" ]; then
  echo "::error::Document upload failed (HTTP $code): $(head -c 500 "$tmp/doc.json")"
  exit 1
fi

id=$(jq -r '.id // empty' "$tmp/doc.json")
echo "Uploaded to GLPI as Document #${id:-?}"
