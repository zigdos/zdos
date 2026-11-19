/* zdos:sqlite: SQLite (SQLITE.ZDL) for QuickJS, in the manner of
 * Node's better-sqlite3 (ZDOSMODS.md). */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <sqlite3.h>

#include "quickjs.h"
#include "zdos_modules.h"

#define countof(a) (sizeof(a) / sizeof((a)[0]))

static JSClassID db_class, stmt_class;

typedef struct {
    sqlite3 *db;
    char *name;
} Db;

typedef struct {
    sqlite3_stmt *stmt;
    JSValue db; /* keeps the database open while the statement lives */
} Stmt;

static JSValue sqlite_error(JSContext *ctx, sqlite3 *db, int rc) {
    return JS_ThrowPlainError(ctx, "SQLite: %s", db != NULL ? sqlite3_errmsg(db) : sqlite3_errstr(rc));
}

static Db *db_of(JSContext *ctx, JSValueConst v) {
    Db *d = JS_GetOpaque2(ctx, v, db_class);
    if (d != NULL && d->db == NULL) {
        JS_ThrowTypeError(ctx, "the database is closed");
        return NULL;
    }
    return d;
}

static void db_finalizer(JSRuntime *rt, JSValueConst val) {
    Db *d = JS_GetOpaque(val, db_class);
    if (d == NULL) return;
    if (d->db != NULL) sqlite3_close_v2(d->db);
    free(d->name);
    free(d);
}

static void stmt_finalizer(JSRuntime *rt, JSValueConst val) {
    Stmt *s = JS_GetOpaque(val, stmt_class);
    if (s == NULL) return;
    if (s->stmt != NULL) sqlite3_finalize(s->stmt);
    JS_FreeValueRT(rt, s->db);
    free(s);
}

static void stmt_mark(JSRuntime *rt, JSValueConst val, JS_MarkFunc *mark) {
    Stmt *s = JS_GetOpaque(val, stmt_class);
    if (s != NULL) JS_MarkValue(rt, s->db, mark);
}

/* DATABASE */

static JSValue js_db_ctor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) {
    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, rc;
    const char *path = JS_ToCString(ctx, argv[0]);
    if (path == NULL) return JS_EXCEPTION;
    if (argc > 1 && JS_IsObject(argv[1])) {
        JSValue ro = JS_GetPropertyStr(ctx, argv[1], "readonly");
        if (JS_ToBool(ctx, ro)) flags = SQLITE_OPEN_READONLY;
        JS_FreeValue(ctx, ro);
    }
    Db *d = calloc(1, sizeof(*d));
    if (d == NULL) {
        JS_FreeCString(ctx, path);
        return JS_ThrowOutOfMemory(ctx);
    }
    d->name = strdup(path);
    rc = sqlite3_open_v2(path, &d->db, flags, NULL);
    JS_FreeCString(ctx, path);
    if (rc != SQLITE_OK) {
        JSValue e = sqlite_error(ctx, d->db, rc);
        sqlite3_close_v2(d->db);
        free(d->name);
        free(d);
        return e;
    }
    sqlite3_busy_timeout(d->db, 5000);
    JSValue obj = JS_NewObjectClass(ctx, db_class);
    if (JS_IsException(obj)) {
        sqlite3_close_v2(d->db);
        free(d->name);
        free(d);
        return obj;
    }
    JS_SetOpaque(obj, d);
    return obj;
}

static JSValue js_db_exec(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Db *d = db_of(ctx, this_val);
    if (d == NULL) return JS_EXCEPTION;
    const char *sql = JS_ToCString(ctx, argv[0]);
    if (sql == NULL) return JS_EXCEPTION;
    char *err = NULL;
    int rc = sqlite3_exec(d->db, sql, NULL, NULL, &err);
    JS_FreeCString(ctx, sql);
    if (rc != SQLITE_OK) {
        JSValue e = JS_ThrowPlainError(ctx, "SQLite: %s", err != NULL ? err : sqlite3_errstr(rc));
        sqlite3_free(err);
        return e;
    }
    return JS_DupValue(ctx, this_val);
}

static JSValue js_db_prepare(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Db *d = db_of(ctx, this_val);
    if (d == NULL) return JS_EXCEPTION;
    size_t len;
    const char *sql = JS_ToCStringLen(ctx, &len, argv[0]);
    if (sql == NULL) return JS_EXCEPTION;
    sqlite3_stmt *st = NULL;
    const char *tail = NULL;
    int rc = sqlite3_prepare_v2(d->db, sql, (int)len, &st, &tail);
    int more = rc == SQLITE_OK && tail != NULL && strspn(tail, " \t\r\n;") != strlen(tail);
    JS_FreeCString(ctx, sql);
    if (rc != SQLITE_OK) return sqlite_error(ctx, d->db, rc);
    if (st == NULL) return JS_ThrowTypeError(ctx, "SQLite: no statement");
    if (more) {
        sqlite3_finalize(st);
        return JS_ThrowTypeError(ctx, "SQLite: prepare takes one statement (exec runs several)");
    }
    Stmt *s = calloc(1, sizeof(*s));
    if (s == NULL) {
        sqlite3_finalize(st);
        return JS_ThrowOutOfMemory(ctx);
    }
    s->stmt = st;
    s->db = JS_DupValue(ctx, this_val);
    JSValue obj = JS_NewObjectClass(ctx, stmt_class);
    if (JS_IsException(obj)) {
        sqlite3_finalize(st);
        JS_FreeValue(ctx, s->db);
        free(s);
        return obj;
    }
    JS_SetOpaque(obj, s);
    return obj;
}

static JSValue js_db_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Db *d = JS_GetOpaque2(ctx, this_val, db_class);
    if (d == NULL) return JS_EXCEPTION;
    if (d->db != NULL) {
        sqlite3_close_v2(d->db); /* statements still alive close it when finalized */
        d->db = NULL;
    }
    return JS_UNDEFINED;
}

static JSValue js_db_get_open(JSContext *ctx, JSValueConst this_val) {
    Db *d = JS_GetOpaque2(ctx, this_val, db_class);
    return d == NULL ? JS_EXCEPTION : JS_NewBool(ctx, d->db != NULL);
}

static JSValue js_db_get_in_transaction(JSContext *ctx, JSValueConst this_val) {
    Db *d = JS_GetOpaque2(ctx, this_val, db_class);
    if (d == NULL) return JS_EXCEPTION;
    return JS_NewBool(ctx, d->db != NULL && !sqlite3_get_autocommit(d->db));
}

static JSValue js_db_get_name(JSContext *ctx, JSValueConst this_val) {
    Db *d = JS_GetOpaque2(ctx, this_val, db_class);
    return d == NULL ? JS_EXCEPTION : JS_NewString(ctx, d->name != NULL ? d->name : "");
}

/* data[0]: the database, data[1]: the function */
static JSValue transaction_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic,
                                JSValueConst *data) {
    Db *d = db_of(ctx, data[0]);
    if (d == NULL) return JS_EXCEPTION;
    int nested = !sqlite3_get_autocommit(d->db);
    /* nested: a savepoint, so an inner failure undoes only its part */
    const char *begin = nested ? "SAVEPOINT zdos_tx" : "BEGIN";
    const char *commit = nested ? "RELEASE zdos_tx" : "COMMIT";
    const char *undo = nested ? "ROLLBACK TO zdos_tx; RELEASE zdos_tx" : "ROLLBACK";
    int rc = sqlite3_exec(d->db, begin, NULL, NULL, NULL);
    if (rc != SQLITE_OK) return sqlite_error(ctx, d->db, rc);
    JSValue r = JS_Call(ctx, data[1], this_val, argc, argv);
    if (JS_IsException(r)) {
        sqlite3_exec(d->db, undo, NULL, NULL, NULL);
        return r;
    }
    rc = sqlite3_exec(d->db, commit, NULL, NULL, NULL);
    if (rc != SQLITE_OK) {
        JSValue e = sqlite_error(ctx, d->db, rc);
        sqlite3_exec(d->db, undo, NULL, NULL, NULL);
        JS_FreeValue(ctx, r);
        return e;
    }
    return r;
}

static JSValue js_db_transaction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (db_of(ctx, this_val) == NULL) return JS_EXCEPTION;
    if (!JS_IsFunction(ctx, argv[0])) return JS_ThrowTypeError(ctx, "transaction takes a function");
    JSValueConst data[2] = {this_val, argv[0]};
    return JS_NewCFunctionData(ctx, transaction_call, 0, 0, 2, data);
}

/* STATEMENTS */

static Stmt *stmt_of(JSContext *ctx, JSValueConst v) {
    Stmt *s = JS_GetOpaque2(ctx, v, stmt_class);
    if (s != NULL && s->stmt == NULL) {
        JS_ThrowTypeError(ctx, "the statement is finalized");
        return NULL;
    }
    if (s != NULL) {
        Db *d = JS_GetOpaque(s->db, db_class);
        if (d == NULL || d->db == NULL) {
            JS_ThrowTypeError(ctx, "the database is closed");
            return NULL;
        }
    }
    return s;
}

static int bind_value(JSContext *ctx, sqlite3_stmt *st, int i, JSValueConst v) {
    int rc;
    if (JS_IsNull(v) || JS_IsUndefined(v)) {
        rc = sqlite3_bind_null(st, i);
    } else if (JS_IsBool(v)) {
        rc = sqlite3_bind_int(st, i, JS_ToBool(ctx, v));
    } else if (JS_IsNumber(v)) {
        double x;
        JS_ToFloat64(ctx, &x, v);
        if (x == floor(x) && fabs(x) <= 9007199254740991.0) rc = sqlite3_bind_int64(st, i, (sqlite3_int64)x);
        else rc = sqlite3_bind_double(st, i, x);
    } else if (JS_IsBigInt(v)) {
        int64_t x;
        if (JS_ToBigInt64(ctx, &x, v)) return -1;
        rc = sqlite3_bind_int64(st, i, x);
    } else if (JS_IsString(v)) {
        size_t len;
        const char *s = JS_ToCStringLen(ctx, &len, v);
        if (s == NULL) return -1;
        rc = sqlite3_bind_text(st, i, s, (int)len, SQLITE_TRANSIENT);
        JS_FreeCString(ctx, s);
    } else if (JS_IsArrayBuffer(v)) {
        size_t len;
        uint8_t *p = JS_GetArrayBuffer(ctx, &len, v);
        if (p == NULL && len != 0) return -1;
        rc = sqlite3_bind_blob(st, i, len ? p : (const void *)"", (int)len, SQLITE_TRANSIENT);
    } else if (JS_GetTypedArrayType(v) >= 0) {
        size_t off, len, per, size;
        JSValue buf = JS_GetTypedArrayBuffer(ctx, v, &off, &len, &per);
        if (JS_IsException(buf)) return -1;
        uint8_t *p = JS_GetArrayBuffer(ctx, &size, buf);
        JS_FreeValue(ctx, buf);
        if (p == NULL && len != 0) return -1;
        rc = sqlite3_bind_blob(st, i, len ? p + off : (const void *)"", (int)len, SQLITE_TRANSIENT);
    } else {
        JS_ThrowTypeError(ctx, "SQLite: parameter %d: numbers, BigInt, strings, booleans, null and blobs only", i);
        return -1;
    }
    if (rc != SQLITE_OK) {
        sqlite_error(ctx, sqlite3_db_handle(st), rc);
        return -1;
    }
    return 0;
}

static int plain_object(JSContext *ctx, JSValueConst v) {
    return JS_IsObject(v) && !JS_IsArray(v) && !JS_IsArrayBuffer(v) && JS_GetTypedArrayType(v) < 0 &&
           !JS_IsFunction(ctx, v);
}

/* Fresh: reset, unbound, then argv's values */
static int bind_all(JSContext *ctx, sqlite3_stmt *st, int argc, JSValueConst *argv) {
    sqlite3_reset(st);
    sqlite3_clear_bindings(st);
    int count = sqlite3_bind_parameter_count(st);
    if (argc == 1 && plain_object(ctx, argv[0])) {
        for (int i = 1; i <= count; i++) {
            const char *name = sqlite3_bind_parameter_name(st, i);
            if (name == NULL) {
                JS_ThrowTypeError(ctx, "SQLite: parameter %d has no name (named values given)", i);
                return -1;
            }
            JSValue v = JS_GetPropertyStr(ctx, argv[0], name + 1);
            if (JS_IsException(v)) return -1;
            int r = bind_value(ctx, st, i, v);
            JS_FreeValue(ctx, v);
            if (r) return -1;
        }
        return 0;
    }
    /* in order; arrays given are spread */
    int n = 0;
    for (int a = 0; a < argc; a++) {
        if (JS_IsArray(argv[a])) {
            int64_t len;
            if (JS_GetLength(ctx, argv[a], &len)) return -1;
            for (int64_t k = 0; k < len; k++) {
                JSValue v = JS_GetPropertyInt64(ctx, argv[a], k);
                if (++n > count) {
                    JS_FreeValue(ctx, v);
                    break;
                }
                int r = bind_value(ctx, st, n, v);
                JS_FreeValue(ctx, v);
                if (r) return -1;
            }
        } else if (++n <= count && bind_value(ctx, st, n, argv[a])) {
            return -1;
        }
    }
    if (n != count) {
        JS_ThrowRangeError(ctx, "SQLite: %d values for %d parameters", n, count);
        return -1;
    }
    return 0;
}

static JSValue column_value(JSContext *ctx, sqlite3_stmt *st, int i) {
    switch (sqlite3_column_type(st, i)) {
    case SQLITE_INTEGER: {
        sqlite3_int64 v = sqlite3_column_int64(st, i);
        if (v > 9007199254740991LL || v < -9007199254740991LL) return JS_NewBigInt64(ctx, v);
        return JS_NewInt64(ctx, v);
    }
    case SQLITE_FLOAT:
        return JS_NewFloat64(ctx, sqlite3_column_double(st, i));
    case SQLITE_TEXT:
        return JS_NewStringLen(ctx, (const char *)sqlite3_column_text(st, i), (size_t)sqlite3_column_bytes(st, i));
    case SQLITE_BLOB:
        return JS_NewUint8ArrayCopy(ctx, sqlite3_column_blob(st, i), (size_t)sqlite3_column_bytes(st, i));
    default:
        return JS_NULL;
    }
}

static JSValue row_object(JSContext *ctx, sqlite3_stmt *st) {
    JSValue row = JS_NewObject(ctx);
    int n = sqlite3_column_count(st);
    for (int i = 0; i < n; i++) JS_SetPropertyStr(ctx, row, sqlite3_column_name(st, i), column_value(ctx, st, i));
    return row;
}

static JSValue step_error(JSContext *ctx, sqlite3_stmt *st, int rc) {
    JSValue e = sqlite_error(ctx, sqlite3_db_handle(st), rc);
    sqlite3_reset(st);
    return e;
}

static JSValue js_stmt_run(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Stmt *s = stmt_of(ctx, this_val);
    if (s == NULL || bind_all(ctx, s->stmt, argc, argv)) return JS_EXCEPTION;
    int rc;
    while ((rc = sqlite3_step(s->stmt)) == SQLITE_ROW) {}
    if (rc != SQLITE_DONE) return step_error(ctx, s->stmt, rc);
    sqlite3 *db = sqlite3_db_handle(s->stmt);
    JSValue r = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, r, "changes", JS_NewInt64(ctx, sqlite3_changes64(db)));
    sqlite3_int64 id = sqlite3_last_insert_rowid(db);
    JS_SetPropertyStr(ctx, r, "lastInsertRowid",
                      id > 9007199254740991LL || id < -9007199254740991LL ? JS_NewBigInt64(ctx, id) : JS_NewInt64(ctx, id));
    sqlite3_reset(s->stmt);
    return r;
}

static JSValue js_stmt_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Stmt *s = stmt_of(ctx, this_val);
    if (s == NULL || bind_all(ctx, s->stmt, argc, argv)) return JS_EXCEPTION;
    int rc = sqlite3_step(s->stmt);
    JSValue r;
    if (rc == SQLITE_ROW) r = row_object(ctx, s->stmt);
    else if (rc == SQLITE_DONE) r = JS_UNDEFINED;
    else return step_error(ctx, s->stmt, rc);
    sqlite3_reset(s->stmt);
    return r;
}

static JSValue js_stmt_all(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Stmt *s = stmt_of(ctx, this_val);
    if (s == NULL || bind_all(ctx, s->stmt, argc, argv)) return JS_EXCEPTION;
    JSValue rows = JS_NewArray(ctx);
    uint32_t n = 0;
    int rc;
    while ((rc = sqlite3_step(s->stmt)) == SQLITE_ROW) JS_SetPropertyUint32(ctx, rows, n++, row_object(ctx, s->stmt));
    if (rc != SQLITE_DONE) {
        JS_FreeValue(ctx, rows);
        return step_error(ctx, s->stmt, rc);
    }
    sqlite3_reset(s->stmt);
    return rows;
}

static JSValue js_stmt_columns(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Stmt *s = stmt_of(ctx, this_val);
    if (s == NULL) return JS_EXCEPTION;
    JSValue names = JS_NewArray(ctx);
    int n = sqlite3_column_count(s->stmt);
    for (int i = 0; i < n; i++) JS_SetPropertyUint32(ctx, names, (uint32_t)i, JS_NewString(ctx, sqlite3_column_name(s->stmt, i)));
    return names;
}

static JSValue js_stmt_finalize(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    Stmt *s = JS_GetOpaque2(ctx, this_val, stmt_class);
    if (s == NULL) return JS_EXCEPTION;
    if (s->stmt != NULL) {
        sqlite3_finalize(s->stmt);
        s->stmt = NULL;
    }
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry db_proto[] = {
    JS_CFUNC_DEF("exec", 1, js_db_exec),
    JS_CFUNC_DEF("prepare", 1, js_db_prepare),
    JS_CFUNC_DEF("transaction", 1, js_db_transaction),
    JS_CFUNC_DEF("close", 0, js_db_close),
    JS_CGETSET_DEF("open", js_db_get_open, NULL),
    JS_CGETSET_DEF("inTransaction", js_db_get_in_transaction, NULL),
    JS_CGETSET_DEF("name", js_db_get_name, NULL),
};

static const JSCFunctionListEntry stmt_proto[] = {
    JS_CFUNC_DEF("run", 0, js_stmt_run),
    JS_CFUNC_DEF("get", 0, js_stmt_get),
    JS_CFUNC_DEF("all", 0, js_stmt_all),
    JS_CFUNC_DEF("columns", 0, js_stmt_columns),
    JS_CFUNC_DEF("finalize", 0, js_stmt_finalize),
};

static JSClassDef db_def = {"Database", .finalizer = db_finalizer};
static JSClassDef stmt_def = {"Statement", .finalizer = stmt_finalizer, .gc_mark = stmt_mark};

static int sqlite_init(JSContext *ctx, JSModuleDef *m) {
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_NewClassID(rt, &db_class);
    JS_NewClassID(rt, &stmt_class);
    JS_NewClass(rt, db_class, &db_def);
    JS_NewClass(rt, stmt_class, &stmt_def);
    JSValue proto = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, proto, db_proto, countof(db_proto));
    JS_SetClassProto(ctx, db_class, proto);
    proto = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, proto, stmt_proto, countof(stmt_proto));
    JS_SetClassProto(ctx, stmt_class, proto);
    JSValue ctor = JS_NewCFunction2(ctx, js_db_ctor, "Database", 2, JS_CFUNC_constructor, 0);
    JSValue p = JS_GetClassProto(ctx, db_class);
    JS_SetConstructor(ctx, ctor, p);
    JS_FreeValue(ctx, p);
    JS_SetModuleExport(ctx, m, "Database", JS_DupValue(ctx, ctor));
    JS_SetModuleExport(ctx, m, "default", ctor);
    JS_SetModuleExport(ctx, m, "version", JS_NewString(ctx, sqlite3_libversion()));
    return 0;
}

JSModuleDef *zdos_init_module_sqlite(JSContext *ctx, const char *name) {
    JSModuleDef *m = JS_NewCModule(ctx, name, sqlite_init);
    if (m == NULL) return NULL;
    JS_AddModuleExport(ctx, m, "Database");
    JS_AddModuleExport(ctx, m, "default");
    JS_AddModuleExport(ctx, m, "version");
    return m;
}
