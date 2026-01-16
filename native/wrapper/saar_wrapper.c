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
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/landlock.h>
#include <poll.h>
#include <sched.h>
#include <sys/syscall.h>
#endif

#define LANDLOCK_UNAVAILABLE_EXIT_CODE 42

static volatile sig_atomic_t child_exited = 0;

static void sigchld_handler(int _) {
  (void)_;
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

static bool poll_for_input_or_child(int stdin_fd, int timeout_ms) {
  struct pollfd fds[1];
  fds[0].fd = stdin_fd;
  fds[0].events = POLLIN;

  while (1) {
    if (child_exited) {
      return true;
    }

    int rc = poll(fds, 1, timeout_ms);
    if (rc < 0) {
      if (errno == EINTR) {
        continue;
      }
      return true;
    }
    if (rc == 0) {
      continue;
    }

    if (fds[0].revents & POLLIN) {
      return true;
    }

    if (fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
      return true;
    }
  }
}

static int read_env_int(const char *name, int default_value) {
  const char *value = getenv(name);
  if (!value) {
    return default_value;
  }
  int parsed = atoi(value);
  if (parsed <= 0) {
    return default_value;
  }
  return parsed;
}

typedef enum {
  LANDLOCK_MODE_BEST_EFFORT,
  LANDLOCK_MODE_ENFORCED,
  LANDLOCK_MODE_OFF,
} LandlockMode;

static LandlockMode read_landlock_mode(void) {
  const char *value = getenv("SAAR_LANDLOCK_MODE");
  if (!value || strcmp(value, "best_effort") == 0) {
    return LANDLOCK_MODE_BEST_EFFORT;
  }
  if (strcmp(value, "enforced") == 0) {
    return LANDLOCK_MODE_ENFORCED;
  }
  if (strcmp(value, "off") == 0) {
    return LANDLOCK_MODE_OFF;
  }
  return LANDLOCK_MODE_BEST_EFFORT;
}

static int read_shutdown_ms(void) {
  return read_env_int("SAAR_SHUTDOWN_MS", 10000);
}

static int read_control_line_max_bytes(void) {
  return read_env_int("SAAR_WRAPPER_CONTROL_LINE_BYTES", 262144);
}

static bool is_json_ws(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static size_t skip_json_ws(const char *buf, size_t len, size_t pos) {
  while (pos < len && is_json_ws(buf[pos])) {
    pos++;
  }
  return pos;
}

static bool skip_json_string(const char *buf, size_t len, size_t *pos) {
  if (*pos >= len || buf[*pos] != '"') {
    return false;
  }
  (*pos)++;
  while (*pos < len) {
    char c = buf[*pos];
    if (c == '"') {
      (*pos)++;
      return true;
    }
    if (c == '\\') {
      (*pos)++;
      if (*pos >= len) {
        return false;
      }
      if (buf[*pos] == 'u') {
        if (*pos + 4 >= len) {
          return false;
        }
        *pos += 4;
      }
    }
    (*pos)++;
  }
  return false;
}

static int hex_value(char c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (c >= 'a' && c <= 'f') {
    return 10 + (c - 'a');
  }
  if (c >= 'A' && c <= 'F') {
    return 10 + (c - 'A');
  }
  return -1;
}

static bool parse_json_string(const char *buf,
                              size_t len,
                              size_t *pos,
                              char *out,
                              size_t out_cap,
                              size_t *out_len,
                              bool *truncated) {
  if (*pos >= len || buf[*pos] != '"') {
    return false;
  }
  (*pos)++;
  size_t out_i = 0;
  bool trunc = false;
  while (*pos < len) {
    char c = buf[*pos];
    if (c == '"') {
      (*pos)++;
      if (out_cap > 0) {
        out[out_i < out_cap ? out_i : out_cap - 1] = '\0';
      }
      if (out_len) {
        *out_len = out_i;
      }
      if (truncated) {
        *truncated = trunc;
      }
      return true;
    }
    if (c == '\\') {
      (*pos)++;
      if (*pos >= len) {
        return false;
      }
      char esc = buf[*pos];
      switch (esc) {
      case '"':
      case '\\':
      case '/':
        c = esc;
        break;
      case 'b':
        c = '\b';
        break;
      case 'f':
        c = '\f';
        break;
      case 'n':
        c = '\n';
        break;
      case 'r':
        c = '\r';
        break;
      case 't':
        c = '\t';
        break;
      case 'u': {
        if (*pos + 4 >= len) {
          return false;
        }
        int h1 = hex_value(buf[*pos + 1]);
        int h2 = hex_value(buf[*pos + 2]);
        int h3 = hex_value(buf[*pos + 3]);
        int h4 = hex_value(buf[*pos + 4]);
        if (h1 < 0 || h2 < 0 || h3 < 0 || h4 < 0) {
          return false;
        }
        int code = (h1 << 12) | (h2 << 8) | (h3 << 4) | h4;
        c = code <= 0x7f ? (char)code : '?';
        *pos += 4;
        break;
      }
      default:
        return false;
      }
    }
    if (!trunc && out_cap > 0) {
      if (out_i + 1 < out_cap) {
        out[out_i++] = c;
      } else {
        trunc = true;
      }
    }
    (*pos)++;
  }
  return false;
}

static bool skip_json_value(const char *buf, size_t len, size_t *pos);

static bool skip_json_container(const char *buf,
                                size_t len,
                                size_t *pos,
                                char open_char,
                                char close_char) {
  if (*pos >= len || buf[*pos] != open_char) {
    return false;
  }
  (*pos)++;
  while (*pos < len) {
    char c = buf[*pos];
    if (c == '"') {
      if (!skip_json_string(buf, len, pos)) {
        return false;
      }
      continue;
    }
    if (c == '{') {
      if (!skip_json_container(buf, len, pos, '{', '}')) {
        return false;
      }
      continue;
    }
    if (c == '[') {
      if (!skip_json_container(buf, len, pos, '[', ']')) {
        return false;
      }
      continue;
    }
    if (c == close_char) {
      (*pos)++;
      return true;
    }
    (*pos)++;
  }
  return false;
}

static bool is_json_value_delim(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == ',' || c == '}' ||
         c == ']';
}

static bool skip_json_value(const char *buf, size_t len, size_t *pos) {
  *pos = skip_json_ws(buf, len, *pos);
  if (*pos >= len) {
    return false;
  }
  char c = buf[*pos];
  if (c == '"') {
    return skip_json_string(buf, len, pos);
  }
  if (c == '{') {
    return skip_json_container(buf, len, pos, '{', '}');
  }
  if (c == '[') {
    return skip_json_container(buf, len, pos, '[', ']');
  }
  size_t start = *pos;
  while (*pos < len && !is_json_value_delim(buf[*pos])) {
    (*pos)++;
  }
  return *pos > start;
}

#ifdef __linux__
static int ll_create_ruleset(struct landlock_ruleset_attr *attr,
                             size_t size,
                             __u32 flags);
static int ll_add_rule(int ruleset_fd,
                       enum landlock_rule_type type,
                       const void *attr,
                       __u32 flags);
static int ll_restrict_self(int ruleset_fd, __u32 flags);

static bool json_consume_char(const char *buf, size_t len, size_t *pos, char c) {
  *pos = skip_json_ws(buf, len, *pos);
  if (*pos >= len || buf[*pos] != c) {
    return false;
  }
  (*pos)++;
  return true;
}

static int landlock_add_rule_for_path(int ruleset_fd,
                                     struct landlock_path_beneath_attr *path,
                                     const char *path_str,
                                     __u64 allowed_access) {
  int fd = open(path_str, O_PATH | O_CLOEXEC);
  if (fd < 0) {
    return 0;
  }
  path->allowed_access = allowed_access;
  path->parent_fd = fd;
  (void)ll_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, path, 0);
  close(fd);
  return 0;
}

static bool landlock_parse_string_path(const char *buf,
                                      size_t len,
                                      size_t *pos,
                                      char *out,
                                      size_t out_cap) {
  size_t out_len = 0;
  bool truncated = false;
  if (!parse_json_string(buf, len, pos, out, out_cap, &out_len, &truncated)) {
    return false;
  }
  return !truncated && out_len > 0;
}

static bool landlock_apply_json_string_array(const char *buf,
                                            size_t len,
                                            size_t *pos,
                                            int ruleset_fd,
                                            struct landlock_path_beneath_attr *path,
                                            __u64 allowed_access) {
  if (!json_consume_char(buf, len, pos, '[')) {
    return false;
  }

  while (1) {
    *pos = skip_json_ws(buf, len, *pos);
    if (*pos >= len) {
      return false;
    }
    if (buf[*pos] == ']') {
      (*pos)++;
      return true;
    }

    char path_buf[4096];
    if (!landlock_parse_string_path(buf, len, pos, path_buf, sizeof(path_buf))) {
      return false;
    }
    (void)landlock_add_rule_for_path(
        ruleset_fd, path, path_buf, allowed_access);

    *pos = skip_json_ws(buf, len, *pos);
    if (*pos >= len) {
      return false;
    }
    if (buf[*pos] == ',') {
      (*pos)++;
      continue;
    }
    if (buf[*pos] == ']') {
      (*pos)++;
      return true;
    }
    return false;
  }
}

static bool landlock_apply_policy_from_json(const char *json,
                                           size_t json_len,
                                           int ruleset_fd,
                                           struct landlock_path_beneath_attr *path) {
  size_t pos = skip_json_ws(json, json_len, 0);
  if (pos >= json_len || json[pos] != '{') {
    return false;
  }
  pos++;

  bool has_allow_read = false;
  bool has_allow_exec = false;
  bool has_allow_write = false;

  const __u64 access_r =
      LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
  const __u64 access_x = access_r | LANDLOCK_ACCESS_FS_EXECUTE;
  const __u64 access_w =
      access_r | LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR |
      LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR |
      LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG |
      LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO |
      LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM;

  while (1) {
    pos = skip_json_ws(json, json_len, pos);
    if (pos >= json_len) {
      return false;
    }
    if (json[pos] == '}') {
      pos++;
      break;
    }

    char key[32] = {0};
    size_t key_len = 0;
    bool key_truncated = false;
    if (!parse_json_string(json,
                           json_len,
                           &pos,
                           key,
                           sizeof(key),
                           &key_len,
                           &key_truncated)) {
      return false;
    }
    if (key_truncated || key_len == 0) {
      return false;
    }
    if (!json_consume_char(json, json_len, &pos, ':')) {
      return false;
    }

    if (strcmp(key, "allow_read") == 0) {
      if (!landlock_apply_json_string_array(
              json, json_len, &pos, ruleset_fd, path, access_r)) {
        return false;
      }
      has_allow_read = true;
    } else if (strcmp(key, "allow_exec") == 0) {
      if (!landlock_apply_json_string_array(
              json, json_len, &pos, ruleset_fd, path, access_x)) {
        return false;
      }
      has_allow_exec = true;
    } else if (strcmp(key, "allow_write") == 0) {
      if (!landlock_apply_json_string_array(
              json, json_len, &pos, ruleset_fd, path, access_w)) {
        return false;
      }
      has_allow_write = true;
    } else {
      if (!skip_json_value(json, json_len, &pos)) {
        return false;
      }
    }

    pos = skip_json_ws(json, json_len, pos);
    if (pos >= json_len) {
      return false;
    }
    if (json[pos] == ',') {
      pos++;
      continue;
    }
    if (json[pos] == '}') {
      pos++;
      break;
    }
    return false;
  }

  pos = skip_json_ws(json, json_len, pos);
  if (pos != json_len) {
    return false;
  }

  return has_allow_read && has_allow_exec && has_allow_write;
}
#endif

typedef enum {
  CONTROL_NONE,
  CONTROL_STOP,
  CONTROL_INPUT,
} ControlCommand;

typedef struct {
  ControlCommand command;
  const char *payload;
  size_t payload_len;
} ControlMessage;

static bool parse_control_line(const char *line,
                               size_t len,
                               ControlMessage *message) {
  message->command = CONTROL_NONE;
  message->payload = NULL;
  message->payload_len = 0;

  size_t pos = skip_json_ws(line, len, 0);
  if (pos >= len) {
    return true;
  }
  if (line[pos] != '{') {
    return false;
  }
  pos++;

  bool has_t = false;
  bool has_payload = false;
  char t_value[16] = {0};

  while (pos < len) {
    pos = skip_json_ws(line, len, pos);
    if (pos >= len) {
      return false;
    }
    if (line[pos] == '}') {
      pos++;
      break;
    }

    char key[16] = {0};
    size_t key_len = 0;
    bool key_truncated = false;
    if (!parse_json_string(
            line, len, &pos, key, sizeof(key), &key_len, &key_truncated)) {
      return false;
    }
    pos = skip_json_ws(line, len, pos);
    if (pos >= len || line[pos] != ':') {
      return false;
    }
    pos++;
    pos = skip_json_ws(line, len, pos);
    if (pos >= len) {
      return false;
    }

    if (!key_truncated && key_len == 1 && key[0] == 't') {
      size_t t_len = 0;
      bool t_truncated = false;
      if (!parse_json_string(
              line, len, &pos, t_value, sizeof(t_value), &t_len, &t_truncated)) {
        return false;
      }
      if (t_truncated) {
        return false;
      }
      has_t = true;
    } else if (!key_truncated && strcmp(key, "payload") == 0) {
      size_t value_start = pos;
      if (!skip_json_value(line, len, &pos)) {
        return false;
      }
      message->payload = line + value_start;
      message->payload_len = pos - value_start;
      has_payload = true;
    } else {
      if (!skip_json_value(line, len, &pos)) {
        return false;
      }
    }

    pos = skip_json_ws(line, len, pos);
    if (pos >= len) {
      return false;
    }
    if (line[pos] == ',') {
      pos++;
      continue;
    }
    if (line[pos] == '}') {
      pos++;
      break;
    }
    return false;
  }

  pos = skip_json_ws(line, len, pos);
  if (pos != len) {
    return false;
  }
  if (!has_t) {
    return false;
  }
  if (strcmp(t_value, "stop") == 0) {
    message->command = CONTROL_STOP;
    return true;
  }
  if (strcmp(t_value, "input") == 0) {
    if (!has_payload || message->payload_len == 0) {
      return false;
    }
    size_t payload_pos = skip_json_ws(message->payload, message->payload_len, 0);
    if (payload_pos >= message->payload_len ||
        message->payload[payload_pos] != '{') {
      return false;
    }
    message->payload += payload_pos;
    message->payload_len -= payload_pos;
    message->command = CONTROL_INPUT;
    return true;
  }
  return false;
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
  while (1) {
    ssize_t n = read(sync_fd, buf, sizeof(buf));
    if (n == 0) {
      break;
    }
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
  }
  close(sync_fd);
}

static bool wait_for_child_exit(pid_t child_pid, int timeout_ms, int poll_ms) {
  int waited = 0;
  int status = 0;
  while (waited < timeout_ms) {
    pid_t result = waitpid(child_pid, &status, WNOHANG);
    if (result == child_pid) {
      return true;
    }
    usleep((useconds_t)poll_ms * 1000);
    waited += poll_ms;
  }
  return false;
}

static void stop_sequence(pid_t child_pid, int shutdown_ms, bool in_namespace) {
  int poll_ms = read_env_int("SAAR_WRAPPER_POLL_MS", 50);
  int post_kill_wait_ms = read_env_int("SAAR_WRAPPER_POST_KILL_WAIT_MS", 200);
  if (wait_for_child_exit(child_pid, shutdown_ms, poll_ms)) {
    int status = 0;
    if (waitpid(child_pid, &status, WNOHANG) == child_pid) {
      _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
    }
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

  usleep((useconds_t)post_kill_wait_ms * 1000);

  int status;
  waitpid(child_pid, &status, 0);
  _exit(0);
}

static void handle_control_line(const char *line,
                                size_t len,
                                pid_t child_pid,
                                int *child_stdin_fd,
                                bool *input_sent,
                                int shutdown_ms,
                                bool in_namespace) {
  ControlMessage message;
  if (!parse_control_line(line, len, &message)) {
    debug_log("wrapper stop: invalid control line");
    close_child_stdin(child_stdin_fd);
    stop_sequence(child_pid, shutdown_ms, in_namespace);
  }
  if (message.command == CONTROL_STOP) {
    debug_log("wrapper stop: stop message");
    close_child_stdin(child_stdin_fd);
    stop_sequence(child_pid, shutdown_ms, in_namespace);
  }
  if (message.command == CONTROL_INPUT) {
    if (*input_sent) {
      debug_log("wrapper stop: duplicate input");
      close_child_stdin(child_stdin_fd);
      stop_sequence(child_pid, shutdown_ms, in_namespace);
    }
    if (*child_stdin_fd >= 0) {
      if (!write_all(*child_stdin_fd, message.payload, message.payload_len) ||
          !write_all(*child_stdin_fd, "\n", 1)) {
        debug_log("wrapper stdin forward failed");
      }
      close_child_stdin(child_stdin_fd);
    }
    *input_sent = true;
  }
}

#ifdef __linux__
static int ll_create_ruleset(struct landlock_ruleset_attr *attr,
                             size_t size,
                             __u32 flags) {
  return syscall(__NR_landlock_create_ruleset, attr, size, flags);
}

static int ll_add_rule(int ruleset_fd,
                       enum landlock_rule_type type,
                       const void *attr,
                       __u32 flags) {
  return syscall(__NR_landlock_add_rule, ruleset_fd, type, attr, flags);
}

static int ll_restrict_self(int ruleset_fd, __u32 flags) {
  return syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}

static bool ensure_directory_exists(const char *path) {
  if (!path || path[0] == '\0') {
    return false;
  }

  // Best-effort recursive mkdir without invoking a shell.
  char buf[4096];
  size_t len = strlen(path);
  if (len >= sizeof(buf)) {
    return false;
  }
  memcpy(buf, path, len + 1);

  // Walk segments, creating intermediate directories.
  for (size_t i = 1; i < len; i++) {
    if (buf[i] != '/') {
      continue;
    }
    buf[i] = '\0';
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) {
      buf[i] = '/';
      return false;
    }
    buf[i] = '/';
  }

  if (mkdir(buf, 0755) != 0 && errno != EEXIST) {
    return false;
  }

  return true;
}

static int try_apply_landlock_policy_v0(const char *workspace_dir,
                                       LandlockMode mode) {
  if (mode == LANDLOCK_MODE_OFF) {
    return 0;
  }

  const char *policy_json = getenv("SAAR_LANDLOCK_POLICY_JSON");

  if (!workspace_dir || workspace_dir[0] == '\0') {
    if (mode == LANDLOCK_MODE_ENFORCED) {
      debug_log("landlock: missing SAAR_WORKSPACE in enforced mode");
      fprintf(stderr, "LANDLOCK_UNAVAILABLE\n");
      return -1;
    }
    debug_log("landlock: missing SAAR_WORKSPACE, skipping");
    return 0;
  }

  // Ensure the workspace exists before we restrict filesystem access.
  (void)ensure_directory_exists(workspace_dir);

  // Landlock requires no_new_privs.
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    if (mode == LANDLOCK_MODE_ENFORCED) {
      debug_log("landlock: PR_SET_NO_NEW_PRIVS failed: %s", strerror(errno));
      fprintf(stderr, "LANDLOCK_UNAVAILABLE\n");
      return -1;
    }
    debug_log("landlock: PR_SET_NO_NEW_PRIVS failed, skipping: %s",
              strerror(errno));
    return 0;
  }

  struct landlock_ruleset_attr ruleset = {0};
  ruleset.handled_access_fs = LANDLOCK_ACCESS_FS_EXECUTE |
                              LANDLOCK_ACCESS_FS_READ_FILE |
                              LANDLOCK_ACCESS_FS_READ_DIR |
                              LANDLOCK_ACCESS_FS_WRITE_FILE |
                              LANDLOCK_ACCESS_FS_REMOVE_DIR |
                              LANDLOCK_ACCESS_FS_REMOVE_FILE |
                              LANDLOCK_ACCESS_FS_MAKE_CHAR |
                              LANDLOCK_ACCESS_FS_MAKE_DIR |
                              LANDLOCK_ACCESS_FS_MAKE_REG |
                              LANDLOCK_ACCESS_FS_MAKE_SOCK |
                              LANDLOCK_ACCESS_FS_MAKE_FIFO |
                              LANDLOCK_ACCESS_FS_MAKE_BLOCK |
                              LANDLOCK_ACCESS_FS_MAKE_SYM;

  int ruleset_fd = ll_create_ruleset(&ruleset, sizeof(ruleset), 0);
  if (ruleset_fd < 0) {
    if (errno == ENOSYS || errno == EOPNOTSUPP) {
      if (mode == LANDLOCK_MODE_ENFORCED) {
        debug_log("landlock: unavailable on this kernel");
        fprintf(stderr, "LANDLOCK_UNAVAILABLE\n");
        return -1;
      }
      debug_log("landlock: unavailable on this kernel, continuing");
      return 0;
    }

    if (mode == LANDLOCK_MODE_ENFORCED) {
      debug_log("landlock: create_ruleset failed: %s", strerror(errno));
      fprintf(stderr, "LANDLOCK_UNAVAILABLE\n");
      return -1;
    }
    debug_log("landlock: create_ruleset failed, skipping: %s", strerror(errno));
    return 0;
  }

  // Helpers to add a path rule.
  struct landlock_path_beneath_attr path = {0};

  if (policy_json && policy_json[0] != '\0') {
    size_t json_len = strlen(policy_json);
    if (!landlock_apply_policy_from_json(
            policy_json, json_len, ruleset_fd, &path)) {
      close(ruleset_fd);
      if (mode == LANDLOCK_MODE_ENFORCED) {
        debug_log("landlock: invalid SAAR_LANDLOCK_POLICY_JSON");
        fprintf(stderr, "LANDLOCK_UNAVAILABLE\n");
        return -1;
      }
      debug_log("landlock: invalid SAAR_LANDLOCK_POLICY_JSON, skipping");
      return 0;
    }
  } else {
    // Read-only paths.
    const char *allow_r[] = {
        "/etc",
        "/run/systemd/resolve/",
        "/proc/self",
        "/dev/random",
        "/dev/urandom",
        NULL,
    };

    // Read+exec paths.
    const char *allow_rx[] = {
        "/bin",
        "/lib",
        "/lib64",
        "/usr",
        "/home",
        NULL,
    };

    // Read+write+exec paths.
    const char *allow_rwx[] = {
        workspace_dir,
        "/tmp",
        "/var/tmp",
        "/dev/null",
        NULL,
    };

    // A minimal allowlist for v0. We allow access beneath each path.
    for (int i = 0; allow_r[i]; i++) {
      int fd = open(allow_r[i], O_PATH | O_CLOEXEC);
      if (fd < 0) {
        continue;
      }
      path.allowed_access = LANDLOCK_ACCESS_FS_READ_FILE |
                            LANDLOCK_ACCESS_FS_READ_DIR;
      path.parent_fd = fd;
      (void)ll_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &path, 0);
      close(fd);
    }

    for (int i = 0; allow_rx[i]; i++) {
      int fd = open(allow_rx[i], O_PATH | O_CLOEXEC);
      if (fd < 0) {
        continue;
      }
      path.allowed_access = LANDLOCK_ACCESS_FS_READ_FILE |
                            LANDLOCK_ACCESS_FS_READ_DIR |
                            LANDLOCK_ACCESS_FS_EXECUTE;
      path.parent_fd = fd;
      (void)ll_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &path, 0);
      close(fd);
    }

    for (int i = 0; allow_rwx[i]; i++) {
      int fd = open(allow_rwx[i], O_PATH | O_CLOEXEC);
      if (fd < 0) {
        continue;
      }
      path.allowed_access = LANDLOCK_ACCESS_FS_READ_FILE |
                            LANDLOCK_ACCESS_FS_READ_DIR |
                            LANDLOCK_ACCESS_FS_WRITE_FILE |
                            LANDLOCK_ACCESS_FS_REMOVE_DIR |
                            LANDLOCK_ACCESS_FS_REMOVE_FILE |
                            LANDLOCK_ACCESS_FS_MAKE_CHAR |
                            LANDLOCK_ACCESS_FS_MAKE_DIR |
                            LANDLOCK_ACCESS_FS_MAKE_REG |
                            LANDLOCK_ACCESS_FS_MAKE_SOCK |
                            LANDLOCK_ACCESS_FS_MAKE_FIFO |
                            LANDLOCK_ACCESS_FS_MAKE_BLOCK |
                            LANDLOCK_ACCESS_FS_MAKE_SYM;
      path.parent_fd = fd;
      (void)ll_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &path, 0);
      close(fd);
    }
  }

  if (ll_restrict_self(ruleset_fd, 0) != 0) {
    close(ruleset_fd);
    if (errno == ENOSYS || errno == EOPNOTSUPP) {
      if (mode == LANDLOCK_MODE_ENFORCED) {
        debug_log("landlock: restrict_self unavailable");
        fprintf(stderr, "LANDLOCK_UNAVAILABLE\n");
        return -1;
      }
      debug_log("landlock: restrict_self unavailable, continuing");
      return 0;
    }

    if (mode == LANDLOCK_MODE_ENFORCED) {
      debug_log("landlock: restrict_self failed: %s", strerror(errno));
      fprintf(stderr, "LANDLOCK_UNAVAILABLE\n");
      return -1;
    }
    debug_log("landlock: restrict_self failed, skipping: %s", strerror(errno));
    return 0;
  }

  close(ruleset_fd);
  debug_log("landlock: policy applied");
  return 0;
}
#endif

static int run_child(char **argv) {
#ifdef __linux__
  LandlockMode mode = read_landlock_mode();
  const char *workspace = getenv("SAAR_WORKSPACE");
  if (try_apply_landlock_policy_v0(workspace, mode) != 0) {
    _exit(LANDLOCK_UNAVAILABLE_EXIT_CODE);
  }
#endif

  execvp(argv[0], argv);
  _exit(127);
}

static int main_loop(pid_t child_pid, bool in_namespace, int child_stdin_fd) {
  int buffer_bytes = read_env_int("SAAR_WRAPPER_READ_BUFFER_BYTES", 4096);
  char *buf = malloc((size_t)buffer_bytes + 1);
  if (!buf) {
    perror("malloc");
    return 1;
  }
  const int shutdown_ms = read_shutdown_ms();
  const int control_line_max = read_control_line_max_bytes();
  char *line_buf = malloc((size_t)control_line_max + 1);
  if (!line_buf) {
    perror("malloc");
    free(buf);
    return 1;
  }
  size_t line_len = 0;
  bool input_sent = false;

  while (1) {
    if (child_exited) {
      int status = 0;
      pid_t waited = waitpid(child_pid, &status, WNOHANG);
      if (waited == child_pid) {
        close_child_stdin(&child_stdin_fd);
        free(buf);
        free(line_buf);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
      }
      child_exited = 0;
    }

    // Avoid blocking forever on stdin when the child exits.
    poll_for_input_or_child(STDIN_FILENO, 100);

    if (child_exited) {
      int status = 0;
      pid_t waited = waitpid(child_pid, &status, WNOHANG);
      if (waited == child_pid) {
        close_child_stdin(&child_stdin_fd);
        free(buf);
        free(line_buf);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
      }
      child_exited = 0;
      continue;
    }

    ssize_t n = read(STDIN_FILENO, buf, (size_t)buffer_bytes);
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
      for (ssize_t i = 0; i < n; i++) {
        char c = buf[i];
        if (c == '\n') {
          if (line_len == 0) {
            continue;
          }
          handle_control_line(line_buf,
                              line_len,
                              child_pid,
                              &child_stdin_fd,
                              &input_sent,
                              shutdown_ms,
                              in_namespace);
          line_len = 0;
          continue;
        }
        if (line_len == (size_t)control_line_max) {
          debug_log("wrapper stop: control line too long");
          close_child_stdin(&child_stdin_fd);
          stop_sequence(child_pid, shutdown_ms, in_namespace);
        }
        line_buf[line_len] = c;
        line_len++;
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
  int sync_fd_read;
  int sync_fd_write;
};

static int ns_init_main(void *arg) {
  prctl(PR_SET_PDEATHSIG, SIGKILL);
  setup_signals();

  struct NamespaceArgs *args = (struct NamespaceArgs *)arg;
  char **argv = args->argv;

  // Close our copy of the write end so EOF is observable.
  close(args->sync_fd_write);

  // The parent writes uid/gid maps and then closes the sync pipe.
  // Wait for that signal before spawning the child.
  wait_for_parent_ready(args->sync_fd_read);

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

  const char *force_fallback = getenv("SAAR_WRAPPER_FORCE_FALLBACK");
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
      .sync_fd_read = sync_pipe[0],
      .sync_fd_write = sync_pipe[1],
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
