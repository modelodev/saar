#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sched.h>
#endif

static volatile sig_atomic_t child_exited = 0;

static void sigchld_handler(int _) {
  child_exited = 1;
}

static bool debug_enabled(void) {
  const char *value = getenv("DEBUG");
  return value != NULL && strcmp(value, "1") == 0;
}

static void debug_log(const char *fmt, ...) {
  if (!debug_enabled()) {
    return;
  }
  va_list args;
  va_start(args, fmt);
  vfprintf(stderr, fmt, args);
  fprintf(stderr, "\n");
  va_end(args);
}

static void setup_signals(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = sigchld_handler;
  sigaction(SIGCHLD, &sa, NULL);
  signal(SIGTERM, SIG_IGN);
}

static int read_shutdown_ms(void) {
  const char *value = getenv("SAD_SHUTDOWN_MS");
  if (!value) {
    return 10000;
  }
  int ms = atoi(value);
  if (ms <= 0) {
    return 10000;
  }
  return ms;
}

static bool is_stop_message(const char *buf) {
  return strstr(buf, "\"t\":\"stop\"") != NULL;
}

static void kill_process_group(pid_t child_pid, int sig) {
  if (child_pid <= 0) {
    return;
  }
  kill(-child_pid, sig);
}

static void kill_namespace_all(int sig) {
#ifdef __linux__
  kill(-1, sig);
#else
  (void)sig;
#endif
}

static bool write_all(int fd, const char *buf, size_t len) {
  size_t written = 0;
  while (written < len) {
    ssize_t n = write(fd, buf + written, len - written);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    written += (size_t)n;
  }
  return true;
}

static void close_child_stdin(int *child_stdin_fd) {
  if (*child_stdin_fd >= 0) {
    close(*child_stdin_fd);
    *child_stdin_fd = -1;
  }
}

static bool write_file(const char *path, const char *value, bool allow_missing) {
  int fd = open(path, O_WRONLY);
  if (fd < 0) {
    if (allow_missing && errno == ENOENT) {
      return true;
    }
    return false;
  }

  size_t len = strlen(value);
  ssize_t written = write(fd, value, len);
  close(fd);
  return written == (ssize_t)len;
}

static bool apply_user_ns_mappings(pid_t pid) {
  char path[64];
  char map[64];
  uid_t uid = getuid();
  gid_t gid = getgid();

  snprintf(path, sizeof(path), "/proc/%d/setgroups", pid);
  if (!write_file(path, "deny\n", true)) {
    return false;
  }

  snprintf(path, sizeof(path), "/proc/%d/uid_map", pid);
  snprintf(map, sizeof(map), "0 %d 1\n", uid);
  if (!write_file(path, map, false)) {
    return false;
  }

  snprintf(path, sizeof(path), "/proc/%d/gid_map", pid);
  snprintf(map, sizeof(map), "0 %d 1\n", gid);
  if (!write_file(path, map, false)) {
    return false;
  }

  return true;
}

static void wait_for_parent_ready(int sync_fd) {
  char buf[1];
  while (read(sync_fd, buf, sizeof(buf)) > 0) {
  }
  close(sync_fd);
}

static bool wait_for_child_exit(pid_t child_pid, int timeout_ms) {
  int waited = 0;
  int status = 0;
  while (waited < timeout_ms) {
    pid_t result = waitpid(child_pid, &status, WNOHANG);
    if (result == child_pid) {
      return true;
    }
    usleep(50 * 1000);
    waited += 50;
  }
  return false;
}

static void stop_sequence(pid_t child_pid, int shutdown_ms, bool in_namespace) {
  if (wait_for_child_exit(child_pid, shutdown_ms)) {
    _exit(0);
  }
  if (in_namespace) {
    debug_log("wrapper stop: namespace kill SIGTERM");
    kill_namespace_all(SIGTERM);
  } else {
    debug_log("wrapper stop: pg kill SIGTERM");
    kill_process_group(child_pid, SIGTERM);
  }

  usleep((useconds_t)shutdown_ms * 1000);

  if (in_namespace) {
    debug_log("wrapper stop: namespace kill SIGKILL");
    kill_namespace_all(SIGKILL);
  } else {
    debug_log("wrapper stop: pg kill SIGKILL");
    kill_process_group(child_pid, SIGKILL);
  }

  usleep(200 * 1000);

  int status;
  waitpid(child_pid, &status, 0);
  _exit(0);
}

static int run_child(char **argv) {
  execvp(argv[0], argv);
  _exit(127);
}

static int main_loop(pid_t child_pid, bool in_namespace, int child_stdin_fd) {
  char buf[4096];
  const int shutdown_ms = read_shutdown_ms();

  while (1) {
    if (child_exited) {
      int status = 0;
      pid_t waited = waitpid(child_pid, &status, WNOHANG);
      if (waited == child_pid) {
        close_child_stdin(&child_stdin_fd);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
      }
      child_exited = 0;
    }

    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf) - 1);
    if (n == 0) {
      debug_log("wrapper stop: stdin EOF");
      close_child_stdin(&child_stdin_fd);
      stop_sequence(child_pid, shutdown_ms, in_namespace);
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      debug_log("wrapper stop: stdin error");
      close_child_stdin(&child_stdin_fd);
      stop_sequence(child_pid, shutdown_ms, in_namespace);
    }
    if (n > 0) {
      buf[n] = '\0';
      if (is_stop_message(buf)) {
        debug_log("wrapper stop: stop message");
        close_child_stdin(&child_stdin_fd);
        stop_sequence(child_pid, shutdown_ms, in_namespace);
      }
      if (child_stdin_fd >= 0) {
        if (!write_all(child_stdin_fd, buf, (size_t)n)) {
          debug_log("wrapper stdin forward failed");
        }
      }
    }
  }
}

static int spawn_and_run(char **argv, bool in_namespace, bool set_process_group) {
  int stdin_pipe[2];
  if (pipe(stdin_pipe) != 0) {
    perror("pipe");
    return 1;
  }
  pid_t pid = fork();
  if (pid == 0) {
    close(stdin_pipe[1]);
    if (dup2(stdin_pipe[0], STDIN_FILENO) < 0) {
      perror("dup2");
      _exit(127);
    }
    close(stdin_pipe[0]);
    if (set_process_group) {
      setpgid(0, 0);
    }
    return run_child(argv);
  }
  if (pid < 0) {
    perror("fork");
    close(stdin_pipe[0]);
    close(stdin_pipe[1]);
    return 1;
  }
  close(stdin_pipe[0]);
  if (set_process_group) {
    setpgid(pid, pid);
  }
  return main_loop(pid, in_namespace, stdin_pipe[1]);
}

static int fallback_main(char **argv) {
  setup_signals();
  return spawn_and_run(argv, false, true);
}

#ifdef __linux__
struct NamespaceArgs {
  char **argv;
  int sync_fd;
};

static int ns_init_main(void *arg) {
  prctl(PR_SET_PDEATHSIG, SIGKILL);
  setup_signals();

  struct NamespaceArgs *args = (struct NamespaceArgs *)arg;
  char **argv = args->argv;
  wait_for_parent_ready(args->sync_fd);

  return spawn_and_run(argv, true, false);
}
#endif

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);

  if (argc < 2) {
    fprintf(stderr, "usage: sad_wrapper <cmd> [args...]\n");
    return 2;
  }

  int arg_start = 1;
  if (strcmp(argv[1], "--") == 0) {
    arg_start = 2;
  }
  if (arg_start >= argc) {
    fprintf(stderr, "usage: sad_wrapper <cmd> [args...]\n");
    return 2;
  }

  char **child_argv = &argv[arg_start];

  const char *force_fallback = getenv("SAD_WRAPPER_FORCE_FALLBACK");
  if (force_fallback && strcmp(force_fallback, "1") == 0) {
    debug_log("wrapper fallback forced");
    return fallback_main(child_argv);
  }

#ifdef __linux__
  const int stack_size = 1024 * 1024;
  void *stack = malloc((size_t)stack_size);
  if (!stack) {
    perror("malloc");
    return fallback_main(child_argv);
  }
  void *stack_top = (char *)stack + stack_size;

  int sync_pipe[2];
  if (pipe(sync_pipe) != 0) {
    perror("pipe");
    free(stack);
    return fallback_main(child_argv);
  }

  struct NamespaceArgs args = {
      .argv = child_argv,
      .sync_fd = sync_pipe[0],
  };

  int flags = CLONE_NEWPID | CLONE_NEWUSER | SIGCHLD;
  pid_t pid = clone(ns_init_main, stack_top, flags, &args);
  if (pid < 0) {
    debug_log("clone failed, falling back: %s", strerror(errno));
    close(sync_pipe[0]);
    close(sync_pipe[1]);
    free(stack);
    return fallback_main(child_argv);
  }

  close(sync_pipe[0]);

  if (!apply_user_ns_mappings(pid)) {
    debug_log("user namespace mapping failed, falling back");
    kill(pid, SIGKILL);
    close(sync_pipe[1]);
    waitpid(pid, NULL, 0);
    free(stack);
    return fallback_main(child_argv);
  }

  close(sync_pipe[1]);

  int status = 0;
  waitpid(pid, &status, 0);
  free(stack);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
#else
  return fallback_main(child_argv);
#endif
}
