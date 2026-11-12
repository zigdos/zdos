/* SQLTEST [CRASH | CHECK]: tests SQLITE.ZDL on the drives labelled
 * SQLDISK and SQLEXT. CRASH commits until the power goes; CHECK then
 * finds every commit whole. Exit code: failures. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include "sqlite3.h"
#include "zdos.h"

static int passed, failed;
static char log_path[32];

static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fputs(line, stdout);
    /* Opened and closed per line: on disk even if the power goes */
    if (log_path[0]) {
        FILE *f = fopen(log_path, "a");
        if (f) {
            fputs(line, f);
            fclose(f);
        }
    }
}

static void check(int ok, const char *what, const char *detail) {
    if (ok) passed++; else failed++;
    say("%s - %s%s%s\n", ok ? "ok" : "not ok", what, detail && !ok ? ": " : "", detail && !ok ? detail : "");
}

/* The drives to test: letters of those labelled SQLDISK, SQLEXT */
static int drives(char *letters, char *log_letter) {
    int n = 0;
    zdos_drive_info info;
    for (uint32_t i = 0; zdos->drives->at(i, &info); i++) {
        if (!info.ready || info.letter == 0) continue;
        if (info.label_len == 7 && strncasecmp(info.label, "SQLDISK", 7) == 0) {
            *log_letter = (char)info.letter;
            letters[n++] = (char)info.letter;
        } else if (info.label_len == 6 && strncasecmp(info.label, "SQLEXT", 6) == 0) {
            letters[n++] = (char)info.letter;
        }
    }
    letters[n] = 0;
    return n;
}

static int exec(sqlite3 *db, const char *sql) {
    char *err = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        say("# %s: %s\n", sql, err ? err : sqlite3_errstr(rc));
        sqlite3_free(err);
    }
    return rc;
}

/* The first column of the first row as a number (-1: none or an error) */
static sqlite3_int64 number(sqlite3 *db, const char *sql) {
    sqlite3_stmt *st;
    sqlite3_int64 v = -1;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        say("# %s: %s\n", sql, sqlite3_errmsg(db));
        return -1;
    }
    if (sqlite3_step(st) == SQLITE_ROW) v = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return v;
}

static void text(sqlite3 *db, const char *sql, char *out, int len) {
    sqlite3_stmt *st;
    out[0] = 0;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        snprintf(out, len, "error: %s", sqlite3_errmsg(db));
        return;
    }
    /* The last column: EXPLAIN QUERY PLAN's is the plan's text */
    int col = sqlite3_column_count(st) - 1;
    if (sqlite3_step(st) == SQLITE_ROW && col >= 0 && sqlite3_column_text(st, col)) {
        snprintf(out, len, "%s", (const char *)sqlite3_column_text(st, col));
    }
    sqlite3_finalize(st);
}

static int exists(const char *path) {
    return access(path, F_OK) == 0;
}

/* Hot as SQLite counts it (pager.c, hasHotJournal): there, not empty,
   its first byte not 0. A power cut before the header's magic is
   written leaves a journal that isn't: SQLite ignores it, reuses it */
static int hot_journal(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return 0;
    int first = fgetc(f);
    fclose(f);
    return first != EOF && first != 0;
}

static void tests_on(char letter) {
    char dir[16], db_path[64], journal[80], what[96], got[256];
    snprintf(dir, sizeof dir, "%c:\\SQLTEST", letter);
    mkdir(dir, 0777);
    snprintf(db_path, sizeof db_path, "%s\\TEST.DB", dir);
    snprintf(journal, sizeof journal, "%s-journal", db_path);
    unlink(db_path);
    unlink(journal);
    say("# drive %c:\n", letter);
#define T(cond, name, detail) do { snprintf(what, sizeof what, "%c: %s", letter, name); check(cond, what, detail); } while (0)

    sqlite3 *db;
    int rc = sqlite3_open(db_path, &db);
    T(rc == SQLITE_OK, "a new database opens", sqlite3_errstr(rc));
    if (rc != SQLITE_OK) return;

    /* Rows through a prepared statement, in one transaction */
    T(exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, v REAL, b BLOB)") == SQLITE_OK, "CREATE TABLE", NULL);
    exec(db, "BEGIN");
    sqlite3_stmt *ins;
    sqlite3_prepare_v2(db, "INSERT INTO t(name, v) VALUES(?1, ?2)", -1, &ins, NULL);
    int bad = 0;
    for (int i = 1; i <= 2000; i++) {
        char name[32];
        snprintf(name, sizeof name, "row %d", i);
        sqlite3_bind_text(ins, 1, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(ins, 2, i * 0.5);
        if (sqlite3_step(ins) != SQLITE_DONE) bad++;
        sqlite3_reset(ins);
    }
    sqlite3_finalize(ins);
    T(exec(db, "COMMIT") == SQLITE_OK && bad == 0, "2000 rows inserted and committed", NULL);
    T(!exists(journal), "the journal is gone after the commit", NULL);
    T(number(db, "SELECT count(*) FROM t") == 2000, "count(*) is 2000", NULL);
    T(number(db, "SELECT sum(v) * 2 FROM t") == 2001000, "sum(v) is right", NULL);
    text(db, "SELECT name FROM t WHERE id = 1234", got, sizeof got);
    T(strcmp(got, "row 1234") == 0, "a row by its key", got);

    /* An index and a query through it */
    T(exec(db, "CREATE INDEX t_name ON t(name)") == SQLITE_OK, "CREATE INDEX", NULL);
    text(db, "EXPLAIN QUERY PLAN SELECT id FROM t WHERE name = 'row 77'", got, sizeof got);
    T(strstr(got, "INDEX t_name") != NULL, "the query uses the index", got);
    T(number(db, "SELECT id FROM t WHERE name = 'row 77'") == 77, "the index finds the row", NULL);

    /* Rollback */
    exec(db, "BEGIN");
    exec(db, "DELETE FROM t");
    T(exists(journal), "a journal while the transaction is open", NULL);
    exec(db, "ROLLBACK");
    T(number(db, "SELECT count(*) FROM t") == 2000, "ROLLBACK brings the rows back", NULL);

    /* A blob over many pages */
    enum { BLOB = 200000 };
    unsigned char *blob = malloc(BLOB);
    for (int i = 0; i < BLOB; i++) blob[i] = (unsigned char)(i * 7 + i / 251);
    sqlite3_stmt *st;
    sqlite3_prepare_v2(db, "UPDATE t SET b = ?1 WHERE id = 5", -1, &st, NULL);
    sqlite3_bind_blob(st, 1, blob, BLOB, SQLITE_STATIC);
    T(sqlite3_step(st) == SQLITE_DONE, "a 200 KB blob written", sqlite3_errmsg(db));
    sqlite3_finalize(st);
    sqlite3_prepare_v2(db, "SELECT b FROM t WHERE id = 5", -1, &st, NULL);
    int same = sqlite3_step(st) == SQLITE_ROW && sqlite3_column_bytes(st, 0) == BLOB &&
               memcmp(sqlite3_column_blob(st, 0), blob, BLOB) == 0;
    sqlite3_finalize(st);
    T(same, "the blob reads back the same", NULL);

    /* A second connection of this program: SQLite's locks between them */
    sqlite3 *db2;
    sqlite3_open(db_path, &db2);
    exec(db, "BEGIN IMMEDIATE");
    exec(db, "INSERT INTO t(name) VALUES('new')");
    T(number(db2, "SELECT count(*) FROM t") == 2000, "another connection doesn't see uncommitted rows", NULL);
    char *err = NULL;
    rc = sqlite3_exec(db2, "BEGIN IMMEDIATE", NULL, NULL, &err);
    sqlite3_free(err);
    T(rc == SQLITE_BUSY, "a second writer is told BUSY", sqlite3_errstr(rc));
    exec(db, "COMMIT");
    T(number(db2, "SELECT count(*) FROM t") == 2001, "and sees the rows once committed", NULL);
    sqlite3_close(db2);

    /* Functions built in: JSON, math, dates, FTS5, random */
    text(db, "SELECT json_extract('{\"a\":[1,2,{\"b\":\"zdos\"}]}', '$.a[2].b')", got, sizeof got);
    T(strcmp(got, "zdos") == 0, "json_extract", got);
    T(number(db, "SELECT CAST(sqrt(144) AS INTEGER)") == 12, "math functions (sqrt)", NULL);
    T(number(db, "SELECT CAST(strftime('%Y', 'now') AS INTEGER)") >= 2025, "the date from ZDOS's clock", NULL);
    T(number(db, "SELECT random() <> random()") == 1, "random() differs", NULL);
    rc = exec(db, "CREATE VIRTUAL TABLE docs USING fts5(body);"
                  "INSERT INTO docs VALUES('ZDOS runs SQLite'), ('a quick brown fox'), ('SQLite on ZDOS drives')");
    T(rc == SQLITE_OK && number(db, "SELECT count(*) FROM docs WHERE docs MATCH 'sqlite AND zdos'") == 2, "FTS5 full-text search", NULL);

    /* Sorting more than fits in memory: temporary files */
    exec(db, "PRAGMA temp_store = FILE; PRAGMA cache_size = 20");
    T(number(db, "SELECT count(*) FROM (SELECT name FROM t ORDER BY random())") == 2001, "a sort through temporary files", NULL);
    exec(db, "PRAGMA temp_store = DEFAULT; PRAGMA cache_size = -2000");

    /* Shrinking, and whole again */
    exec(db, "UPDATE t SET b = NULL");
    T(exec(db, "VACUUM") == SQLITE_OK, "VACUUM", NULL);
    text(db, "PRAGMA integrity_check", got, sizeof got);
    T(strcmp(got, "ok") == 0, "integrity_check after it", got);
    sqlite3_close(db);

    /* Reopened: still there */
    rc = sqlite3_open_v2(db_path, &db, SQLITE_OPEN_READONLY, NULL);
    T(rc == SQLITE_OK && number(db, "SELECT count(*) FROM t") == 2001, "the rows are there after reopening (read-only)", NULL);
    rc = sqlite3_exec(db, "DELETE FROM t", NULL, NULL, NULL);
    T(rc == SQLITE_READONLY, "read-only refuses changes", sqlite3_errstr(rc));
    sqlite3_close(db);

    /* Errors */
    char missing[64];
    snprintf(missing, sizeof missing, "%c:\\NO\\SUCH\\DIR\\X.DB", letter);
    rc = sqlite3_open_v2(missing, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    T(rc == SQLITE_CANTOPEN, "a missing folder: CANTOPEN", sqlite3_errstr(rc));
    sqlite3_close(db);
    snprintf(missing, sizeof missing, "%c:\\SQLTEST\\NONE.DB", letter);
    rc = sqlite3_open_v2(missing, &db, SQLITE_OPEN_READONLY, NULL);
    T(rc == SQLITE_CANTOPEN && !exists(missing), "opening a missing file read-only fails, makes none", sqlite3_errstr(rc));
    sqlite3_close(db);
    free(blob);
#undef T
}

static const char *crash_db(char letter, char *buf, int len) {
    snprintf(buf, len, "%c:\\SQLTEST\\CRASH.DB", letter);
    return buf;
}

static int crash(const char *letters) {
    char path[64], dir[16];
    sqlite3 *dbs[4];
    int n = (int)strlen(letters);
    for (int i = 0; i < n; i++) {
        snprintf(dir, sizeof dir, "%c:\\SQLTEST", letters[i]);
        mkdir(dir, 0777);
        crash_db(letters[i], path, sizeof path);
        unlink(path);
        if (sqlite3_open(path, &dbs[i]) != SQLITE_OK ||
            exec(dbs[i], "CREATE TABLE counter(n INTEGER); INSERT INTO counter VALUES(0);"
                         "CREATE TABLE log(n INTEGER PRIMARY KEY, filler BLOB)") != SQLITE_OK) {
            say("not ok - CRASH: %s can't be made\n", path);
            return 1;
        }
    }
    say("# CRASH: committing until the power goes\n");
    log_path[0] = 0; /* nothing more into the log: only the databases change */
    for (long round = 1;; round++) {
        for (int i = 0; i < n; i++) {
            /* Rows of growing size: pages, then overflow pages: */
            char sql[160];
            snprintf(sql, sizeof sql, "BEGIN; UPDATE counter SET n = n + 1;"
                     "INSERT INTO log VALUES(%ld, randomblob(%ld)); COMMIT", round, 200 + (round * 977) % 6000);
            if (exec(dbs[i], sql) != SQLITE_OK) return 1;
        }
        if (round % 25 == 0) printf("%ld commits\n", round);
    }
}

static void check_crash(const char *letters) {
    char path[64], what[96], got[256];
    for (const char *l = letters; *l; l++) {
        crash_db(*l, path, sizeof path);
        sqlite3 *db;
        int rc = sqlite3_open(path, &db);
        snprintf(what, sizeof what, "%c: the database opens after the power failure", *l);
        check(rc == SQLITE_OK, what, sqlite3_errstr(rc));
        if (rc != SQLITE_OK) continue;
        text(db, "PRAGMA integrity_check", got, sizeof got);
        snprintf(what, sizeof what, "%c: integrity_check", *l);
        check(strcmp(got, "ok") == 0, what, got);
        sqlite3_int64 counter = number(db, "SELECT n FROM counter");
        sqlite3_int64 rows = number(db, "SELECT count(*) FROM log");
        sqlite3_int64 last = number(db, "SELECT max(n) FROM log");
        snprintf(got, sizeof got, "counter %lld, rows %lld, last %lld", counter, rows, last);
        snprintf(what, sizeof what, "%c: every transaction whole (%lld committed)", *l, counter);
        check(counter > 0 && counter == rows && rows == last, what, got);
        snprintf(path + strlen(path), sizeof path - strlen(path), "-journal");
        snprintf(what, sizeof what, "%c: no hot journal left", *l);
        check(!hot_journal(path), what, NULL);
        sqlite3_close(db);
    }
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";
    char letters[8], log_letter = 0;
    int n = drives(letters, &log_letter);
    if (log_letter) {
        const char *name = strcasecmp(mode, "CHECK") == 0 ? "CHECK.LOG" : strcasecmp(mode, "CRASH") == 0 ? "CRASH.LOG" : "SQLTEST.LOG";
        snprintf(log_path, sizeof log_path, "%c:\\%s", log_letter, name);
        unlink(log_path);
        char v[2] = {log_letter, ':'};
        zdos->programs->set_var("SQLDISK", 7, v, 2);
    }
    say("# SQLTEST %s, SQLite %s (library %s)\n", mode, SQLITE_VERSION, sqlite3_libversion());
    if (n == 0) {
        say("not ok - no drive labelled SQLDISK or SQLEXT\n");
        return 1;
    }
    if (strcasecmp(mode, "CRASH") == 0) return crash(letters);
    if (strcasecmp(mode, "CHECK") == 0) {
        check_crash(letters);
    } else {
        check(strcmp(sqlite3_libversion(), SQLITE_VERSION) == 0, "the library is the headers' version", sqlite3_libversion());
        check(strcmp(sqlite3_vfs_find(NULL)->zName, "zdos") == 0, "the file layer is ZDOS's", NULL);
        for (int i = 0; i < n; i++) tests_on(letters[i]);
    }
    say("# SQLTEST: %d passed, %d failed\n", passed, failed);
    return failed > 255 ? 255 : failed;
}
