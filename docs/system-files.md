# System files (`system_files/`)

The files this image adds to the system, laid out the way they end up on disk: `system_files/etc/...` becomes
`/etc/...` and `system_files/usr/...` becomes `/usr/...`. Configuration for the desktop, PAM, firewall, sudo and
GameMode, `ujust` recipes, helper scripts, services, presets and the like live here.

`build_files/build.sh` copies the whole tree over the image root during the build, after the Homebrew files, so a file
here wins over one with the same path from the base. The dx variant has its own tree in `variants/dx/system_files/`, the gx variant has none (its packages bring their own files).

Before editing: everything here ships in every image, so keep it free of secrets and personal key material (the build
refuses to run if it finds some). Any file you add, README or notes included, lands on the installed system, so
documentation belongs in `docs/` instead. Packages are installed in `build_files/build.sh`, not here.
