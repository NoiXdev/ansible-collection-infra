#!/usr/bin/env python3
"""Adds the noix error pages include to CloudPanel's vhost templates and vhosts.

usage: error_pages_vhosts.py <database> <sites dir> <include file> <state file>

CloudPanel keeps the vhost of every site in its database (site.vhost_template:
what the vhost editor shows and saves) and writes <sites dir>/<domain>.conf
from it whenever the site changes, so a line only in that file would be lost
on the next save. The include line goes after every "server {" line (LF or
CRLF, as the vhost editor stored it):

- of CloudPanel's own vhost templates (type system), which new sites copy.
  CloudPanel imports these again every day and on its updates, so they are
  patched again on every run.
- of each site's vhost, in the database and in the vhost file, once. A site
  (id, domain and, where CloudPanel stores it, creation time) is recorded in
  the state file as soon as its vhost has the include; a recorded site without
  it had the include removed (in the vhost editor) and is reported and left
  alone. A site recreated under the same domain counts as new.

Without a state file the run counts as the first one, unless a site already
has the include: then the record was lost (or the include was added by hand
before the first run), and the sites without it are reported instead of
patched (record_lost in the output).

All of it runs in one write transaction (BEGIN IMMEDIATE, so a vhost editor
save cannot slip in between reading and writing a vhost). The vhost files are
written, then `nginx -t` runs, and only then is the transaction committed. If
nginx -t or the commit fails, every file is restored (each on its own; an
atomic replace first, else an overwrite in place, which needs no free space),
the transaction is rolled back and the script exits non-zero with the reason.
A file that cannot be restored is named in the message: it still has the
include while CloudPanel's database does not.

Templates of type custom are left alone; a site made from one gets the
include on the next run. Prints JSON: templates and vhosts (patched now),
without (sites that lack the include and are left alone), overrides (system templates with an
error_page of their own: their sites do not get the default codes), record_lost,
changed.

SQLite gives a journal it creates as root the owner of the database, so
CloudPanel (user clp) can still write the database afterwards.
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile

TYPE_SYSTEM = 1
SERVER = re.compile(r"^([ \t]*)server[ \t]*\{[ \t]*(\r?)$", re.M)
ERROR_PAGE = re.compile(r"^[ \t]*error_page[ \t]", re.M)


class Failed(Exception):
    """What failed and the details; the script's error message is "<what>: <details>"."""


def write_atomic(path, text):
    st = os.stat(path)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w", newline="") as f:
            f.write(text)
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def restore(originals):
    """Writes every original back, each on its own; returns the files that are left patched."""
    left = []
    for path, content in originals.items():
        try:
            write_atomic(path, content)
            continue
        except BaseException:
            pass
        # The original is shorter than the patched file: overwritten in place,
        # it needs no new space (a full disk fails the atomic replace).
        try:
            with open(path, "r+", newline="") as f:
                f.write(content)
                f.truncate()
        except BaseException as e:
            left.append("%s (%s)" % (path, e))
    return left


def read_state(path):
    try:
        with open(path) as f:
            return {(entry["id"], entry["domain"], entry.get("created")) for entry in json.load(f)}
    except FileNotFoundError:
        return None


def main():
    db_path, sites_dir, include, state_path = sys.argv[1:]
    line = "include %s;" % include
    present = re.compile(r"^[ \t]*include[ \t]+%s[ \t]*;" % re.escape(include), re.M)

    def add(text):
        # Keeps the line ending: "server {\r" gets "  include ...;\r".
        return SERVER.sub(lambda m: "%s\n%s  %s%s" % (m.group(0), m.group(1), line, m.group(2)), text)

    seen = read_state(state_path)
    result = {"templates": [], "vhosts": [], "without": [], "overrides": [], "record_lost": False}
    with_include = set()
    originals = {}
    db = sqlite3.connect(db_path, timeout=60, isolation_level=None)
    try:
        db.execute("BEGIN IMMEDIATE")
        try:
            rows = db.execute(
                "SELECT id, name, template FROM vhost_template WHERE type = ? ORDER BY name", (TYPE_SYSTEM,)
            ).fetchall()
            for row_id, name, template in rows:
                if ERROR_PAGE.search(template):
                    result["overrides"].append(name)
                if not present.search(template) and SERVER.search(template):
                    db.execute("UPDATE vhost_template SET template = ? WHERE id = ?", (add(template), row_id))
                    result["templates"].append(name)

            # SQLite gives a new site the id of a deleted newest one again; with
            # its creation time a recreated site is still a new one.
            columns = {row[1] for row in db.execute("PRAGMA table_info(site)")}
            created = "created_at" if "created_at" in columns else "NULL"
            sites = [
                ((row_id, domain, created_at), vhost)
                for row_id, domain, vhost, created_at in db.execute(
                    "SELECT id, domain_name, vhost_template, %s FROM site ORDER BY domain_name" % created
                )
            ]
            # No record although a site has the include: not the first run (the
            # record was lost), or someone added the include by hand before the
            # first run. Patch nothing, report.
            record_lost = seen is None and any(present.search(vhost) for _, vhost in sites)
            result["record_lost"] = record_lost
            seen = seen or set()
            for key, vhost in sites:
                row_id, domain, _ = key
                if present.search(vhost):
                    with_include.add(key)
                    continue
                if record_lost or key in seen or not SERVER.search(vhost):
                    result["without"].append(domain)
                    continue
                db.execute("UPDATE site SET vhost_template = ? WHERE id = ?", (add(vhost), row_id))
                vhost_file = os.path.join(sites_dir, domain + ".conf")
                if os.path.exists(vhost_file):
                    with open(vhost_file, newline="") as f:
                        content = f.read()
                    if not present.search(content):
                        originals[vhost_file] = content
                        write_atomic(vhost_file, add(content))
                result["vhosts"].append(domain)
                with_include.add(key)

            if originals:
                test = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
                if test.returncode != 0:
                    raise Failed(
                        "nginx -t failed after adding the include to %s" % ", ".join(result["vhosts"]),
                        test.stderr.strip(),
                    )
            # Inside the try: a failed commit restores the files too.
            db.execute("COMMIT")
        except BaseException as e:
            left = restore(originals)
            try:
                db.execute("ROLLBACK")
            except sqlite3.Error:
                pass  # a failed COMMIT may have rolled back already
            if not isinstance(e, Exception):
                raise
            what, detail = e.args if isinstance(e, Failed) else ("The vhost changes failed", "%s: %s" % (type(e).__name__, e))
            if left:
                raise Failed(
                    "%s, and restoring failed: %s still have the include while CloudPanel's database does "
                    "not. Remove the line `%s` from them by hand before nginx is reloaded or restarted"
                    % (what, ", ".join(left), line),
                    detail,
                ) from e
            raise Failed("%s; the vhosts are unchanged" % what, detail) from e
    finally:
        db.close()

    # Sites that no longer exist are dropped. After a lost record every site
    # is recorded, so the ones without the include stay reported.
    current = {key for key, _ in sites}
    if record_lost:
        with_include |= current
    order = lambda key: (key[0], key[1], str(key[2]))  # noqa: E731
    recorded = sorted(with_include | (seen & current), key=order)
    if recorded != sorted(seen, key=order):
        os.makedirs(os.path.dirname(state_path), mode=0o700, exist_ok=True)
        with open(state_path + ".new", "w") as f:
            json.dump([{"id": i, "domain": d, "created": c} for i, d, c in recorded], f, indent=1)
            f.write("\n")
        os.replace(state_path + ".new", state_path)

    result["changed"] = bool(result["templates"] or result["vhosts"])
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Failed as e:
        sys.exit("%s: %s" % e.args)
