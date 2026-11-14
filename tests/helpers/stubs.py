"""Stub factory: executable stand-ins for external tools, written into a per-test bin directory.

Every call of a stub appends one JSON line {"cmd": name, "argv": [...]} to one shared log, so tests assert on the
list of calls (and their order), never on output wording. Stubs are small bash scripts: they log, then answer from
a fixed exit code, a queue, a table keyed by the first argument, or a custom body. The commands are not
reimplemented in Python.

    stubs = Stubs(tmp_path)
    stubs.add("sudo")                                   # exit 0, logged
    stubs.add("cosign", exit={"verify": 1, "default": 0})
    stubs.add("skopeo", script='echo "manifest of $*"')   # custom body, its exit status is the stub's
    assert stubs["sudo"].calls == []
"""
from __future__ import annotations

import json
import os
import stat
from pathlib import Path

# Tools a test must never reach for real. A stub in the test's own bin directory shadows these.
DENIED = (
    "sudo pkexec systemctl podman rpm-ostree virsh flatpak dconf bootc skopeo cosign modprobe curl wget gh "
    "distrobox ostree"
).split()

_HEADER = r"""#!/usr/bin/env bash
j() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; printf '"%s"' "$s"; }
{
    printf '{"cmd":"@NAME@","argv":['
    sep=''
    for a in "$@"; do printf '%s' "$sep"; j "$a"; sep=','; done
    printf ']}\n'
} >> @LOG@
STUB_DIR=@STATE@
"""

_DEFAULT_BODY = "\n@OUT@\n@EXIT@\n"


class Stub:
    def __init__(self, name: str, path: Path, log: Path):
        self.name, self.path, self._log = name, path, log

    @property
    def calls(self) -> list[list[str]]:
        """argv of every call, each starting with the command name."""
        return [[c["cmd"], *c["argv"]] for c in _read(self._log) if c["cmd"] == self.name]


def _read(log: Path) -> list[dict]:
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines() if line.strip()]


def _sq(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


class Stubs:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.bin = self.root / "bin"
        self.state = self.root / "stubstate"
        self.bin.mkdir(parents=True, exist_ok=True)
        self.state.mkdir(parents=True, exist_ok=True)
        self.log = self.state / "calls.jsonl"
        self.log.touch()
        self._stubs: dict[str, Stub] = {}

    def add(self, name: str, exit=0, stdout: str = "", script: str | None = None) -> Stub:
        """Write stub `name`.

        exit    int, or a list (one value per call, the last one repeats), or a dict {first argument: code,
                "default": code}
        stdout  printed on every call (ignored when `script` is given)
        script  bash body run after logging; its exit status is the stub's. $STUB_DIR is its private directory.
        """
        sdir = self.state / name
        sdir.mkdir(parents=True, exist_ok=True)
        text = (_HEADER.replace("@NAME@", name).replace("@LOG@", _sq(str(self.log)))
                .replace("@STATE@", _sq(str(sdir))))
        if script is not None:
            text += script + "\n"
        else:
            out = f"printf '%s' {_sq(stdout)}" if stdout else ":"
            if isinstance(exit, int):
                ex = f"exit {exit}"
            elif isinstance(exit, list):
                q = sdir / "queue"
                q.write_text("\n".join(str(x) for x in exit) + "\n")
                ex = (
                    f"q={_sq(str(q))}; code=$(head -n1 \"$q\"); "
                    f"if [ \"$(wc -l < \"$q\")\" -gt 1 ]; then sed -i 1d \"$q\"; fi; exit \"$code\""
                )
            else:
                arms = "".join(f"    {_sq(str(k))}) exit {int(v)} ;;\n" for k, v in exit.items() if k != "default")
                ex = f'case "${{1-}}" in\n{arms}    *) exit {int(exit.get("default", 0))} ;;\nesac'
            text += _DEFAULT_BODY.replace("@OUT@", out).replace("@EXIT@", ex)
        p = self.bin / name
        p.write_text(text)
        p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        s = Stub(name, p, self.log)
        self._stubs[name] = s
        return s

    def __getitem__(self, name: str) -> Stub:
        return self._stubs[name]

    @property
    def all_calls(self) -> list[list[str]]:
        """Every call of every stub in the order it happened."""
        return [[c["cmd"], *c["argv"]] for c in _read(self.log)]


def write_deny_dir(path: Path) -> Path:
    """The deny directory: one stub per dangerous tool that records the attempt in $DENY_LOG and exits 99."""
    path.mkdir(parents=True, exist_ok=True)
    for name in DENIED:
        p = path / name
        p.write_text(f'#!/bin/sh\necho "{name} $*" >> "${{DENY_LOG:-/dev/null}}"\nexit 99\n')
        p.chmod(0o755)
    return path


# ---- tables for the tools the pipeline scripts ask

class GhTable:
    """A `gh api` GET table: replies come from files named after the API path (a ".fail" file next to it makes the
    call print the reply and exit 1). Every other gh subcommand is only logged; `rc` maps "<a> <b>" to a code."""

    def __init__(self, stubs: Stubs, rc: dict[str, int] | None = None):
        self.dir = stubs.state / "gh-table"
        self.dir.mkdir(parents=True, exist_ok=True)
        rc = rc or {}
        arms = "".join(f"    {_sq(k)}) exit {v} ;;\n" for k, v in rc.items())
        body = f"""
if [[ "$1" == api ]]; then
    path=${{2//\\//_}}
    f={_sq(str(self.dir))}/$path
    if [[ -f "$f" ]]; then cat "$f"; [[ ! -f "$f.fail" ]]; else exit 1; fi
    exit
fi
case "$1 $2" in
{arms}    "pr list") cat {_sq(str(self.dir))}/pr_list 2>/dev/null; exit 0 ;;
    "pr create"|"pr edit"|"workflow run") exit 0 ;;
    *) exit 99 ;;
esac
"""
        self.stub = stubs.add("gh", script=body)

    def reply(self, *pairs: tuple[str, str]) -> None:
        """Replace the table: reply(("repos/o/p/releases/latest", "v1.1.5"), ...)."""
        for f in self.dir.iterdir():
            f.unlink()
        for path, text in pairs:
            (self.dir / path.replace("/", "_")).write_text(text + "\n")

    def set_pr_list(self, text: str) -> None:
        (self.dir / "pr_list").write_text(text)


class FakeRegistry:
    """skopeo and cosign over a fake registry, the way the dx plan sees it.

    The raw manifest of a reference is the text "manifest of docker://<ref>", so its digest is a pure function of
    the reference (`digest(ref)`); `alias(a, b)` gives `a` the manifest of `b` (a retag), `missing` lists references
    that do not exist, `unsigned` references cosign refuses. `config(tag, base, inputs)` publishes the labels of a
    dx image tag. `base_unsigned()` makes cosign reject the default-image base.
    """

    def __init__(self, stubs: Stubs):
        d = self.dir = stubs.state / "registry"
        (d / "cfg").mkdir(parents=True, exist_ok=True)
        for f in ("missing", "alias", "unsigned"):
            (d / f).write_text("")
        self.base_fail = d / "base_fail"
        sk = f"""
ref="${{@: -1}}"
D={_sq(str(d))}
case "$1 $2" in
    "inspect --raw")
        ref="${{ref#docker://}}"
        ! grep -qxF "$ref" "$D/missing" || exit 1
        to=$(awk -v r="$ref" '$1 == r {{ print $2 }}' "$D/alias"); printf 'manifest of docker://%s' "${{to:-$ref}}" ;;
    "inspect --config")
        tag="${{ref##*:}}"
        [[ ( "$ref" == *octarine-os-dx:* || "$ref" == *octarine-os-nvidia-dx:* ) && -f "$D/cfg/$tag" ]] && {{ cat "$D/cfg/$tag"; exit 0; }}
        exit 1 ;;
esac
"""
        cs = f"""
ref="${{@: -1}}"
D={_sq(str(d))}
[[ ! -e "$D/base_fail" || "$ref" != *octarine-os@* ]] || exit 1
! grep -qxF "$ref" "$D/unsigned"
"""
        stubs.add("skopeo", script=sk)
        stubs.add("cosign", script=cs)
        self.skopeo, self.cosign = stubs["skopeo"], stubs["cosign"]

    @staticmethod
    def digest(ref: str) -> str:
        import hashlib

        return hashlib.sha256(f"manifest of docker://{ref}".encode()).hexdigest()

    def _append(self, name: str, line: str) -> None:
        with open(self.dir / name, "a") as f:
            f.write(line + "\n")

    def missing(self, *refs: str, only: bool = True) -> None:
        (self.dir / "missing").write_text("\n".join(refs) + ("\n" if refs else ""))

    def alias(self, a: str, b: str) -> None:
        self._append("alias", f"{a} {b}")

    def clear_alias(self) -> None:
        (self.dir / "alias").write_text("")

    def unsigned(self, *refs: str) -> None:
        (self.dir / "unsigned").write_text("\n".join(refs) + ("\n" if refs else ""))

    def config(self, tag: str, base: str, inputs: str) -> None:
        (self.dir / "cfg" / tag).write_text(json.dumps({"config": {"Labels": {
            "org.opencontainers.image.base.digest": base,
            "io.github.redcodeworks.octarine-os.dx-inputs": inputs}}}))

    def clear_configs(self) -> None:
        for f in (self.dir / "cfg").iterdir():
            f.unlink()

    def drop_config(self, tag: str) -> None:
        (self.dir / "cfg" / tag).unlink(missing_ok=True)

    def fail_base_signature(self) -> None:
        self.base_fail.write_text("")
