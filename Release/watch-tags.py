"""Queue tagged TruGit commits on the local ShipStack Mac runner."""
import json
import re
import subprocess
import sys
from urllib.request import Request, urlopen

REPO = "Jdrew001/TruGit"
API = "http://127.0.0.1:3500/api"
TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def shipstack(route, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = Request(API + route, data=body, headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=20) as response:
        return json.load(response)


def output(*args):
    return subprocess.check_output(args, text=True, timeout=40).strip()


def tag_commits():
    refs = {}
    peeled = {}
    for line in output("git", "ls-remote", "--tags", f"https://github.com/{REPO}.git", "v*").splitlines():
        sha, ref = line.split()
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            peeled[name[:-3]] = sha
        else:
            refs[name] = sha
    return {name: peeled.get(name, sha) for name, sha in refs.items() if TAG.fullmatch(name)}


def version(tag):
    return tuple(map(int, TAG.fullmatch(tag).groups()))


def main():
    project_id = sys.argv[1]
    if not shipstack("/runner/health").get("ready"):
        raise RuntimeError("ShipStack Mac runner is offline")
    latest = output("gh", "api", f"repos/{REPO}/releases/latest", "--jq", ".tag_name")
    tags = tag_commits()
    pending = sorted((tag for tag in tags if version(tag) > version(latest)), key=version)
    if not pending:
        return
    builds = shipstack("/builds?projectId=" + project_id)
    if any(b["status"] in ("queued","running") for b in builds):
        return
    for tag in pending:
        branch = "shipstack/releases/" + tag
        # A failed run remains visible and can be retried manually in ShipStack.
        # A later fixed tag is eligible even if an older tag failed.
        if any(b.get("branch") == branch for b in builds):
            continue
        ref = "refs/heads/" + branch
        existing = output("git","ls-remote","--heads",f"https://github.com/{REPO}.git",ref)
        if existing:
            if existing.split()[0] != tags[tag]:
                raise RuntimeError("Release branch differs from " + tag)
        else:
            output("gh","api","--method","POST",f"repos/{REPO}/git/refs","-f","ref="+ref,"-f","sha="+tags[tag])
        result = shipstack("/builds/trigger", {"projectId":project_id,"platform":"nodejs","branch":branch})
        print(f"{tag}: queued ShipStack build {result['id']}",flush=True)
        return


if __name__ == "__main__":
    main()
