#!/bin/sh
# Publishes a release of Derivate:
#
#   1. builds build/Derivate.app and signs it with a Developer ID certificate
#   2. sends it to Apple's notary service and staples the ticket to it
#   3. tags the commit and puts Derivate-<version>.zip in a GitHub release
#   4. points the cask in jkroso/homebrew-tap at the new zip
#
#   scripts/release.sh
#
# Change `version` in scripts/build-app.sh and commit it first. The tag is
# v<version>.
#
# Before the first release from a Mac:
#
#   - The keychain must hold a "Developer ID Application" certificate.
#   - The keychain must hold the notary profile "derivate". Make it with
#       xcrun notarytool store-credentials derivate \
#           --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer>
#   - gh must be logged in, with push access to jkroso/derivate and
#     jkroso/homebrew-tap.
#
# SIGN_IDENTITY and NOTARY_PROFILE choose another certificate or profile.
set -eu
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version=//p' scripts/build-app.sh)
tag=v$version
zip=build/Derivate-$version.zip
repo=jkroso/derivate
tap=jkroso/homebrew-tap
profile=${NOTARY_PROFILE:-derivate}
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

fail() { echo "error: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
git fetch -q origin
git merge-base --is-ancestor HEAD origin/main || fail "push this commit to origin/main first"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
    fail "$tag exists already. Change version in scripts/build-app.sh."
fi

scripts/build-app.sh

# The notary service takes a zip and makes a ticket for the app in it.
# Stapling puts the ticket in the app, so Gatekeeper accepts the app on a Mac
# with no network. The zip for people is made again after that, with the
# ticket in it.
rm -f "$zip"
ditto -c -k --keepParent build/Derivate.app "$zip"
echo "Sending the app to Apple's notary service. It usually answers within a few minutes."
# notarytool can exit non-zero when Apple refuses the app, and its log is
# what tells you why.
result=$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json) || true
status=$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null) || status=""
if [ "$status" != Accepted ]; then
    id=$(echo "$result" | plutil -extract id raw -o - - 2>/dev/null) || id=""
    echo "$result" >&2
    if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true; fi
    fail "Apple's notary service did not accept the app (status: ${status:-none})"
fi
xcrun stapler staple build/Derivate.app
verdict=$(spctl --assess --type execute --verbose=2 build/Derivate.app 2>&1) || true
echo "$verdict"
echo "$verdict" | grep -q "source=Notarized Developer ID" || fail "Gatekeeper does not accept the app as notarised"
rm -f "$zip"
ditto -c -k --keepParent build/Derivate.app "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

git tag -a "$tag" -m "Derivate $version"
git push -q origin "$tag"
gh release create "$tag" "$zip" -R "$repo" --verify-tag --title "Derivate $version" --notes "$(cat <<EOF
Install it with Homebrew:

    brew install --cask jkroso/tap/derivate

Or download Derivate-$version.zip, open it, and move Derivate.app to your Applications folder.

Derivate needs macOS 14 or later. It runs on Macs with Apple silicon and on Macs with Intel.
EOF
)"

# The cask: Homebrew downloads the zip, checks it against sha256 and puts
# Derivate.app in /Applications.
work=$(mktemp -d)
gh repo clone "$tap" "$work" -- -q
mkdir -p "$work/Casks"
cat > "$work/Casks/derivate.rb" <<EOF
cask "derivate" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/Derivate-#{version}.zip"
  name "Derivate"
  desc "Menu bar app that makes your passwords from your name and secret"
  homepage "https://github.com/$repo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Derivate.app"

  uninstall quit: "dev.derivate.app"

  zap trash: "~/Library/Application Support/Derivate"
end
EOF
git -C "$work" add Casks/derivate.rb
git -C "$work" commit -q -m "derivate $version"
git -C "$work" push -q origin HEAD:main
rm -rf "$work"

echo "Released Derivate $version: https://github.com/$repo/releases/tag/$tag"
