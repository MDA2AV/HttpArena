-- The records behind HttpArena's site.
--
-- A publish is a snapshot of the HttpArena repository's site/data at one commit of main.
-- frameworks and results hold what the newest publish had; result_history holds every row
-- as each publish changed it (row_json NULL: the row went away with that publish). logs says
-- which container log is kept under which path; the gzip itself is in the workspace, at
-- logs/{sha256}.gz, so logs with the same content are kept once.

CREATE TABLE publishes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created     TEXT    NOT NULL,
    commit_sha  TEXT    NOT NULL,
    pr          INTEGER,
    title       TEXT    NOT NULL DEFAULT '',
    host        TEXT    NOT NULL DEFAULT '{}',
    changed     INTEGER NOT NULL DEFAULT 0,
    removed     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE frameworks (
    name        TEXT    PRIMARY KEY,
    meta        TEXT    NOT NULL,
    publish_id  INTEGER NOT NULL REFERENCES publishes (id)
);

CREATE TABLE results (
    framework   TEXT    NOT NULL,
    result_key  TEXT    NOT NULL,
    slug        TEXT    NOT NULL,
    row_json    TEXT    NOT NULL,
    hash        TEXT    NOT NULL,
    publish_id  INTEGER NOT NULL REFERENCES publishes (id),
    PRIMARY KEY (framework, result_key)
);

CREATE INDEX results_by_slug ON results (slug, result_key);

CREATE TABLE result_history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    slug        TEXT    NOT NULL,
    framework   TEXT    NOT NULL,
    result_key  TEXT    NOT NULL,
    row_json    TEXT,
    publish_id  INTEGER NOT NULL REFERENCES publishes (id)
);

CREATE INDEX result_history_by_row ON result_history (slug, result_key, publish_id);

CREATE TABLE logs (
    path        TEXT    PRIMARY KEY,
    sha256      TEXT    NOT NULL,
    bytes       INTEGER NOT NULL,
    stored      INTEGER NOT NULL,
    updated     TEXT    NOT NULL
);

CREATE INDEX logs_by_blob ON logs (sha256);
