#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_ARGS=("$@")
DEFAULT_SUDO_PASSWORD=qiditech

usage() {
  cat <<'EOF'
Usage: collect-qidi-plus5-firmware-check.sh [options]

Collects the read-only evidence needed to reproduce the QIDI Plus 5 firmware
check. The script does not contact QIDI, install software, restart services, or
change printer configuration.

Options:
  --output-dir DIR   Write temporary results to DIR instead of the current directory.
  --no-binaries      Do not include candidate QIDI client executables.
  -h, --help         Show this help.

Run this directly on an idle printer. It automatically tries QIDI's public
default sudo password, collects the files, sends them to Tuba Makes through
Discord, and removes the local result files after a successful upload.
EOF
}

OUTPUT_DIR=$PWD
INCLUDE_BINARIES=true
CONFIRM_IDLE=true
DEFAULT_UPLOAD_URL=https://contact-api.tubamakes.com/qidi-plus5-collection
UPLOAD_URL=${QIDI_COLLECTION_UPLOAD_URL-$DEFAULT_UPLOAD_URL}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ "$#" -ge 2 ] || { echo "--output-dir requires a value" >&2; exit 2; }
      OUTPUT_DIR=$2
      shift 2
      ;;
    --no-binaries)
      INCLUDE_BINARIES=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "$UPLOAD_URL" ]; then
  case "$UPLOAD_URL" in
    https://*) ;;
    *) echo "Upload URL must use HTTPS" >&2; exit 2 ;;
  esac
fi

# Used only by fixture tests. Real printer runs always use /.
ROOT=${QIDI_COLLECTOR_ROOT:-/}

ensure_root() {
  [ "$ROOT" = "/" ] || return 0
  [ "$EUID" -eq 0 ] && return 0

  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required to inspect the QIDI client." >&2
    exit 1
  fi

  script_path=${BASH_SOURCE[0]}
  if [ ! -f "$script_path" ]; then
    echo "Download this script to a file before running it; it cannot elevate when piped directly to bash." >&2
    exit 1
  fi

  if sudo -n true >/dev/null 2>&1 \
      || printf '%s\n' "$DEFAULT_SUDO_PASSWORD" | sudo -S -p '' true >/dev/null 2>&1; then
    exec sudo -n -- bash "$script_path" "${ORIGINAL_ARGS[@]}"
  fi

  echo "QIDI's default sudo password did not work; sudo may ask for the printer's password." >&2
  exec sudo -- bash "$script_path" "${ORIGINAL_ARGS[@]}"
}

ensure_root

root_path() {
  if [ "$ROOT" = "/" ]; then
    printf '/%s' "${1#/}"
  else
    printf '%s/%s' "${ROOT%/}" "${1#/}"
  fi
}

display_path() {
  case "$1" in
    "$ROOT"/*) printf '/%s' "${1#"$ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

if [ "$ROOT" = "/" ]; then
  PRINT_STATE_JSON=""
  if command -v curl >/dev/null 2>&1; then
    PRINT_STATE_JSON=$(curl -fsS --connect-timeout 2 --max-time 5 \
      'http://127.0.0.1:7125/printer/objects/query?print_stats' 2>/dev/null || true)
  fi

  if printf '%s' "$PRINT_STATE_JSON" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"(printing|paused)"'; then
    echo "Printer is printing or paused; collection aborted." >&2
    exit 1
  fi

  if ! printf '%s' "$PRINT_STATE_JSON" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"(standby|complete|cancelled|error)"'; then
    if [ "$CONFIRM_IDLE" != true ]; then
      echo "Unable to confirm that the printer is idle." >&2
      echo "Verify it is idle, then rerun with --confirm-idle." >&2
      exit 1
    fi
  fi
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
BASENAME="qidi-plus5-firmware-check-$TIMESTAMP"
SECRET_BASENAME="qidi-plus5-device-id-$TIMESTAMP.txt"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/qidi-plus5-collect.XXXXXX")
COLLECTION_DIR="$WORK_DIR/$BASENAME"
SECRET_FILE="$OUTPUT_DIR/$SECRET_BASENAME"
ARCHIVE_FILE="$OUTPUT_DIR/$BASENAME.tar.gz"
SECRET_VALUES="$WORK_DIR/secret-values.txt"
mkdir -p "$COLLECTION_DIR/client-strings" "$COLLECTION_DIR/client-binaries"
chmod 700 "$WORK_DIR" "$COLLECTION_DIR"
: > "$SECRET_VALUES"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

record_secret() {
  local label=$1
  local value=$2
  [ -n "$value" ] || return 0
  printf '%s=%s\n' "$label" "$value" >> "$SECRET_FILE"
  printf '%s\n' "$value" >> "$SECRET_VALUES"
}

{
  echo "QIDI Plus 5 firmware-check device-ID candidates"
  echo ""
  echo "SENSITIVE: send this file privately; never commit or publish it."
  echo "The current Max 4 checker uses the uppercase CPU serial as deviceId."
  echo "Plus 5 client analysis is required to confirm whether it does the same."
  echo ""
} > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"

CPUINFO=$(root_path /proc/cpuinfo)
if [ -r "$CPUINFO" ]; then
  CPU_SERIAL=$(awk -F: 'tolower($1) ~ /^[[:space:]]*serial[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print toupper($2); exit}' "$CPUINFO")
  record_secret cpu_serial_uppercase "$CPU_SERIAL"
fi

DEVICE_TREE_SERIAL=$(root_path /proc/device-tree/serial-number)
if [ -r "$DEVICE_TREE_SERIAL" ]; then
  DT_SERIAL=$(tr -d '\000\r\n ' < "$DEVICE_TREE_SERIAL" 2>/dev/null || true)
  record_secret device_tree_serial "$DT_SERIAL"
fi

for machine_id_path in /etc/machine-id /var/lib/dbus/machine-id; do
  path=$(root_path "$machine_id_path")
  if [ -r "$path" ]; then
    value=$(tr -d '\r\n ' < "$path")
    record_secret "$(printf '%s' "$machine_id_path" | tr '/-' '__')" "$value"
  fi
done

NET_DIR=$(root_path /sys/class/net)
if [ -d "$NET_DIR" ]; then
  for address_file in "$NET_DIR"/*/address; do
    [ -r "$address_file" ] || continue
    interface_name=$(basename "$(dirname "$address_file")")
    [ "$interface_name" != lo ] || continue
    value=$(tr -d '\r\n ' < "$address_file")
    record_secret "mac_$interface_name" "$value"
  done
fi

cat > "$WORK_DIR/sanitize.py" <<'PYTHON'
import pathlib
import re
import sys

secrets_path, source_path, destination_path = map(pathlib.Path, sys.argv[1:4])
secrets = []
if secrets_path.exists():
    secrets = [line.strip() for line in secrets_path.read_text(errors="replace").splitlines() if len(line.strip()) >= 4]

text = source_path.read_text(errors="replace")
for secret in sorted(set(secrets), key=len, reverse=True):
    text = text.replace(secret, "[REDACTED_DEVICE_VALUE]")
    text = text.replace(secret.lower(), "[REDACTED_DEVICE_VALUE]")
    text = text.replace(secret.upper(), "[REDACTED_DEVICE_VALUE]")

text = re.sub(r"(?i)\b(deviceId|X-DeviceId|authorization|cookie|token|password)\b(\s*[:=]\s*)([^\s,;&\"']+)",
              r"\1\2[REDACTED]", text)
text = re.sub(r"(?i)\b(X-Signature)\b(\s*[:=]\s*)([0-9a-f]{16,})", r"\1\2[REDACTED]", text)
ipv4_octet = r"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
text = re.sub(rf"(?<![0-9.]){ipv4_octet}(?:\.{ipv4_octet}){{3}}(?![0-9.])", "[REDACTED_IPV4]", text)
text = re.sub(r"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b", "[REDACTED_MAC]", text)
text = re.sub(r"(https?://[^\s?\"']+)\?[^\s\"']+", r"\1?[REDACTED_QUERY]", text)
destination_path.write_text(text)
PYTHON

sanitize_file() {
  local source=$1
  local destination=$2
  if command -v python3 >/dev/null 2>&1; then
    python3 "$WORK_DIR/sanitize.py" "$SECRET_VALUES" "$source" "$destination"
  else
    cp "$source" "$destination"
    while IFS= read -r secret; do
      [ -n "$secret" ] || continue
      escaped=$(printf '%s' "$secret" | sed 's/[.[\*^$()+?{|/]/\\&/g')
      sed -i "s/$escaped/[REDACTED_DEVICE_VALUE]/g" "$destination"
    done < "$SECRET_VALUES"
  fi
}

cat > "$COLLECTION_DIR/README.txt" <<'EOF'
QIDI Plus 5 firmware-check discovery bundle

This bundle was produced using read-only inspection. It contains system and
firmware-version evidence, targeted strings from likely QIDI update clients,
and (unless disabled) copies of candidate client executables for private static
analysis.

The collector attempts to remove per-printer identifiers, network addresses,
request signatures, tokens, and URL query strings from text evidence. Review
the bundle before sharing it. Do not publish it without separately reviewing
whether redistribution of the included vendor binaries is appropriate.

The device-ID candidates are deliberately stored in a separate sensitive text
file that is not present in this archive.
EOF

SYSTEM_RAW="$WORK_DIR/system.raw"
{
  printf 'collection_time_utc=%s\n' "$TIMESTAMP"
  printf 'collector_user_id=%s\n' "$(id -u 2>/dev/null || echo unknown)"
  printf 'collector_effective_user_id=%s\n' "$(id -u 2>/dev/null || echo unknown)"
  printf 'kernel='; uname -srvm 2>/dev/null || true
  printf 'architecture='; uname -m 2>/dev/null || true
  for os_release in /etc/os-release /usr/lib/os-release; do
    path=$(root_path "$os_release")
    if [ -r "$path" ]; then
      printf '\n[%s]\n' "$os_release"
      grep -E '^(NAME|VERSION|ID|VERSION_ID|PRETTY_NAME)=' "$path" || true
      break
    fi
  done
} > "$SYSTEM_RAW"
sanitize_file "$SYSTEM_RAW" "$COLLECTION_DIR/system.txt"

PACKAGES_RAW="$WORK_DIR/packages.raw"
: > "$PACKAGES_RAW"
if [ "$ROOT" = "/" ] && command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' 2>/dev/null \
    | grep -Ei 'qidi|xindi|makerbase|mks|klipper|moonraker|fluidd' \
    > "$PACKAGES_RAW" || true
else
  DPKG_STATUS=$(root_path /var/lib/dpkg/status)
  if [ -r "$DPKG_STATUS" ]; then
    awk 'BEGIN {RS=""; FS="\n"} tolower($0) ~ /(qidi|xindi|makerbase|mks|klipper|moonraker|fluidd)/ {print $0 "\n"}' \
      "$DPKG_STATUS" > "$PACKAGES_RAW"
  fi
fi
sanitize_file "$PACKAGES_RAW" "$COLLECTION_DIR/packages.txt"

VERSION_RAW="$WORK_DIR/version-evidence.raw"
: > "$VERSION_RAW"
for base_name in /home/mks /home/qidi /root; do
  base=$(root_path "$base_name")
  [ -d "$base" ] || continue
  while IFS= read -r candidate; do
    [ -r "$candidate" ] || continue
    size=$(wc -c < "$candidate" 2>/dev/null || echo 0)
    [ "$size" -le 4194304 ] || continue
    printf '\n[%s]\n' "$(display_path "$candidate")" >> "$VERSION_RAW"
    grep -aEi 'version|firmware|hardware|machine|model|region|device.?type|soc|plus.?5|qd[_-]' \
      "$candidate" 2>/dev/null | head -n 200 >> "$VERSION_RAW" || true
  done < <(find "$base" -type f \( \
      -iname 'firmware_manifest.json' -o \
      -iname '*version*.txt' -o \
      -iname '*version*.json' -o \
      -iname 'config.mksini' -o \
      -iname 'dev_info.txt' -o \
      -iname 'iso_version.txt' \
    \) 2>/dev/null)
done
sanitize_file "$VERSION_RAW" "$COLLECTION_DIR/version-evidence.txt"

CLIENT_LIST="$WORK_DIR/client-paths.txt"
: > "$CLIENT_LIST"
for base_name in /home/mks /home/qidi /root; do
  base=$(root_path "$base_name")
  [ -d "$base" ] || continue
  find "$base" -type f \( \
      -iname 'qidiclient' -o \
      -iname 'qidi_client' -o \
      -iname 'xindi' -o \
      -iname 'mksclient' \
    \) -print 2>/dev/null >> "$CLIENT_LIST" || true
done

if [ "$ROOT" = "/" ] && [ -d /proc ]; then
  for executable_link in /proc/[0-9]*/exe; do
    target=$(readlink "$executable_link" 2>/dev/null || true)
    case "$target" in
      *[Qq][Ii][Dd][Ii]*|*[Xx][Ii][Nn][Dd][Ii]*|*[Mm][Kk][Ss][Cc][Ll][Ii][Ee][Nn][Tt]*)
        [ -f "$target" ] && printf '%s\n' "$target" >> "$CLIENT_LIST"
        ;;
    esac
  done
fi

sort -u "$CLIENT_LIST" -o "$CLIENT_LIST"
CLIENT_METADATA_RAW="$WORK_DIR/client-candidates.raw"
: > "$CLIENT_METADATA_RAW"
CLIENT_INDEX=0
BINARY_BYTES_INCLUDED=0
MAX_INCLUDED_BINARY_BYTES=73400320
while IFS= read -r client; do
  [ -r "$client" ] || continue
  CLIENT_INDEX=$((CLIENT_INDEX + 1))
  client_name=$(basename "$client" | tr -c 'A-Za-z0-9._-' '_')
  digest=$(sha256_file "$client")
  size=$(wc -c < "$client" 2>/dev/null || echo unknown)
  evidence_name=$(printf '%02d-%s-%s.txt' "$CLIENT_INDEX" "$client_name" "${digest:0:16}")

  {
    printf 'path=%s\n' "$(display_path "$client")"
    printf 'size=%s\n' "$size"
    printf 'sha256=%s\n' "$digest"
    if command -v file >/dev/null 2>&1; then
      printf 'file='; file -b "$client" 2>/dev/null || true
    fi
    printf 'strings_evidence=%s\n' "client-strings/$evidence_name"
  } >> "$CLIENT_METADATA_RAW"

  strings_raw="$WORK_DIR/client-strings-$CLIENT_INDEX.raw"
  : > "$strings_raw"
  if command -v strings >/dev/null 2>&1; then
    strings -a "$client" 2>/dev/null \
      | grep -Ei 'upgrade-info|fireware|firmware|api\.qidi|api-cn|currentVersion|deviceId|X-Device|X-Platform|X-Region|X-Version|X-Timezone|X-Signature|User-Agent|xindi/[0-9]|QD[_-][A-Za-z0-9_.-]+|PLUS.?5|qidi3d null|CAFE-BABE' \
      | head -n 2000 > "$strings_raw" || true
  fi
  sanitize_file "$strings_raw" "$COLLECTION_DIR/client-strings/$evidence_name"

  if [ "$INCLUDE_BINARIES" = true ] && [ "$size" != unknown ] \
      && [ $((BINARY_BYTES_INCLUDED + size)) -le "$MAX_INCLUDED_BINARY_BYTES" ]; then
    cp "$client" "$COLLECTION_DIR/client-binaries/$(printf '%02d-%s-%s' "$CLIENT_INDEX" "$client_name" "${digest:0:16}")"
    BINARY_BYTES_INCLUDED=$((BINARY_BYTES_INCLUDED + size))
  elif [ "$INCLUDE_BINARIES" = true ]; then
    printf 'binary_copy=skipped-to-keep-upload-under-size-limit\n' >> "$CLIENT_METADATA_RAW"
  fi
done < "$CLIENT_LIST"
sanitize_file "$CLIENT_METADATA_RAW" "$COLLECTION_DIR/client-candidates.txt"

LOG_RAW="$WORK_DIR/update-log-evidence.raw"
: > "$LOG_RAW"
for log_name in \
  /tmp/*.log \
  /home/mks/printer_data/logs/*.log \
  /home/qidi/printer_data/logs/*.log; do
  log_path=$(root_path "$log_name")
  for log_file in $log_path; do
    [ -f "$log_file" ] && [ -r "$log_file" ] || continue
    size=$(wc -c < "$log_file" 2>/dev/null || echo 0)
    [ "$size" -le 20971520 ] || continue
    matches=$(grep -aEi 'upgrade-info|fireware|firmware (check|update)|currentVersion|X-Device|版本请求' "$log_file" 2>/dev/null \
      | tail -n 200 || true)
    if [ -n "$matches" ]; then
      printf '\n[%s]\n%s\n' "$(display_path "$log_file")" "$matches" >> "$LOG_RAW"
    fi
  done
done
sanitize_file "$LOG_RAW" "$COLLECTION_DIR/update-log-evidence.txt"

if [ "$INCLUDE_BINARIES" != true ]; then
  rmdir "$COLLECTION_DIR/client-binaries"
fi

chmod -R go-rwx "$COLLECTION_DIR"
tar -C "$WORK_DIR" -czf "$ARCHIVE_FILE" "$BASENAME"
chmod 600 "$ARCHIVE_FILE"

printf 'Created investigation bundle: %s\n' "$ARCHIVE_FILE"
printf 'Created sensitive ID file:    %s\n' "$SECRET_FILE"

if [ -n "$UPLOAD_URL" ]; then
  command -v curl >/dev/null 2>&1 || { echo "curl is required for upload" >&2; exit 1; }
  command -v split >/dev/null 2>&1 || { echo "split is required for upload" >&2; exit 1; }

  SUBMISSION_BASENAME="qidi-plus5-submission-$TIMESTAMP.tar.gz"
  SUBMISSION_DIR="$WORK_DIR/submission"
  SUBMISSION_FILE="$WORK_DIR/$SUBMISSION_BASENAME"
  CHUNK_DIR="$WORK_DIR/chunks"
  UPLOAD_RESPONSE="$WORK_DIR/upload-response.txt"
  mkdir -p "$SUBMISSION_DIR" "$CHUNK_DIR"
  cp "$ARCHIVE_FILE" "$SECRET_FILE" "$SUBMISSION_DIR/"
  {
    printf '%s  %s\n' "$(sha256_file "$ARCHIVE_FILE")" "$(basename "$ARCHIVE_FILE")"
    printf '%s  %s\n' "$(sha256_file "$SECRET_FILE")" "$(basename "$SECRET_FILE")"
  } > "$SUBMISSION_DIR/SHA256SUMS"
  tar -C "$SUBMISSION_DIR" -czf "$SUBMISSION_FILE" .
  SUBMISSION_SHA256=$(sha256_file "$SUBMISSION_FILE")
  COLLECTION_ID="$TIMESTAMP-${SUBMISSION_SHA256:0:16}"

  # Discord's default attachment limit is larger than each 7 MiB part. Keeping
  # each request small also stays well below the Worker's request-body limit.
  split -b 7340032 -d -a 4 "$SUBMISSION_FILE" "$CHUNK_DIR/part-"
  CHUNKS=("$CHUNK_DIR"/part-*)
  PART_COUNT=${#CHUNKS[@]}

  for index in "${!CHUNKS[@]}"; do
    chunk=${CHUNKS[$index]}
    PART_NUMBER=$((index + 1))
    CHUNK_SHA256=$(sha256_file "$chunk")
    CURL_CONFIG="$WORK_DIR/upload-$PART_NUMBER.curl.conf"

    {
      printf 'url = "%s"\n' "$UPLOAD_URL"
      printf 'header = "Content-Type: application/octet-stream"\n'
      printf 'header = "X-Collection-Id: %s"\n' "$COLLECTION_ID"
      printf 'header = "X-Collection-Filename: %s"\n' "$SUBMISSION_BASENAME"
      printf 'header = "X-Collection-SHA256: %s"\n' "$SUBMISSION_SHA256"
      printf 'header = "X-Chunk-SHA256: %s"\n' "$CHUNK_SHA256"
      printf 'header = "X-Chunk-Number: %s"\n' "$PART_NUMBER"
      printf 'header = "X-Chunk-Count: %s"\n' "$PART_COUNT"
      printf 'header = "Expect:"\n'
      printf 'fail-with-body\n'
      printf 'silent\n'
      printf 'show-error\n'
      printf 'retry = 4\n'
      printf 'retry-all-errors\n'
      printf 'retry-delay = 2\n'
      printf 'connect-timeout = 15\n'
      printf 'max-time = 180\n'
    } > "$CURL_CONFIG"
    chmod 600 "$CURL_CONFIG"

    if ! curl --config "$CURL_CONFIG" --upload-file "$chunk" --output "$UPLOAD_RESPONSE"; then
      echo "Upload failed on part $PART_NUMBER of $PART_COUNT. Local result files were retained." >&2
      exit 1
    fi
    printf 'Uploaded part %s of %s.\n' "$PART_NUMBER" "$PART_COUNT"
    sleep 1
  done

  printf 'Upload completed successfully. Collection ID: %s\n' "$COLLECTION_ID"
  rm -f "$ARCHIVE_FILE" "$SECRET_FILE"
  printf 'Removed local result files after successful upload.\n'
else
  printf '\nUpload disabled for this run; review both local result files before sharing them.\n'
fi

if [ "$0" = /tmp/qidi-plus5-collect.sh ]; then
  rm -f -- "$0"
fi
