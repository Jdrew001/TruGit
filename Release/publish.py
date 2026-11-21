"""ShipStack's macOS release step. Run inside the checkout for a release branch."""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPO = "Jdrew001/TruGit"
BASE = "https://github.com/" + REPO
TEAM = "863DA9NUJ9"
PUBLIC_KEY = "qRNXAju4S8MJGxJ8zUzn1EedsXnNU2YE+C46q1NByrc="
TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
STATE = Path.home() / "Library/Application Support/TruGit/Release"


def run(*args):
    subprocess.run(args, check=True)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def version(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError("Expected a stable release tag such as v0.2.1")
    return tuple(map(int, match.groups()))


def verify_tag(tag):
    # Fetch the tag explicitly because the runner checks out a shallow release branch.
    run("git", "fetch", "--no-tags", BASE + ".git", "refs/tags/" + tag)
    if output("git", "rev-parse", "FETCH_HEAD^{commit}") != output("git", "rev-parse", "HEAD"):
        raise ValueError(f"Remote tag {tag} and the checked-out commit differ")


def feed(url):
    return ET.fromstring(subprocess.check_output(["curl", "-fsSL", "--retry", "3", url]))


def latest():
    return output("gh", "api", f"repos/{REPO}/releases/latest", "--jq", ".tag_name")


def signing_identity():
    identities = output("security", "find-identity", "-v", "-p", "codesigning")
    matches = re.findall(r'([A-F0-9]{40}) "Developer ID Application: [^"]+ \(' + TEAM + r'\)"', identities)
    if len(matches) != 1:
        raise RuntimeError("Expected one valid Developer ID Application identity for " + TEAM)
    return matches[0]


def build_app(tag, build, folder, signer):
    cache = STATE / "ShipStackBuildCache"
    tools = cache / "SourcePackages/artifacts/sparkle/Sparkle/bin"
    archive = folder / "TruGit.xcarchive"
    run("xcodebuild", "-resolvePackageDependencies", "-scheme", "TruGit", "-derivedDataPath", cache,
        "-onlyUsePackageVersionsFromResolvedFile")
    if output(tools / "generate_keys", "--account", "TruGit", "-p") != PUBLIC_KEY:
        raise RuntimeError("Sparkle signing key differs from the key in installed copies of TruGit")
    run("xcodebuild", "-quiet", "-scheme", "TruGit", "-configuration", "Release", "-destination",
        "generic/platform=macOS", "-derivedDataPath", cache, "-archivePath", archive,
        "-onlyUsePackageVersionsFromResolvedFile", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
        "CODE_SIGN_IDENTITY=" + signer, "DEVELOPMENT_TEAM=" + TEAM, "ENABLE_HARDENED_RUNTIME=YES",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "TRUGIT_UPDATE_PUBLIC_KEY=" + PUBLIC_KEY,
        "MARKETING_VERSION=" + tag[1:], f"CURRENT_PROJECT_VERSION={build}", "archive")
    options = folder / "export.plist"
    options.write_bytes(plistlib.dumps(dict(method="developer-id", teamID=TEAM, signingStyle="manual",
                                            signingCertificate=signer)))
    dest = folder / "export"
    run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportOptionsPlist", options, "-exportPath", dest)
    app = dest / "TruGit.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["SUPublicEDKey"], info["CFBundleVersion"], info["CFBundleShortVersionString"]) != (PUBLIC_KEY, str(build), tag[1:]):
        raise ValueError("Exported app has unexpected signing key or version")
    if set(output("lipo", "-archs", app / "Contents/MacOS/TruGit").split()) != {"arm64", "x86_64"}:
        raise ValueError("Expected a universal Mac app")
    run("codesign", "--verify", "--deep", "--strict", app)
    return app, tools


def submit_for_notarization(archive):
    result = json.loads(output("xcrun", "notarytool", "submit", archive, "--keychain-profile", "TruGit",
                               "--wait", "--output-format", "json"))
    print("Apple notarization", result["id"], result["status"], flush=True)
    if result["status"] != "Accepted":
        raise RuntimeError("Apple did not accept this archive")


def notarize(app, folder):
    zip_path = folder / "notarize.zip"
    run("ditto", "-c", "-k", "--keepParent", app, zip_path)
    submit_for_notarization(zip_path)
    run("xcrun", "stapler", "staple", app)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose", app)


def make_disk_image(app, tag, folder, signer):
    stage = folder / "disk-image-contents"
    stage.mkdir()
    run("ditto", app, stage / "TruGit.app")
    (stage / "Applications").symlink_to("/Applications")
    image = folder / f"TruGit-{tag[1:]}.dmg"
    run("hdiutil", "create", "-volname", "TruGit", "-fs", "HFS+", "-format", "UDZO",
        "-srcfolder", stage, image)
    run("codesign", "--sign", signer, "--timestamp", "--identifier", "com.drewatkison.TruGit.diskimage", image)
    submit_for_notarization(image)
    run("xcrun", "stapler", "staple", image)
    run("xcrun", "stapler", "validate", image)
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose", image)
    return image


def install_notes(tag):
    url = f"{BASE}/releases/download/{tag}/TruGit-{tag[1:]}.dmg"
    return (f"[Download TruGit for macOS]({url})\n\n"
            "Open the disk image, drag TruGit into Applications, then open TruGit from Applications.")


def publish(tag, build, previous, app, tools, folder, image):
    import hashlib
    assets = folder / "assets"
    assets.mkdir()
    zip_path = assets / f"TruGit-{tag[1:]}.zip"
    run("ditto", "-c", "-k", "--keepParent", app, zip_path)
    prefix = f"{BASE}/releases/download/{tag}/"
    run(tools / "generate_appcast", "--account", "TruGit", "--download-url-prefix", prefix, assets)
    xml = assets / "appcast.xml"
    item = ET.parse(xml).find("./channel/item")
    enclosure = item.find("enclosure")
    if (item.findtext(NS+"version") != str(build) or enclosure.get("url") != prefix + zip_path.name
            or not enclosure.get(NS+"edSignature") or int(enclosure.get("length")) != zip_path.stat().st_size):
        raise ValueError("Generated update feed does not match the archive")
    verify_tag(tag)
    drafts = json.loads(output("gh", "release", "list", "--repo", REPO, "--limit", "100", "--json", "tagName,isDraft"))
    if not any(r["tagName"] == tag and r["isDraft"] for r in drafts):
        run("gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--draft",
            "--title", "TruGit " + tag[1:], "--notes", install_notes(tag), "--generate-notes")
    if output("gh","release","view",tag,"--repo",REPO,"--json","isDraft","--jq",".isDraft") != "true":
        raise RuntimeError("Expected a draft before uploading")
    run("gh", "release", "upload", tag, zip_path, xml, image, "--repo", REPO, "--clobber")
    uploaded = json.loads(output("gh", "release", "view", tag, "--repo", REPO, "--json", "assets"))["assets"]
    for path in (xml, zip_path, image):
        digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
        if not any(asset["name"] == path.name and asset["digest"] == digest for asset in uploaded):
            raise ValueError("Uploaded asset digest mismatch for " + path.name)
    if latest() != previous:
        raise RuntimeError("Latest release changed while preparing this build")
    run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest")
    print("Published", BASE + "/releases/tag/" + tag, flush=True)


def main():
    branch = os.environ.get("CAPACITOR_DEPLOY_BRANCH", "")
    if not branch.startswith("shipstack/releases/"):
        raise ValueError("Choose a shipstack/releases/vX.Y.Z branch")
    tag = branch.split("/")[-1]
    target = version(tag)
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "shipstack-publish.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        verify_tag(tag)
        previous = latest()
        if target == version(previous):
            print(tag, "is already published")
            return
        if target < version(previous):
            raise ValueError("This tag is older than the current stable release")
        xml = feed(f"{BASE}/releases/download/{previous}/appcast.xml")
        published = xml.find("./channel/item")
        if published.findtext(NS+"shortVersionString") != previous[1:]:
            raise ValueError("Previous release and update feed disagree")
        build = int(published.findtext(NS+"version")) + 1
        print(f"Preparing {tag}, build {build}, from {output('git','rev-parse','HEAD')}", flush=True)
        with tempfile.TemporaryDirectory(prefix="TruGitDist-") as work:
            folder = Path(work)
            signer = signing_identity()
            app, tools = build_app(tag, build, folder, signer)
            notarize(app, folder)
            image = make_disk_image(app, tag, folder, signer)
            publish(tag, build, previous, app, tools, folder, image)


if __name__ == "__main__":
    main()
