#!/bin/sh
# Installs/updates KindleMap on a jailbroken Kindle over SSH (Wi-Fi, or the
# Jobman "USB Networking" mode, where the Kindle is 192.168.15.244 and the
# computer must use 192.168.15.201/24 on the USB network interface).
#
#   tools/deploy-ssh.sh KINDLE_IP            # app + receiver + icons
#   tools/deploy-ssh.sh KINDLE_IP --data     # also build/pack and build/data (~50 MB)
#
# Runs update-waf.sh on the Kindle (needs the WAF registered once with
# install-waf.sh). Asks for the root password configured in Jobman.
set -eu

HOST="${1:?usage: tools/deploy-ssh.sh KINDLE_IP [--data]}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXTRA=""
if [ "${2:-}" = "--data" ]; then
    for d in pack data; do
        [ -d "$ROOT/build/$d" ] || { echo "missing build/$d (run tools/build_*.py or unzip the release data)"; exit 1; }
    done
    EXTRA="-C $ROOT/build pack data"
fi

# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar -cf - --exclude='._*' --exclude='.DS_Store' \
    -C "$ROOT/kindle-map" index.html app-dom.js config.xml update-waf.sh receiver icons $EXTRA |
ssh "root@$HOST" 'rm -rf /mnt/us/kindlemap_staging && mkdir -p /mnt/us/kindlemap_staging &&
    tar -xf - -C /mnt/us/kindlemap_staging && sh /mnt/us/kindlemap_staging/update-waf.sh'
echo "Done. On the Kindle, tap 'KindleMap GPS' in the library (tap again to stop)."
