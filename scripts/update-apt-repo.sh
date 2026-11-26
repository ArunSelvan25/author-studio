#!/usr/bin/env bash
# Adds .deb packages to the APT repository in ./apt and re-signs it.
#
# Usage:  scripts/update-apt-repo.sh path/to/author-studio_<version>_amd64.deb [more.deb ...]
#         scripts/update-apt-repo.sh            (no arguments: just rebuild and re-sign)
#
# Needs: apt-ftparchive (package "apt-utils"), gpg, and the release signing key
# in your GnuPG keyring. Afterwards: git add apt && git commit && git push.

set -euo pipefail

SIGNING_KEY="5104BE82800F02ACDA3B516E3CEF4E54B0E6DA6E"
SUITE="stable"
COMPONENT="main"
ARCH="amd64"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apt_dir="$repo_root/apt"
pool_dir="$apt_dir/pool/$COMPONENT/a/author-studio"
dist_dir="$apt_dir/dists/$SUITE"
bin_dir="$dist_dir/$COMPONENT/binary-$ARCH"

for tool in apt-ftparchive gpg gzip; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
gpg --list-secret-keys "$SIGNING_KEY" >/dev/null 2>&1 || {
  echo "The signing key $SIGNING_KEY is not in your GnuPG keyring." >&2
  exit 1
}

mkdir -p "$pool_dir" "$bin_dir"

for deb in "$@"; do
  [ -f "$deb" ] || { echo "Not a file: $deb" >&2; exit 1; }
  cp -- "$deb" "$pool_dir/"
  echo "Added $(basename "$deb")"
done

if ! compgen -G "$pool_dir/*.deb" >/dev/null; then
  echo "No packages in $pool_dir; pass a .deb file." >&2
  exit 1
fi

cd "$apt_dir"

# Package index. Paths in it are relative to ./apt.
apt-ftparchive packages "pool/$COMPONENT" > "$bin_dir/Packages"
gzip -9 -n -c "$bin_dir/Packages" > "$bin_dir/Packages.gz"

# Release file, written outside the tree first so it does not list itself.
rm -f "$dist_dir/Release" "$dist_dir/InRelease" "$dist_dir/Release.gpg"
release_tmp="$(mktemp)"
trap 'rm -f "$release_tmp"' EXIT
apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=Author Studio" \
  -o "APT::FTPArchive::Release::Label=Author Studio" \
  -o "APT::FTPArchive::Release::Suite=$SUITE" \
  -o "APT::FTPArchive::Release::Codename=$SUITE" \
  -o "APT::FTPArchive::Release::Architectures=$ARCH" \
  -o "APT::FTPArchive::Release::Components=$COMPONENT" \
  -o "APT::FTPArchive::Release::Description=Author Studio packages" \
  release "dists/$SUITE" > "$release_tmp"
install -m 644 "$release_tmp" "$dist_dir/Release"

# Signatures: InRelease (inline) and Release.gpg (detached).
gpg --batch --yes --local-user "$SIGNING_KEY" --digest-algo SHA512 \
  --clearsign --output "$dist_dir/InRelease" "$dist_dir/Release"
gpg --batch --yes --local-user "$SIGNING_KEY" --digest-algo SHA512 \
  --armor --detach-sign --output "$dist_dir/Release.gpg" "$dist_dir/Release"

# Public key that users install.
gpg --batch --yes --export "$SIGNING_KEY" > "$apt_dir/author-studio.gpg"

echo
echo "Repository updated. Packages now in it:"
grep -E '^(Package|Version):' "$bin_dir/Packages" | paste - - | sed 's/^/  /'
