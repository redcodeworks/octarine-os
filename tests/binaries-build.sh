#!/usr/bin/env bash
# Tests for the build side of binaries/ (sched_ext schedulers and extest, built in this repository): the upstream.env parser, the
# commit-SHA verification of the checkout (local git repositories, no network), stage.sh, the scheduler list driving scx/build.sh,
# and the real files (pins, builder digest, tsv shape, cargo commands). Nothing is built. Needs: bash, git, python3, readelf and ldd.
# Run: tests/binaries-build.sh
# shellcheck disable=SC2001,SC2013,SC2015,SC2016,SC2034
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

sha() { local s='' i; for i in {1..40}; do s+=$1; done; echo "${s}"; }
# shellcheck source=/dev/null
. "${src}/binaries/lib/upstream-env.sh"

# --- the real files
tsv="${src}/binaries/scx/schedulers.tsv"
upstream_env_load "${src}/binaries/scx/upstream.env" && [[ "${UPSTREAM_REPO}" == sched-ext/scx && -n "${UPSTREAM_TAG}" && "${UPSTREAM_COMMIT}" == e7b3a219617472cf78880ac424714e52c932db61 ]] && ok "scx pins the tag of sched-ext/scx and its peeled commit" || bad "scx upstream.env"
upstream_env_load "${src}/binaries/scx/upstream.env" && [[ "${UPSTREAM_WATCH}" == "${UPSTREAM_REPO}" ]] && ok "scx watches the repository it builds from (no fork)" || bad "scx watch"
upstream_env_load "${src}/binaries/extest/upstream.env" && [[ "${UPSTREAM_REPO}" == redcodeworks/extest && "${UPSTREAM_WATCH}" == Supreeeme/extest && -z "${UPSTREAM_TAG}" && "${UPSTREAM_COMMIT}" == cb77cd4f80f83393a24bae17dd975e14fa6eb1b2 ]] && ok "extest builds from the fork redcodeworks/extest at cb77cd4f, follows Supreeeme/extest" || bad "extest upstream.env"
[[ "$(grep -vE '^[[:space:]]*(#|$)' "${tsv}" | cut -f1 | tr '\n' ' ')" == "scx_rusty scx_lavd scx_cake scx_bpfland scx_cosmos scx_flash scx_p2dq " ]] && ok "schedulers.tsv lists the seven schedulers" || bad "schedulers.tsv names"
badrows=$(grep -vE '^[[:space:]]*(#|$)' "${tsv}" | awk -F'\t' 'NF != 3 || $3 == "" || length($3) > 120 || ($2 != "" && $2 !~ /^[0-9]+\.[0-9]+$/) {print $1}')
[[ -z "${badrows}" ]] && ok "schedulers.tsv: three fields per row, a description of at most 120 characters, a MAJOR.MINOR kernel or none" || bad "schedulers.tsv rows: ${badrows}"
grep -q '^(cd "${srcdir}" && cargo build --release --locked "${pkgs\[@\]}")$' "${src}/binaries/scx/build.sh" && ok "scx builds its schedulers with cargo build --release --locked -p <each>" || bad "scx cargo command"
eb="${src}/binaries/extest/build.sh"
grep -q 'cargo build --release --locked --target x86_64-unknown-linux-gnu' "${eb}" && grep -q 'cargo build --release --locked --target i686-unknown-linux-gnu' "${eb}" && ok "extest builds both targets with --locked" || bad "extest cargo commands"
grep -q 'x86_64-unknown-linux-gnu/release/libextest.so:lib64/libextest.so' "${eb}" && grep -q 'i686-unknown-linux-gnu/release/libextest.so:lib/libextest.so' "${eb}" && grep -q -- '--elf-x86-64 lib64/libextest.so --elf-i386 lib/libextest.so' "${eb}" && ok "extest: x86_64 build is lib64, i686 build is lib, ELF class of each is checked" || bad "extest install paths"
cf="${src}/binaries/Containerfile"
[[ "$(grep -E '^ARG BUILDER=' "${cf}")" =~ ^ARG\ BUILDER=registry.fedoraproject.org/fedora:45@sha256:[0-9a-f]{64}$ ]] && ok "the builder is Fedora 45 pinned by digest" || bad "builder pin"
grep -qx 'FROM ${BUILDER} AS scx' "${cf}" && grep -qx 'FROM ${BUILDER} AS extest' "${cf}" && grep -qx 'FROM ${BUILDER} AS assemble' "${cf}" && [[ "$(grep -E '^FROM ' "${cf}" | tail -n1)" == "FROM scratch" ]] && ok "stages scx, extest, assemble, and a FROM scratch final stage" || bad "stages"
grep -c 'fetch-source.sh /binaries/.*/upstream.env /src' "${cf}" | grep -qx 2 && ok "both sources come through the commit-verifying fetch" || bad "fetch-source in the Containerfile"
grep -q 'git-core rust cargo clang llvm lld libbpf-devel elfutils-libelf-devel zlib-devel libzstd-devel' "${cf}" && grep -q 'rust-std-static-i686-unknown-linux-gnu glibc-devel.i686 libgcc.i686' "${cf}" && ok "build dependencies of both components" || bad "build dependencies"
[[ ! -e "${src}/binaries/Containerfile.dockerignore" ]] && ok "no stray ignore file: the context is binaries/ and its tree hash is the tag" || bad "ignore file"
[[ -z "$(find "${src}/binaries" -type f ! -path '*/lib/*' ! -name Containerfile ! -name 'upstream.env' ! -name schedulers.tsv ! -name build.sh)" ]] && ok "binaries/ holds only the Containerfile, lib/, and per-component upstream.env, build.sh, schedulers.tsv" || bad "unexpected file in binaries/: $(find "${src}/binaries" -type f | tr '\n' ' ')"
for f in "${src}"/binaries/lib/*.sh "${src}"/binaries/*/build.sh; do bash -n "${f}" && [[ -x "${f}" ]] || bad "script ${f} not parsing or not executable"; done; ok "every script under binaries/ parses and is executable"

# --- the parser
w() { printf '%s\n' "$2" > "${tmp}/$1"; }
good=$(printf 'UPSTREAM_REPO=a/b\nUPSTREAM_TAG=v1.2.3\nUPSTREAM_COMMIT=%s\n' "$(sha a)")
w good.env "${good}"
(upstream_env_load "${tmp}/good.env" 2> /dev/null && [[ "${UPSTREAM_TAG}" == v1.2.3 && "${UPSTREAM_REPO}" == a/b ]]) && ok "parser: a valid file" || bad "parser: valid"
w c.env "# comment
${good}  # trailing
"
(upstream_env_load "${tmp}/c.env" 2> /dev/null) && ok "parser: comments and blank lines" || bad "parser: comments"
w q.env "$(sed 's/=v1.2.3/="v1.2.3"/' <<<"${good}")"
(upstream_env_load "${tmp}/q.env" 2> /dev/null && [[ "${UPSTREAM_TAG}" == v1.2.3 ]]) && ok "parser: quotes are stripped" || bad "parser: quotes"
w e.env "$(printf 'UPSTREAM_REPO=a/b\nUPSTREAM_TAG=\nUPSTREAM_COMMIT=%s\n' "$(sha b)")"
(upstream_env_load "${tmp}/e.env" 2> /dev/null && [[ -z "${UPSTREAM_TAG}" ]]) && ok "parser: an empty tag is a commit pin" || bad "parser: empty tag"
for tc in "short commit:$(sed 's/UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=abc123/' <<<"${good}")" \
    "uppercase commit:$(sed 's/UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD/' <<<"${good}")" \
    "no commit:$(grep -v COMMIT <<<"${good}")" \
    "bad repo:$(sed 's#UPSTREAM_REPO=.*#UPSTREAM_REPO=nonsense#' <<<"${good}")" \
    "unknown key:${good}"$'\nFOO=bar' \
    "duplicate key:${good}"$'\nUPSTREAM_TAG=v2' \
    "shell syntax:${good}"$'\n$(touch /tmp/x)' \
    "bad tag:$(sed 's/=v1.2.3/=v1 2/' <<<"${good}")"; do
    w bad.env "${tc#*:}"
    (upstream_env_load "${tmp}/bad.env" > /dev/null 2>&1) && bad "parser accepts: ${tc%%:*}" || ok "parser rejects: ${tc%%:*}"
done
(upstream_env_load "${tmp}/good.env" 2> /dev/null && [[ "${UPSTREAM_WATCH}" == a/b ]]) && ok "parser: UPSTREAM_WATCH defaults to UPSTREAM_REPO" || bad "parser: watch default"
w wf.env "${good}"$'\nUPSTREAM_WATCH=up/stream'
(upstream_env_load "${tmp}/wf.env" 2> /dev/null && [[ "${UPSTREAM_REPO}" == a/b && "${UPSTREAM_WATCH}" == up/stream ]]) && ok "parser: UPSTREAM_WATCH names the project the weekly check follows" || bad "parser: watch"
w wb.env "${good}"$'\nUPSTREAM_WATCH=nonsense'
(upstream_env_load "${tmp}/wb.env" > /dev/null 2>&1) && bad "parser accepts a bad UPSTREAM_WATCH" || ok "parser rejects a bad UPSTREAM_WATCH"
cp "${tmp}/good.env" "${tmp}/set.env"
upstream_env_set "${tmp}/set.env" v9.9.9 "$(sha c)" && grep -qx "UPSTREAM_TAG=v9.9.9" "${tmp}/set.env" && grep -qx "UPSTREAM_REPO=a/b" "${tmp}/set.env" && ok "upstream_env_set rewrites tag and commit only" || bad "upstream_env_set"
upstream_env_set "${tmp}/set.env" v9 short 2> /dev/null && bad "upstream_env_set accepts a short commit" || ok "upstream_env_set refuses a bad commit"

# --- the commit-SHA verification of the checkout
up="${tmp}/up/o/p.git"
mkdir -p "${up}"
git init -q -b main "${up}"
echo one > "${up}/f"; git -C "${up}" add f; git -C "${up}" commit -q -m one
c1=$(git -C "${up}" rev-parse HEAD)
git -C "${up}" tag -a v1 -m v1
echo two > "${up}/f"; git -C "${up}" commit -q -a -m two
c2=$(git -C "${up}" rev-parse HEAD)
git -C "${up}" tag light
fetch() { # tag commit -> rc
    printf 'UPSTREAM_REPO=o/p\nUPSTREAM_TAG=%s\nUPSTREAM_COMMIT=%s\n' "$1" "$2" > "${tmp}/f.env"
    rm -rf "${tmp}/co"
    UPSTREAM_BASE_URL="file://${tmp}/up" "${src}/binaries/lib/fetch-source.sh" "${tmp}/f.env" "${tmp}/co" > "${tmp}/fetch.log" 2>&1
}
fetch v1 "${c1}" && [[ "$(git -C "${tmp}/co" rev-parse HEAD)" == "${c1}" ]] && ok "fetch: an annotated tag resolving to the pinned commit is checked out (peeled)" || bad "fetch annotated: $(cat "${tmp}/fetch.log")"
fetch light "${c2}" && ok "fetch: a lightweight tag at the pinned commit" || bad "fetch lightweight"
fetch v1 "${c2}" && bad "fetch: a tag that does not match the pin must fail" || { grep -q 'moved tag' "${tmp}/fetch.log" && ok "fetch: a tag that resolves to another commit fails (moved tag)"; }
fetch "" "${c2}" && ok "fetch: a commit pin at a fetchable commit" || bad "fetch commit pin: $(cat "${tmp}/fetch.log")"
fetch v1 0000000000000000000000000000000000000000 && bad "fetch: a wrong commit must fail" || ok "fetch: a pin that is not the tag's commit fails"
fetch nosuchtag "${c1}" && bad "fetch: a missing tag must fail" || ok "fetch: a missing tag fails"
# a fork (UPSTREAM_WATCH differs): the tag is only a label, so a tag the fork does not have is fine and the commit decides
printf 'UPSTREAM_REPO=o/p\nUPSTREAM_WATCH=real/project\nUPSTREAM_TAG=1.2.0\nUPSTREAM_COMMIT=%s\n' "${c2}" > "${tmp}/f.env"
rm -rf "${tmp}/co"
UPSTREAM_BASE_URL="file://${tmp}/up" "${src}/binaries/lib/fetch-source.sh" "${tmp}/f.env" "${tmp}/co" > "${tmp}/fetch.log" 2>&1 && [[ "$(git -C "${tmp}/co" rev-parse HEAD)" == "${c2}" ]] && ok "fetch: from a fork the pinned commit is fetched; the tag is a label the fork need not have" || bad "fetch fork label: $(cat "${tmp}/fetch.log")"
printf 'UPSTREAM_REPO=o/p\nUPSTREAM_WATCH=real/project\nUPSTREAM_TAG=1.2.0\nUPSTREAM_COMMIT=%s\n' "$(sha e)" > "${tmp}/f.env"
rm -rf "${tmp}/co"
UPSTREAM_BASE_URL="file://${tmp}/up" "${src}/binaries/lib/fetch-source.sh" "${tmp}/f.env" "${tmp}/co" > "${tmp}/fetch.log" 2>&1 && bad "fetch: a fork commit that is not the pin must fail" || ok "fetch: from a fork a commit the fork does not have fails"

# --- stage.sh: layout, SOURCE, BUILDINFO, smoke test
sdir="${tmp}/srcdir"
mkdir -p "${sdir}/target/release" "${sdir}/lic"
cp "$(type -P true)" "${sdir}/target/release/tool"
echo "license text" > "${sdir}/lic/LICENSE"
stage() { rm -rf "${tmp}/out"; "${src}/binaries/lib/stage.sh" --out "${tmp}/out" --env "${tmp}/good.env" --src "${sdir}" "$@" > "${tmp}/stage.log" 2>&1; }
stage --bin target/release/tool:bin/tool --license lic/LICENSE:up-LICENSE --smoke bin/tool:--version && ok "stage: succeeds" || bad "stage: $(cat "${tmp}/stage.log")"
[[ -x "${tmp}/out/bin/tool" && -s "${tmp}/out/LICENSES/up-LICENSE" && -s "${tmp}/out/SOURCE" && -s "${tmp}/out/BUILDINFO" ]] && ok "stage: /bin, /LICENSES, /SOURCE and /BUILDINFO exist" || bad "stage layout"
grep -qx 'upstream=https://github.com/a/b' "${tmp}/out/SOURCE" && grep -qx "commit=$(sha a)" "${tmp}/out/SOURCE" && grep -qx 'tag=v1.2.3' "${tmp}/out/SOURCE" && grep -q '^repository=https://github.com/a/b$' "${tmp}/out/SOURCE" && grep -q '^built=20' "${tmp}/out/SOURCE" && ok "stage: SOURCE has repository, tag, 40-hex commit and build date" || bad "SOURCE: $(cat "${tmp}/out/SOURCE")"
grep -q '^rustc:' "${tmp}/out/BUILDINFO" && grep -q '^cargo:' "${tmp}/out/BUILDINFO" && grep -q '^clang:' "${tmp}/out/BUILDINFO" && grep -q '^needs bin/tool:' "${tmp}/out/BUILDINFO" && ok "stage: BUILDINFO has rustc, cargo, clang and the needed libraries" || bad "BUILDINFO"
stage --bin target/release/missing:bin/x --license lic/LICENSE:l && bad "stage: a missing build output must fail" || ok "stage: a missing build output fails"
stage --bin target/release/tool:bin/tool --license lic/missing:l && bad "stage: a missing license must fail" || ok "stage: a missing license file fails"
printf '#!/bin/sh\nexit 3\n' > "${sdir}/target/release/broken"
stage --bin target/release/broken:bin/broken --license lic/LICENSE:l --smoke bin/broken:--version && bad "stage: a failing smoke test must fail" || ok "stage: a binary that fails --version fails the build"
stage --bin target/release/tool:bin/tool --license lic/LICENSE:l --elf-x86-64 bin/tool && ok "stage: an x86-64 ELF object passes the architecture check" || bad "elf check: $(cat "${tmp}/stage.log")"
stage --bin target/release/tool:bin/tool --license lic/LICENSE:l --elf-i386 bin/tool 2> /dev/null && bad "stage: a 64-bit file must fail the 32-bit check" || ok "stage: a 64-bit file fails the --elf-i386 check"
# a 32-bit ELF header (class ELF32, machine Intel 80386) built by hand
python3 -I - "${sdir}/target/release/lib32.so" <<'PYEOF'
import struct, sys
h = b"\x7fELF" + bytes([1, 1, 1, 0]) + bytes(8) + struct.pack("<HHIIIIIHHHHHH", 3, 3, 1, 0, 0, 0, 0, 52, 32, 0, 40, 0, 0)
open(sys.argv[1], "wb").write(h)
PYEOF
stage --bin target/release/lib32.so:lib/lib32.so --license lic/LICENSE:l --elf-i386 lib/lib32.so --info 'targets: a, b' && ok "stage: a 32-bit Intel 80386 object passes --elf-i386" || bad "elf32 check: $(cat "${tmp}/stage.log")"
grep -qx 'targets: a, b' "${tmp}/out/BUILDINFO" && ok "stage: --info lines appear in BUILDINFO" || bad "BUILDINFO info line"
stage --bin target/release/lib32.so:lib/lib32.so --license lic/LICENSE:l --elf-x86-64 lib/lib32.so 2> /dev/null && bad "stage: a 32-bit object must fail --elf-x86-64" || ok "stage: a 32-bit object fails the 64-bit check"
printf 'not elf' > "${sdir}/target/release/text"
stage --bin target/release/text:bin/text --license lic/LICENSE:l --elf-x86-64 bin/text 2> /dev/null && bad "stage: a non-ELF file must fail the check" || ok "stage: a file that is not an ELF object fails the check"

# --- scx-bin/build.sh: the scheduler list drives cargo, the binaries and the licenses (a stub cargo and stub stage.sh)
bsrc="${tmp}/scxsrc"
mkdir -p "${bsrc}/scheds/rust/scx_a" "${bsrc}/scheds/rust/scx_b" "${bsrc}/scheds/experimental/scx_c" "${tmp}/stub" "${tmp}/bin"
for n in rust/scx_a rust/scx_b experimental/scx_c; do echo "lic ${n}" > "${bsrc}/scheds/${n}/LICENSE"; done
mkdir -p "${bsrc}/scheds/rust/scx_nolic"
echo root > "${bsrc}/LICENSE"
printf '#!/usr/bin/env bash\necho "cargo $*" >> "${CALLS}"\n' > "${tmp}/bin/cargo"
printf '#!/usr/bin/env bash\necho "stage $*" >> "${CALLS}"\n' > "${tmp}/stub/stage.sh"
chmod +x "${tmp}/bin/cargo" "${tmp}/stub/stage.sh"
export CALLS="${tmp}/calls"
sbuild() { : > "${CALLS}"; rm -rf "${tmp}/o"; mkdir -p "${tmp}/o"; printf '%b\n' "$@" > "${tmp}/sched.tsv"; PATH="${tmp}/bin:${PATH}" STAGE_SH="${tmp}/stub/stage.sh" "${src}/binaries/scx/build.sh" "${tmp}/sched.tsv" "${tmp}/good.env" "${bsrc}" "${tmp}/o" > "${tmp}/sb.log" 2>&1; }
sbuild "# comment" 'scx_a\t6.12\tAlpha scheduler' 'scx_b\t\tBeta scheduler'
grep -qx 'cargo build --release --locked -p scx_a -p scx_b' "${CALLS}" && ok "scx build: one cargo call, --locked, a -p per scheduler in the list" || bad "scx build cargo: $(cat "${CALLS}" "${tmp}/sb.log")"
grep -q -- '--bin target/release/scx_a:bin/scx_a --smoke bin/scx_a:--version' "${CALLS}" && grep -q -- '--license scheds/rust/scx_b/LICENSE:scx_b-LICENSE' "${CALLS}" && grep -q -- '--license LICENSE:scx-LICENSE' "${CALLS}" && ok "scx build: each scheduler is staged as /bin/<name> with its own LICENSE, smoke-tested with --version" || bad "scx build stage: $(cat "${CALLS}")"
[[ "$(cat "${tmp}/o/schedulers.tsv")" == "$(printf 'scx_a\tbin/scx_a\t6.12\tAlpha scheduler\nscx_b\tbin/scx_b\t\tBeta scheduler')" ]] && ok "scx build: /schedulers.tsv has name, binary path, minimum kernel (maybe empty) and description per line" || bad "scx manifest: $(cat -A "${tmp}/o/schedulers.tsv")"
sbuild 'scx_a\t\tA' 'scx_b\t\tB' 'scx_c\t\tC'
grep -qx 'cargo build --release --locked -p scx_a -p scx_b -p scx_c' "${CALLS}" && grep -q -- '--license scheds/experimental/scx_c/LICENSE:scx_c-LICENSE' "${CALLS}" && [[ "$(wc -l < "${tmp}/o/schedulers.tsv")" == 3 ]] && ok "scx build: adding a line adds a scheduler (also under scheds/experimental) and a manifest line, no code change" || bad "scx build third: $(cat "${CALLS}")"
sbuild 'scx_missing\t\tNo such scheduler' && bad "scx build: an unknown scheduler must fail" || ok "scx build: a name that is not a scheduler directory fails before cargo runs"
sbuild 'scx_a\t\tA' 'scx_a\t\tA again' && bad "scx build: a duplicate must fail" || ok "scx build: a duplicate scheduler fails"
sbuild '# nothing' && bad "scx build: an empty list must fail" || ok "scx build: an empty list fails"
sbuild 'bad name\t\tX' && bad "scx build: a bad name must fail" || ok "scx build: a bad scheduler name fails"
sbuild 'scx_a\t\t' && bad "scx build: an empty description must fail" || ok "scx build: an empty description fails"
sbuild 'scx_a\tsix\tA' && bad "scx build: a bad kernel must fail" || ok "scx build: a minimum kernel that is not MAJOR.MINOR fails"
sbuild 'scx_a\tA description without the kernel column' && bad "scx build: two fields must fail" || ok "scx build: a row without three tab separated fields fails"
sbuild 'scx_a\t\tA' 'scx_nolic\t\tNo LICENSE file of its own'
grep -qx 'cargo build --release --locked -p scx_a -p scx_nolic' "${CALLS}" && ! grep -q 'scx_nolic-LICENSE' "${CALLS}" && grep -q -- '--bin target/release/scx_nolic:bin/scx_nolic' "${CALLS}" && ok "scx build: a scheduler directory without a LICENSE (scx_cake) is built and staged, the repository LICENSE covers it" || bad "scx build no license: $(cat "${CALLS}" "${tmp}/sb.log")"
# the real list through the same script: all seven present, one manifest line each, no empty description
rsrc="${tmp}/realsrc"
mkdir -p "${rsrc}/scheds/rust" "${tmp}/o2"
echo root > "${rsrc}/LICENSE"
for n in $(grep -vE '^[[:space:]]*(#|$)' "${tsv}" | cut -f1); do mkdir -p "${rsrc}/scheds/rust/${n}"; [[ "${n}" == scx_cake ]] || echo "lic ${n}" > "${rsrc}/scheds/rust/${n}/LICENSE"; done
: > "${CALLS}"
PATH="${tmp}/bin:${PATH}" STAGE_SH="${tmp}/stub/stage.sh" "${src}/binaries/scx/build.sh" "${tsv}" "${tmp}/good.env" "${rsrc}" "${tmp}/o2" > "${tmp}/sb2.log" 2>&1 && ok "scx build: the real schedulers.tsv runs through build.sh" || bad "real list: $(cat "${tmp}/sb2.log")"
man="${tmp}/o2/schedulers.tsv"
[[ "$(wc -l < "${man}")" == 7 && "$(cut -f1 "${man}" | tr '\n' ' ')" == "scx_rusty scx_lavd scx_cake scx_bpfland scx_cosmos scx_flash scx_p2dq " ]] && ok "manifest: all seven schedulers, one line each" || bad "manifest names: $(cat "${man}")"
[[ -z "$(awk -F'\t' 'NF != 4 || $1 == "" || $2 != "bin/" $1 || $4 == "" {print $1}' "${man}")" ]] && ok "manifest: four fields per line, binary path /bin/<name>, no empty description" || bad "manifest fields"
grep -qx 'cargo build --release --locked -p scx_rusty -p scx_lavd -p scx_cake -p scx_bpfland -p scx_cosmos -p scx_flash -p scx_p2dq' "${CALLS}" && ok "scx build: the seven schedulers are built with one cargo invocation" || bad "seven cargo: $(cat "${CALLS}")"


# --- assemble.sh: component directories to the published layout
asm="${tmp}/asm"
mkdir -p "${asm}/scx/LICENSES" "${asm}/extest/LICENSES"
echo gpl > "${asm}/scx/LICENSES/scx-LICENSE"; echo mit > "${asm}/extest/LICENSES/extest-LICENSE"
for c in scx extest; do echo "src ${c}" > "${asm}/${c}/SOURCE"; echo "build ${c}" > "${asm}/${c}/BUILDINFO"; done
"${src}/binaries/lib/assemble.sh" "${asm}" > "${tmp}/asm.log" 2>&1 && ok "assemble: runs" || bad "assemble: $(cat "${tmp}/asm.log")"
[[ -s "${asm}/LICENSES/scx-LICENSE" && -s "${asm}/LICENSES/extest-LICENSE" ]] && ok "assemble: /LICENSES is the union of both license directories" || bad "assemble licenses"
[[ "$(cat "${asm}/SOURCE")" == "$(printf '[scx]\nsrc scx\n\n[extest]\nsrc extest\n')" && -s "${asm}/BUILDINFO" ]] && ok "assemble: /SOURCE and /BUILDINFO are both components' files under [name] headings" || bad "assemble SOURCE: $(cat "${asm}/SOURCE")"
[[ -s "${asm}/scx/SOURCE" && -s "${asm}/extest/BUILDINFO" ]] && ok "assemble: the component directories stay as they are" || bad "assemble components"
rm "${asm}/extest/SOURCE"; "${src}/binaries/lib/assemble.sh" "${asm}" > /dev/null 2>&1 && bad "assemble: a missing component file must fail" || ok "assemble: a missing component file fails"

# --- extest/build.sh: both targets, then the staging (stub cargo and stage.sh)
mkdir -p "${tmp}/esrc" "${tmp}/eo"
printf '#!/usr/bin/env bash\necho "cargo $*" >> "${CALLS}"\n' > "${tmp}/bin/cargo"
chmod +x "${tmp}/bin/cargo"
: > "${CALLS}"
PATH="${tmp}/bin:${PATH}" STAGE_SH="${tmp}/stub/stage.sh" "${src}/binaries/extest/build.sh" "${tmp}/good.env" "${tmp}/esrc" "${tmp}/eo" > "${tmp}/eb.log" 2>&1
grep -qx 'cargo build --release --locked --target i686-unknown-linux-gnu' "${CALLS}" && grep -qx 'cargo build --release --locked --target x86_64-unknown-linux-gnu' "${CALLS}" && grep -q -- '--bin target/x86_64-unknown-linux-gnu/release/libextest.so:lib64/libextest.so --bin target/i686-unknown-linux-gnu/release/libextest.so:lib/libextest.so' "${CALLS}" && ok "extest build: both targets built, the 64-bit one staged as lib64 and the 32-bit one as lib" || bad "extest build: $(cat "${CALLS}" "${tmp}/eb.log")"

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
