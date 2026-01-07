#define _GNU_SOURCE
#include <errno.h>
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
  int status;
  (void)status;
  child_exited = 1;
  while (waitpid(-1, &status, WNOHANG) > 0) {
  }
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

static void stop_sequence(pid_t child_pid, int shutdown_ms, bool in_namespace) {
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

static int main_loop(pid_t child_pid, bool in_namespace) {
  char buf[4096];
  const int shutdown_ms = read_shutdown_ms();

  while (1) {
    if (child_exited) {
      int status = 0;
      pid_t waited = waitpid(child_pid, &status, WNOHANG);
      if (waited == child_pid) {
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
      }
      child_exited = 0;
    }

    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf) - 1);
    if (n == 0) {
      debug_log("wrapper stop: stdin EOF");
      stop_sequence(child_pid, shutdown_ms, in_namespace);
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      debug_log("wrapper stop: stdin error");
      stop_sequence(child_pid, shutdown_ms, in_namespace);
    }
    if (n > 0) {
      buf[n] = '\0';
      if (is_stop_message(buf)) {
        debug_log("wrapper stop: stop message");
        stop_sequence(child_pid, shutdown_ms, in_namespace);
      }
    }
  }
}

static int fallback_main(char **argv) {
  setup_signals();
  pid_t pid = fork();
  if (pid == 0) {
    setpgid(0, 0);
    return run_child(argv);
  }
  if (pid < 0) {
    perror("fork");
    return 1;
  }
  setpgid(pid, pid);
  return main_loop(pid, false);
}

#ifdef __linux__
static int ns_init_main(void *arg) {
  prctl(PR_SET_PDEATHSIG, SIGKILL);
  setup_signals();

  char **argv = (char **)arg;
  pid_t pid = fork();
  if (pid == 0) {
    return run_child(argv);
  }
  if (pid < 0) {
    perror("fork");
    return 1;
  }
  return main_loop(pid, true);
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

  int flags = CLONE_NEWPID | CLONE_NEWUSER | SIGCHLD;
  pid_t pid = clone(ns_init_main, stack_top, flags, child_argv);
  if (pid < 0) {
    debug_log("clone failed, falling back: %s", strerror(errno));
    free(stack);
    return fallback_main(child_argv);
  }

  int status = 0;
  waitpid(pid, &status, 0);
  free(stack);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
#else
  return fallback_main(child_argv);
#endif
}
