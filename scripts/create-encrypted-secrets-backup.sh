#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
SECRETS_DIR="$HOME/apps/secrets"
PASS_FILE="$SECRETS_DIR/.encryption-passphrase"
ENC_FILE="$SECRETS_DIR/cinerankml-secret.env.enc"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

python3 - "$TMP" <<'PY'
import base64, json, os, subprocess, sys
from pathlib import Path

out = Path(sys.argv[1])
raw = subprocess.check_output(
    ["kubectl", "-n", "cinerankml", "get", "secret", "cinerankml-secret", "-o", "json"],
    env=os.environ,
)
data = json.loads(raw)["data"]
lines = []
for key in sorted(data):
    value = base64.b64decode(data[key]).decode()
    safe = value.replace("'", "'\"'\"'")
    lines.append(f"{key}='{safe}'")
out.write_text("\n".join(lines) + "\n")
out.chmod(0o600)
print(f"exported {len(lines)} keys")
PY

if [[ ! -f "$PASS_FILE" ]]; then
  openssl rand -hex 32 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi

openssl enc -aes-256-cbc -pbkdf2 -salt -in "$TMP" -out "$ENC_FILE" -pass "file:$PASS_FILE"
chmod 600 "$ENC_FILE"

cat > "$SECRETS_DIR/decrypt.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ENC="$DIR/cinerankml-secret.env.enc"
PASS="$DIR/.encryption-passphrase"
OUT="${1:-}"
if [[ ! -f "$ENC" || ! -f "$PASS" ]]; then
  echo "missing encrypted file or passphrase" >&2
  exit 1
fi
if [[ -n "$OUT" ]]; then
  openssl enc -d -aes-256-cbc -pbkdf2 -in "$ENC" -pass "file:$PASS" -out "$OUT"
  chmod 600 "$OUT"
  echo "wrote $OUT"
else
  openssl enc -d -aes-256-cbc -pbkdf2 -in "$ENC" -pass "file:$PASS"
fi
EOS
chmod 700 "$SECRETS_DIR/decrypt.sh"

cat > "$SECRETS_DIR/restore-to-cluster.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
"$DIR/decrypt.sh" "$TMP"
set -a
# shellcheck disable=SC1090
source "$TMP"
set +a
kubectl create namespace cinerankml --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cinerankml create secret generic cinerankml-secret \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=S3_ACCESS_KEY="$S3_ACCESS_KEY" \
  --from-literal=S3_SECRET_KEY="$S3_SECRET_KEY" \
  --from-literal=GF_SECURITY_ADMIN_USER="${GF_SECURITY_ADMIN_USER:-admin}" \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD="${GF_SECURITY_ADMIN_PASSWORD:?missing GF_SECURITY_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "restored cinerankml-secret in namespace cinerankml"
EOS
chmod 700 "$SECRETS_DIR/restore-to-cluster.sh"

cat > "$SECRETS_DIR/README.md" <<'EOS'
# CineRankML secrets backup (VPS only — do not commit)

- `cinerankml-secret.env.enc` — AES-256-CBC encrypted dotenv of cluster Secret keys
- `.encryption-passphrase` — passphrase file (mode 600); keep with the `.enc` file
- `decrypt.sh` — decrypt to stdout, or to a file path argument
- `restore-to-cluster.sh` — decrypt and apply Secret `cinerankml-secret`

Keys typically include: POSTGRES_PASSWORD, DATABASE_URL, S3_ACCESS_KEY, S3_SECRET_KEY,
GF_SECURITY_ADMIN_USER, GF_SECURITY_ADMIN_PASSWORD.

```bash
./decrypt.sh /tmp/cinerankml.env
./restore-to-cluster.sh
```

Copy both `.enc` and `.encryption-passphrase` off-box for disaster recovery.
EOS
chmod 600 "$SECRETS_DIR/README.md"

# Round-trip check without printing values
"$SECRETS_DIR/decrypt.sh" "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
keys = {ln.split("=", 1)[0] for ln in text.splitlines() if ln and not ln.startswith("#")}
required = {
    "POSTGRES_PASSWORD",
    "DATABASE_URL",
    "S3_ACCESS_KEY",
    "S3_SECRET_KEY",
    "GF_SECURITY_ADMIN_USER",
    "GF_SECURITY_ADMIN_PASSWORD",
}
missing = required - keys
assert not missing, f"missing keys: {sorted(missing)}"
print("round-trip ok:", ", ".join(sorted(keys)))
PY

ls -la "$SECRETS_DIR"
