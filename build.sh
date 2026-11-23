#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build a release tarball:  dist/pve-bsdmem-<version>.tar.gz
#
#   ./build.sh
#
# Verifies the bundle is self-consistent before packing, so a broken release
# cannot be produced by accident.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$SRC/VERSION")"
NAME="pve-bsdmem-$VERSION"
DIST="$SRC/dist"
STAGE="$DIST/$NAME"

FILES=(
    VERSION
    LICENSE
    README.md
    CHANGELOG.md
    qemuserver-bsdmem.patch
    pve-bsdmem
    pve-bsdmem-apply
    pve-bsdmem-reapply
    pve-bsdmem.service
    pve-bsdmem.timer
    99-pve-bsdmem
    install.sh
    uninstall.sh
    setup-opnsense-vm.sh
)
EXECUTABLE=(pve-bsdmem pve-bsdmem-apply pve-bsdmem-reapply install.sh uninstall.sh setup-opnsense-vm.sh)

echo "==> checking bundle $VERSION"
for f in "${FILES[@]}"; do
    [ -f "$SRC/$f" ] || { echo "  missing: $f" >&2; exit 1; }
done
echo "  ok    all ${#FILES[@]} files present"

for f in install.sh uninstall.sh setup-opnsense-vm.sh pve-bsdmem-reapply; do
    bash -n "$SRC/$f" || exit 1
done
echo "  ok    shell syntax"

for f in pve-bsdmem pve-bsdmem-apply; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/$f" || exit 1
done
echo "  ok    python syntax"

# the version the scripts report must match VERSION
for f in pve-bsdmem pve-bsdmem-apply; do
    got="$(cd "$SRC" && python3 "./$f" --version | awk '{print $2}')"
    [ "$got" = "$VERSION" ] || { echo "  $f reports '$got', expected '$VERSION'" >&2; exit 1; }
done
echo "  ok    scripts report $VERSION"

# CHANGELOG must mention this version
grep -q "$VERSION" "$SRC/CHANGELOG.md" || {
    echo "  CHANGELOG.md has no entry for $VERSION" >&2; exit 1; }
echo "  ok    CHANGELOG has $VERSION"

echo "==> staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
for f in "${FILES[@]}"; do
    cp "$SRC/$f" "$STAGE/$f"
done
chmod 0755 "${EXECUTABLE[@]/#/$STAGE/}"
chmod 0644 "$STAGE/VERSION" "$STAGE"/*.md "$STAGE"/*.patch \
           "$STAGE"/pve-bsdmem.service "$STAGE"/pve-bsdmem.timer "$STAGE"/99-pve-bsdmem

echo "==> packing"
# force root:root - the build host may be anything (incl. Windows/Git Bash,
# where the files would otherwise carry a meaningless local uid)
tar --owner=0 --group=0 --numeric-owner \
    -czf "$DIST/$NAME.tar.gz" -C "$DIST" "$NAME"
rm -rf "$STAGE"

cd "$DIST"
sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"

echo
echo "built: dist/$NAME.tar.gz"
cat "$NAME.tar.gz.sha256"
tar -tzf "$NAME.tar.gz"
