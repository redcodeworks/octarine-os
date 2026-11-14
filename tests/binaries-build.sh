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
grep -qx 'FROM ${BUILDER} AS scx' "${cf}" && grep -qx 'FROM ${BUILDER} AS extest' "${cf}" && grep -qx 'FROM ${BUILDER} AS ghostty' "${cf}" && grep -qx 'FROM ${BUILDER} AS assemble' "${cf}" && [[ "$(grep -E '^FROM ' "${cf}" | tail -n1)" == "FROM scratch" ]] && ok "stages scx, extest, ghostty, assemble, and a FROM scratch final stage" || bad "stages"
grep -c 'fetch-source.sh /binaries/.*/upstream.env /src' "${cf}" | grep -qx 3 && ok "all three sources come through the verifying fetch" || bad "fetch-source in the Containerfile"
grep -q 'git-core rust cargo clang llvm lld libbpf-devel elfutils-libelf-devel zlib-devel libzstd-devel' "${cf}" && grep -q 'rust-std-static-i686-unknown-linux-gnu glibc-devel.i686 libgcc.i686' "${cf}" && ok "build dependencies of both components" || bad "build dependencies"
[[ ! -e "${src}/binaries/Containerfile.dockerignore" ]] && ok "no stray ignore file: the context is binaries/ and its tree hash is the tag" || bad "ignore file"
[[ -z "$(find "${src}/binaries" -type f ! -path '*/lib/*' ! -name Containerfile ! -name 'upstream.env' ! -name schedulers.tsv ! -name build.sh ! -path '*/ghostty/*')" && -z "$(find "${src}/binaries/ghostty" -type f ! -name upstream.env ! -name build.sh ! -name fetch-zig.sh ! -name zig-version.sh ! -name bump-extra.sh)" ]] && ok "binaries/ holds only the Containerfile, lib/, per-component upstream.env, build.sh, schedulers.tsv and the ghostty helper scripts" || bad "unexpected file in binaries/: $(find "${src}/binaries" -type f | tr '\n' ' ')"
for f in "${src}"/binaries/lib/*.sh "${src}"/binaries/*/*.sh; do bash -n "${f}" && [[ -x "${f}" ]] || bad "script ${f} not parsing or not executable"; done; ok "every script under binaries/ parses and is executable"

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
mkdir -p "${asm}/scx/LICENSES" "${asm}/extest/LICENSES" "${asm}/ghostty/LICENSES"
echo gpl > "${asm}/scx/LICENSES/scx-LICENSE"; echo mit > "${asm}/extest/LICENSES/extest-LICENSE"; echo mit > "${asm}/ghostty/LICENSES/ghostty-LICENSE"
for c in scx extest ghostty; do echo "src ${c}" > "${asm}/${c}/SOURCE"; echo "build ${c}" > "${asm}/${c}/BUILDINFO"; done
"${src}/binaries/lib/assemble.sh" "${asm}" > "${tmp}/asm.log" 2>&1 && ok "assemble: runs" || bad "assemble: $(cat "${tmp}/asm.log")"
[[ -s "${asm}/LICENSES/scx-LICENSE" && -s "${asm}/LICENSES/extest-LICENSE" ]] && ok "assemble: /LICENSES is the union of both license directories" || bad "assemble licenses"
[[ "$(cat "${asm}/SOURCE")" == "$(printf '[scx]\nsrc scx\n\n[extest]\nsrc extest\n\n[ghostty]\nsrc ghostty\n')" && -s "${asm}/BUILDINFO" ]] && ok "assemble: /SOURCE and /BUILDINFO are all components' files under [name] headings" || bad "assemble SOURCE: $(cat "${asm}/SOURCE")"
[[ -s "${asm}/scx/SOURCE" && -s "${asm}/extest/BUILDINFO" ]] && ok "assemble: the component directories stay as they are" || bad "assemble components"
rm "${asm}/extest/SOURCE"; "${src}/binaries/lib/assemble.sh" "${asm}" > /dev/null 2>&1 && bad "assemble: a missing component file must fail" || ok "assemble: a missing component file fails"

# --- extest/build.sh: both targets, then the staging (stub cargo and stage.sh)
mkdir -p "${tmp}/esrc" "${tmp}/eo"
printf '#!/usr/bin/env bash\necho "cargo $*" >> "${CALLS}"\n' > "${tmp}/bin/cargo"
chmod +x "${tmp}/bin/cargo"
: > "${CALLS}"
PATH="${tmp}/bin:${PATH}" STAGE_SH="${tmp}/stub/stage.sh" "${src}/binaries/extest/build.sh" "${tmp}/good.env" "${tmp}/esrc" "${tmp}/eo" > "${tmp}/eb.log" 2>&1
grep -qx 'cargo build --release --locked --target i686-unknown-linux-gnu' "${CALLS}" && grep -qx 'cargo build --release --locked --target x86_64-unknown-linux-gnu' "${CALLS}" && grep -q -- '--bin target/x86_64-unknown-linux-gnu/release/libextest.so:lib64/libextest.so --bin target/i686-unknown-linux-gnu/release/libextest.so:lib/libextest.so' "${CALLS}" && ok "extest build: both targets built, the 64-bit one staged as lib64 and the 32-bit one as lib" || bad "extest build: $(cat "${CALLS}" "${tmp}/eb.log")"

# ===== ghostty: the signed-tarball pin, the Zig toolchain, the build, the bump check (stub curl, minisign, zig; no network)
ge="${src}/binaries/ghostty"
gcf="${src}/binaries/Containerfile"
upstream_env_load "${ge}/upstream.env" && [[ "${UPSTREAM_REPO}" == ghostty-org/ghostty && "${UPSTREAM_WATCH}" == ghostty-org/ghostty && "${UPSTREAM_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${UPSTREAM_COMMIT}" =~ ^[0-9a-f]{40}$ ]] && ok "ghostty pins a v<semver> tag of ghostty-org/ghostty and its commit" || bad "ghostty upstream.env"
upstream_env_load "${ge}/upstream.env" && [[ "${UPSTREAM_MINISIGN_KEY}" == RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV && "${UPSTREAM_TARBALL_URL}" == 'https://release.files.ghostty.org/@VERSION@/ghostty-@VERSION@.tar.gz' ]] && ok "ghostty: the release tarball URL and the minisign key published in PACKAGING.md" || bad "ghostty key or url"
upstream_env_load "${ge}/upstream.env" && grep -E -q -- "${UPSTREAM_TAG_REGEX}" <<<"v1.4.0" && ! grep -E -q -- "${UPSTREAM_TAG_REGEX}" <<<"vt-1.0.1" && ! grep -E -q -- "${UPSTREAM_TAG_REGEX}" <<<"tip" && ! grep -E -q -- "${UPSTREAM_TAG_REGEX}" <<<"v1.5.0-rc1" && ok "ghostty: the tag regex matches v1.4.0 and ignores vt-*, tip and pre-releases" || bad "ghostty tag regex"
upstream_env_load "${ge}/upstream.env" && [[ "${ZIG_VERSION}" =~ ^0\.[0-9]+\.[0-9]+$ && "${ZIG_URL}" == https://ziglang.org/download/@VERSION@/zig-x86_64-linux-@VERSION@.tar.xz ]] && ok "ghostty: the Zig toolchain is an official ziglang.org release" || bad "ghostty zig pin"
upstream_env_load "${ge}/upstream.env"; if [[ -z "${UPSTREAM_TARBALL_SHA256}" || -z "${ZIG_SHA256}" || -z "${ZIG_MINISIGN_KEY}" ]]; then echo "NOTE the ghostty tarball sha256 and the Zig sha256/key are still empty: the build fails closed until they are pinned"; else ok "ghostty: tarball sha256, Zig sha256 and Zig key are pinned"; fi
grep -q 'fetch-zig.sh /binaries/ghostty/upstream.env' "${gcf}" && grep -q 'fetch-source.sh /binaries/ghostty/upstream.env /src' "${gcf}" && grep -q 'ghostty/build.sh /binaries/ghostty/upstream.env /src /out' "${gcf}" && ok "ghostty stage: Zig, then the verified source, then the build" || bad "ghostty stage steps"
grep -q 'minisign' "${gcf}" && grep -q 'gtk4-devel libadwaita-devel gtk4-layer-shell-devel' "${gcf}" && grep -q 'pandoc-cli' "${gcf}" && grep -q 'oniguruma-devel simdutf-devel' "${gcf}" && ok "ghostty stage: minisign, the GTK -devel set, pandoc and the font/text -devel set from Fedora" || bad "ghostty build dependencies"
gb="${ge}/build.sh"
grep -q -- '--prefix /usr --system "${cache}/p"' "${gb}" && grep -q -- '-Doptimize=ReleaseFast -Dcpu=baseline' "${gb}" && grep -q -- '-Dinstalled-exe-path=/usr/bin/ghostty' "${gb}" && grep -q 'DESTDIR="${srcdir}/.stage"' "${gb}" && ok "ghostty build: PACKAGING.md's system-package build (--system, ReleaseFast, baseline CPU, installed-exe-path without DESTDIR)" || bad "ghostty zig build command"
grep -q -- '--smoke usr/bin/ghostty:--version' "${gb}" && grep -q -- '--elf-x86-64 usr/bin/ghostty' "${gb}" && grep -q -- '--tree .stage/usr:usr' "${gb}" && grep -q -- '--license LICENSE:ghostty-LICENSE' "${gb}" && ok "ghostty build: staged through stage.sh with the tree, a --version run, the ELF check and the license" || bad "ghostty stage call"

# --- the extended parser
gfull=$(printf 'UPSTREAM_REPO=a/b\nUPSTREAM_TAG=v1.2.3\nUPSTREAM_COMMIT=%s\nUPSTREAM_TAG_REGEX=^v[0-9]+\\.[0-9]+\\.[0-9]+$\nUPSTREAM_TARBALL_URL=https://example.invalid/@VERSION@/t-@VERSION@.tar.gz\nUPSTREAM_TARBALL_SHA256=%s\nUPSTREAM_MINISIGN_KEY=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV\nZIG_VERSION=0.17.0\nZIG_URL=https://example.invalid/zig-@VERSION@.tar.xz\nZIG_SHA256=%s\nZIG_MINISIGN_KEY=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV\n' "$(sha a)" "$(printf 'b%.0s' {1..64})" "$(printf 'c%.0s' {1..64})")
w gfull.env "${gfull}"
(upstream_env_load "${tmp}/gfull.env" 2> /dev/null && [[ "${UPSTREAM_TAG_REGEX}" == '^v[0-9]+\.[0-9]+\.[0-9]+$' && "${ZIG_VERSION}" == 0.17.0 && ${#UPSTREAM_TARBALL_SHA256} == 64 ]]) && ok "parser: the optional tarball, minisign, regex and Zig keys" || bad "parser: ghostty keys"
for tc in "short sha:$(sed 's/^UPSTREAM_TARBALL_SHA256=.*/UPSTREAM_TARBALL_SHA256=abc/' <<<"${gfull}")" \
    "uppercase sha:$(sed 's/^ZIG_SHA256=.*/ZIG_SHA256=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/' <<<"${gfull}")" \
    "bad tarball key:$(sed 's/^UPSTREAM_MINISIGN_KEY=.*/UPSTREAM_MINISIGN_KEY=notakey/' <<<"${gfull}")" \
    "bad zig key:$(sed 's/^ZIG_MINISIGN_KEY=.*/ZIG_MINISIGN_KEY=RWshort/' <<<"${gfull}")" \
    "http url:$(sed 's#^UPSTREAM_TARBALL_URL=https#UPSTREAM_TARBALL_URL=http#' <<<"${gfull}")" \
    "file url:$(sed 's#^ZIG_URL=https#ZIG_URL=file#' <<<"${gfull}")" \
    "bad zig version:$(sed 's/^ZIG_VERSION=.*/ZIG_VERSION=0.17/' <<<"${gfull}")" \
    "shell in regex:$(sed 's/^UPSTREAM_TAG_REGEX=.*/UPSTREAM_TAG_REGEX=$(id)/' <<<"${gfull}")"; do
    w bad.env "${tc#*:}"
    (upstream_env_load "${tmp}/bad.env" > /dev/null 2>&1) && bad "parser accepts: ${tc%%:*}" || ok "parser rejects: ${tc%%:*}"
done
w gempty.env "$(sed 's/^UPSTREAM_TARBALL_SHA256=.*/UPSTREAM_TARBALL_SHA256=/' <<<"${gfull}")"
(upstream_env_load "${tmp}/gempty.env" 2> /dev/null) && ok "parser: an empty sha256 loads (the fetch step is what refuses it)" || bad "parser: empty sha"
cp "${tmp}/gfull.env" "${tmp}/gset.env"
upstream_env_set_key "${tmp}/gset.env" UPSTREAM_TARBALL_SHA256 "$(printf 'd%.0s' {1..64})" && grep -qx "UPSTREAM_TARBALL_SHA256=$(printf 'd%.0s' {1..64})" "${tmp}/gset.env" && grep -qx 'ZIG_VERSION=0.17.0' "${tmp}/gset.env" && ok "upstream_env_set_key rewrites that one line only" || bad "upstream_env_set_key"
upstream_env_set_key "${tmp}/gset.env" UPSTREAM_TARBALL_SHA256 nothex 2> /dev/null && bad "upstream_env_set_key accepts a bad value" || ok "upstream_env_set_key refuses a value the parser would refuse"
upstream_env_set_key "${tmp}/good.env" UPSTREAM_TARBALL_SHA256 "$(printf 'd%.0s' {1..64})" 2> /dev/null && bad "upstream_env_set_key invents a key" || ok "upstream_env_set_key refuses a key that is not in the file"
cp "${tmp}/gfull.env" "${tmp}/gset2.env"; upstream_env_set "${tmp}/gset2.env" v9.9.9 "$(sha e)" && grep -q '^UPSTREAM_TAG_REGEX=' "${tmp}/gset2.env" && grep -qx 'UPSTREAM_TAG=v9.9.9' "${tmp}/gset2.env" && ok "upstream_env_set does not touch UPSTREAM_TAG_REGEX" || bad "upstream_env_set vs regex"

# --- fetch-tarball.sh and the tarball pin of fetch-source.sh (a stub curl that serves local files, a stub minisign)
fx="${tmp}/fx"; mkdir -p "${fx}/pkg/ghostty-1.2.3" "${tmp}/gbin"
echo 1.2.3 > "${fx}/pkg/ghostty-1.2.3/VERSION"; echo 'MIT License' > "${fx}/pkg/ghostty-1.2.3/LICENSE"
printf '.{\n    .name = .ghostty,\n    .minimum_zig_version = "0.17.0",\n}\n' > "${fx}/pkg/ghostty-1.2.3/build.zig.zon"
tar -C "${fx}/pkg" -czf "${fx}/t-1.2.3.tar.gz" ghostty-1.2.3
echo sig > "${fx}/t-1.2.3.tar.gz.minisig"
gsha=$(sha256sum "${fx}/t-1.2.3.tar.gz" | cut -d' ' -f1)
cat > "${tmp}/gbin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do case "$1" in --output) out=$2; shift 2 ;; --*) [[ "$1" == --retry || "$1" == --retry-delay ]] && shift; shift ;; *) url=$1; shift ;; esac; done
echo "curl ${url}" >> "${CALLS}"
f="${FIX}/$(basename "${url}")"
[[ -f "${f}" ]] || exit 22
cp "${f}" "${out}"
STUB
cat > "${tmp}/gbin/minisign" <<'STUB'
#!/usr/bin/env bash
echo "minisign $*" >> "${CALLS}"
[[ -z "${MINISIGN_FAIL:-}" ]]
STUB
chmod +x "${tmp}/gbin/curl" "${tmp}/gbin/minisign"
export FIX="${fx}"
gkey=RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV
ft() { rm -rf "${tmp}/gd"; : > "${CALLS}"; PATH="${tmp}/gbin:${PATH}" "${src}/binaries/lib/fetch-tarball.sh" "$@" > "${tmp}/ft.log" 2>&1; }
ft https://example.invalid/t-1.2.3.tar.gz "${gsha}" "${gkey}" "${tmp}/gd" && [[ -f "${tmp}/gd/VERSION" && ! -d "${tmp}/gd/ghostty-1.2.3" ]] && ok "fetch-tarball: a good tarball is verified and unpacked without its top directory" || bad "fetch-tarball good: $(cat "${tmp}/ft.log")"
grep -q -- "minisign -V -m .* -x .*minisig -P ${gkey}" "${CALLS}" && ok "fetch-tarball: minisign verifies the file against the pinned key and the .minisig next to it" || bad "fetch-tarball minisign call: $(cat "${CALLS}")"
ft https://example.invalid/t-1.2.3.tar.gz "$(sha b)$(sha b | cut -c1-24)" "${gkey}" "${tmp}/gd" && bad "fetch-tarball: a wrong sha256 must fail" || { [[ ! -e "${tmp}/gd" ]] && grep -q 'pins' "${tmp}/ft.log" && ok "fetch-tarball: a sha256 that differs from the pin fails and unpacks nothing"; }
MINISIGN_FAIL=1 ft https://example.invalid/t-1.2.3.tar.gz "${gsha}" "${gkey}" "${tmp}/gd" && bad "fetch-tarball: a bad signature must fail" || { [[ ! -e "${tmp}/gd" ]] && grep -q 'does not verify' "${tmp}/ft.log" && ok "fetch-tarball: a signature that does not verify fails (the sha256 alone is not enough) and unpacks nothing"; }
ft https://example.invalid/t-1.2.3.tar.gz "" "${gkey}" "${tmp}/gd" && bad "fetch-tarball: an empty sha256 must fail" || { ! grep -q '^curl' "${CALLS}" && ok "fetch-tarball: an empty sha256 pin fails before anything is downloaded"; }
ft https://example.invalid/t-1.2.3.tar.gz "${gsha}" "" "${tmp}/gd" && bad "fetch-tarball: an empty key must fail" || ok "fetch-tarball: an empty minisign key fails"
ft https://example.invalid/missing.tar.gz "${gsha}" "${gkey}" "${tmp}/gd" && bad "fetch-tarball: a download error must fail" || ok "fetch-tarball: a download error fails"
mkdir -p "${tmp}/gd"; echo x > "${tmp}/gd/old"; : > "${CALLS}"; PATH="${tmp}/gbin:${PATH}" "${src}/binaries/lib/fetch-tarball.sh" https://example.invalid/t-1.2.3.tar.gz "${gsha}" "${gkey}" "${tmp}/gd" > /dev/null 2>&1 && bad "fetch-tarball: a non-empty destination must fail" || ok "fetch-tarball: a destination that is not empty fails"

gsrc="${tmp}/gtag"; mkdir -p "${gsrc}"; git init -q -b main "${gsrc}/g/h.git"; echo x > "${gsrc}/g/h.git/f"; git -C "${gsrc}/g/h.git" add f; git -C "${gsrc}/g/h.git" commit -q -m one
gc1=$(git -C "${gsrc}/g/h.git" rev-parse HEAD); git -C "${gsrc}/g/h.git" tag -a v1.2.3 -m v1.2.3
genv() { printf 'UPSTREAM_REPO=g/h\nUPSTREAM_TAG=v1.2.3\nUPSTREAM_COMMIT=%s\nUPSTREAM_TARBALL_URL=https://example.invalid/@VERSION@/t-@VERSION@.tar.gz\nUPSTREAM_TARBALL_SHA256=%s\nUPSTREAM_MINISIGN_KEY=%s\n' "$1" "$2" "${gkey}" > "${tmp}/g.env"; }
gf() { rm -rf "${tmp}/gco"; : > "${CALLS}"; PATH="${tmp}/gbin:${PATH}" UPSTREAM_BASE_URL="file://${gsrc}" "${src}/binaries/lib/fetch-source.sh" "${tmp}/g.env" "${tmp}/gco" > "${tmp}/gf.log" 2>&1; }
cp "${fx}/t-1.2.3.tar.gz" "${fx}/t-1.2.3.tar.gz.keep"
genv "${gc1}" "${gsha}"; gf && [[ -f "${tmp}/gco/VERSION" && ! -d "${tmp}/gco/.git" ]] && ok "fetch-source (tarball pin): tag at the pinned commit, signature and sha256 good: source unpacked (no git checkout)" || bad "fetch-source tarball: $(cat "${tmp}/gf.log")"
genv "$(sha 9)" "${gsha}"; gf && bad "fetch-source (tarball pin): a tag that is not the pinned commit must fail" || { grep -q 'moved tag' "${tmp}/gf.log" && ! grep -q '^curl' "${CALLS}" && ok "fetch-source (tarball pin): a moved tag fails before anything is downloaded"; }
genv "${gc1}" "$(printf 'e%.0s' {1..64})"; gf && bad "fetch-source (tarball pin): a wrong sha256 must fail" || ok "fetch-source (tarball pin): a wrong sha256 fails"
genv "${gc1}" ""; gf && bad "fetch-source (tarball pin): no sha256 pinned must fail" || ok "fetch-source (tarball pin): no sha256 pinned fails closed"
genv "${gc1}" "${gsha}"; MINISIGN_FAIL=1 gf && bad "fetch-source (tarball pin): a bad signature must fail" || ok "fetch-source (tarball pin): a bad signature fails"
echo 9.9.9 > "${fx}/pkg/ghostty-1.2.3/VERSION"; tar -C "${fx}/pkg" -czf "${fx}/t-1.2.3.tar.gz" ghostty-1.2.3; echo 1.2.3 > "${fx}/pkg/ghostty-1.2.3/VERSION"
genv "${gc1}" "$(sha256sum "${fx}/t-1.2.3.tar.gz" | cut -d' ' -f1)"; gf && bad "fetch-source (tarball pin): a VERSION file that is not the tag must fail" || { grep -q 'VERSION file' "${tmp}/gf.log" && ok "fetch-source (tarball pin): a tarball whose VERSION is not the tag fails"; }
tar -C "${fx}/pkg" -czf "${fx}/t-1.2.3.tar.gz" ghostty-1.2.3

# --- zig-version.sh
. "${ge}/zig-version.sh"
for tc in "0.17.0 0.17.0 y" "0.17.0 0.17.2 y" "0.17.1 0.17.0 n" "0.17.0 0.18.0 n" "0.17.0 0.16.9 n" "0.17.0 1.17.0 n" "0.17.0 dev n"; do
    set -- ${tc}
    if zig_satisfies "$1" "$2"; then r=y; else r=n; fi
    [[ "${r}" == "$3" ]] && ok "zig_satisfies required $1 have $2: ${r}" || bad "zig_satisfies $1 $2 gave ${r}, expected $3"
done
[[ "$(zig_required_of "${fx}/pkg/ghostty-1.2.3/build.zig.zon")" == 0.17.0 ]] && ok "zig_required_of reads minimum_zig_version" || bad "zig_required_of"
printf '.{ .name = .x }\n' > "${tmp}/nozon"; zig_required_of "${tmp}/nozon" 2> /dev/null && bad "zig_required_of must fail without a version" || ok "zig_required_of fails when there is no minimum_zig_version"

# --- fetch-zig.sh (the tarball holds a stub zig)
zp="${tmp}/zp/zig-x86_64-linux-0.17.0"; mkdir -p "${zp}"; printf '#!/bin/sh\necho 0.17.0\n' > "${zp}/zig"; chmod +x "${zp}/zig"
tar -C "${tmp}/zp" -cJf "${fx}/zig-0.17.0.tar.xz" zig-x86_64-linux-0.17.0; echo sig > "${fx}/zig-0.17.0.tar.xz.minisig"
zsha=$(sha256sum "${fx}/zig-0.17.0.tar.xz" | cut -d' ' -f1)
printf 'UPSTREAM_REPO=g/h\nUPSTREAM_TAG=v1.2.3\nUPSTREAM_COMMIT=%s\nZIG_VERSION=0.17.0\nZIG_URL=https://example.invalid/zig-@VERSION@.tar.xz\nZIG_SHA256=%s\nZIG_MINISIGN_KEY=%s\n' "${gc1}" "${zsha}" "${gkey}" > "${tmp}/z.env"
fz() { rm -rf "${tmp}/zdest" "${tmp}/zlink"; : > "${CALLS}"; PATH="${tmp}/gbin:${PATH}" ZIG_DEST="${tmp}/zdest" ZIG_LINK="${tmp}/zlink" "${ge}/fetch-zig.sh" "${tmp}/z.env" > "${tmp}/fz.log" 2>&1; }
fz && [[ -x "${tmp}/zlink" ]] && grep -q 'zig-0.17.0.tar.xz.minisig' "${CALLS}" && ok "fetch-zig: the pinned release is verified (signature and sha256), unpacked and linked as zig" || bad "fetch-zig: $(cat "${tmp}/fz.log")"
sed -i "s/^ZIG_SHA256=.*/ZIG_SHA256=$(printf '0%.0s' {1..64})/" "${tmp}/z.env"; fz && bad "fetch-zig: a wrong sha256 must fail" || ok "fetch-zig: a Zig tarball with another sha256 fails"
sed -i "s/^ZIG_SHA256=.*/ZIG_SHA256=${zsha}/; s/^ZIG_VERSION=.*/ZIG_VERSION=0.17.1/" "${tmp}/z.env"; fz && bad "fetch-zig: a version that does not match the tarball must fail" || ok "fetch-zig: a toolchain that reports another version than the pin fails"
sed -i "s/^ZIG_VERSION=.*/ZIG_VERSION=0.17.0/; s/^ZIG_MINISIGN_KEY=.*/ZIG_MINISIGN_KEY=/" "${tmp}/z.env"; fz && bad "fetch-zig: no key must fail" || ok "fetch-zig: no Zig key pinned fails closed"

# --- ghostty/build.sh with stubs (zig, pkg-config, the dependency fetch script, stage.sh)
gs="${tmp}/gsrc"; rm -rf "${gs}"; mkdir -p "${gs}/nix/build-support" "${tmp}/gcache/p/JetBrainsMono-2.304-x"
cp "${fx}/pkg/ghostty-1.2.3/LICENSE" "${fx}/pkg/ghostty-1.2.3/build.zig.zon" "${gs}/"; echo u > "${gs}/build.zig.zon.txt"
echo 'OFL text' > "${tmp}/gcache/p/JetBrainsMono-2.304-x/OFL.txt"
printf '#!/bin/sh\necho "fetch-zig-cache ZIG_GLOBAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR" >> "$CALLS"\n' > "${gs}/nix/build-support/fetch-zig-cache.sh"; chmod +x "${gs}/nix/build-support/fetch-zig-cache.sh"
cat > "${tmp}/gbin/zig" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then echo "${ZIG_STUB_VERSION:-0.17.0}"; exit 0; fi
echo "zig $* DESTDIR=${DESTDIR:-}" >> "${CALLS}"
mkdir -p "${DESTDIR}/usr/bin"; echo bin > "${DESTDIR}/usr/bin/ghostty"; chmod +x "${DESTDIR}/usr/bin/ghostty"
STUB
cat > "${tmp}/gbin/pkg-config" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == --exists ]]; then [[ " ${PKG_MISSING:-} " != *" $2 "* ]]; exit; fi
[[ "$1" == --modversion ]] && echo 1.0 && exit 0
exit 1
STUB
printf '#!/usr/bin/env bash\necho "stage $*" >> "${CALLS}"\n' > "${tmp}/stub/gstage.sh"
chmod +x "${tmp}/gbin/zig" "${tmp}/gbin/pkg-config" "${tmp}/stub/gstage.sh"
printf 'UPSTREAM_REPO=g/h\nUPSTREAM_TAG=v1.2.3\nUPSTREAM_COMMIT=%s\nZIG_VERSION=0.17.0\n' "${gc1}" > "${tmp}/gb.env"
gbuild() { : > "${CALLS}"; rm -rf "${gs}/.stage" "${gs}/.licenses" "${tmp}/gout"; PATH="${tmp}/gbin:${PATH}" STAGE_SH="${tmp}/stub/gstage.sh" ZIG_OFFLINE_CACHE="${tmp}/gcache" "${ge}/build.sh" "${tmp}/gb.env" "${gs}" "${tmp}/gout" > "${tmp}/gbuild.log" 2>&1; }
gbuild && ok "ghostty build: runs with stubs" || bad "ghostty build: $(cat "${tmp}/gbuild.log")"
grep -q 'fetch-zig-cache ZIG_GLOBAL_CACHE_DIR='"${tmp}"'/gcache$' "${CALLS}" && ok "ghostty build: the dependency cache is fetched first, into the offline cache directory" || bad "ghostty build cache: $(cat "${CALLS}")"
grep -q "^zig build --prefix /usr --system ${tmp}/gcache/p -Doptimize=ReleaseFast -Dcpu=baseline -Dversion-string=1.2.3 -Dinstalled-exe-path=/usr/bin/ghostty -fno-sys=spirv-cross -fno-sys=glslang DESTDIR=${gs}/.stage\$" "${CALLS}" && ok "ghostty build: zig build with --system, ReleaseFast, baseline, the version, /usr/bin/ghostty as the exe path, spirv-cross built from the package, DESTDIR the staging directory" || bad "ghostty zig call: $(cat "${CALLS}")"
grep -q -- '--tree .stage/usr:usr --bin .stage/usr/bin/ghostty:usr/bin/ghostty --license LICENSE:ghostty-LICENSE' "${CALLS}" && grep -q -- '--license .licenses/ghostty-font-JetBrainsMono-2.304-x-OFL.txt:ghostty-font-JetBrainsMono-2.304-x-OFL.txt' "${CALLS}" && ok "ghostty build: the Ghostty license and the font license found in the cache are staged" || bad "ghostty licenses: $(cat "${CALLS}")"
ZIG_STUB_VERSION=0.17.1 gbuild && bad "ghostty build: another Zig than the pin must fail" || ok "ghostty build: a Zig that is not the pinned version fails"
sed -i 's/0.17.0/0.18.0/' "${gs}/build.zig.zon"; gbuild && bad "ghostty build: a source that needs another Zig must fail" || { grep -q 'needs Zig 0.18.0' "${tmp}/gbuild.log" && ok "ghostty build: a source whose minimum_zig_version the pinned Zig does not satisfy fails, naming the Zig it needs"; }
sed -i 's/0.18.0/0.17.0/' "${gs}/build.zig.zon"
PKG_MISSING="simdutf" gbuild && bad "ghostty build: a missing -devel module must fail" || { grep -q 'cannot find: simdutf' "${tmp}/gbuild.log" && ! grep -q '^zig build' "${CALLS}" && ok "ghostty build: a pkg-config module that is missing fails before zig runs, naming it"; }
mv "${gs}/build.zig.zon.txt" "${tmp}/zon.txt"; gbuild && bad "ghostty build: a tarball without build.zig.zon.txt must fail" || ok "ghostty build: a source without the dependency list fails"; mv "${tmp}/zon.txt" "${gs}/build.zig.zon.txt"

# --- bump-extra.sh: signature, sha256, VERSION and the Zig check, then the pin
cp "${tmp}/gfull.env" "${tmp}/be.env"; sed -i 's/^UPSTREAM_TAG=.*/UPSTREAM_TAG=v1.2.3/; s/^ZIG_VERSION=.*/ZIG_VERSION=0.17.0/' "${tmp}/be.env"
be() { : > "${CALLS}"; PATH="${tmp}/gbin:${PATH}" "${ge}/bump-extra.sh" "${tmp}/be.env" "${1:-v1.2.3}" > "${tmp}/be.log" 2>&1; }
cp "${fx}/t-1.2.3.tar.gz" "${fx}/t-1.2.3.tar.gz.bak"
be && grep -qx "UPSTREAM_TARBALL_SHA256=$(sha256sum "${fx}/t-1.2.3.tar.gz" | cut -d' ' -f1)" "${tmp}/be.env" && ok "bump-extra: the sha256 of the verified new tarball is written to upstream.env" || bad "bump-extra: $(cat "${tmp}/be.log")"
cp "${tmp}/gfull.env" "${tmp}/be.env"; sed -i 's/^UPSTREAM_TAG=.*/UPSTREAM_TAG=v1.2.3/' "${tmp}/be.env"; MINISIGN_FAIL=1 be && bad "bump-extra: a bad signature must fail" || { grep -qx "UPSTREAM_TARBALL_SHA256=$(sha b)$(sha b | cut -c1-24)" "${tmp}/be.env" 2> /dev/null; grep -q "UPSTREAM_TARBALL_SHA256=$(printf 'b%.0s' {1..64})" "${tmp}/be.env" && ok "bump-extra: a signature that does not verify fails and the sha256 is not changed"; }
sed -i 's/0.17.0/0.18.0/' "${fx}/pkg/ghostty-1.2.3/build.zig.zon"; tar -C "${fx}/pkg" -czf "${fx}/t-1.2.3.tar.gz" ghostty-1.2.3; sed -i 's/0.18.0/0.17.0/' "${fx}/pkg/ghostty-1.2.3/build.zig.zon"
be; rc=$?; [[ ${rc} == 3 ]] && grep -q 'ZIG-MISMATCH 0.18.0' "${tmp}/be.log" 2> /dev/null; [[ ${rc} == 3 && "$(cat "${tmp}/be.log")" == *"needs Zig 0.18.0"* ]] && grep -q "UPSTREAM_TARBALL_SHA256=$(sha256sum "${fx}/t-1.2.3.tar.gz" | cut -d' ' -f1)" "${tmp}/be.env" && ok "bump-extra: a release whose minimum_zig_version the pinned Zig does not satisfy exits 3 (flag, not failure), names the Zig, and still pins the verified sha256" || bad "bump-extra zig flag (rc ${rc}): $(cat "${tmp}/be.log")"
tar -C "${fx}/pkg" -czf "${fx}/t-1.2.3.tar.gz" ghostty-1.2.3
be v1.9.9 && bad "bump-extra: a file that does not carry the tag must fail" || ok "bump-extra: an upstream.env that does not carry the new tag fails"

# --- stage.sh --tree, assemble with ghostty
mkdir -p "${sdir}/tree/usr/share/x" "${sdir}/tree/usr/bin"; echo f > "${sdir}/tree/usr/share/x/file"; ln -s file "${sdir}/tree/usr/share/x/link"; cp "$(type -P true)" "${sdir}/tree/usr/bin/tool"
stage --tree tree/usr:usr --bin tree/usr/bin/tool:usr/bin/tool --license lic/LICENSE:l --smoke usr/bin/tool:--version && [[ -f "${tmp}/out/usr/share/x/file" && -L "${tmp}/out/usr/share/x/link" && -x "${tmp}/out/usr/bin/tool" ]] && grep -q '^needs usr/bin/tool:' "${tmp}/out/BUILDINFO" && ok "stage: --tree copies an install tree (links kept) before the --bin files, BUILDINFO lists the binary's libraries" || bad "stage tree: $(cat "${tmp}/stage.log")"
stage --tree tree/missing:usr --bin tree/usr/bin/tool:usr/bin/tool --license lic/LICENSE:l && bad "stage: a missing --tree must fail" || ok "stage: a missing install tree fails"
asm2="${tmp}/asm2"; mkdir -p "${asm2}"; for c in scx extest ghostty; do mkdir -p "${asm2}/${c}/LICENSES"; echo "lic ${c}" > "${asm2}/${c}/LICENSES/${c}-LICENSE"; echo "src ${c}" > "${asm2}/${c}/SOURCE"; echo "build ${c}" > "${asm2}/${c}/BUILDINFO"; done
"${src}/binaries/lib/assemble.sh" "${asm2}" > /dev/null 2>&1 && [[ -s "${asm2}/LICENSES/ghostty-LICENSE" && "$(cat "${asm2}/SOURCE")" == "$(printf '[scx]\nsrc scx\n\n[extest]\nsrc extest\n\n[ghostty]\nsrc ghostty\n')" ]] && ok "assemble: ghostty joins /LICENSES, /SOURCE and /BUILDINFO" || bad "assemble ghostty"

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
