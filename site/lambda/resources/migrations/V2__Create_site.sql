-- The site, kept as data rather than in a version: what scripts/gen_leaderboard_data.py
-- generated at a commit of main, sent through api/ingest/site/. site_files says which content
-- each path of the site is; the content itself is in the workspace at site/{sha256}, so a file
-- that did not change from one publish to the next is sent and kept once. site_publishes says
-- which commit's site went online, and when.

CREATE TABLE site_publishes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created     TEXT    NOT NULL,
    commit_sha  TEXT    NOT NULL,
    files       INTEGER NOT NULL,
    changed     INTEGER NOT NULL DEFAULT 0,
    removed     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE site_files (
    path        TEXT    PRIMARY KEY,
    sha256      TEXT    NOT NULL
);
