#!/usr/bin/env bash
#
# Uploads a plugin package to GLPI as a Document attached to the plugin's Software,
# through the High-Level API (v2) route that Gapp Xtended adds:
#   POST /api.php/v2.3/Gapp/Assets/Software/{id}/Document
# (the core's own POST /Management/Document leaves the document empty).
# The document's entity and recursion are taken from the Software by the route.
#
# Usage: glpi-upload.sh <package-file> <version>
#
# Environment:
#   GLPI_URL             Base URL of the GLPI instance, without trailing slash.
#   GLPI_CLIENT_ID       Identifier of the OAuth client (password grant, scope "api").
#   GLPI_CLIENT_SECRET   Secret of the OAuth client.
#   GLPI_USERNAME        Login of the GLPI service user (needs software read/update
#                        and document create rights).
#   GLPI_PASSWORD        Password of that user.
#   GLPI_SOFTWARE_ID     Id of the plugin's Software in GLPI.
#   GLPI_DOCUMENT_CATEGORY_ID  Optional, id of the document heading ("TICGAL Plugins")
#                        given to the document. Needs the update right on documents.
#   GLPI_REQUEST_TIMEOUT / GLPI_UPLOAD_TIMEOUT  Seconds allowed to each request (default
#                        60) and to the file upload (default 600).
#   GLPI_INSECURE_TLS    "true" to accept self-signed certificates (tests only).
#   RELEASE_URL          Optional, link to the GitHub release, stored in the document's
#                        "Web link" field (must be a valid URL, 255 characters at most).
#   NOTES_FILE           Optional, changelog entry used as the document comment.
#   NAME                 Plugin display name (e.g. "More Security"); the document
#                        is named "<NAME> <version>". Defaults to the file name.

set -euo pipefail

file=${1:?package file required}
version=${2:?version required}
: "${GLPI_URL:?GLPI_URL is not set}"
: "${GLPI_CLIENT_ID:?GLPI_CLIENT_ID is not set}"
: "${GLPI_CLIENT_SECRET:?GLPI_CLIENT_SECRET is not set}"
: "${GLPI_USERNAME:?GLPI_USERNAME is not set}"
: "${GLPI_PASSWORD:?GLPI_PASSWORD is not set}"
: "${GLPI_SOFTWARE_ID:?GLPI_SOFTWARE_ID is not set}"

[[ "$GLPI_SOFTWARE_ID" =~ ^[1-9][0-9]*$ ]] || { echo "::error::GLPI_SOFTWARE_ID must be a positive integer"; exit 1; }
if [ -n "${GLPI_DOCUMENT_CATEGORY_ID:-}" ]; then
  [[ "$GLPI_DOCUMENT_CATEGORY_ID" =~ ^[1-9][0-9]*$ ]] || { echo "::error::GLPI_DOCUMENT_CATEGORY_ID must be a positive integer"; exit 1; }
fi
[ -s "$file" ] || { echo "::error::Package $file not found or empty"; exit 1; }

base="${GLPI_URL%/}/api.php"
name=$(basename "$file")

curl_opts=(--silent --show-error --connect-timeout 20 --max-time "${GLPI_REQUEST_TIMEOUT:-60}")
[ "${GLPI_INSECURE_TLS:-false}" = "true" ] && curl_opts+=(--insecure)

# Secrets must never reach the logs, even if something echoed them back.
for secret in "$GLPI_CLIENT_ID" "$GLPI_CLIENT_SECRET" "$GLPI_USERNAME" "$GLPI_PASSWORD"; do
  echo "::add-mask::${secret}"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# First 300 characters of a response body, on one line and without HTML tags
# (a proxy or PHP limit answers with a whole page).
excerpt() { tr '\n' ' ' < "$1" | sed -e 's/<[^>]*>//g' -e 's/  */ /g' | cut -c1-300; }

echo "Requesting an OAuth token from ${GLPI_URL%/}"
# Credentials go through temporary files (name@file), not through the command line,
# so they never show up in the process list.
printf '%s' "$GLPI_CLIENT_ID"     > "$tmp/client_id"
printf '%s' "$GLPI_CLIENT_SECRET" > "$tmp/client_secret"
printf '%s' "$GLPI_USERNAME"      > "$tmp/username"
printf '%s' "$GLPI_PASSWORD"      > "$tmp/password"
auth_args=(
  --data-urlencode "grant_type=password" --data-urlencode "scope=api"
  --data-urlencode "client_id@$tmp/client_id" --data-urlencode "client_secret@$tmp/client_secret"
  --data-urlencode "username@$tmp/username" --data-urlencode "password@$tmp/password"
)
code=$(curl "${curl_opts[@]}" -D "$tmp/token.headers" -o "$tmp/token.json" -w '%{http_code}' "${auth_args[@]}" "${base}/token") \
  || { echo "::error::Could not reach ${GLPI_URL%/} to request the token (curl exit $?)"; exit 1; }
if [[ "$code" =~ ^3 ]]; then
  # Never follow it: the credentials would be sent again to wherever it points.
  echo "::error::${GLPI_URL%/} redirects (HTTP $code) to $(tr -d '\r' < "$tmp/token.headers" | sed -n 's/^[Ll]ocation: //p' | head -n1 || true); set GLPI_URL to the final address."
  exit 1
fi
if [ "$code" != "200" ]; then
  echo "::error::Token request failed (HTTP $code): $(jq -r '.error_description // .error // empty' "$tmp/token.json" 2>/dev/null || excerpt "$tmp/token.json")"
  exit 1
fi
token=$(jq -r '.access_token // empty' "$tmp/token.json")
[ -n "$token" ] || { echo "::error::The token response has no access_token"; exit 1; }
echo "::add-mask::${token}"
auth_header="Authorization: Bearer ${token}"

# A server without Gapp Xtended 4.0.0-beta.20 would accept the request and drop the
# comment and the web link: refuse to upload there.
code=$(curl "${curl_opts[@]}" -o "$tmp/caps.json" -w '%{http_code}' -H "$auth_header" "${base}/v2.3/Gapp/Capabilities") \
  || { echo "::error::Could not reach GLPI to read its capabilities (curl exit $?)"; exit 1; }
if [ "$code" != "200" ] || [ "$(jq -r '.features.software_document_details // false' "$tmp/caps.json" 2>/dev/null || true)" != "true" ]; then
  echo "::error::GLPI does not offer the Software document upload with comment and link (Gapp Xtended >= 4.0.0-beta.20 is required). Capabilities HTTP $code."
  exit 1
fi

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

# Document heading: the Xtended route does not take it, so it is set afterwards with the
# core API. GLPI answers 200 even for a heading that does not exist, hence the check.
set_category() {
  local docid=$1
  [ -n "${GLPI_DOCUMENT_CATEGORY_ID:-}" ] || return 0
  local c
  c=$(curl "${curl_opts[@]}" -X PATCH -H "$auth_header" -H 'Content-Type: application/json' \
    --data "{\"category\":{\"id\":${GLPI_DOCUMENT_CATEGORY_ID}}}" -o "$tmp/category.json" -w '%{http_code}' \
    "${base}/v2.3/Management/Document/${docid}") \
    || { echo "::error::Could not set the heading of Document #${docid} (curl exit $?)"; exit 1; }
  if [ "$c" != "200" ]; then
    echo "::error::Setting the heading of Document #${docid} failed (HTTP $c): $(excerpt "$tmp/category.json"). The document exists; fix the cause and re-run the job."
    exit 1
  fi
  if [ "$(jq -r '.category.id // empty' "$tmp/category.json")" != "$GLPI_DOCUMENT_CATEGORY_ID" ]; then
    echo "::error::Document #${docid} did not get the heading ${GLPI_DOCUMENT_CATEGORY_ID}: does it exist, and may the user see it? Re-run the job after fixing it."
    exit 1
  fi
  echo "Document #${docid} filed under the heading #${GLPI_DOCUMENT_CATEGORY_ID}"
}

# Idempotency: GLPI does not reject a second document with the same file, so a
# re-run of this job would duplicate it. Look for the file name first (it is built
# from the plugin key and the version; only safe characters go into the filter).
expected=$(sha1sum "$file" | cut -d' ' -f1)
if [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  code=$(curl "${curl_opts[@]}" -G -o "$tmp/existing.json" -w '%{http_code}' -H "$auth_header" \
    --data-urlencode "filter=filename==\"${name}\"" "${base}/v2.3/Management/Document") \
    || { echo "::error::Could not reach GLPI to look for an existing document (curl exit $?)"; exit 1; }
  if [ "$code" != "200" ]; then
    echo "::error::Looking for an existing document failed (HTTP $code): $(excerpt "$tmp/existing.json")"
    exit 1
  fi
  same=$(jq -r --arg s "$expected" '[.[] | select((.is_deleted // false) == false and .sha1sum == $s)] | first | .id // empty' "$tmp/existing.json")
  other=$(jq -r --arg s "$expected" '[.[] | select((.is_deleted // false) == false and .sha1sum != $s)] | first | .id // empty' "$tmp/existing.json")
  if [ -n "$same" ]; then
    echo "::notice::${name} is already in GLPI as Document #${same} (same SHA-1); nothing to upload."
    set_category "$same"
    exit 0
  fi
  if [ -n "$other" ]; then
    echo "::error::GLPI already has a document named ${name} (Document #${other}) with different content. Delete it in GLPI or bump the version."
    exit 1
  fi
else
  echo "::warning::File name '${name}' has unusual characters; skipping the duplicate check."
fi

doc_name="${NAME:+${NAME} ${version}}"
doc_name="${doc_name:-${name%.tar.bz2}}"

# Optional fields go in with --form-string so that no value is read as a file or an option.
form=(-F "file=@${file}" --form-string "name=${doc_name}" --form-string "comment=${comment}")
[ -n "${RELEASE_URL:-}" ] && form+=(--form-string "link=${RELEASE_URL}")

echo "Uploading ${name} to Software #${GLPI_SOFTWARE_ID}"
code=$(curl "${curl_opts[@]}" --max-time "${GLPI_UPLOAD_TIMEOUT:-600}" -o "$tmp/doc.json" -w '%{http_code}' -H "$auth_header" \
  "${form[@]}" "${base}/v2.3/Gapp/Assets/Software/${GLPI_SOFTWARE_ID}/Document") \
  || { rc=$?; echo "::error::The upload to GLPI was interrupted (curl exit ${rc}$([ "$rc" = 28 ] && echo ', timeout: raise GLPI_UPLOAD_TIMEOUT' || true))"; exit 1; }

if [ "$code" = "413" ]; then
  echo "::error::GLPI refused the package as too large (HTTP 413): $(wc -c < "$file") bytes; check upload_max_filesize and post_max_size of the GLPI server (GET /Gapp/Documents/Constraints reports max_size)."
  exit 1
fi
if [ "$code" != "201" ]; then
  echo "::error::Document upload failed (HTTP $code): $(excerpt "$tmp/doc.json")"
  exit 1
fi

# A 201 without documents_id is the core's empty creation, not a success.
id=$(jq -r '.documents_id // empty' "$tmp/doc.json")
[ -n "$id" ] || { echo "::error::GLPI answered 201 without documents_id; the upload cannot be trusted: $(excerpt "$tmp/doc.json")"; exit 1; }

# GLPI stores the file and reports its SHA-1: it must be the one of the package.
actual=$(jq -r '.sha1sum // empty' "$tmp/doc.json")
if [ "$actual" != "$expected" ]; then
  echo "::error::Document #${id} was created but its SHA-1 (${actual:-none}) is not the package's (${expected})."
  exit 1
fi

echo "Uploaded to GLPI as Document #${id} of Software #${GLPI_SOFTWARE_ID}"
set_category "$id"
