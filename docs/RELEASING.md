# Releasing Atelier

For maintainers. Every release goes the same way: **test → beta → stable**. The code that ships as
stable is the code that ran as the last beta, plus the version bump. All of it is driven by
`scripts/release.sh`.

## What a release is

A GitHub Release on `kaizensx/Atelier`, tagged `v<version>`, carrying three assets:

| Asset | What it is |
|---|---|
| `Atelier-<version>.zip` | The app, zipped with `ditto -c -k --keepParent`. |
| `Atelier-<version>.zip.sig` | A base64 Ed25519 signature of the zip, made with the release key. |
| `Atelier-<version>.zip.sha256` | A checksum, for people who download by hand. |

A beta is published as a GitHub **pre-release**; a stable release as a normal one. The app's
updater only considers a release when both the zip and the `.sig` are attached under exactly those
names (`ReleaseInfo.installable` in `Sources/DockCore/UpdateLogic.swift`).

## One-time setup

Everything secret lives outside the repository, in
`~/Library/Application Support/Atelier Release/`. **Never commit anything from this folder.**

| File / item | Purpose |
|---|---|
| `update-ed25519.key` | Private Ed25519 key (base64 of the 32-byte raw representation). Signs update archives. |
| `update-ed25519.pub` | Its public half (base64). `release.sh` verifies every signature against it. The same value is compiled into the app as `UpdateConfig.publicKey` in `Sources/DockStacks/Updater.swift`. |
| `Atelier Release` | A code-signing identity in the login keychain. `build.sh` signs with it when present. |

The code-signing identity matters as much as the update key. Its designated requirement stays the
same from version to version, so macOS keeps the Accessibility, Screen Recording and other grants
across updates. Keep it, back it up, and do not replace it lightly: a new identity makes every
user grant permissions again.

To make a key pair, if you ever need one:

```sh
cat > /tmp/atelier-keygen.swift <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
FileHandle.standardError.write(Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8))
EOF
cd ~/Library/Application\ Support/Atelier\ Release
swift /tmp/atelier-keygen.swift > update-ed25519.key 2> update-ed25519.pub
chmod 600 update-ed25519.key
rm /tmp/atelier-keygen.swift
```

You also need the GitHub CLI (`gh`), signed in with push access to the repository.

## The version and the changelog

- **`VERSION`** at the repository root holds the full semantic version, for example
  `1.0.0-beta.1`. `build.sh` writes it to `AtelierVersion` in Info.plist (the updater reads this),
  gives macOS the numeric part as `CFBundleShortVersionString`, and uses the commit count as
  `CFBundleVersion`.
- **`CHANGELOG.md`** at the repository root has one section per version. The heading must be
  exactly `## [<version>]`; the section runs until the next `## [` heading. Its text becomes the
  GitHub release notes, and the first line shows in the app's Updates card.

```markdown
## [1.1.0-beta.2]
Display Memory now restores windows after a resolution change.

- Fixed …

## [1.1.0-beta.1]
…
```

A stable release needs its own section too, `## [1.1.0]`, written before you promote.

Versions order like semver: `1.1.0-beta.1 < 1.1.0-beta.2 < 1.1.0 < 1.1.1-beta.1`.

## Step 1: test

```sh
echo 1.1.0-beta.1 > VERSION        # and add ## [1.1.0-beta.1] to CHANGELOG.md
git commit -am "1.1.0-beta.1"
scripts/release.sh test
```

`test` does, in order, and stops at the first failure:

1. `swift test`.
2. `zsh build.sh`, then checks the built app's `AtelierVersion` is `VERSION` and its code signature
   verifies (`codesign --verify --deep --strict`).
3. Zips it to `dist/<version>/Atelier-<version>.zip`.
4. Builds the signer from `scripts/sign-update.swift` (into `.build/tools/`), signs the zip, and
   verifies the signature against `update-ed25519.pub`.
5. Writes the `.sha256`, the release notes from `CHANGELOG.md`, and the commit it was built from.
6. Installs the build to `/Applications` with `zsh build.sh --install` and opens it.
7. Stamps `dist/<version>/TESTED_BUILD`.

Nothing leaves the Mac. Now use it: exercise what changed, and run the relevant `atelier://` hooks
from [FEATURES.md](FEATURES.md).

## Step 2: beta

```sh
scripts/release.sh beta
```

Refuses unless `VERSION` is a beta (`x.y.z-beta.N`), the version was built by `test`, the commit is
still the one that was tested, and the working tree is clean. It asks for confirmation, tags
`v<version>`, pushes the branch and the tag, and creates a **pre-release** with the three assets and
the changelog notes. Only Macs on the Beta channel are offered it.

If you change anything after testing, `beta` refuses: run `test` again.

## Step 3: stable

When the beta has run well:

```sh
# Add a ## [1.1.0] section to CHANGELOG.md and commit it.
scripts/release.sh stable
```

`stable` reads `VERSION` (still the beta, for example `1.1.0-beta.3`) and checks that the beta
`v1.1.0-beta.3` was published and that nothing but `VERSION` and `CHANGELOG.md` has changed since
it: the code that ships as stable is exactly the code that ran as the beta. It then:

1. writes `1.1.0` to `VERSION` and commits "Release 1.1.0";
2. runs the whole of step 1 for `1.1.0` (tests, build, sign, verify, install here);
3. publishes `v1.1.0` as a normal release, after asking.

If any code changed after the beta, `stable` refuses: publish another beta first.

Status at any time:

```sh
scripts/release.sh status
```

## How the app verifies an update

From `Sources/DockStacks/Updater.swift` and `Sources/DockCore/UpdateLogic.swift`:

1. It asks `api.github.com/repos/kaizensx/Atelier/releases` with a generic `Atelier-Updater`
   User-Agent, every six hours when automatic checks are on, and on **Check Now**.
2. It picks the newest release above the running version that the channel allows. Stable never
   sees pre-releases. Drafts and releases without both assets are ignored, as are versions the
   person chose to skip.
3. On **Download** it fetches the `.sig`, then the zip, and checks the zip is exactly the size
   GitHub announced (and between 1 MB and 600 MB).
4. It verifies the Ed25519 signature over the zip bytes against the public key compiled into the
   running app. A mismatch stops here: "The download's signature did not match".
5. It unpacks into Caches and checks the bundle identifier is Atelier's, `AtelierVersion` is the
   version it expected, and `codesign --verify --deep --strict` passes.
6. On **Install and Relaunch** a small script waits for Atelier to quit, copies the running app to
   `~/Library/Application Support/Atelier/Previous/Atelier.app`, swaps the new one into place and
   opens it.

## Rolling back

**For a person:** Settings › Updates › **Roll Back** swaps the kept previous version back in.

**For the project,** when a published release is bad:

1. Stop new installs: turn the GitHub release back into a draft
   (`gh release edit v1.1.0 --draft --repo kaizensx/Atelier`) or delete it
   (`gh release delete v1.1.0 --repo kaizensx/Atelier`). The updater ignores drafts.
2. Macs that already installed it are only offered a *higher* version. Ship the fix as the next
   version (for example `1.1.1-beta.1`, then `1.1.1`) through the normal flow, and point people at
   Roll Back in the release notes meanwhile.
3. Never re-upload different bytes under an existing version: a Mac that already has that version
   will not take it again.

## Rotating the update key

The public key is compiled into the app, so a Mac only trusts releases signed with the key its own
version carries. Rotating therefore takes a transition release.

1. **Make the new pair** somewhere safe (see One-time setup), but do not replace the files in
   `Atelier Release` yet.
2. **Ship the new public key, signed with the old key.** Put the new public key in
   `UpdateConfig.publicKey` (`Sources/DockStacks/Updater.swift`), commit, and release that version
   through test → beta → stable as usual. `release.sh` still signs with the old private key and
   verifies with the old `.pub`, so every existing Mac accepts it. Once installed, those Macs trust
   only the new key.
3. **Wait.** Give the transition release time to reach people: weeks, not days. A Mac still on an
   older version will try to jump straight to the newest release, and will refuse anything signed
   with the new key.
4. **Switch the files.** Replace `update-ed25519.key` and `update-ed25519.pub` with the new pair.
   Every release from now on is signed with the new key.
5. **Destroy the old private key** once you are sure you will not need another release under it.

Say in the notes of the first new-key release that anyone whose update is refused should download
the transition release, or the latest zip, by hand.

If the private key is ever exposed, rotate at once and say so publicly: anyone holding it can sign
an update that every Mac on the old key would install.
