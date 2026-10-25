/* src/plugins/pool_shim.c — A3 插件子进程的 C 侧助手
 *
 * Uya 里直接写 fork/execve 需要构造 `char *const argv[]` 和小心处理 fd 继承；
 * 放到 C 里一共四个小函数，语义清楚、也避免 Uya 0.11 的 FFI 边界踩坑。
 *
 * 约定：
 *   * stdin/stdout 是两条管道（双向 JSONL）；stderr 继承（插件自己的日志进服务端日志）。
 *   * 子进程启动后父进程把两端设成 O_NONBLOCK 且 FD_CLOEXEC：读由 epoll/poll 驱动，
 *     不会因为插件不吐数据而卡住事件循环。
 *   * 只负责「生 / 收尸 / 杀 / 等」，不解析协议。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

/* 写已死插件的管道会触发 SIGPIPE；网关/测试进程不应因此退出。 */
void aigw_pool_ignore_sigpipe(void) {
    signal(SIGPIPE, SIG_IGN);
}

/* 返回 0 成功；-1 建管道失败；-2 fork 失败。错误原因留给 errno。 */
int aigw_pool_spawn(const char *cmd, int *pid_out, int *in_fd, int *out_fd) {
    int inp[2] = {-1, -1};
    int outp[2] = {-1, -1};
    if (pipe(inp) != 0) {
        return -1;
    }
    if (pipe(outp) != 0) {
        close(inp[0]);
        close(inp[1]);
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(inp[0]);
        close(inp[1]);
        close(outp[0]);
        close(outp[1]);
        return -2;
    }
    if (pid == 0) {
        /* 子进程：管道接到 stdin/stdout，其余 fd 关掉。 */
        if (dup2(inp[0], 0) < 0 || dup2(outp[1], 1) < 0) {
            _exit(126);
        }
        close(inp[0]);
        close(inp[1]);
        close(outp[0]);
        close(outp[1]);
        execl("/bin/sh", "sh", "-c", cmd, (char *)0);
        _exit(127);
    }
    close(inp[0]);
    close(outp[1]);
    int flags = fcntl(inp[1], F_GETFL, 0);
    fcntl(inp[1], F_SETFL, flags | O_NONBLOCK);
    flags = fcntl(outp[0], F_GETFL, 0);
    fcntl(outp[0], F_SETFL, flags | O_NONBLOCK);
    fcntl(inp[1], F_SETFD, FD_CLOEXEC);
    fcntl(outp[0], F_SETFD, FD_CLOEXEC);
    *pid_out = (int)pid;
    *in_fd = inp[1];
    *out_fd = outp[0];
    return 0;
}

/* WNOHANG 收尸：返回 >0 已退出（status 写入），0 还活着，<0 出错。 */
int aigw_pool_wait_nohang(int pid, int *status) {
    if (pid <= 0) {
        return -1;
    }
    return (int)waitpid((pid_t)pid, status, WNOHANG);
}

/* 非阻塞收尸（阻塞 waitpid）。cancel/shutdown 用，子进程已被 SIGKILL，不会久等。 */
int aigw_pool_wait(int pid, int *status) {
    if (pid <= 0) {
        return -1;
    }
    return (int)waitpid((pid_t)pid, status, 0);
}

int aigw_pool_kill(int pid, int sig) {
    if (pid <= 0) {
        return -1;
    }
    return kill((pid_t)pid, sig);
}

/* 等 fd 可读/可写；events 用 poll 的 POLLIN=1 / POLLOUT=4。返回 1 就绪，0 超时，<0 出错。 */
int aigw_pool_poll(int fd, int events, int timeout_ms) {
    struct pollfd p;
    p.fd = fd;
    p.events = (short)events;
    p.revents = 0;
    int rc = poll(&p, 1, timeout_ms);
    if (rc <= 0) {
        return rc;
    }
    if ((p.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0
        && (p.revents & (short)events) == 0) {
        return -1;
    }
    return 1;
}
