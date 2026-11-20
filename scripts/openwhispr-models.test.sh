#!/usr/bin/env bash
set -euo pipefail

script=${1:?Pass the path to openwhispr-models.sh.}
scratch=$(mktemp -d)
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

write_manifest() {
  jq -n \
    --arg generation "$1" \
    --arg source_url "file://$scratch/$2" \
    --arg whisper_sha256 "$3" \
    --arg cleanup_sha256 "$4" \
    '{
      generation: $generation,
      models: [
        {name: "whisper.bin", url: ($source_url + "/whisper.bin"), sha256: $whisper_sha256},
        {name: "cleanup.gguf", url: ($source_url + "/cleanup.gguf"), sha256: $cleanup_sha256}
      ]
    }' > "$scratch/$1.json"
}

prepare() {
  bash "$script" "$scratch/$1.json" "$state"
}

require_model() {
  local path=$1 expected=$2 checksum
  [[ -f "$path" ]] || fail "The model was not published at ${path#"$state"/}."
  checksum=$(sha256sum < "$path")
  [[ ${checksum%% *} == "$expected" ]] || fail "Incorrect model at ${path#"$state"/}."
  [[ $(stat -c '%a' -- "$path") == 440 ]] || fail "Expected a group-readable, read-only model at ${path#"$state"/}."
}

require_pair() {
  local generation=$1
  require_model "$state/$generation/whisper.bin" "$2"
  require_model "$state/$generation/cleanup.gguf" "$3"
}

require_permanent_failure() {
  local generation=$1 status=0
  prepare "$generation" > "$scratch/failure.log" 2>&1 || status=$?
  [[ $status == 65 ]] || fail "Expected exit 65 for generation $generation, got $status. $(<"$scratch/failure.log")"
  [[ ! -e "$state/$generation" ]] || fail "Failed generation $generation was published."
}

state="$scratch/state"
mkdir "$state" "$scratch/a" "$scratch/b"
printf 'Whisper A\n' > "$scratch/a/whisper.bin"
printf 'Cleanup A\n' > "$scratch/a/cleanup.gguf"
printf 'Whisper B\n' > "$scratch/b/whisper.bin"
printf 'Cleanup B\n' > "$scratch/b/cleanup.gguf"
a_whisper=7957bfc14f3b0107175e0e1d8400b222c879698977616ca4eee5aa3399907cbd
a_cleanup=34a85e68941646425b1acf69df9dafee0f8a985fdb9b67f0e0741aab930007cc
b_whisper=f01e7fd0a38ae52d925f601af5400f1adbb64a1df1e1b892f62d16b1562730b4
b_cleanup=c7935c3ea178b18c642ffe5ad320295e42cbe052326f52c5a09fbbc16d6ef82d

write_manifest a a "$a_whisper" "$a_cleanup"
status=0
prepare a || status=$?
require_pair a "$a_whisper" "$a_cleanup"
[[ $status == 0 ]] || fail "Expected exit 0 when publishing both models, got $status."
echo 'Published two verified, read-only models.'

rm "$scratch/a/whisper.bin" "$scratch/a/cleanup.gguf"
prepare a
require_pair a "$a_whisper" "$a_cleanup"
echo 'Reused a complete generation with both sources removed.'

write_manifest c b "$b_whisper" "$a_cleanup"
require_permanent_failure c
require_pair a "$a_whisper" "$a_cleanup"
echo 'Rejected a mismatched second model and preserved the previous generation.'

write_manifest b b "$b_whisper" "$b_cleanup"
mkdir "$state/.download.interrupted"
printf unfinished > "$state/.download.interrupted/cleanup.gguf"
prepare b
[[ ! -e "$state/.download.interrupted" ]] || fail "An interrupted download was not reclaimed."
require_pair b "$b_whisper" "$b_cleanup"

rm "$scratch/b/cleanup.gguf"
write_manifest d b "$b_whisper" "$b_cleanup"
require_permanent_failure d
require_pair b "$b_whisper" "$b_cleanup"
echo 'Rejected a missing local source and preserved the previous generation.'

rm "$scratch/b/whisper.bin"
prepare a
require_pair a "$a_whisper" "$a_cleanup"
require_pair b "$b_whisper" "$b_cleanup"
echo 'Returned to the old generation with all sources removed.'
