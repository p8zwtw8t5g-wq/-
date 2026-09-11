#!/bin/bash
# Cloud build for InjectorDemo — theos, iOS 15+, arm64, /var/jb (rootless/roothide)
set -e
set -o pipefail

cd "${GITHUB_WORKSPACE:-$(pwd)}"
LOG="$PWD/build.log"

step() { echo; echo "==================== $* ===================="; }

dump_errors() {   # $1 = log file
  echo
  echo "############## BUILD ERRORS ##############"
  grep -n "error:" "$1" | head -40 || true
  echo "-------------------- tail -----------------"
  tail -40 "$1" || true
  echo "############ END BUILD ERRORS ############"
}

step "1/6 theos tooling"
brew install ldid xz >/dev/null 2>&1 || true
export THEOS="$HOME/theos"
if [ ! -d "$THEOS" ]; then
  git clone --recursive -q https://github.com/theos/theos.git "$THEOS"
fi
# dm.pl is required by `make package`; a bare clone does not put it on PATH
if [ -f "$THEOS/vendor/dm.pl/dm.pl" ]; then
  chmod +x "$THEOS/vendor/dm.pl/dm.pl"
  export PATH="$THEOS/vendor/dm.pl:$PATH"
fi
echo "THEOS=$THEOS"

step "2/6 iOS SDKs"
if [ -z "$(ls -A "$THEOS/sdks" 2>/dev/null)" ]; then
  curl -sL https://github.com/theos/sdks/archive/refs/heads/master.zip -o /tmp/s.zip
  rm -rf /tmp/s && unzip -q -o /tmp/s.zip -d /tmp/s
  mkdir -p "$THEOS/sdks"
  # SDK dirs are named iPhoneOS15.6.sdk (capital I, capital OS) — match case-insensitively
  find /tmp/s -maxdepth 2 -type d -iname 'iPhoneOS*.sdk' -exec cp -R {} "$THEOS/sdks/" \;
fi
ls "$THEOS/sdks"

step "3/6 unpack upload.zip"
rm -rf unpacked
python3 - <<'PY'
import zipfile, os
z = zipfile.ZipFile('upload.zip')
for i in z.infolist():
    n = i.filename.replace('\\', '/')
    if not n or n.endswith('/'):
        continue
    p = os.path.join('unpacked', n)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(z.read(i))
PY

D=$(dirname "$(find unpacked -name Makefile | head -1)")
echo "project dir: $D"
ls -la "$D"
cd "$D"

step "4/6 preflight"
chmod 755 layout/DEBIAN/postinst
chmod 755 postinst 2>/dev/null || true
sed -i '' '/THEOS_PACKAGE_SCHEME/d' Makefile || true
grep -n "INSTALL_PREFIX\|GO_EASY_ON_ME\|TWEAK_NAME\|APPLICATION_NAME\|RESOURCE_FILES\|_FILES =" Makefile || true
echo "--- app dir ---"
ls -la app

step "5/6 compile + stage"
if ! make stage FINALPACKAGE=1 >"$LOG" 2>&1; then
  dump_errors "$LOG"
  exit 1
fi
tail -8 "$LOG"
echo "--- .theos/_ (staged tree) ---"
find .theos/_ -maxdepth 8 -not -path '*/DEBIAN/*' | sort || true

step "6/6 package deb"
if ! make package FINALPACKAGE=1 THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip >"$LOG" 2>&1; then
  dump_errors "$LOG"
  exit 1
fi
tail -8 "$LOG"
ls -la packages/

step "deb payload listing"
DEB="$(pwd)/$(ls packages/*.deb | head -1)"
echo "deb: $DEB"
rm -rf /tmp/debx && mkdir -p /tmp/debx
cd /tmp/debx
ar x "$DEB"
for f in data.tar.*; do echo "--- $f ---"; tar -tf "$f" | sort; done

step "collect artifact"
cd "${GITHUB_WORKSPACE:-/tmp}"
mkdir -p out
cp "$DEB" out/
ls -la out

echo
echo "############### BUILD OK ###############"
echo "deb: $(ls out/*.deb)"
echo "########################################"
