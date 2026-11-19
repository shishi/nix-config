# Readest の構成を、基準版で作ったアカウントとデータを引き継ぐ更新として起動し、
# 更新前のセッション・ログイン・同期 API の読み書き・ファイルの保存と取得・DB migration・照合順序の更新が
# 通ることを確かめる。
# 使い方: readest-compat-test <基準の commit> [<更新後の flake 参照>]
# 更新後の既定は、作業ツリーの HEAD の commit。Docker と Nix が使えるマシンで実行する。
set -euo pipefail

if (($# < 1 || $# > 2)); then
  echo 'Usage: readest-compat-test BASE_COMMIT [HEAD_FLAKE_REF]' >&2
  exit 2
fi

# 本番と同じ Compose プロジェクト名・volume・ポートを使い、終了時に volume を削除する。
# 問い合わせに失敗したら止まるよう、一覧を代入で受け取ってから判定する。
containers=$(docker ps --all --quiet --filter label=com.docker.compose.project=readest)
volumes=$(docker volume ls --quiet)
if [[ -n $containers ]] || grep -qxE 'readest_(db-data|db-config|storage-data)' <<<"$volumes"; then
  echo 'This host already has a Readest project. Run the test on a host without Readest.' >&2
  exit 1
fi

repo=$(git rev-parse --show-toplevel)
# CI の checkout は浅い clone なので、Nix の git fetcher にも履歴を求めさせない。
base_ref="git+file://$repo?rev=$(git -C "$repo" rev-parse "$1^{commit}")&shallow=1"
head_ref=${2:-"git+file://$repo?rev=$(git -C "$repo" rev-parse 'HEAD^{commit}')&shallow=1"}

compose_for() {
  nix build --no-link --print-out-paths --no-update-lock-file --impure --expr "
    let flake = builtins.getFlake \"$1\"; in
    builtins.head (builtins.filter (package: (package.name or \"\") == \"readest-compose\")
      flake.nixosConfigurations.jupiter.config.home-manager.users.shishi.home.packages)"
}

echo "== Building the Readest Compose wrappers"
base_compose="$(compose_for "$base_ref")/bin/readest-compose"
head_compose="$(compose_for "$head_ref")/bin/readest-compose"

work=$(mktemp -d)
export XDG_DATA_HOME="$work/data"
mkdir -p "$XDG_DATA_HOME/readest"
cleanup() {
  # 起動に失敗したコンテナーの理由はログにしか残らないため、消す前に CI の出力へ残す。
  if (($? != 0)); then
    "$head_compose" ps --all >&2 || true
    "$head_compose" logs --no-color --tail 40 >&2 || true
  fi
  "$head_compose" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

python3 "$repo/scripts/readest-init.py" "$XDG_DATA_HOME/readest/.env" https://readest.test
env_value() { sed -n "s/^$1='\(.*\)'$/\1/p" "$XDG_DATA_HOME/readest/.env"; }
anon_key=$(env_value ANON_KEY)
s3_credentials="$(env_value S3_ACCESS_KEY_ID):$(env_value S3_SECRET_ACCESS_KEY)"
s3_object="$(env_value S3_BUCKET_NAME)/readest-compat/base.bin"

wait_for() {
  local url=$1 deadline=$((SECONDS + 600))
  until curl --fail --silent --max-time 5 --header "apikey: $anon_key" "$url" >/dev/null; do
    if ((SECONDS >= deadline)); then
      echo "Timed out waiting for $url" >&2
      return 1
    fi
    sleep 2
  done
}

s3_request() {
  curl --fail --silent --show-error --aws-sigv4 'aws:amz:us-east-1:s3' --user "$s3_credentials" "$@"
}

# 署名付き URL の Host を保ったまま、ローカルの proxy へ送る。
through_proxy() {
  local url=$1 rest
  shift
  rest=${url#*://}
  curl --fail --silent --show-error --header "Host: ${rest%%/*}" "$@" "$head_api/${rest#*/}"
}

auth_request() {
  local base=$1 path=$2 body=$3
  curl --fail --silent --show-error --request POST "$base/auth/v1/$path" \
    --header "apikey: $anon_key" --header 'Content-Type: application/json' --data "$body"
}

echo "== Creating an account and a book with the base configuration"
# 基準版では Web 版を起動しないため、Kong と S3 をホストへ公開して直接呼ぶ。
cat >"$work/base-ports.yaml" <<'YAML'
services:
  kong:
    ports:
      - 127.0.0.1:18000:8000
  storage:
    ports:
      - 127.0.0.1:19000:9000
YAML
"$base_compose" --file "$work/base-ports.yaml" up --detach db auth rest kong storage
base_api=http://127.0.0.1:18000
wait_for "$base_api/auth/v1/health"

email=readest-compat@example.invalid
password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
credentials=$(jq -n --arg email "$email" --arg password "$password" '{email: $email, password: $password}')
signup=$(auth_request "$base_api" signup "$credentials")
user_id=$(jq -er '.user.id' <<<"$signup")
base_token=$(jq -er '.access_token' <<<"$signup")
base_refresh_token=$(jq -er '.refresh_token' <<<"$signup")
book_hash=readest-compat-check
curl --fail --silent --show-error --request POST "$base_api/rest/v1/books" \
  --header "apikey: $anon_key" --header "Authorization: Bearer $base_token" \
  --header 'Content-Type: application/json' --header 'Prefer: return=minimal' \
  --data "$(jq -n --arg user_id "$user_id" --arg book_hash "$book_hash" \
    '{user_id: $user_id, book_hash: $book_hash, title: "Compatibility check", format: "EPUB"}')"
head -c 4096 /dev/urandom >"$work/base.bin"
# SeaweedFS は healthcheck の成功後もバケットの作成を終えていないことがある。
deadline=$((SECONDS + 300))
until s3_request --upload-file "$work/base.bin" "http://127.0.0.1:19000/$s3_object" 2>"$work/s3.err"; do
  if ((SECONDS >= deadline)); then
    cat "$work/s3.err" >&2
    echo 'Timed out writing to the base object storage' >&2
    exit 1
  fi
  sleep 2
done
"$base_compose" --file "$work/base-ports.yaml" down

echo "== Starting the updated configuration on the same volumes"
"$head_compose" build client
"$head_compose" up --detach
head_api=http://127.0.0.1:3080
wait_for "$head_api/"
wait_for "$head_api/auth/v1/health"

# 端末は更新前に発行されたトークンを持ったまま使い続けるため、ログインし直さずに
# 同期を読み、そのトークンで更新できることを確かめる。
books=$(curl --fail --silent --show-error \
  --header "Authorization: Bearer $base_token" \
  "$head_api/api/sync?since=0&type=books&book=&meta_hash=&limit=1000")
if ! jq -e --arg book_hash "$book_hash" '.books | map(.book_hash) | index($book_hash) != null' <<<"$books" >/dev/null; then
  echo "The book created with the base configuration is missing from /api/sync" >&2
  exit 1
fi
refreshed=$(auth_request "$head_api" 'token?grant_type=refresh_token' \
  "$(jq -n --arg token "$base_refresh_token" '{refresh_token: $token}')")
token=$(jq -er '.access_token' <<<"$refreshed")
login=$(auth_request "$head_api" 'token?grant_type=password' "$credentials")
jq -er '.access_token' <<<"$login" >/dev/null

# 更新後の同期 API で読書位置を保存し、読み直す。
location='epubcfi(/6/4!/4/2/1:0)'
curl --fail --silent --show-error --request POST "$head_api/api/sync" \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data "$(jq -n --arg book_hash "$book_hash" --arg location "$location" --argjson now "$(date +%s%3N)" \
    '{configs: [{bookHash: $book_hash, location: $location, progress: [3, 10], updatedAt: $now}]}')" >/dev/null
configs=$(curl --fail --silent --show-error \
  --header "Authorization: Bearer $token" \
  "$head_api/api/sync?since=0&type=configs&book=$book_hash")
if ! jq -e --arg book_hash "$book_hash" --arg location "$location" \
  '.configs | any(.book_hash == $book_hash and .location == $location)' <<<"$configs" >/dev/null; then
  echo 'The reading position saved through /api/sync was not returned' >&2
  exit 1
fi

# 基準版で保存したファイルを更新後のストレージから読み、Web 版の API でも保存と取得を往復する。
s3_request --output "$work/base.out" "$head_api/$s3_object"
cmp "$work/base.bin" "$work/base.out"
head -c 4096 /dev/urandom >"$work/book.epub"
upload=$(curl --fail --silent --show-error --request POST "$head_api/api/storage/upload" \
  --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
  --data "$(jq -n --arg book_hash "$book_hash" --argjson size "$(stat -c %s "$work/book.epub")" \
    '{fileName: "Readest/Books/\($book_hash)/\($book_hash).epub", fileSize: $size, bookHash: $book_hash}')")
through_proxy "$(jq -er '.uploadUrl' <<<"$upload")" --upload-file "$work/book.epub"
file_key=$(jq -er '.fileKey | @uri' <<<"$upload")
download=$(curl --fail --silent --show-error --header "Authorization: Bearer $token" \
  "$head_api/api/storage/download?fileKey=$file_key")
through_proxy "$(jq -er '.downloadUrl' <<<"$download")" --output "$work/book.out"
cmp "$work/book.epub" "$work/book.out"

migrations=$("$head_compose" config --format json |
  jq -er '.services.db.volumes[] | select(.target == "/readest-migrations") | .source')
find "$migrations" -maxdepth 1 -name '*.sql' -printf '%f\n' | sort >"$work/expected-migrations"
"$head_compose" exec -T db psql -U supabase_admin -d postgres -tAc 'select name from readest_meta.migrations' |
  sort >"$work/applied-migrations"
missing=$(comm -23 "$work/expected-migrations" "$work/applied-migrations")
if [[ -n $missing ]]; then
  echo "Database migrations not applied: $missing" >&2
  exit 1
fi
applied=$(wc -l <"$work/expected-migrations")
stale_collations=$("$head_compose" exec -T db psql -U supabase_admin -d postgres -tAc "SELECT datname FROM pg_database
  WHERE datallowconn AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)")
if [[ -n $stale_collations ]]; then
  echo "Indexes not rebuilt for the new collation version: $stale_collations" >&2
  exit 1
fi

curl --fail --silent --show-error --request POST "$head_api/auth/v1/logout" \
  --header "apikey: $anon_key" --header "Authorization: Bearer $token"

echo "== Readest accepted the update: existing sessions, sign-in, sync, storage, $applied migrations and collation versions"
