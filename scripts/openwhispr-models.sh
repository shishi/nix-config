#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  printf 'Usage: bash openwhispr-models.sh MANIFEST_JSON STATE_DIRECTORY\n' >&2
  exit 65
fi

manifest=$1
state_directory=$2
if ! manifest_values=$(jq -ers '
  def hex: type == "string" and test("\\A[0-9a-fA-F]+\\z");
  def model_url: type == "string" and test("\\A(https|file)://[^[:space:][:cntrl:]]+\\z");

  select(length == 1)
  | .[0]
  | select(type == "object" and (.generation | hex))
  | select((.models | type) == "array")
  | select(([.models[].name] | sort) == ["cleanup.gguf", "whisper.bin"])
  | select(all(.models[]; (.sha256 | hex and length == 64) and (.url | model_url)))
  | .generation, (.models[] | [.name, (.sha256 | ascii_downcase), .url] | join("\t"))
' -- "$manifest"); then
  printf 'Invalid model manifest %s. Check the generation and both model definitions.\n' "$manifest" >&2
  exit 65
fi

{
  read -r generation
  destination="$state_directory/$generation"
  # The preparation unit is the sole writer, including after an interrupted boot.
  for abandoned in "$state_directory"/.download.*; do
    [[ -d "$abandoned" ]] || continue
    chmod u+w -- "$abandoned"
    rm -rf -- "$abandoned"
  done
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -d "$destination" && -f "$destination/whisper.bin" && -f "$destination/cleanup.gguf" ]]; then
      # A previous start may have stopped between the rename and this directory sync.
      sync -- "$state_directory"
      printf 'Reusing model generation %s.\n' "$generation"
      exit 0
    fi
    printf 'Incomplete model generation at %s. Move it out of the state directory and restart preparation.\n' "$destination" >&2
    exit 65
  fi

  staging=$(mktemp -d -- "$state_directory/.download.XXXXXXXX")
  cleanup() {
    if [[ -d "$staging" ]]; then
      chmod u+w -- "$staging" && rm -rf -- "$staging"
    fi
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM

  while IFS=$'\t' read -r name expected_sha256 url; do
    printf 'Downloading %s from %s.\n' "$name" "$url"
    curl_status=0
    curl --disable --globoff --fail --location --proto '=https,file' --proto-redir '=https' \
      --silent --show-error --output "$staging/$name" -- "$url" || curl_status=$?
    if (( curl_status != 0 )); then
      printf 'Could not download %s from %s (curl exit %s). Expected SHA-256 %s.\n' \
        "$name" "$url" "$curl_status" "$expected_sha256" >&2
      if (( curl_status == 3 )) || { [[ $url == file://* ]] && (( curl_status == 37 )); }; then
        printf 'Check the model source and restart preparation.\n' >&2
        exit 65
      fi
      exit 1
    fi

    printf 'Checking SHA-256 for %s.\n' "$name"
    checksum=$(sha256sum < "$staging/$name")
    actual_sha256=${checksum%% *}
    if [[ $actual_sha256 != "$expected_sha256" ]]; then
      printf 'SHA-256 mismatch for %s from %s. Expected %s, got %s. Restore the verified source and restart preparation.\n' \
        "$name" "$url" "$expected_sha256" "$actual_sha256" >&2
      exit 65
    fi
  done
} <<< "$manifest_values"

chgrp --reference="$state_directory" -- "$staging" "$staging/whisper.bin" "$staging/cleanup.gguf"
chmod 0440 -- "$staging/whisper.bin" "$staging/cleanup.gguf"
chmod 0550 -- "$staging"
sync -- "$staging/whisper.bin" "$staging/cleanup.gguf" "$staging"
mv --no-copy --no-target-directory --update=none-fail -- "$staging" "$destination"
if ! sync -- "$state_directory"; then
  mv --no-copy --no-target-directory --update=none-fail -- "$destination" "$staging"
  exit 1
fi
printf 'Prepared model generation %s.\n' "$generation"
