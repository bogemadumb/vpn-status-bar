#!/usr/bin/env python3
import sys, os, re, json, uuid, time, shutil, subprocess, fcntl, tempfile, datetime

CONF = "/usr/local/etc/xray/config.json"
STATE = "/var/lib/vpn-admin"
USERS = STATE + "/users.json"
USAGE = STATE + "/usage.json"
API = "127.0.0.1:10085"
TAG = "vless-in"
RULE = "notorrent"
HOST = os.environ.get("VPN_ADMIN_HOST") or open("/etc/vpn-admin.host").read().strip()
ACCESS = "/var/log/xray/access.log"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")


def out(obj, code=0):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.exit(code)


def fail(msg, **kw):
    out(dict(error=msg, **kw), 1)


def run(cmd, timeout=15):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def load_conf():
    with open(CONF) as f:
        return json.load(f)


def save_conf(c):
    shutil.copy2(CONF, STATE + "/config.prev.json")
    st = os.stat(CONF)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CONF), prefix=".cfg-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(c, f, indent=2)
    os.chmod(tmp, st.st_mode & 0o777)
    os.chown(tmp, st.st_uid, st.st_gid)
    r = run(["/usr/local/bin/xray", "run", "-test", "-config", tmp])
    if r.returncode != 0:
        os.unlink(tmp)
        fail("config test failed after edit, not saved")
    os.replace(tmp, CONF)


def inbound(c):
    for ib in c["inbounds"]:
        if ib.get("tag") == TAG:
            return ib
    fail("inbound %s not found" % TAG)


def nt_rule(c):
    for r in c["routing"]["rules"]:
        if r.get("ruleTag") == RULE:
            return r
    fail("rule %s not found" % RULE)


def jload(p, default):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return default


def jsave(p, obj):
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix=".t-")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, p)


def lock():
    f = open(STATE + "/.lock", "w")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def sync_meta(c):
    meta = jload(USERS, {"users": {}})
    names = [x["email"] for x in inbound(c)["settings"]["clients"] if x.get("email")]
    for n in names:
        meta["users"].setdefault(n, {"created": None})
    for n in list(meta["users"]):
        if n not in names:
            del meta["users"][n]
    jsave(USERS, meta)
    return meta


def tmpjson(obj):
    fd, p = tempfile.mkstemp(dir="/run", prefix="vpna-", suffix=".json")
    os.chmod(p, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    return p


def push_rule(users):
    run(["/usr/local/bin/xray", "api", "rmrules", "-s", API, RULE])
    rule = {"type": "field", "ruleTag": RULE, "user": users, "protocol": ["bittorrent"], "outboundTag": "block"}
    p = tmpjson({"routing": {"rules": [rule]}})
    try:
        r = run(["/usr/local/bin/xray", "api", "adrules", "-s", API, "-append", p])
    finally:
        os.unlink(p)
    return r.returncode == 0


def cmd_users():
    c = load_conf()
    meta = sync_meta(c)
    nt = set(nt_rule(c).get("user", []))
    res = []
    for x in inbound(c)["settings"]["clients"]:
        n = x.get("email")
        if n:
            res.append({"email": n, "level": x.get("level", 0), "notorrent": n in nt, "created": meta["users"].get(n, {}).get("created")})
    out({"users": res})


def cmd_add(name, notorrent):
    with lock():
        c = load_conf()
        cl = inbound(c)["settings"]["clients"]
        if any(x.get("email") == name for x in cl):
            fail("user exists")
        uid = str(uuid.uuid4())
        client = {"id": uid, "email": name, "level": 0}
        p = tmpjson({"inbounds": [{"tag": TAG, "listen": "127.0.0.1", "port": 10000, "protocol": "vless", "settings": {"clients": [client], "decryption": "none"}}]})
        try:
            r = run(["/usr/local/bin/xray", "api", "adu", "-s", API, p])
        finally:
            os.unlink(p)
        if r.returncode != 0 or "Added 1 user" not in r.stdout:
            fail("runtime add failed", detail=(r.stdout + r.stderr).strip()[-200:])
        cl.append(client)
        restart_needed = False
        runtime_rule = None
        if notorrent:
            r_ = nt_rule(c)
            users = [u for u in r_.get("user", []) if u != "nobody-placeholder"] + [name]
            r_["user"] = users
            runtime_rule = push_rule(users)
            restart_needed = not runtime_rule
        try:
            save_conf(c)
        except SystemExit:
            run(["/usr/local/bin/xray", "api", "rmu", "-s", API, "-tag", TAG, name])
            raise
        meta = jload(USERS, {"users": {}})
        meta["users"][name] = {"created": datetime.date.today().isoformat()}
        jsave(USERS, meta)
        res = {"ok": True, "name": name, "notorrent": notorrent, "restart_needed": restart_needed}
        if notorrent:
            res["notorrent_runtime"] = runtime_rule
        out(res)


def cmd_revoke(name, force):
    if name == "mac" and not force:
        fail("refusing to revoke mac without --force")
    with lock():
        c = load_conf()
        cl = inbound(c)["settings"]["clients"]
        if not any(x.get("email") == name for x in cl):
            fail("no such user")
        r = run(["/usr/local/bin/xray", "api", "rmu", "-s", API, "-tag", TAG, name])
        if r.returncode != 0 or ("Removed 1 user" not in r.stdout and "not found" not in r.stdout):
            fail("runtime remove failed", detail=(r.stderr or r.stdout).strip()[-200:])
        inbound(c)["settings"]["clients"] = [x for x in cl if x.get("email") != name]
        rr = nt_rule(c)
        restart_needed = False
        if name in rr.get("user", []):
            users = [u for u in rr["user"] if u != name]
            rr["user"] = users or ["nobody-placeholder"]
            restart_needed = not push_rule(rr["user"])
        save_conf(c)
        meta = jload(USERS, {"users": {}})
        meta["users"].pop(name, None)
        jsave(USERS, meta)
        out({"ok": True, "name": name, "restart_needed": restart_needed})


def cmd_link(name):
    c = load_conf()
    for x in inbound(c)["settings"]["clients"]:
        if x.get("email") == name:
            out({"name": name, "link": "vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%%2Fwsx#%s" % (x["id"], HOST, HOST, HOST, name)})
    fail("no such user")


def month_now():
    return time.strftime("%Y-%m")


def scan_lastseen(prev):
    seen = dict(prev)
    rx = re.compile(r"^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)\S* from \S+ accepted .*email: (\S+)\s*$")
    try:
        size = os.path.getsize(ACCESS)
        with open(ACCESS, "rb") as f:
            f.seek(max(0, size - 16 * 1024 * 1024))
            data = f.read().decode("utf-8", "replace")
    except Exception:
        return seen
    for line in data.splitlines():
        m = rx.match(line)
        if m:
            try:
                dt = datetime.datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S").astimezone()
            except ValueError:
                continue
            seen[m.group(2)] = dt.isoformat(timespec="seconds")
    return seen


def cmd_stats():
    with lock():
        r = run(["/usr/local/bin/xray", "api", "statsquery", "-s", API, "-pattern", "user>>>"])
        if r.returncode != 0:
            fail("xray api unavailable", detail=(r.stderr or r.stdout).strip()[-200:])
        raw = {}
        for s in json.loads(r.stdout or "{}").get("stat", []):
            m = re.match(r"user>>>(.+)>>>traffic>>>(uplink|downlink)$", s["name"])
            if m:
                raw.setdefault(m.group(1), {"up": 0, "down": 0})["up" if m.group(2) == "uplink" else "down"] = int(s.get("value", 0))
        start = run(["systemctl", "show", "xray", "-p", "ActiveEnterTimestampMonotonic", "--value"]).stdout.strip()
        acc = jload(USAGE, {})
        last = acc.get("last", {})
        total = acc.get("total", {})
        if acc.get("xray_start") != start:
            last = {}
        if acc.get("month") != month_now():
            total = {}
        for n, v in raw.items():
            lt = last.get(n, {"up": 0, "down": 0})
            t = total.setdefault(n, {"up": 0, "down": 0})
            for k in ("up", "down"):
                d = v[k] - lt[k]
                t[k] += d if d >= 0 else v[k]
        acc = {"month": month_now(), "xray_start": start, "last": raw, "total": total, "lastseen": scan_lastseen(acc.get("lastseen", {}))}
        jsave(USAGE, acc)
    users = []
    for n in sorted(set(total) | set(acc["lastseen"])):
        t = total.get(n, {"up": 0, "down": 0})
        users.append({"email": n, "up": t["up"], "down": t["down"], "last_seen": acc["lastseen"].get(n)})
    out({"month": acc["month"], "users": users})


def cmd_health():
    def active(u):
        return run(["systemctl", "is-active", u]).stdout.strip() == "active"

    def cpu():
        def rd():
            v = list(map(int, open("/proc/stat").readline().split()[1:]))
            return sum(v), v[3] + v[4]
        t1, i1 = rd()
        time.sleep(0.5)
        t2, i2 = rd()
        return round(100.0 * (1 - (i2 - i1) / max(1, t2 - t1)), 1)

    mem = {}
    for l in open("/proc/meminfo"):
        k, v = l.split(":")
        mem[k] = int(v.split()[0]) * 1024
    du = shutil.disk_usage("/")
    cert = None
    r = run(["openssl", "x509", "-enddate", "-noout", "-in", "/etc/letsencrypt/live/%s/fullchain.pem" % HOST])
    if r.returncode == 0:
        d = r.stdout.strip().split("=", 1)[1]
        cert = datetime.datetime.strptime(d, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc).isoformat()
    iface = None
    r = run(["ip", "-o", "route", "show", "default"])
    m = re.search(r"dev (\S+)", r.stdout)
    if m:
        iface = m.group(1)
    vn = None
    if iface:
        r = run(["vnstat", "--json", "m", "-i", iface])
        try:
            months = json.loads(r.stdout)["interfaces"][0]["traffic"]["month"]
            cur = [x for x in months if x["date"]["year"] == int(time.strftime("%Y")) and x["date"]["month"] == int(time.strftime("%m"))]
            if cur:
                vn = {"iface": iface, "rx": cur[0]["rx"], "tx": cur[0]["tx"]}
            else:
                vn = {"iface": iface, "rx": 0, "tx": 0}
        except Exception:
            vn = None
    out({
        "xray": active("xray"), "nginx": active("nginx"),
        "cpu_percent": cpu(), "load": list(os.getloadavg()), "cpus": os.cpu_count(),
        "ram_used": mem["MemTotal"] - mem["MemAvailable"], "ram_total": mem["MemTotal"],
        "disk_free": du.free, "disk_total": du.total,
        "uptime_s": int(float(open("/proc/uptime").read().split()[0])),
        "cert_not_after": cert, "vnstat_month": vn,
    })


def main():
    a = sys.argv[1:]
    if os.geteuid() != 0:
        fail("root only")
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    if not a:
        fail("no command")
    c, rest = a[0], a[1:]
    if c in ("health", "stats", "users") and not rest:
        {"health": cmd_health, "stats": cmd_stats, "users": cmd_users}[c]()
    elif c in ("add", "revoke", "link") and rest and NAME_RE.match(rest[0]):
        flags = set(rest[1:])
        if c == "add" and flags <= {"--no-torrent"} and len(rest[1:]) == len(flags):
            cmd_add(rest[0], "--no-torrent" in flags)
        elif c == "revoke" and flags <= {"--force"} and len(rest[1:]) == len(flags):
            cmd_revoke(rest[0], "--force" in flags)
        elif c == "link" and not flags:
            cmd_link(rest[0])
    fail("bad command")


main()
