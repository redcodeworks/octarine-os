#!/usr/bin/env python3
"""Tier 1 compatibility check of the shipped sched_ext schedulers against the image's own kernel, statically.

    scx-kernel-check.py --kernel-dir /usr/lib/modules/<kver> [--binary-dir /usr/bin] [--manifest schedulers.tsv] [NAME ...]

What it checks (nothing is loaded, no BPF runs; a real machine still has to load a scheduler):

  1. The kernel config in the image (config next to vmlinuz): CONFIG_SCHED_CLASS_EXT=y, CONFIG_BPF_SYSCALL=y and
     CONFIG_DEBUG_INFO_BTF=y. This part is simple and reliable; without it no scheduler can load.
  2. The kernel's BTF, read out of vmlinuz (the bzImage payload is decompressed with the zstd, xz or gzip tool, then the
     .BTF section of the vmlinux ELF is parsed). Without a readable BTF the comparison below is skipped with a warning
     (check 1 still counts).
  3. For every scheduler binary: the BPF object that the Rust program embeds (an ELF of machine EM_BPF) is parsed and
       - every REQUIRED kernel symbol it imports (an undefined, non-weak symbol: kfuncs and kernel variables) must exist in the
         kernel: as a BTF function or variable, or as a symbol in System.map. Weak imports are optional (the scx compat layer
         guards them with bpf_ksym_exists) and are only listed as notes.
       - every member of struct sched_ext_ops that its struct_ops sets with a program must exist in the kernel's own
         struct sched_ext_ops (members are found through the relocations of the .struct_ops* sections and the object's BTF).
  The check exits 1 when a required import or a set member is missing from the kernel. Limits (printed, not hidden): it does not
  prove that the verifier accepts the programs, that a member's meaning is unchanged, or that the userspace side works.
"""
import argparse
import glob
import os
import re
import struct
import subprocess
import sys

BTF_MAGIC = 0xEB9F
KIND_INT, KIND_PTR, KIND_ARRAY, KIND_STRUCT, KIND_UNION, KIND_ENUM = 1, 2, 3, 4, 5, 6
KIND_FWD, KIND_TYPEDEF, KIND_VOLATILE, KIND_CONST, KIND_RESTRICT, KIND_FUNC = 7, 8, 9, 10, 11, 12
KIND_FUNC_PROTO, KIND_VAR, KIND_DATASEC, KIND_FLOAT, KIND_DECL_TAG, KIND_TYPE_TAG, KIND_ENUM64 = 13, 14, 15, 16, 17, 18, 19
EM_BPF = 247


class CheckError(Exception):
    pass


def parse_btf(blob):
    """Return (types, strings) of a BTF blob: types is a list of dicts (index 0 is void), strings a function name -> str."""
    if len(blob) < 24:
        raise CheckError("BTF too short")
    magic, version, flags, hdr_len, type_off, type_len, str_off, str_len = struct.unpack_from("<HBBIIIII", blob, 0)
    if magic != BTF_MAGIC:
        raise CheckError("not BTF (magic %#x)" % magic)
    sdata = blob[hdr_len + str_off: hdr_len + str_off + str_len]

    def name(off):
        end = sdata.find(b"\0", off)
        return sdata[off:end].decode("utf-8", "replace")

    types = [{"kind": 0, "name": "", "members": []}]
    pos = hdr_len + type_off
    end = pos + type_len
    while pos < end:
        name_off, info, size_type = struct.unpack_from("<III", blob, pos)
        pos += 12
        kind = (info >> 24) & 0x1F
        vlen = info & 0xFFFF
        t = {"kind": kind, "name": name(name_off), "vlen": vlen, "size": size_type, "members": []}
        if kind == KIND_INT:
            pos += 4
        elif kind == KIND_ARRAY:
            pos += 12
        elif kind in (KIND_STRUCT, KIND_UNION):
            for _ in range(vlen):
                m_name, m_type, m_off = struct.unpack_from("<III", blob, pos)
                pos += 12
                # with kind_flag the offset field packs a bitfield size in its top byte
                if info >> 31:
                    m_off &= 0xFFFFFF
                t["members"].append((name(m_name), m_off))
        elif kind == KIND_ENUM:
            pos += 8 * vlen
        elif kind == KIND_ENUM64:
            pos += 12 * vlen
        elif kind == KIND_FUNC_PROTO:
            pos += 8 * vlen
        elif kind == KIND_VAR:
            pos += 4
        elif kind == KIND_DATASEC:
            for _ in range(vlen):
                v_type, v_off, v_size = struct.unpack_from("<III", blob, pos)
                pos += 12
                t["members"].append((v_type, v_off))
        elif kind == KIND_DECL_TAG:
            pos += 4
        elif kind in (KIND_PTR, KIND_FWD, KIND_TYPEDEF, KIND_VOLATILE, KIND_CONST, KIND_RESTRICT, KIND_FUNC, KIND_FLOAT, KIND_TYPE_TAG):
            pass
        else:
            raise CheckError("unknown BTF kind %d" % kind)
        types.append(t)
    return types


def elf_sections(data):
    """Section list of an ELF64 little-endian file: dicts with name, type, offset, size, link, info, entsize."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise CheckError("not an ELF64 little-endian file")
    e_machine = struct.unpack_from("<H", data, 18)[0]
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)
    raw = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_align, sh_entsize = struct.unpack_from("<IIQQQQIIQQ", data, o)
        raw.append((sh_name, sh_type, sh_offset, sh_size, sh_link, sh_info, sh_entsize))
    shstr = raw[e_shstrndx]
    strtab = data[shstr[2]: shstr[2] + shstr[3]]
    out = []
    for sh_name, sh_type, off, size, link, info, ent in raw:
        end = strtab.find(b"\0", sh_name)
        out.append({"name": strtab[sh_name:end].decode(), "type": sh_type, "offset": off, "size": size, "link": link, "info": info, "entsize": ent})
    return e_machine, e_shoff + e_shnum * e_shentsize, out


def elf_symbols(data, sections):
    for s in sections:
        if s["type"] == 2:  # SHT_SYMTAB
            strs = sections[s["link"]]
            stab = data[strs["offset"]: strs["offset"] + strs["size"]]
            syms = []
            for i in range(s["size"] // 24):
                st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", data, s["offset"] + i * 24)
                end = stab.find(b"\0", st_name)
                syms.append({"name": stab[st_name:end].decode(), "bind": st_info >> 4, "type": st_info & 0xF, "shndx": st_shndx, "value": st_value})
            return syms
    raise CheckError("no symbol table")


def embedded_bpf_objects(path):
    """The BPF ELF objects embedded in a scheduler binary (the skeleton includes the compiled object as bytes)."""
    data = open(path, "rb").read()
    found = []
    for m in re.finditer(b"\x7fELF\x02\x01\x01", data):
        start = m.start()
        if start == 0:
            continue
        try:
            machine, size, _ = elf_sections(data[start:])
        except (CheckError, struct.error, IndexError):
            continue
        if machine == EM_BPF:
            found.append(data[start: start + size])
    return found


def analyse_object(obj):
    """(required imports, weak imports, struct_ops member names set with a program) of one BPF object."""
    machine, _, secs = elf_sections(obj)
    syms = elf_symbols(obj, secs)
    required, weak = set(), set()
    for s in syms:
        if s["shndx"] == 0 and s["name"] and s["bind"] in (1, 2):  # SHN_UNDEF, GLOBAL or WEAK
            (weak if s["bind"] == 2 else required).add(s["name"])
    btf_sec = [s for s in secs if s["name"] == ".BTF"]
    if not btf_sec:
        raise CheckError("the BPF object has no .BTF section")
    types = parse_btf(obj[btf_sec[0]["offset"]: btf_sec[0]["offset"] + btf_sec[0]["size"]])
    ops = [t for t in types if t["kind"] == KIND_STRUCT and t["name"] == "sched_ext_ops"]
    if not ops:
        raise CheckError("the BPF object's BTF has no struct sched_ext_ops")
    by_off = {}
    for mname, mbits in ops[0]["members"]:
        by_off.setdefault(mbits // 8, mname)
    members = set()
    for i, s in enumerate(secs):
        if s["type"] == 9 and secs[s["info"]]["name"].startswith(".struct_ops"):  # SHT_REL against a struct_ops section
            for r in range(s["size"] // 16):
                r_offset, r_info = struct.unpack_from("<QQ", obj, s["offset"] + r * 16)
                if r_offset in by_off:
                    members.add(by_off[r_offset])
    return required, weak, members


def decompress_vmlinuz(path):
    """The vmlinux image inside an x86 bzImage: payload offset and length come from the setup header."""
    data = open(path, "rb").read()
    if data[0x202:0x206] != b"HdrS":
        raise CheckError("vmlinuz is not an x86 bzImage")
    setup_sects = data[0x1F1] or 4
    start = (setup_sects + 1) * 512
    payload_off, payload_len = struct.unpack_from("<II", data, 0x248)
    payload = data[start + payload_off: start + payload_off + payload_len]
    tools = {b"\x28\xb5\x2f\xfd": ["zstd", "-dc"], b"\xfd7zXZ\x00": ["xz", "-dc"], b"\x1f\x8b": ["gzip", "-dc"]}
    for magic, cmd in tools.items():
        if payload.startswith(magic):
            try:
                r = subprocess.run(cmd, input=payload, capture_output=True)
            except OSError as e:
                raise CheckError("cannot run %s to unpack the kernel: %s" % (cmd[0], e))
            # the payload is followed by a few trailer bytes, so the tool may exit non-zero after writing all of the image
            if r.stdout[:4] != b"\x7fELF":
                raise CheckError("%s did not produce a kernel image (exit %d)" % (cmd[0], r.returncode))
            return r.stdout
    raise CheckError("unknown kernel payload compression (starts with %s)" % payload[:6].hex())


def kernel_btf(kernel_dir):
    vmlinux = decompress_vmlinuz(os.path.join(kernel_dir, "vmlinuz"))
    _, _, secs = elf_sections(vmlinux)
    btf = [s for s in secs if s["name"] == ".BTF"]
    if not btf:
        raise CheckError("the kernel has no .BTF section")
    return parse_btf(vmlinux[btf[0]["offset"]: btf[0]["offset"] + btf[0]["size"]])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel-dir", required=True)
    ap.add_argument("--binary-dir", default="/usr/bin")
    ap.add_argument("--manifest", default="/usr/share/octarine-os/schedulers.tsv")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    failed = False
    kver = os.path.basename(os.path.normpath(args.kernel_dir))

    # 1. the kernel config
    cfg = {}
    cfg_path = os.path.join(args.kernel_dir, "config")
    try:
        for line in open(cfg_path):
            m = re.match(r"^(CONFIG_[A-Z0-9_]+)=(.*)$", line.strip())
            if m:
                cfg[m.group(1)] = m.group(2)
            m = re.match(r"^# (CONFIG_[A-Z0-9_]+) is not set$", line.strip())
            if m:
                cfg[m.group(1)] = "n"
    except OSError as e:
        print("FAIL kernel config unreadable: %s" % e)
        return 1
    for key in ("CONFIG_SCHED_CLASS_EXT", "CONFIG_BPF_SYSCALL", "CONFIG_DEBUG_INFO_BTF"):
        if cfg.get(key) == "y":
            print("ok   %s=y in the %s kernel config" % (key, kver))
        else:
            print("FAIL %s is not y in the %s kernel config (%s): no scheduler can load" % (key, kver, cfg.get(key, "unset")))
            failed = True

    # 2. the kernel's BTF and symbols
    types = None
    try:
        types = kernel_btf(args.kernel_dir)
        print("ok   kernel BTF read from vmlinuz (%d types)" % len(types))
    except CheckError as e:
        print("WARN kernel BTF could not be read (%s): the comparison below is skipped, only the config check counts" % e)
    if types is None:
        return 1 if failed else 0
    kernel_funcs = {t["name"] for t in types if t["kind"] == KIND_FUNC}
    kernel_vars = {t["name"] for t in types if t["kind"] == KIND_VAR}
    kops = [t for t in types if t["kind"] == KIND_STRUCT and t["name"] == "sched_ext_ops"]
    if not kops:
        print("FAIL the kernel BTF has no struct sched_ext_ops: this kernel has no usable sched_ext")
        return 1
    kernel_members = {m for m, _ in kops[0]["members"]}
    sysmap = set()
    try:
        for line in open(os.path.join(args.kernel_dir, "System.map")):
            parts = line.split()
            if len(parts) == 3:
                sysmap.add(parts[2])
    except OSError:
        print("WARN System.map not found: kernel variables are checked in BTF only")

    # 3. each scheduler binary
    names = args.names
    if not names:
        names = []
        for line in open(args.manifest):
            if line.strip() and not line.startswith("#"):
                names.append(line.split("\t")[0])
    if not names:
        print("FAIL no scheduler to check")
        return 1
    for name in names:
        path = os.path.join(args.binary_dir, name)
        try:
            objs = embedded_bpf_objects(path)
            if not objs:
                raise CheckError("no embedded BPF object found in %s" % path)
            req, weak, members = set(), set(), set()
            for o in objs:
                r, w, m = analyse_object(o)
                req |= r
                weak |= w
                members |= m
        except (CheckError, OSError, struct.error) as e:
            print("FAIL %s: %s" % (name, e))
            failed = True
            continue
        if not members:
            print("FAIL %s: found no struct_ops member (the reader is wrong or the object is unexpected)" % name)
            failed = True
            continue
        def known(sym):
            # CONFIG_* and LINUX_KERNEL_VERSION are libbpf's own externs (.kconfig), filled from the kernel config at load time:
            # they are not kernel symbols; a CONFIG_ option must at least be known to the image's kernel config
            if sym == "LINUX_KERNEL_VERSION":
                return True
            if sym.startswith("CONFIG_"):
                return sym in cfg
            return sym in kernel_funcs or sym in kernel_vars or sym in sysmap
        miss_req = sorted(s for s in req if not known(s))
        miss_weak = sorted(s for s in weak if not known(s) and not s.startswith("CONFIG_"))
        miss_members = sorted(m for m in members if m not in kernel_members)
        status = "ok  "
        if miss_req or miss_members:
            status = "FAIL"
            failed = True
        print("%s %s: %d required imports, %d weak, %d struct_ops members set" % (status, name, len(req), len(weak), len(members)))
        if miss_req:
            print("       required kernel symbols missing from %s: %s" % (kver, ", ".join(miss_req)))
        if miss_members:
            print("       struct sched_ext_ops members set by the scheduler but absent from the kernel: %s" % ", ".join(miss_members))
        if miss_weak:
            print("       note: optional (weak) imports absent from the kernel, the compat layer handles them: %s" % ", ".join(miss_weak))
    print("limits: static comparison only; verifier acceptance, changed semantics and the userspace side are not checked")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
