/* src/core/journal.c — 计费 journal 的 C 侧助手（只需要 fsync）
 *
 * Uya 的 libc.syscall 没有导出 fsync；journal 的 RPO 依赖「写完即落盘」，
 * 所以用一个 3 行的 C 包装，而不是在 Uya 里绕 sys_sync（整机 sync 太重）。
 */
#include <unistd.h>

int aigw_journal_fsync(int fd) {
    return fsync(fd);
}
