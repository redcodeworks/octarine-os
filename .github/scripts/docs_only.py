"""The one place that lists the files that do not need an image build: top-level *.md (README.md, AGENTS.md, CLAUDE.md ...), docs/** (the config guide is docs/CONFIG-GUIDE.md), LICENSE,
.gitignore, and the test suite (tests/**). Imported by plan_build.py and inputs_hash.py (plan_promote.py through it).

Nothing in the image build copies, mounts or runs the tests: the Containerfile takes build_files, system_files, packages, cosign.pub and the variants, and the workflows run the tests in their own
job. A change to them therefore changes no input hash and a push that touches only them builds nothing. (.github/scripts and the workflows stay inputs.)
"""


def is_docs(path: str) -> bool:
    if "/" in path:
        return path.startswith(("docs/", "tests/"))
    return path.endswith(".md") or path in ("LICENSE", ".gitignore")
