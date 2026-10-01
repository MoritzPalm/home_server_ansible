"""Applies ansible-managed settings to calibre-web-automated's SQLite databases.

Run inside the container as abc, so any WAL sidecar it creates stays writable by
CWA. Reads one JSON document on stdin (it carries secrets, so never argv):

    {"app_settings": {...}, "oauth_provider": {...}, "cwa_settings": {...},
     "admin": {"username": "...", "password": "..."}}

Prints {"changed": [...], "restart": bool}. Exit 3 means CWA has not finished
creating its databases yet and the caller should retry.
"""
import json
import os
import sqlite3
import sys

from werkzeug.security import check_password_hash, generate_password_hash

APP_DB = "/config/app.db"
CWA_DB = "/config/cwa.db"
NOT_READY = 3

# cps/constants.py
ROLE_ADMIN = 1 << 0
ADMIN_USER_ROLES = 479  # every role bit except ROLE_ANONYMOUS


def not_ready(reason):
    print(json.dumps({"not_ready": reason}))
    sys.exit(NOT_READY)


def fail(reason):
    print(json.dumps({"failed": reason}))
    sys.exit(1)


def table_exists(cur, table):
    return cur.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
    ).fetchone() is not None


def normalise(value):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (list, dict)):
        return json.dumps(value)
    return value


def same(current, desired):
    if isinstance(desired, (list, dict)):
        try:
            return json.loads(current) == desired
        except (TypeError, ValueError):
            return False
    desired = normalise(desired)
    # Column affinity can hand back 338 for '338' and the reverse.
    return current == desired or (current is not None and str(current) == str(desired))


def apply(cur, table, where, params, desired, label, changed):
    """Update the single row matched by `where` to the desired column values."""
    columns = {row[1] for row in cur.execute(f'PRAGMA table_info("{table}")')}
    unknown = sorted(set(desired) - columns)
    if unknown:
        # A renamed column would otherwise be silently ignored.
        fail(f"{table} has no column(s) {unknown}; the CWA schema has changed")

    names = list(desired)
    row = cur.execute(
        f'SELECT {", ".join(names)} FROM "{table}" WHERE {where}', params
    ).fetchone()
    if row is None:
        not_ready(f"no {label} row yet")

    stale = [n for n, current in zip(names, row) if not same(current, desired[n])]
    if stale:
        assignments = ", ".join(f"{n} = ?" for n in stale)
        values = [normalise(desired[n]) for n in stale]
        cur.execute(f'UPDATE "{table}" SET {assignments} WHERE {where}', values + list(params))
        # Names only: some of these values are secrets.
        changed.extend(f"{label}.{n}" for n in stale)


def main():
    cfg = json.load(sys.stdin)
    changed = []
    restart = False

    for path in (APP_DB, CWA_DB):
        if not os.path.exists(path):
            not_ready(f"{path} does not exist")

    app = sqlite3.connect(APP_DB, timeout=30)
    cur = app.cursor()
    for table in ("settings", "oauthProvider", "user"):
        if not table_exists(cur, table):
            not_ready(f"app.db has no {table} table")

    # CWA creates github, google and then generic at startup, and the login
    # template renders the generic button only for provider id 3 — so the row is
    # waited for rather than inserted, which could give it another id.
    generic = cur.execute(
        "SELECT id FROM oauthProvider WHERE provider_name = 'generic'"
    ).fetchone()
    if generic is None:
        not_ready("generic oauthProvider row not created yet")
    if generic[0] != 3:
        fail(f"generic oauthProvider has id {generic[0]}; CWA only renders the login button for id 3")

    before = len(changed)
    apply(cur, "settings", "1 = 1", (), cfg["app_settings"], "settings", changed)
    apply(cur, "oauthProvider", "id = ?", (generic[0],), cfg["oauth_provider"], "oauthProvider", changed)
    restart = len(changed) > before

    admin = cfg["admin"]
    user = cur.execute(
        "SELECT id, password FROM user WHERE lower(name) = lower(?)", (admin["username"],)
    ).fetchone()
    if user is None:
        not_ready(f"user {admin['username']} not created yet")
    if not user[1] or not check_password_hash(user[1], admin["password"]):
        cur.execute(
            "UPDATE user SET password = ? WHERE id = ?",
            (generate_password_hash(admin["password"]), user[0]),
        )
        changed.append(f"user.{admin['username']}.password")

    # An OIDC user created as an admin gets ROLE_ADMIN alone — no download,
    # reading or editing — because oauth_bb assigns it instead of OR-ing it in.
    # Nobody sets that combination on purpose, so it is widened to full admin.
    widened = cur.execute(
        "UPDATE user SET role = ? WHERE role = ?", (ADMIN_USER_ROLES, ROLE_ADMIN)
    ).rowcount
    if widened:
        changed.append(f"user.role widened for {widened} admin(s)")

    app.commit()
    app.close()

    cwa = sqlite3.connect(CWA_DB, timeout=30)
    cur = cwa.cursor()
    if not table_exists(cur, "cwa_settings"):
        not_ready("cwa.db has no cwa_settings table")
    apply(cur, "cwa_settings", "1 = 1", (), cfg["cwa_settings"], "cwa_settings", changed)
    cwa.commit()
    cwa.close()

    print(json.dumps({"changed": changed, "restart": restart}))


if __name__ == "__main__":
    main()
