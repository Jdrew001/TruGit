"""Install or update the TruGit tag trigger for the current macOS login."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

project = str(uuid.UUID(sys.argv[1]))
label = "com.trugit.shipstack-release-tags"
domain = f"gui/{os.getuid()}"
state = Path.home() / "Library/Application Support/TruGit/Release"
state.mkdir(parents=True, exist_ok=True)
watcher = state / "watch-tags.py"
shutil.copyfile(Path(__file__).with_name("watch-tags.py"), watcher)
agents = Path.home() / "Library/LaunchAgents"
agents.mkdir(exist_ok=True)
plist = agents / (label + ".plist")
config = dict(Label=label, ProgramArguments=["/usr/bin/python3", str(watcher), project],
              StartInterval=180, RunAtLoad=True,
              EnvironmentVariables={"PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
              StandardOutPath=str(state / "tag-trigger.log"), StandardErrorPath=str(state / "tag-trigger-errors.log"))
target = f"{domain}/{label}"
if subprocess.run(["launchctl","print",target],capture_output=True).returncode == 0:
    subprocess.run(["launchctl","bootout",target],check=True)
plist.write_bytes(plistlib.dumps(config))
subprocess.run(["launchctl","bootstrap",domain,str(plist)],check=True)
