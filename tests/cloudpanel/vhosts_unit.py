"""Unit test of roles/cloudpanel/files/error_pages_vhosts.py, on the controller.

usage: python3 -I vhosts_unit.py <path of error_pages_vhosts.py>

A scratch copy of the two CloudPanel tables the script uses, vhost files in a
temporary directory and a fake `nginx -t`. Covers what the end-to-end test
cannot provoke on a real host: a failing COMMIT and a vhost file that cannot
be restored. Plain asserts; exits non-zero on the first failure.
"""

import builtins
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # no __pycache__ next to the role's file

INCLUDE = "/etc/nginx/noix-error-pages.conf"
LINE = "include %s;" % INCLUDE
VHOSTS = {
    # domain: vhost (the same in the database and in the file)
    "a.test": "server {\n  listen 443;\n}\n",
    "b.test": "server {\r\n  listen 443;\r\n}\r\n",
    "c.test": "server {\n  listen 8080;\n}\n",
}

spec = importlib.util.spec_from_file_location("error_pages_vhosts", sys.argv[1])
script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(script)


def host(tmp):
    """A fresh database, sites directory and state path in tmp."""
    db_path = os.path.join(tmp, "db.sq3")
    sites = os.path.join(tmp, "sites")
    os.makedirs(sites)
    db = sqlite3.connect(db_path)
    db.execute("CREATE TABLE vhost_template (id INTEGER PRIMARY KEY, name TEXT, template TEXT, type INTEGER)")
    db.execute(
        "CREATE TABLE site (id INTEGER PRIMARY KEY, domain_name TEXT, vhost_template TEXT, created_at DATETIME)"
    )
    db.execute("INSERT INTO vhost_template (name, template, type) VALUES ('Generic', 'server {\n}\n', 1)")
    for domain, vhost in VHOSTS.items():
        db.execute(
            "INSERT INTO site (domain_name, vhost_template, created_at) VALUES (?, ?, '2026-01-01 00:00:00')",
            (domain, vhost),
        )
        with open(os.path.join(sites, domain + ".conf"), "w", newline="") as f:
            f.write(vhost)
    db.commit()
    db.close()
    return db_path, sites, os.path.join(tmp, "state", "vhosts.json")


def snapshot(db_path, sites):
    db = sqlite3.connect(db_path)
    rows = db.execute("SELECT domain_name, vhost_template FROM site UNION ALL SELECT name, template FROM vhost_template")
    state = sorted(rows.fetchall())
    db.close()
    files = {}
    for name in sorted(os.listdir(sites)):
        with open(os.path.join(sites, name), newline="") as f:
            files[name] = f.read()
    return state, files


def run(db_path, sites, state, nginx_rc=0):
    """Runs the script's main(); returns its JSON output or the Failed message."""
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, nginx_rc, "", "" if nginx_rc == 0 else "nginx: [emerg] test")

    script.subprocess.run = fake_run
    sys.argv = ["error_pages_vhosts.py", db_path, sites, INCLUDE, state]
    out = []
    builtins_print = builtins.print
    builtins.print = lambda *a, **k: out.append(" ".join(map(str, a)))
    try:
        script.main()
        return json.loads(out[-1])
    except script.Failed as e:
        return "%s: %s" % e.args
    finally:
        builtins.print = builtins_print


def check(name, condition, detail=""):
    if not condition:
        sys.exit("FAILED: %s %s" % (name, detail))
    print("ok: %s" % name)


# 1. Patches LF and CRLF vhosts, keeps the line ending, records the sites
#    with their creation time; a second run changes nothing.
with tempfile.TemporaryDirectory() as tmp:
    db_path, sites, state = host(tmp)
    result = run(db_path, sites, state)
    check("patches every vhost", result["vhosts"] == ["a.test", "b.test", "c.test"], result)
    _, files = snapshot(db_path, sites)
    check("LF vhost gets an LF include", "server {\n  %s\n" % LINE in files["a.test.conf"])
    check("CRLF vhost gets a CRLF include", "server {\r\n  %s\r\n" % LINE in files["b.test.conf"])
    with open(state) as f:
        recorded = json.load(f)
    check("records id, domain and creation time", recorded[0] == {"id": 1, "domain": "a.test", "created": "2026-01-01 00:00:00"}, recorded)
    check("second run changes nothing", run(db_path, sites, state)["changed"] is False)

# 2. A site deleted and created again under the same domain and id, but at
#    another time, counts as new and gets the include.
with tempfile.TemporaryDirectory() as tmp:
    db_path, sites, state = host(tmp)
    run(db_path, sites, state)
    db = sqlite3.connect(db_path)
    db.execute("UPDATE site SET vhost_template = ?, created_at = '2026-02-02 00:00:00' WHERE domain_name = 'c.test'", (VHOSTS["c.test"],))
    db.commit()
    db.close()
    with open(os.path.join(sites, "c.test.conf"), "w") as f:
        f.write(VHOSTS["c.test"])
    result = run(db_path, sites, state)
    check("recreated site with the same id is patched", result["vhosts"] == ["c.test"] and result["without"] == [], result)

# 3. nginx -t fails: files and database unchanged.
with tempfile.TemporaryDirectory() as tmp:
    db_path, sites, state = host(tmp)
    before = snapshot(db_path, sites)
    message = run(db_path, sites, state, nginx_rc=1)
    check("nginx -t failure is reported", isinstance(message, str) and "nginx -t failed" in message and "the vhosts are unchanged" in message, message)
    check("nginx -t failure leaves everything unchanged", snapshot(db_path, sites) == before)

# 4. COMMIT fails: the files are restored as well.
with tempfile.TemporaryDirectory() as tmp:
    db_path, sites, state = host(tmp)
    before = snapshot(db_path, sites)
    connect = sqlite3.connect

    class FailingCommit:
        def __init__(self, conn):
            self.conn = conn

        def execute(self, sql, *args):
            if sql == "COMMIT":
                raise sqlite3.OperationalError("database or disk is full")
            return self.conn.execute(sql, *args)

        def close(self):
            self.conn.close()

    sqlite3.connect = lambda *a, **k: FailingCommit(connect(*a, **k))
    try:
        message = run(db_path, sites, state)
    finally:
        sqlite3.connect = connect
    check("failed COMMIT is reported", isinstance(message, str) and "database or disk is full" in message and "the vhosts are unchanged" in message, message)
    check("failed COMMIT restores the files", snapshot(db_path, sites) == before)

# 5. The atomic restore fails for every file: the in-place overwrite restores them.
# 6. ... and for a.test the overwrite fails too: a.test is named, the other
#    files are still restored and the database is rolled back.
for in_place_fails in (False, True):
    with tempfile.TemporaryDirectory() as tmp:
        db_path, sites, state = host(tmp)
        before = snapshot(db_path, sites)
        write_atomic = script.write_atomic

        def failing_restore(path, text):
            if LINE not in text:
                raise OSError(28, "No space left on device")
            write_atomic(path, text)

        def failing_open(path, mode="r", *args, **kwargs):
            if in_place_fails and mode == "r+" and path.endswith("a.test.conf"):
                raise OSError(28, "No space left on device")
            return builtins.open(path, mode, *args, **kwargs)

        script.write_atomic = failing_restore
        script.open = failing_open
        try:
            message = run(db_path, sites, state, nginx_rc=1)
        finally:
            script.write_atomic = write_atomic
            del script.open
        db_state, files = snapshot(db_path, sites)
        check("database rolled back (in place fails: %s)" % in_place_fails, db_state == before[0])
        if not in_place_fails:
            check("in-place overwrite restores every file", files == before[1], files)
            check("restored by overwrite is reported unchanged", "the vhosts are unchanged" in message, message)
        else:
            check("the file left patched is named", "restoring failed" in message and "a.test.conf" in message
                  and "b.test.conf" not in message and LINE in message, message)
            check("the other files are still restored", files["b.test.conf"] == before[1]["b.test.conf"]
                  and files["c.test.conf"] == before[1]["c.test.conf"])
            check("the file left patched has the include", LINE in files["a.test.conf"])

# 7. No record, but a site already has the include: nothing patched, reported.
with tempfile.TemporaryDirectory() as tmp:
    db_path, sites, state = host(tmp)
    db = sqlite3.connect(db_path)
    db.execute("UPDATE site SET vhost_template = ? WHERE domain_name = 'a.test'", ("server {\n  %s\n}\n" % LINE,))
    db.commit()
    db.close()
    result = run(db_path, sites, state)
    check("lost record is flagged", result["record_lost"] is True and result["vhosts"] == []
          and result["without"] == ["b.test", "c.test"], result)

print("== all error_pages_vhosts.py unit tests passed")
