# octarineOS: a terminal that Steam launches (added to Steam as a non-Steam game) inherits Steam's LD_PRELOAD with the
# 32-bit and 64-bit gameoverlayrenderer.so, and every 64-bit process the shell then starts prints "wrong ELF class:
# ELFCLASS32". Drop the overlay entries; any other entry stays.
# Disable for yourself: create an empty file of the same name in ~/.config/fish/conf.d/.
status is-interactive; or return
if set -q LD_PRELOAD; and string match -q '*gameoverlayrenderer.so*' -- $LD_PRELOAD
    set -l kept
    for p in (string split : -- $LD_PRELOAD)
        string match -q '*gameoverlayrenderer.so' -- $p; or set -a kept $p
    end
    if set -q kept[1]
        set -gx LD_PRELOAD (string join : -- $kept)
    else
        set -e LD_PRELOAD
    end
end
