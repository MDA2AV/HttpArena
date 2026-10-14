-- The runs' logs stay in the HttpArena repository, and logs/... sends a reader there (Logs.cs),
-- so the table that said which log this lambda kept under which path goes. The gzipped logs it
-- named were in the workspace under logs/, which is removed with them.

DROP INDEX IF EXISTS logs_by_blob;

DROP TABLE IF EXISTS logs;
