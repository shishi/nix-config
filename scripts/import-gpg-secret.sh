#!/usr/bin/env bash

set -euo pipefail

umask 077

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /absolute/path/to/gpg-secret.asc /absolute/path/to/gnupg-home" >&2
  exit 64
fi

export_path=$1
gnupg_home=$2

case "$export_path" in
  /*) ;;
  *)
    echo "GPG export path must be absolute" >&2
    exit 64
    ;;
esac

case "$gnupg_home" in
  /*) ;;
  *)
    echo "GnuPG home path must be absolute" >&2
    exit 64
    ;;
esac

if [ ! -f "$export_path" ] || [ ! -s "$export_path" ]; then
  echo "GPG export must be a nonempty regular file" >&2
  exit 1
fi

mkdir -p -- "$gnupg_home"
chmod 700 -- "$gnupg_home"

if ! key_listing=$(gpg --homedir "$gnupg_home" --batch --with-colons --show-keys "$export_path" 2>/dev/null); then
  echo "GPG export could not be inspected" >&2
  exit 1
fi
mapfile -t primary_fingerprints < <(
  printf '%s\n' "$key_listing" | awk -F: '
    $1 == "pub" || $1 == "sec" { need_fingerprint = 1; next }
    need_fingerprint && $1 == "fpr" { print $10; need_fingerprint = 0 }
  '
)

if [ "${#primary_fingerprints[@]}" -ne 1 ]; then
  echo "GPG export must contain exactly one primary key" >&2
  exit 1
fi

fingerprint=${primary_fingerprints[0]}

gpg --homedir "$gnupg_home" --batch --import "$export_path"
printf '%s:6:\n' "$fingerprint" | gpg --homedir "$gnupg_home" --batch --import-ownertrust
printf '%s\n' 'Jupiter GPG import verification' | \
  gpg --homedir "$gnupg_home" --batch --yes --pinentry-mode loopback \
    --local-user "$fingerprint" --clearsign >/dev/null

rm -- "$export_path"
