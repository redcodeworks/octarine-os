#!/usr/bin/env bash
# Sourced by plan-build.sh, plan-promote.sh and inputs-hash.sh: the one place that lists the files that do not need an
# image build: top-level *.md (README.md, AGENTS.md, CLAUDE.md, CONFIG-GUIDE.md ...), docs/**, LICENSE, .gitignore, and the
# test suite (tests/**). Nothing in the image build copies, mounts or runs the tests: the Containerfile takes build_files,
# system_files, cosign.pub and the variants, and the workflows run the tests in their own job. A change to them therefore changes
# no input hash and a push that touches only them builds nothing. (.github/scripts and the workflows stay inputs.)
is_docs() {
    case "$1" in
        */*) [[ "$1" == docs/* || "$1" == tests/* ]] ;;
        *.md | LICENSE | .gitignore) return 0 ;;
        *) return 1 ;;
    esac
}
