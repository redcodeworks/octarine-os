#!/usr/bin/env bash
# Sourced by plan-build.sh and plan-promote.sh: the one place that lists the files that do not need an
# image build: top-level *.md (README.md, AGENTS.md, CLAUDE.md, CONFIG-GUIDE.md ...), docs/**, LICENSE,
# .gitignore.
is_docs() {
    case "$1" in
        */*) [[ "$1" == docs/* ]] ;;
        *.md | LICENSE | .gitignore) return 0 ;;
        *) return 1 ;;
    esac
}
