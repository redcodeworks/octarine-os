#!/usr/bin/env python3
"""Decide whether a push to `testing` can skip the default image build because an image built from identical inputs is already published (same vanilla_inputs, see inputs_hash.py: a dx-only or
docs-only change), and print key=value lines (for $GITHUB_OUTPUT). Usage: plan_vanilla_reuse.py <event> <ref> <after>

  reuse=true|false
  source_tag=testing-<short sha>   (only when reuse=true)
  source_digest=<digest>           (only when reuse=true)
  inputs=<vanilla_inputs of <after>>

Environment: IMAGE (the registry image) or REGISTRY_LOOKUP (a command, see plan_promote.py). Nothing is published or retagged: the image of the nearest earlier commit stays the `testing` image.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import inputs_hash as ih  # noqa: E402


def no(reason):
    ci.err(f"no reuse: {reason}")
    print("reuse=false")
    raise SystemExit(0)


def main(argv):
    if len(argv) < 2:
        sys.exit("usage: plan_vanilla_reuse.py <event> <ref> <after>")
    event, ref = argv[0], argv[1]
    after = (argv[2] if len(argv) > 2 else "") or "HEAD"
    if not (event == "push" and ref == "refs/heads/testing"):
        no(f"not a push to testing ({event} {ref})")
    print(f"inputs={ih.vanilla_inputs(after)}")
    try:
        tag, digest = ih.nearest_image_for_inputs(after)
    except ih.Unreadable as e:
        ci.err(f"::warning::registry read error while looking for a reusable testing image (building instead): {e}")
        no(str(e))
    except ih.NoImage as e:
        no(str(e))
    ci.err(f"reuse: {tag} ({digest}) was built from the same default-image inputs as {after}")
    print(f"reuse=true\nsource_tag={tag}\nsource_digest={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
