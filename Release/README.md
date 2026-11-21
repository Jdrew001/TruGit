# Distribute TruGit to another Mac

TruGit uses Sparkle 2. The installed app checks the public GitHub Releases feed while running. The latest stable release must contain both `appcast.xml` and the ZIP referenced by that feed. For a Finder install, download the signed and notarized DMG from the release page, open it, and drag TruGit into Applications.

## Publish a new version with ShipStack

Push a stable version tag on the commit you want to ship. For example, after 0.2.1:

```sh
git tag -a v0.2.2 -m "TruGit 0.2.2"
git push origin v0.2.2
```

On the signing Mac, a user LaunchAgent checks GitHub every three minutes and catches up after downtime. It creates a release branch at the tagged commit and queues the **TruGit** project through ShipStack’s local API. ShipStack uses its Node.js target to run the custom macOS pipeline on the Mac worker. Track the build in ShipStack → Builds. Keep the signing Mac logged in with ShipStack, Docker and its runner available.

The pipeline verifies that the tag matches the checkout, archives for Intel and Apple silicon, signs with Developer ID, submits to Apple, staples the ticket and verifies the app with Gatekeeper. It assigns the next Sparkle build number from the published feed and checks the GitHub digests of the DMG, ZIP and feed before publishing the release. Installed copies use the same signed feed as 0.2.0.

A failed build stays in ShipStack. Retry it from the same `shipstack/releases/vX.Y.Z` branch. Publish a new tag for source changes. Unrelated tags, prereleases and versions older than the current stable release are skipped.

### Install the tag trigger on a replacement signing Mac

In ShipStack create a project for `Jdrew001/TruGit` using the Node.js custom pipeline target, semantic versioning, and branch-triggered automatic builds disabled. Authenticate the release user's GitHub CLI with repository write access. Restore the same Sparkle key in the `TruGit` Keychain account, the Apple Developer ID identity for the distribution team, and the `TruGit` notarytool profile. Then run:

```sh
/usr/bin/python3 Release/install-shipstack-watcher.py YOUR_SHIPSTACK_PROJECT_UUID
```

Run the tag trigger on one signing Mac. Its logs are in `~/Library/Application Support/TruGit/Release/tag-trigger*.log`. ShipStack retains the build and publish logs. To remove the trigger, unload `gui/$(id -u)/com.trugit.shipstack-release-tags` with launchctl and remove its plist from `~/Library/LaunchAgents`.

## Prepare the release Mac once

Use a Developer ID Application certificate and configure an Apple notarization keychain profile (`xcrun notarytool store-credentials TruGit`). Resolve the package to get Sparkle’s release tools, then create a dedicated update signing key in the release Mac’s Keychain.

```sh
xcodebuild -resolvePackageDependencies -scheme TruGit -derivedDataPath .build
sparkle=.build/SourcePackages/artifacts/sparkle/Sparkle/bin
"$sparkle/generate_keys" --account TruGit
```

Keep a secure backup of the Sparkle private key on the release side. Use the same key and Apple team for subsequent releases. Only its public key goes into the app.

## Prepare each release

From the project root, choose a version tag and a build number greater than the previous release. Set `signer` to your Developer ID Application certificate fingerprint and `team` to its Apple Developer Team ID. The example creates a universal Release build in a dedicated directory.

```sh
version=0.2.0
build=2
signer='YOUR_DEVELOPER_ID_APPLICATION_CERTIFICATE_SHA1'
team='YOUR_TEAM_ID'
sparkle=.build/SourcePackages/artifacts/sparkle/Sparkle/bin
public_key=$("$sparkle/generate_keys" --account TruGit -p)
out=".build/releases/v$version"
mkdir -p .build/releases
mkdir "$out"
xcodebuild -scheme TruGit -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$signer" DEVELOPMENT_TEAM="$team" ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  TRUGIT_UPDATE_PUBLIC_KEY="$public_key" MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  -archivePath "$out/TruGit.xcarchive" archive
plutil -create xml1 "$out/export.plist"
plutil -insert method -string developer-id "$out/export.plist"
plutil -insert signingStyle -string manual "$out/export.plist"
plutil -insert signingCertificate -string "$signer" "$out/export.plist"
plutil -insert teamID -string "$team" "$out/export.plist"
xcodebuild -exportArchive -archivePath "$out/TruGit.xcarchive" \
  -exportOptionsPlist "$out/export.plist" -exportPath "$out/distribution"
app="$out/distribution/TruGit.app"
codesign --verify --deep --strict "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")" = "$public_key"
ditto -c -k --keepParent "$app" "$out/notarization.zip"
xcrun notarytool submit "$out/notarization.zip" --keychain-profile TruGit --wait
```

After Apple reports **Accepted**, staple the ticket and generate the two distribution files.

```sh
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"
mkdir "$out/assets"
ditto -c -k --keepParent "$app" "$out/assets/TruGit-$version.zip"
"$sparkle/generate_appcast" --account TruGit \
  --download-url-prefix "https://github.com/Jdrew001/TruGit/releases/download/v$version/" \
  "$out/assets"
```

Attach the versioned ZIP and `appcast.xml` from `assets` to the same draft GitHub Release tagged `v$version`, against the commit used to build it. Publish it as the latest stable release when both files are attached. The feed URL embedded in the app stays constant across releases. Each prepared feed lists the current universal macOS release.

## On the work Mac

Install the first approved distribution build in Applications and open it. Under **Settings → Updates**, automatic checks and installation are enabled by default. **Check for Updates** checks immediately. Sparkle can stage an update while the app is open and finish installation at quit. macOS may request permission to replace the app depending on its location and ownership.

For a first rollout, install the earlier signed build on a second Mac, publish a higher build, check for updates, and verify the build number and restored tabs after relaunch.

[Sparkle setup](https://sparkle-project.org/documentation/) · [Sparkle publishing](https://sparkle-project.org/documentation/publishing/) · [Apple Developer ID and notarization](https://developer.apple.com/developer-id/)
