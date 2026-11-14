#!/usr/bin/env bash
# Tests for the chunkah rechunk: the verified pin (.github/scripts/chunkah-ref.sh with a fake cosign), the Justfile recipe and its use in
# every image workflow. Nothing is pulled or run. Run: tests/chunkah.sh. Needs: bash, python3 with PyYAML.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
printf '#!/usr/bin/env bash\necho "cosign $*" >>"$LOG"\nexit "${COSIGN_RC:-0}"\n' >"$bin/cosign"; chmod +x "$bin/cosign"
export LOG="$root/log"
ref() { : >"$LOG"; env "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/chunkah-ref.sh" "${ENVF:-$here/config/chunkah.env}" >"$root/run" 2>&1; rc=$?; }
d=$(sed -n 's/^CHUNKAH_DIGEST=//p' "$here/config/chunkah.env")
ref X=1
check "chunkah-ref: the pin in config/chunkah.env is verified keyless (OIDC issuer, coreos/chunkah identity) and printed as image@digest" bash -c "[ $rc = 0 ] && grep -qx 'quay.io/coreos/chunkah@$d' '$root/run' && grep -q 'cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp ^https://github.com/coreos/chunkah/ quay.io/coreos/chunkah@$d' '$LOG'"
ref COSIGN_RC=1
check "chunkah-ref: a signature that does not verify fails (exit 1), nothing is printed as a reference" bash -c "[ $rc = 1 ] && grep -q 'cosign verification of' '$root/run' && ! grep -qx 'quay.io/coreos/chunkah@.*' '$root/run'"
printf 'CHUNKAH_IMAGE=quay.io/coreos/chunkah\nCHUNKAH_TAG=latest\nCHUNKAH_DIGEST=latest\n' >"$root/bad.env"; ENVF="$root/bad.env" ref X=1
check "chunkah-ref: a pin that is not a sha256 digest (a floating tag) is refused before cosign runs" bash -c "[ $rc = 1 ] && [ ! -s '$LOG' ]"
ENVF="$root/missing.env" ref X=1
check "chunkah-ref: a missing pin file fails" test "$rc" = 1
check "config/chunkah.env: the pin is the digest of quay.io/coreos/chunkah, tag only a label" bash -c "grep -qx 'CHUNKAH_IMAGE=quay.io/coreos/chunkah' '$here/config/chunkah.env' && grep -Eq '^CHUNKAH_DIGEST=sha256:[0-9a-f]{64}\$' '$here/config/chunkah.env'"
check "Justfile: rechunk uses the verified reference, Aurora's flags and keeps the labels of just build through the image config" bash -c "
  j='$here/Justfile'; grep -q '^rechunk ' \"\$j\" && ! grep -q 'ostree-rechunk\|build-chunked-oci' \"\$j\"
  grep -q 'CHUNKAH_REF=\"\$(.github/scripts/chunkah-ref.sh)\"' \"\$j\" && grep -q '\"\${CHUNKAH_REF}\"' \"\$j\" && ! grep -q 'chunkah:latest@' \"\$j\"
  grep -q -- '--max-layers 256' \"\$j\" && grep -q -- '--prune /sysroot/' \"\$j\" && grep -q -- '--label ostree.commit- --label ostree.final-diffid-' \"\$j\"
  grep -q 'podman inspect \"\${target_image}:\${tag}\" > \"\${CHUNKAH_CONFIG_FILE}\"' \"\$j\" && grep -q -- '--config /chunkah-config.json' \"\$j\""
check "every image workflow (default, beta, dx, nvidia-dx) rechunks with 'just rechunk' after cosign is set up; none calls ostree-rechunk; the NVIDIA variant stays a layer without rechunk" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
for f in ("build", "build-beta", "build-dx", "build-nvidia-dx"):
    t = open(f"{root}/.github/workflows/{f}.yml").read()
    assert "ostree-rechunk" not in t and "rpm-ostree compose build-chunked-oci" not in t, f
    w = yaml.safe_load(t)
    steps = [s for j in w["jobs"].values() for s in j.get("steps", [])]
    names = [s.get("name", "") for s in steps]
    r = [i for i, s in enumerate(steps) if "just rechunk" in s.get("run", "")]
    assert len(r) == 1 and names[r[0]] == "Rechunk with chunkah", f
    c = [i for i, s in enumerate(steps) if s.get("uses") == "./.github/actions/setup-tool" and s.get("with", {}).get("tool") == "cosign"]
    assert c and min(c) < r[0], f + ": cosign must be set up before the rechunk"
assert "rechunk" not in open(f"{root}/.github/workflows/build-nvidia.yml").read().replace("rechunked", "")
PY
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
