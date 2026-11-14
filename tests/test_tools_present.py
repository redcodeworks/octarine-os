"""The tools the suite and the scripts under test need from the host. One clear failure instead of a scatter of
confusing ones (CI once failed on a missing `readelf` and a missing `setpriv`)."""
import shutil

TOOLS = ["readelf", "setpriv", "node", "gzip", "git", "jq", "just", "bash", "python3", "sha256sum"]


def test_tools_present():
    """NEW: the shell tests assumed these tools silently."""
    missing = [t for t in TOOLS if shutil.which(t) is None]
    assert not missing, (
        f"missing host tools: {', '.join(missing)}. CI installs them in test.yml (dnf line); locally use the dx "
        "image, brew or a distrobox."
    )
