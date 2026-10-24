/* src/core/dbx_shim.c — SQLite 的最小 C 侧门面
 *
 * Uya 侧不想碰 `sqlite3 **` 这种二级指针和 `char** errmsg`：这里把它们收进一个不透明
 * `void *` 句柄，错误信息走 thread-local 的 `aigw_db_last_error()`。这样 Uya 里只需要
 * `&byte` 句柄 + i32 返回值，和项目其他模块的调用风格一致。
 *
 * 编译选项（见 dbx.uya 的 @c_import）：单线程、禁用扩展加载 —— 网关里每个连接自己拿
 * 一个句柄，SQLite 不需要自己的互斥锁。
 */
#include <stddef.h>
#include <string.h>

#include "../../third_party/sqlite/sqlite3.h"

static _Thread_local char aigw_db_err[512];

static void aigw_set_err(const char *msg) {
    if (msg == NULL) {
        msg = "unknown sqlite error";
    }
    strncpy(aigw_db_err, msg, sizeof(aigw_db_err) - 1);
    aigw_db_err[sizeof(aigw_db_err) - 1] = '\0';
}

unsigned char *aigw_db_last_error(void) {
    return (unsigned char *)aigw_db_err;
}

unsigned char *aigw_sqlite_version(void) {
    return (unsigned char *)sqlite3_libversion();
}

void *aigw_db_open(const char *path) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open(path, &db);
    if (rc != SQLITE_OK) {
        aigw_set_err(db != NULL ? sqlite3_errmsg(db) : "sqlite3_open failed");
        if (db != NULL) {
            sqlite3_close(db);
        }
        return NULL;
    }
    /* 单写者、多读者：WAL 让备份/读不挡写；busy_timeout 让并发写自动等一会。 */
    sqlite3_busy_timeout(db, 5000);
    sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA foreign_keys=ON", NULL, NULL, NULL);
    aigw_db_err[0] = '\0';
    return (void *)db;
}

void aigw_db_close(void *h) {
    if (h != NULL) {
        sqlite3_close((sqlite3 *)h);
    }
}

int aigw_db_exec(void *h, const char *sql) {
    char *err = NULL;
    int rc = sqlite3_exec((sqlite3 *)h, sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        aigw_set_err(err != NULL ? err : sqlite3_errmsg((sqlite3 *)h));
        if (err != NULL) {
            sqlite3_free(err);
        }
        return rc;
    }
    return 0;
}

/* 单值查询：把第一行第一列当 i64 取出来。0 = 成功且有行，1 = 无行，<0 = 出错。 */
int aigw_db_scalar_i64(void *h, const char *sql, long long *out) {
    sqlite3_stmt *st = NULL;
    int rc = sqlite3_prepare_v2((sqlite3 *)h, sql, -1, &st, NULL);
    if (rc != SQLITE_OK) {
        aigw_set_err(sqlite3_errmsg((sqlite3 *)h));
        return -1;
    }
    rc = sqlite3_step(st);
    if (rc == SQLITE_ROW) {
        if (out != NULL) {
            *out = sqlite3_column_int64(st, 0);
        }
        sqlite3_finalize(st);
        return 0;
    }
    if (rc == SQLITE_DONE) {
        sqlite3_finalize(st);
        return 1;
    }
    aigw_set_err(sqlite3_errmsg((sqlite3 *)h));
    sqlite3_finalize(st);
    return -1;
}

/* 受影响行数 / 最近插入 rowid 之类的无参查询小工具。 */
long long aigw_db_last_insert_rowid(void *h) {
    return (long long)sqlite3_last_insert_rowid((sqlite3 *)h);
}

int aigw_db_changes(void *h) {
    return sqlite3_changes((sqlite3 *)h);
}
