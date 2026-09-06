#!/usr/bin/bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=../scripts/prepare-vps.sh
source "$ROOT/scripts/prepare-vps.sh"
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
COUNT=0
pass() { COUNT=$((COUNT + 1)); printf 'PASS %s\n' "$1"; }
reject() { if ("$@") >"$TEMP/rejection" 2>&1; then say 'Expected rejection.'; exit 1; fi; }

artifact_for_arch amd64
[[ $ARCHIVE_SIZE == 32258946 && $BINARY_SIZE == 91842368 && $ARCHIVE_URL == *linux_amd64.deb ]]
artifact_for_arch arm64
[[ $ARCHIVE_SIZE == 29525840 && $BINARY_SIZE == 85908600 && $ARCHIVE_URL == *linux_arm64.deb ]]
reject artifact_for_arch riscv64
pass 'fixed architectures and artifact locks'

printf fixture > "$TEMP/blob"
DIGEST=$(sha256sum "$TEMP/blob" | cut -d ' ' -f 1)
matches_artifact "$TEMP/blob" 7 "$DIGEST"
reject matches_artifact "$TEMP/blob" 8 "$DIGEST"
printf altered > "$TEMP/blob"
reject matches_artifact "$TEMP/blob" 7 "$DIGEST"
ln -s "$TEMP/blob" "$TEMP/link"
reject matches_artifact "$TEMP/link" 7 "$DIGEST"
pass 'size, digest and symlink rejection'

openssl rand -base64 16 > "$TEMP/key"
render_config "$TEMP/key" "$TEMP/config.json"
jq -e '.inbounds|length==1' "$TEMP/config.json" >/dev/null
jq -e '.inbounds[0] | .listen=="0.0.0.0" and .listen_port==443 and .network=="tcp" and
  .method=="2022-blake3-aes-128-gcm" and .multiplex.enabled==true' "$TEMP/config.json" >/dev/null
jq -e '.outbounds==[{"type":"direct","tag":"direct"}] and .route.final=="direct"' "$TEMP/config.json" >/dev/null
pass 'single-user TCP 443 configuration and direct outbound'

CONFIG="$TEMP/config.json" WORK="$TEMP/reuse"
mkdir "$WORK"
prepare_key
cmp "$TEMP/key" "$WORK/key"
render_config "$WORK/key" "$TEMP/repeated.json"
cmp "$CONFIG" "$TEMP/repeated.json"
pass 'repeat retains exact key and configuration'

jq '.inbounds[0].password="bad"' "$CONFIG" > "$TEMP/bad.json"
CONFIG="$TEMP/bad.json"
reject prepare_key
[[ $(jq -r '.inbounds[0].password' "$CONFIG") == bad ]]
pass 'invalid existing key is refused instead of replaced'

if (( EUID == 0 )); then
    safe_path "$TEMP/blob"
    reject safe_path "$TEMP/link"
    chmod 0666 "$TEMP/blob"
    reject safe_path "$TEMP/blob"
    chmod 0600 "$TEMP/blob"
    ln "$TEMP/blob" "$TEMP/hardlink"
    reject safe_path "$TEMP/blob"
    pass 'root-file permissions, symlinks and hardlinks'
else
    printf 'SKIP root-owned file checks (run with sudo in CI)\n'
fi

"$ROOT/scripts/prepare-vps.sh" --help > "$TEMP/help"
reject "$ROOT/scripts/prepare-vps.sh" --unknown
reject "$ROOT/scripts/prepare-vps.sh" --upgrade-system extra
pass 'help and invalid CLI return before installation'
printf 'Unit checks passed: %s\n' "$COUNT"
