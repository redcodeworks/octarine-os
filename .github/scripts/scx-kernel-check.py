#!/usr/bin/env python3
"""Tier 1 compatibility check of the shipped sched_ext schedulers against the image's
own kernel, statically.

    scx-kernel-check.py --kernel-dir /usr/lib/modules/<kver> [--binary-dir /usr/bin]
        [--manifest schedulers.tsv] [NAME ...]

What it checks (nothing is loaded, no BPF runs; a real machine still has to load a
scheduler):

  1. The kernel config in the image (config next to vmlinuz): CONFIG_SCHED_CLASS_EXT=y,
     CONFIG_BPF_SYSCALL=y and CONFIG_DEBUG_INFO_BTF=y. This part is simple and reliable;
     without it no scheduler can load.
  2. The kernel's BTF, read out of vmlinuz (the bzImage payload is decompressed with the
     zstd, xz or gzip tool, then the .BTF section of the vmlinux ELF is parsed). Without
     a readable BTF the comparison below is skipped with a warning (check 1 still
     counts).
  3. For every scheduler binary: the BPF object that the Rust program embeds (an ELF of
     machine EM_BPF) is parsed and
       - every REQUIRED kernel symbol it imports (an undefined, non-weak symbol: kfuncs
         and kernel variables) must exist in the kernel: as a BTF function or variable,
         or as a symbol in System.map. Weak imports are optional (the scx compat layer
         guards them with bpf_ksym_exists) and are only listed as notes.
       - every member of struct sched_ext_ops that its struct_ops sets with a program
         must exist in the kernel's own struct sched_ext_ops (members are found through
         the relocations of the .struct_ops* sections and the object's BTF).
  4. The runtime model of libbpf's kernel-config lookup. A BPF object with `.kconfig`
     externs (extern ... CONFIG_* __kconfig) makes libbpf read the kernel config at load
     time, and libbpf (v1.7.0) tries exactly /boot/config-<uname -r> and
     /proc/config.gz. The image has neither (CONFIG_IKCONFIG is off, the ostree /boot
     has no config), so such a scheduler fails with "failed to open system Kconfig" /
     EINVAL (scx_lavd, first real start 2026-11-14). The check lists the CONFIG_*
     externs of every scheduler and FAILS when there are any and --run-script (default
     /usr/libexec/octarine-os/scx-run) does not carry the mechanism that gives the
     scheduler a config (a private mount namespace with the image's config bound at
     /boot/config-<release>).
  The check exits 1 when a required import or a set member is missing from the kernel.
  Limits (printed, not hidden): it does not prove that the verifier accepts the
  programs, that a member's meaning is unchanged, or that the userspace side works.
"""

import argparse
import enum
import glob
import os
import re
import struct
import subprocess
import sys

BTF_MAGIC = 0xEB9F


class Kind(enum.IntEnum):
    """BTF type kinds (linux/btf.h)."""

    INT, PTR, ARRAY, STRUCT, UNION, ENUM = 1, 2, 3, 4, 5, 6
    FWD, TYPEDEF, VOLATILE, CONST, RESTRICT, FUNC = 7, 8, 9, 10, 11, 12
    FUNC_PROTO, VAR, DATASEC, FLOAT, DECL_TAG, TYPE_TAG, ENUM64 = (
        13,
        14,
        15,
        16,
        17,
        18,
        19,
    )


EM_BPF = 247


class CheckError(Exception):
    pass


def parse_btf(blob):
    """Return (types, strings) of a BTF blob: types is a list of dicts (index 0 is
    void), strings a function name -> str.
    """
    # a blob shorter than the header cannot be BTF
    if len(blob) < 24:
        raise CheckError("BTF too short")
    magic, version, flags, hdr_len, type_off, type_len, str_off, str_len = (
        struct.unpack_from("<HBBIIIII", blob, 0)
    )
    # the magic number tells BTF from any other data
    if magic != BTF_MAGIC:
        raise CheckError("not BTF (magic %#x)" % magic)
    sdata = blob[hdr_len + str_off : hdr_len + str_off + str_len]

    def name(off):
        """Return the string at an offset of the BTF string table.

        Receives the offset; undecodable bytes are replaced.
        """
        end = sdata.find(b"\0", off)
        return sdata[off:end].decode("utf-8", "replace")

    types = [{"kind": 0, "name": "", "members": []}]
    pos = hdr_len + type_off
    end = pos + type_len
    # walk the type records one after another
    while pos < end:
        name_off, info, size_type = struct.unpack_from("<III", blob, pos)
        pos += 12
        kind = (info >> 24) & 0x1F
        vlen = info & 0xFFFF
        t = {
            "kind": kind,
            "name": name(name_off),
            "vlen": vlen,
            "size": size_type,
            "members": [],
        }
        # each kind has its own size after the common three words; only members are kept
        match kind:
            case Kind.INT | Kind.VAR | Kind.DECL_TAG:
                pos += 4
            case Kind.ARRAY:
                pos += 12
            case Kind.STRUCT | Kind.UNION:
                # struct and union members are (name, offset) triples
                for _ in range(vlen):
                    m_name, m_type, m_off = struct.unpack_from("<III", blob, pos)
                    pos += 12
                    # with kind_flag the offset field packs a bitfield size in its top
                    # byte
                    if info >> 31:
                        m_off &= 0xFFFFFF
                    t["members"].append((name(m_name), m_off))
            case Kind.ENUM | Kind.FUNC_PROTO:
                pos += 8 * vlen
            case Kind.ENUM64:
                pos += 12 * vlen
            case Kind.DATASEC:
                # datasec entries are (type, offset, size) triples
                for _ in range(vlen):
                    v_type, v_off, v_size = struct.unpack_from("<III", blob, pos)
                    pos += 12
                    t["members"].append((v_type, v_off))
            case (
                Kind.PTR
                | Kind.FWD
                | Kind.TYPEDEF
                | Kind.VOLATILE
                | Kind.CONST
                | Kind.RESTRICT
                | Kind.FUNC
                | Kind.FLOAT
                | Kind.TYPE_TAG
            ):
                pass
            case _:
                raise CheckError("unknown BTF kind %d" % kind)
        types.append(t)
    return types


def elf_sections(data):
    """Section list of an ELF64 little-endian file: dicts with name, type, offset, size,
    link, info, entsize.
    """
    # only 64-bit little-endian ELF files are understood
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise CheckError("not an ELF64 little-endian file")
    e_machine = struct.unpack_from("<H", data, 18)[0]
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)
    raw = []
    # read every section header
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        (
            sh_name,
            sh_type,
            sh_flags,
            sh_addr,
            sh_offset,
            sh_size,
            sh_link,
            sh_info,
            sh_align,
            sh_entsize,
        ) = struct.unpack_from("<IIQQQQIIQQ", data, o)
        raw.append((sh_name, sh_type, sh_offset, sh_size, sh_link, sh_info, sh_entsize))
    shstr = raw[e_shstrndx]
    strtab = data[shstr[2] : shstr[2] + shstr[3]]
    out = []
    # resolve each section name through the section name string table
    for sh_name, sh_type, off, size, link, info, ent in raw:
        end = strtab.find(b"\0", sh_name)
        out.append(
            {
                "name": strtab[sh_name:end].decode(),
                "type": sh_type,
                "offset": off,
                "size": size,
                "link": link,
                "info": info,
                "entsize": ent,
            }
        )
    return e_machine, e_shoff + e_shnum * e_shentsize, out


def elf_symbols(data, sections):
    """Return the symbols of an ELF file's symbol table.

    Receives the file data and its sections. Returns a list of dicts with name,
    bind, type, shndx and value; raises CheckError when there is no symbol table.
    """
    # find the symbol table section
    for s in sections:
        # the symbol table section (SHT_SYMTAB)
        if s["type"] == 2:
            strs = sections[s["link"]]
            stab = data[strs["offset"] : strs["offset"] + strs["size"]]
            syms = []
            # each symbol entry is 24 bytes
            for i in range(s["size"] // 24):
                st_name, st_info, st_other, st_shndx, st_value, st_size = (
                    struct.unpack_from("<IBBHQQ", data, s["offset"] + i * 24)
                )
                end = stab.find(b"\0", st_name)
                syms.append(
                    {
                        "name": stab[st_name:end].decode(),
                        "bind": st_info >> 4,
                        "type": st_info & 0xF,
                        "shndx": st_shndx,
                        "value": st_value,
                    }
                )
            return syms
    raise CheckError("no symbol table")


def embedded_bpf_objects(path):
    """The BPF ELF objects embedded in a scheduler binary (the skeleton includes the
    compiled object as bytes).
    """
    data = open(path, "rb").read()
    found = []
    # every ELF header inside the binary is a candidate for an embedded object
    for m in re.finditer(b"\x7fELF\x02\x01\x01", data):
        start = m.start()
        # the binary's own header at offset 0 is not an embedded object
        if start == 0:
            continue
        # a candidate that does not parse is skipped
        try:
            machine, size, _ = elf_sections(data[start:])
        except CheckError, struct.error, IndexError:
            continue
        # only objects built for BPF are kept
        if machine == EM_BPF:
            found.append(data[start : start + size])
    return found


def analyse_object(obj):
    """(required imports, weak imports, struct_ops member names set with a program) of
    one BPF object.
    """
    machine, _, secs = elf_sections(obj)
    syms = elf_symbols(obj, secs)
    required, weak = set(), set()
    # collect the imports of the object: required and weak
    for s in syms:
        # undefined (SHN_UNDEF), global or weak symbols are the imports
        if s["shndx"] == 0 and s["name"] and s["bind"] in (1, 2):
            (weak if s["bind"] == 2 else required).add(s["name"])
    # collect the BTF section of the object
    btf_sec = [s for s in secs if s["name"] == ".BTF"]
    # without BTF the object's struct_ops members cannot be named
    if not btf_sec:
        raise CheckError("the BPF object has no .BTF section")
    types = parse_btf(
        obj[btf_sec[0]["offset"] : btf_sec[0]["offset"] + btf_sec[0]["size"]]
    )
    # the object's own definition of struct sched_ext_ops
    ops = [
        t for t in types if t["kind"] == Kind.STRUCT and t["name"] == "sched_ext_ops"
    ]
    # an object without that struct is not a sched_ext scheduler
    if not ops:
        raise CheckError("the BPF object's BTF has no struct sched_ext_ops")
    by_off = {}
    # member offsets in bytes, to match relocations against
    for mname, mbits in ops[0]["members"]:
        by_off.setdefault(mbits // 8, mname)
    members = set()
    # each struct_ops relocation section names the members the object sets
    for i, s in enumerate(secs):
        # a relocation section (SHT_REL) against a struct_ops section
        if s["type"] == 9 and secs[s["info"]]["name"].startswith(".struct_ops"):
            # every relocation entry is 16 bytes
            for r in range(s["size"] // 16):
                r_offset, r_info = struct.unpack_from("<QQ", obj, s["offset"] + r * 16)
                # a relocation at a member's offset means the member is set with a
                # program
                if r_offset in by_off:
                    members.add(by_off[r_offset])
    return required, weak, members


def decompress_vmlinuz(path):
    """The vmlinux image inside an x86 bzImage: payload offset and length come from the
    setup header.
    """
    data = open(path, "rb").read()
    # a bzImage carries the setup header magic at 0x202
    if data[0x202:0x206] != b"HdrS":
        raise CheckError("vmlinuz is not an x86 bzImage")
    setup_sects = data[0x1F1] or 4
    start = (setup_sects + 1) * 512
    payload_off, payload_len = struct.unpack_from("<II", data, 0x248)
    payload = data[start + payload_off : start + payload_off + payload_len]
    tools = {
        b"\x28\xb5\x2f\xfd": ["zstd", "-dc"],
        b"\xfd7zXZ\x00": ["xz", "-dc"],
        b"\x1f\x8b": ["gzip", "-dc"],
    }
    # find the compression of the payload by its magic bytes
    for magic, cmd in tools.items():
        # the tool that matches the magic unpacks the payload
        if payload.startswith(magic):
            # the unpacking tool may be missing
            try:
                r = subprocess.run(cmd, input=payload, capture_output=True)
            except OSError as e:
                raise CheckError("cannot run %s to unpack the kernel: %s" % (cmd[0], e))
            # the payload is followed by a few trailer bytes, so the tool may exit
            # non-zero after writing all of the image
            if r.stdout[:4] != b"\x7fELF":
                raise CheckError(
                    "%s did not produce a kernel image (exit %d)"
                    % (cmd[0], r.returncode)
                )
            return r.stdout
    raise CheckError(
        "unknown kernel payload compression (starts with %s)" % payload[:6].hex()
    )


def kernel_btf(kernel_dir):
    """Return the types of the kernel's own BTF.

    Receives the kernel directory (with vmlinuz); raises CheckError when vmlinuz
    cannot be unpacked or has no .BTF section.
    """
    vmlinux = decompress_vmlinuz(os.path.join(kernel_dir, "vmlinuz"))
    _, _, secs = elf_sections(vmlinux)
    # the BTF section of the unpacked vmlinux
    btf = [s for s in secs if s["name"] == ".BTF"]
    # a kernel without BTF cannot be compared against
    if not btf:
        raise CheckError("the kernel has no .BTF section")
    return parse_btf(vmlinux[btf[0]["offset"] : btf[0]["offset"] + btf[0]["size"]])


def main():
    """Run the checks and print one line per result.

    Reads the command line (--kernel-dir, --binary-dir, --run-script, --manifest and
    optional scheduler names). Prints lines that start with ok, FAIL, WARN or note.
    Returns 1 when a required import or struct_ops member is missing, the kernel
    config lacks a needed option or a scheduler cannot be analysed; 0 otherwise.
    """
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel-dir", required=True)
    ap.add_argument("--binary-dir", default="/usr/bin")
    ap.add_argument("--run-script", default="/usr/libexec/octarine-os/scx-run")
    ap.add_argument("--manifest", default="/usr/share/octarine-os/schedulers.tsv")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    failed = False
    kver = os.path.basename(os.path.normpath(args.kernel_dir))

    # 1. the kernel config
    cfg = {}
    cfg_path = os.path.join(args.kernel_dir, "config")
    # an unreadable config fails the check
    try:
        # read every `CONFIG_X=value` and `# CONFIG_X is not set` line
        for line in open(cfg_path):
            m = re.match(r"^(CONFIG_[A-Z0-9_]+)=(.*)$", line.strip())
            # an option that is set
            if m:
                cfg[m.group(1)] = m.group(2)
            m = re.match(r"^# (CONFIG_[A-Z0-9_]+) is not set$", line.strip())
            # an option that is explicitly not set
            if m:
                cfg[m.group(1)] = "n"
    except OSError as e:
        print("FAIL kernel config unreadable: %s" % e)
        return 1
    # the options without which no scheduler can load
    for key in (
        "CONFIG_SCHED_CLASS_EXT",
        "CONFIG_BPF_SYSCALL",
        "CONFIG_DEBUG_INFO_BTF",
    ):
        # each of them must be y
        if cfg.get(key) == "y":
            print("ok   %s=y in the %s kernel config" % (key, kver))
        else:
            print(
                "FAIL %s is not y in the %s kernel config (%s): no scheduler can load"
                % (key, kver, cfg.get(key, "unset"))
            )
            failed = True

    # 2. the kernel's BTF and symbols
    types = None
    # read the kernel's BTF; without it the symbol comparison is skipped with a warning
    try:
        types = kernel_btf(args.kernel_dir)
        print("ok   kernel BTF read from vmlinuz (%d types)" % len(types))
    except CheckError as e:
        print(
            "WARN kernel BTF could not be read (%s): the comparison below is skipped, only the config check counts"
            % e
        )
    # without BTF only the config check counts
    if types is None:
        return 1 if failed else 0
    # the names of the kernel's functions
    kernel_funcs = {t["name"] for t in types if t["kind"] == Kind.FUNC}
    # the names of the kernel's variables
    kernel_vars = {t["name"] for t in types if t["kind"] == Kind.VAR}
    # the kernel's own definition of struct sched_ext_ops
    kops = [
        t for t in types if t["kind"] == Kind.STRUCT and t["name"] == "sched_ext_ops"
    ]
    # a kernel without it has no usable sched_ext
    if not kops:
        print(
            "FAIL the kernel BTF has no struct sched_ext_ops: this kernel has no usable sched_ext"
        )
        return 1
    # the member names of the kernel's struct sched_ext_ops
    kernel_members = {m for m, _ in kops[0]["members"]}
    sysmap = set()
    # System.map adds kernel variables that BTF may not list
    try:
        # each line is address, type, name
        for line in open(os.path.join(args.kernel_dir, "System.map")):
            parts = line.split()
            # only complete lines carry a name
            if len(parts) == 3:
                sysmap.add(parts[2])
    except OSError:
        print("WARN System.map not found: kernel variables are checked in BTF only")

    # 3. each scheduler binary
    names = args.names
    # no names on the command line: read them from the manifest
    if not names:
        names = []
        # the manifest has one scheduler per line, name first
        for line in open(args.manifest):
            # blank and comment lines are skipped
            if line.strip() and not line.startswith("#"):
                names.append(line.split("\t")[0])
    # an empty manifest leaves nothing to check
    if not names:
        print("FAIL no scheduler to check")
        return 1
    # the mechanism that gives libbpf a kernel config (see 4. above): scx-run runs the
    # scheduler in a private mount namespace
    try:
        run_text = open(args.run_script).read()
    except OSError:
        run_text = ""
    # all four markers must be present in the run script
    wrapper = all(
        m in run_text
        for m in ("unshare", "--bind", "config-${rel}", "/usr/lib/modules")
    )
    needing = []
    # check each scheduler in turn
    for name in names:
        path = os.path.join(args.binary_dir, name)
        # a binary that cannot be read or parsed fails its own check, not the whole run
        try:
            objs = embedded_bpf_objects(path)
            # an object-less binary is not a Rust scheduler with a BPF skeleton
            if not objs:
                raise CheckError("no embedded BPF object found in %s" % path)
            req, weak, members = set(), set(), set()
            # merge the imports and members of every embedded object
            for o in objs:
                r, w, m = analyse_object(o)
                req |= r
                weak |= w
                members |= m
        except (CheckError, OSError, struct.error) as e:
            print("FAIL %s: %s" % (name, e))
            failed = True
            continue
        # a scheduler that sets no member is not understood by this reader: fail
        if not members:
            print(
                "FAIL %s: found no struct_ops member (the reader is wrong or the object is unexpected)"
                % name
            )
            failed = True
            continue

        def known(sym):
            """Whether a symbol exists as far as this check can tell.

            Receives the symbol name; returns True for libbpf's own externs,
            for a CONFIG_ option the kernel config knows, or for a kernel
            function, variable or System.map symbol.
            """
            # CONFIG_* and LINUX_KERNEL_VERSION are libbpf's own externs (.kconfig),
            # filled from the kernel config at load time: they are not kernel symbols; a
            # CONFIG_ option must at least be known to the image's kernel config
            if sym == "LINUX_KERNEL_VERSION":
                return True
            # CONFIG_ options are looked up in the kernel config, not in the symbol
            # tables
            if sym.startswith("CONFIG_"):
                return sym in cfg
            return sym in kernel_funcs or sym in kernel_vars or sym in sysmap

        # required imports the kernel lacks
        miss_req = sorted(s for s in req if not known(s))
        # weak imports the kernel lacks (only a note)
        miss_weak = sorted(
            s for s in weak if not known(s) and not s.startswith("CONFIG_")
        )
        # the CONFIG_ externs libbpf resolves at load time
        kconfig = sorted(s for s in (req | weak) if s.startswith("CONFIG_"))
        # struct_ops members the scheduler sets that this kernel lacks
        miss_members = sorted(m for m in members if m not in kernel_members)
        status = "ok  "
        # a missing required import or member fails the scheduler
        if miss_req or miss_members:
            status = "FAIL"
            failed = True
        # a .kconfig extern without the run script's mount trick fails at load time
        if kconfig and not wrapper:
            status = "FAIL"
            failed = True
        print(
            "%s %s: %d required imports, %d weak, %d struct_ops members set"
            % (status, name, len(req), len(weak), len(members))
        )
        # show the .kconfig externs of this scheduler
        if kconfig:
            needing.append(name)
            print(
                "       .kconfig externs (libbpf reads the kernel config at load time): %s"
                % ", ".join(kconfig)
            )
            # say why the missing mechanism matters
            if not wrapper:
                print(
                    "       FAIL: libbpf finds no kernel config here (no /boot/config-<release>, no /proc/config.gz) and %s does not give the scheduler one"
                    % args.run_script
                )
        # list the missing kernel symbols
        if miss_req:
            print(
                "       required kernel symbols missing from %s: %s"
                % (kver, ", ".join(miss_req))
            )
        # list the missing struct_ops members
        if miss_members:
            print(
                "       struct sched_ext_ops members set by the scheduler but absent from the kernel: %s"
                % ", ".join(miss_members)
            )
        # weak imports are only a note
        if miss_weak:
            print(
                "       note: optional (weak) imports absent from the kernel, the compat layer handles them: %s"
                % ", ".join(miss_weak)
            )
    print(
        "schedulers that need a kernel config at load time (CONFIG_* externs): %s; run script provides it: %s"
        % (", ".join(needing) or "none", "yes" if wrapper else "no")
    )
    print(
        "limits: static comparison only; verifier acceptance, changed semantics and the userspace side are not checked"
    )
    return 1 if failed else 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
