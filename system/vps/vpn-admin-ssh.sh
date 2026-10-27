#!/usr/bin/env python3
import os, re, sys, json
NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
cmd = os.environ.get("SSH_ORIGINAL_COMMAND", "")
w = cmd.split(" ")
ok = False
if re.fullmatch(r"[a-z0-9_ -]{1,100}", cmd) and "" not in w:
    if w[0] in ("health", "stats", "users") and len(w) == 1:
        ok = True
    elif w[0] in ("add", "revoke", "link") and 2 <= len(w) <= 3 and NAME.match(w[1]):
        flag = {"add": "--no-torrent", "revoke": "--force", "link": None}[w[0]]
        ok = len(w) == 2 or (flag is not None and w[2] == flag)
if not ok:
    sys.stdout.write(json.dumps({"error": "command not allowed"}) + "\n")
    sys.exit(1)
os.execv("/usr/local/bin/vpn-admin", ["vpn-admin"] + w)
