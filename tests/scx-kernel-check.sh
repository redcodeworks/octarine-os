#!/usr/bin/env bash
# Tests for the Tier 1 scheduler/kernel check (.github/scripts/scx-kernel-check.py) with a SYNTHETIC kernel directory (config,
# System.map and a bzImage whose gzip payload is a fake vmlinux ELF with a .BTF section) and synthetic scheduler binaries that embed
# a hand-built BPF ELF object (symbols, .BTF with struct sched_ext_ops, .rel.struct_ops.link). It proves the reader and the decisions;
# the real kernel and the real schedulers are read by the image build. Needs: bash, python3, gzip. Run: tests/scx-kernel-check.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -I - "$here/.github/scripts/scx-kernel-check.py" <<'PYEOF'
import gzip, importlib.util, io, os, struct, subprocess, sys, tempfile, contextlib

spec = importlib.util.spec_from_file_location("k", sys.argv[1])
k = importlib.util.module_from_spec(spec)
spec.loader.exec_module(k)
passed = failed = 0
RUN_SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(sys.argv[1]))), "system_files/usr/libexec/octarine-os/scx-run")

def result(ok, msg):
    global passed, failed
    print(("ok   " if ok else "FAIL ") + msg)
    if ok:
        passed += 1
    else:
        failed += 1

# ---- builders
class Strs:
    def __init__(self):
        self.b = b"\0"
        self.idx = {"": 0}
    def add(self, s):
        if s not in self.idx:
            self.idx[s] = len(self.b)
            self.b += s.encode() + b"\0"
        return self.idx[s]

def btf(structs=(), funcs=(), vars_=()):
    """structs: [(name, [(member, byte_offset)])]. Returns a BTF blob: type 1 is INT, then structs, funcs, vars."""
    st = Strs()
    types = b""
    types += struct.pack("<III", st.add("long"), 1 << 24, 8) + struct.pack("<I", 0)  # INT, 4 more bytes
    n = 1
    for name, members in structs:
        types += struct.pack("<III", st.add(name), (4 << 24) | len(members), 64)
        for m, off in members:
            types += struct.pack("<III", st.add(m), 1, off * 8)
        n += 1
    for f in funcs:
        types += struct.pack("<III", st.add(f), 12 << 24, 1)
        n += 1
    for v in vars_:
        types += struct.pack("<III", st.add(v), 14 << 24, 1) + struct.pack("<I", 1)
        n += 1
    hdr = struct.pack("<HBBIIIII", 0xEB9F, 1, 0, 24, 0, len(types), len(types), len(st.b))
    return hdr + types + st.b

def elf(machine, sections):
    """sections: [(name, type, data, link, info, entsize)] after the null section; a .shstrtab is added last."""
    st = Strs()
    body = b""
    shdrs = [struct.pack("<IIQQQQIIQQ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)]
    off = 64
    items = list(sections) + [(".shstrtab", 3, None, 0, 0, 0)]
    names = [st.add(i[0]) for i in items]
    # the shstrtab data is known once every name is added
    for (name, typ, data, link, info, ent), nm in zip(items, names):
        if data is None:
            data = st.b
        pad = (-off) % 8
        body += b"\0" * pad
        off += pad
        shdrs.append(struct.pack("<IIQQQQIIQQ", nm, typ, 0, 0, off, len(data), link, info, 8, ent))
        body += data
        off += len(data)
    pad = (-off) % 8
    body += b"\0" * pad
    off += pad
    shoff = off
    hdr = b"\x7fELF\x02\x01\x01" + b"\0" * 9 + struct.pack("<HHIQQQIHHHHHH", 1, machine, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(shdrs), len(shdrs) - 1)
    return hdr + body + b"".join(shdrs)

def bpf_object(imports, members):
    """imports: [(name, 'global'|'weak')]; members: ops member names the struct_ops sets with a program."""
    layout = ["name", "enqueue", "dispatch", "select_cpu", "init", "exit"]
    offsets = [(m, 8 * i) for i, m in enumerate(layout)]
    objbtf = btf(structs=[("sched_ext_ops", offsets)])
    sy = Strs()
    syms = [struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)]
    syms.append(struct.pack("<IBBHQQ", sy.add("prog"), (1 << 4) | 2, 0, 3, 0, 0))   # a FUNC in some section
    for name, bind in imports:
        syms.append(struct.pack("<IBBHQQ", sy.add(name), ((1 if bind == "global" else 2) << 4) | 0, 0, 0, 0, 0))
    rels = b"".join(struct.pack("<QQ", 8 * layout.index(m), (1 << 32) | 1) for m in members)
    # section indexes: 1 .BTF, 2 .struct_ops.link, 3 .rel.struct_ops.link, 4 .symtab, 5 .strtab
    return elf(247, [
        (".BTF", 1, objbtf, 0, 0, 0),
        (".struct_ops.link", 1, b"\0" * 48, 0, 0, 0),
        (".rel.struct_ops.link", 9, rels, 4, 2, 16),
        (".symtab", 2, b"".join(syms), 5, 1, 24),
        (".strtab", 3, sy.b, 0, 0, 0),
    ])

def kernel_dir(root, kver="6.99.0-test", funcs=(), vars_=(), members=("name", "enqueue", "dispatch", "select_cpu", "init", "exit"),
               config=("CONFIG_SCHED_CLASS_EXT=y", "CONFIG_BPF_SYSCALL=y", "CONFIG_DEBUG_INFO_BTF=y", "CONFIG_NR_CPUS=8192", "# CONFIG_PREEMPT_RT is not set"),
               sysmap=("scx_bpf_in_sysmap",), payload="btf"):
    d = os.path.join(root, kver)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "config"), "w").write("\n".join(config) + "\n")
    open(os.path.join(d, "System.map"), "w").write("".join("ffffffff81000000 T %s\n" % s for s in sysmap))
    blob = btf(structs=[("sched_ext_ops", [(m, 8 * i) for i, m in enumerate(members)])], funcs=funcs, vars_=vars_)
    if payload == "btf":
        vmlinux = elf(2, [(".BTF", 1, blob, 0, 0, 0)])
    else:
        vmlinux = elf(2, [(".text", 1, b"\x90" * 16, 0, 0, 0)])   # a kernel without .BTF
    comp = gzip.compress(vmlinux)
    setup = bytearray(512 * 5)
    setup[0x1F1] = 4
    setup[0x202:0x206] = b"HdrS"
    struct.pack_into("<II", setup, 0x248, 0, len(comp))
    open(os.path.join(d, "vmlinuz"), "wb").write(bytes(setup) + comp)
    return d

def binary(root, name, imports, members, objects=1):
    os.makedirs(os.path.join(root, "bin"), exist_ok=True)
    path = os.path.join(root, "bin", name)
    blob = b"\x7fELF\x02\x01\x01" + b"\0" * 200 + (b"junk" * 50)
    for _ in range(objects):
        blob += bpf_object(imports, members) + b"\0\0\0"
    open(path, "wb").write(blob)
    return path

def run(kdir, names, root):
    out = io.StringIO()
    argv = sys.argv
    sys.argv = ["x", "--kernel-dir", kdir, "--binary-dir", os.path.join(root, "bin"), "--run-script", RUN_SCRIPT] + names
    try:
        with contextlib.redirect_stdout(out):
            rc = k.main()
    finally:
        sys.argv = argv
    return rc, out.getvalue()

base_imports = [("scx_bpf_dsq_insert", "global"), ("scx_bpf_in_sysmap", "global"), ("CONFIG_NR_CPUS", "global"), ("LINUX_KERNEL_VERSION", "global"),
                ("scx_bpf_dispatch___compat", "weak"), ("CONFIG_PREEMPT_RT", "weak")]
base_members = ["enqueue", "dispatch", "select_cpu"]

with tempfile.TemporaryDirectory() as root:
    # the readers on their own
    objs = k.embedded_bpf_objects(binary(root, "scx_ok", base_imports, base_members))
    result(len(objs) == 1, "the embedded BPF object is found inside a binary (the host ELF at offset 0 is skipped)")
    req, weak, mem = k.analyse_object(objs[0])
    result(req == {"scx_bpf_dsq_insert", "scx_bpf_in_sysmap", "CONFIG_NR_CPUS", "LINUX_KERNEL_VERSION"} and weak == {"scx_bpf_dispatch___compat", "CONFIG_PREEMPT_RT"},
           "undefined global symbols are required imports, weak ones optional")
    result(mem == set(base_members), "struct_ops members come from the relocations and the object's own BTF layout: %s" % sorted(mem))

    kd = kernel_dir(root, funcs=["scx_bpf_dsq_insert"])
    rc, out = run(kd, ["scx_ok"], root)
    result(rc == 0 and "ok   scx_ok: 4 required imports, 2 weak, 3 struct_ops members set" in out and "kernel BTF read from vmlinuz" in out, "everything present: exit 0 (kfunc in BTF, symbol only in System.map, CONFIG_ and LINUX_KERNEL_VERSION are libbpf's own)")
    result(".kconfig externs (libbpf reads the kernel config at load time): CONFIG_NR_CPUS, CONFIG_PREEMPT_RT" in out and "need a kernel config at load time (CONFIG_* externs): scx_ok; run script provides it: yes" in out,
           "the CONFIG_* externs are listed per scheduler (not LINUX_KERNEL_VERSION) and the summary names the schedulers that need a kernel config")
    argv0 = sys.argv
    sys.argv = ["x", "--kernel-dir", kd, "--binary-dir", os.path.join(root, "bin"), "--run-script", os.path.join(root, "no-such-scx-run"), "scx_ok"]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc_nw = k.main()
    sys.argv = argv0
    result(rc_nw == 1 and "FAIL scx_ok" in buf.getvalue() and "does not give the scheduler one" in buf.getvalue(),
           "a scheduler with CONFIG_* externs FAILS the build when scx-run lacks the kernel-config mechanism (libbpf finds no config in the image)")
    stub = os.path.join(root, "scx-run-without")
    open(stub, "w").write("#!/bin/sh\nexec \"$@\"\n")
    sys.argv = ["x", "--kernel-dir", kd, "--binary-dir", os.path.join(root, "bin"), "--run-script", stub, "scx_ok"]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc_nw2 = k.main()
    sys.argv = argv0
    result(rc_nw2 == 1, "an scx-run that merely execs the binary is not the mechanism")
    result("note: optional (weak) imports absent from the kernel" in out and "scx_bpf_dispatch___compat" in out, "a missing weak import is only a note")

    kd = kernel_dir(root, kver="6.98.0-test", funcs=[])
    rc, out = run(kd, ["scx_ok"], root)
    result(rc == 1 and "FAIL scx_ok" in out and "required kernel symbols missing from 6.98.0-test: scx_bpf_dsq_insert" in out, "a REQUIRED kfunc that the kernel lacks fails and is named")

    kd = kernel_dir(root, kver="6.97.0-test", funcs=["scx_bpf_dsq_insert"], members=("name", "enqueue", "dispatch", "init", "exit"))
    rc, out = run(kd, ["scx_ok"], root)
    result(rc == 1 and "absent from the kernel: select_cpu" in out, "a struct sched_ext_ops member the scheduler sets but the kernel struct lacks fails and is named")

    kd = kernel_dir(root, kver="6.96.0-test", funcs=["scx_bpf_dsq_insert"], vars_=[])
    binary(root, "scx_var", base_imports + [("scx_kernel_var", "global")], base_members)
    rc, out = run(kd, ["scx_var"], root)
    result(rc == 1 and "scx_kernel_var" in out, "a required kernel variable that is in neither BTF nor System.map fails")
    kd2 = kernel_dir(root, kver="6.95.0-test", funcs=["scx_bpf_dsq_insert"], vars_=["scx_kernel_var"])
    rc, out = run(kd2, ["scx_var"], root)
    result(rc == 0, "the same variable found as a BTF VAR passes")

    kd = kernel_dir(root, kver="6.94.0-test", funcs=["scx_bpf_dsq_insert"], config=("CONFIG_BPF_SYSCALL=y", "CONFIG_DEBUG_INFO_BTF=y", "CONFIG_NR_CPUS=8192"))
    rc, out = run(kd, ["scx_ok"], root)
    result(rc == 1 and "FAIL CONFIG_SCHED_CLASS_EXT is not y" in out and "no scheduler can load" in out, "CONFIG_SCHED_CLASS_EXT missing from the kernel config fails")

    kd = kernel_dir(root, kver="6.93.0-test", funcs=["scx_bpf_dsq_insert"], config=("CONFIG_SCHED_CLASS_EXT=y", "CONFIG_BPF_SYSCALL=y", "CONFIG_DEBUG_INFO_BTF=n", "CONFIG_NR_CPUS=8192"))
    rc, out = run(kd, ["scx_ok"], root)
    result(rc == 1 and "FAIL CONFIG_DEBUG_INFO_BTF" in out, "CONFIG_DEBUG_INFO_BTF not y fails")

    kd = kernel_dir(root, kver="6.92.0-test", funcs=["scx_bpf_dsq_insert"], config=("CONFIG_SCHED_CLASS_EXT=y", "CONFIG_BPF_SYSCALL=y", "CONFIG_DEBUG_INFO_BTF=y"))
    rc, out = run(kd, ["scx_ok"], root)
    result(rc == 1 and "CONFIG_NR_CPUS" in out, "a required CONFIG_ extern that the kernel config does not know fails")

    kd = kernel_dir(root, kver="6.91.0-test", payload="nobtf")
    rc, out = run(kd, ["scx_ok"], root)
    result(rc == 0 and "WARN kernel BTF could not be read" in out and "the kernel has no .BTF section" in out and "CONFIG_SCHED_CLASS_EXT=y" in out, "a kernel image without readable BTF: the config part still counts, the comparison is skipped with a warning (exit 0)")

    kd = kernel_dir(root, kver="6.90.0-test", funcs=["scx_bpf_dsq_insert"])
    open(os.path.join(root, "bin", "scx_none"), "wb").write(b"\x7fELF\x02\x01\x01" + b"\0" * 300)
    rc, out = run(kd, ["scx_none"], root)
    result(rc == 1 and "no embedded BPF object" in out, "a binary without an embedded BPF object fails (the reader must not pass silently)")
    rc, out = run(kd, ["scx_missing_file"], root)
    result(rc == 1 and "FAIL scx_missing_file" in out, "a scheduler binary that is not there fails")
    binary(root, "scx_nomem", base_imports, [])
    rc, out = run(kd, ["scx_nomem"], root)
    result(rc == 1 and "found no struct_ops member" in out, "an object where no struct_ops member is found fails (a wrong reader is not a pass)")

    # all names from a manifest; a failure in one does not hide the others
    open(os.path.join(root, "m.tsv"), "w").write("# c\nscx_ok\tbin/scx_ok\t\tA\nscx_var\tbin/scx_var\t\tB\n")
    out = io.StringIO()
    argv = sys.argv
    sys.argv = ["x", "--kernel-dir", kernel_dir(root, kver="6.89.0-test", funcs=["scx_bpf_dsq_insert"]), "--binary-dir", os.path.join(root, "bin"), "--manifest", os.path.join(root, "m.tsv"), "--run-script", RUN_SCRIPT]
    with contextlib.redirect_stdout(out):
        rc = k.main()
    sys.argv = argv
    t = out.getvalue()
    result(rc == 1 and "ok   scx_ok" in t and "FAIL scx_var" in t, "the manifest lists the schedulers; one failing scheduler is reported next to the passing one and the exit is 1")

    # decompression of the other payload formats goes through the tools; an unknown one is refused
    d = os.path.join(root, "kx")
    os.makedirs(d)
    setup = bytearray(512 * 5)
    setup[0x1F1] = 4
    setup[0x202:0x206] = b"HdrS"
    struct.pack_into("<II", setup, 0x248, 0, 16)
    open(os.path.join(d, "vmlinuz"), "wb").write(bytes(setup) + b"\x00" * 16)
    try:
        k.decompress_vmlinuz(os.path.join(d, "vmlinuz"))
        result(False, "an unknown kernel payload compression is refused")
    except k.CheckError as e:
        result("unknown kernel payload compression" in str(e), "an unknown kernel payload compression is refused with a clear message")

    # the text of the check says what it does not prove
    out_text = run(kernel_dir(root, kver="6.88.0-test", funcs=["scx_bpf_dsq_insert"]), ["scx_ok"], root)[1]
    result("limits: static comparison only" in out_text, "the output states its limits")

print()
print("passed: %d, failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
PYEOF
