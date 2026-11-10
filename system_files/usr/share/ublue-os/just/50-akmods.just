# vim: set ft=make :

# Replaces the base image's 50-akmods.just, which holds only configure-broadcom-wl. It is hidden from `ujust --list`
# (private) but behaves as before: the image ships no Broadcom kernel module, so it does nothing useful by default.
alias broadcom-wl := configure-broadcom-wl

[private]
configure-broadcom-wl ACTION="prompt":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION={{ ACTION }}
    if [ "$OPTION" == "prompt" ]; then
      echo "${bold}Configuring Broadcom Wi-Fi${normal}"
      echo 'Enabling Broadcom WL driver will break numerous other Wi-Fi adapters.'
      echo 'Enable or Disable Broadcom Wl?'
      OPTION=$(ugum choose Enable Disable)
    elif [ "$OPTION" == "help" ]; then
      echo "Usage: ujust configure-broadcom-wl <option>"
      echo "  <option>: Specify the quick option - 'enable' or 'disable'"
      echo "  Use 'enable' to select Enable"
      echo "  Use 'disable' to select Disable"
      exit 0
    fi
    if [ "${OPTION,,}" == "enable" ]; then
      sudo rm -f /etc/modprobe.d/broadcom-wl-blacklist.conf
      sudo rm -f /etc/modprobe.d/default-disable-broadcom-wl.conf
      echo "${bold}Enabled${normal} Broadcom Wireless, please reboot for changes to take effect"
    elif [ "${OPTION,,}" == "disable" ]; then
      sudo ln -sf /dev/null /etc/modprobe.d/broadcom-wl-blacklist.conf
      sudo bash -c 'echo "blacklist wl" > /etc/modprobe.d/default-disable-broadcom-wl.conf'
      echo "${bold}Disabled${normal} Broadcom Wireless, please reboot for changes to take effect"
    fi
