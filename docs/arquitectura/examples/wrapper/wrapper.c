// wrapper.c (referencia; v0)
//
// Objetivo: ejecutar un runner bajo PID namespace con un proceso "init" (PID 1) que:
// - Reapee zombies (SIGCHLD/waitpid(-1)).
// - Propague stop a toda la subtree: SIGTERM -> grace -> SIGKILL.
// - Trate EOF/stdin como orden de parada.
// - Permanezca silencioso en STDOUT (SAD espera JSONL del runner ahí).
//
// NOTA: Este fichero es un esquema de referencia para la arquitectura.
// Falta manejo de errores/uid_map/gid_map/robustez de parsing. No es un wrapper listo para producción.
//
#define _GNU_SOURCE
#include <sched.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
 
static int child_pid = -1;
static int stopping = 0;

static void sigchld_handler(int _) {
  int status;
  while (waitpid(-1, &status, WNOHANG) > 0) { /* reap */ }
}

static void setup_signals(void) {
  struct sigaction sa = {0};
  sa.sa_handler = sigchld_handler;
  sigaction(SIGCHLD, &sa, NULL);
  // Durante stop, ignorar SIGTERM en el wrapper para que kill(-1, SIGTERM) no lo mate antes de reapear.
  signal(SIGTERM, SIG_IGN);
}

static void write_json(const char* s) {
  // Importante: no escribir en STDOUT; SAD espera JSONL del runner en STDOUT.
  // El wrapper puede escribir diagnósticos en STDERR (fuera de contrato).
  write(STDERR_FILENO, s, strlen(s));
  write(STDERR_FILENO, "\n", 1);
}

static void kill_all(int sig) {
  // Dentro de un PID namespace, kill(-1, sig) envía a todos los procesos "matables" del namespace.
  kill(-1, sig);
}

static void do_stop_sequence(useconds_t grace_us) {
  if (stopping) return;
  stopping = 1;
  write_json("{\"t\":\"wrapper_ack_stop\"}");

  kill_all(SIGTERM);
  usleep(grace_us);

  // Segunda pasada: si algo sigue vivo, SIGKILL
  kill_all(SIGKILL);
  usleep(200 * 1000);

  // Reap final
  int status;
  while (waitpid(-1, &status, WNOHANG) > 0) {}

  write_json("{\"t\":\"wrapper_done\",\"result\":\"killed\"}");
  _exit(0);
}

static void apply_user_ns_mappings(void) {
  // En un wrapper real, escribe /proc/self/uid_map y gid_map.
  // Ejemplo: mapear UID/GID 0 -> UID/GID real (unshare requiere permisos).
  // Aquí se omite por brevedad.
}

static int ns_init_main(void* arg) {
  setvbuf(stdout, NULL, _IONBF, 0);
  prctl(PR_SET_PDEATHSIG, SIGKILL);
  setup_signals();

  char** argv = (char**)arg;

  // Mapea UID/GID dentro del user namespace (requerido para usar CLONE_NEWUSER sin root).
  apply_user_ns_mappings();

  pid_t pid = fork();
  if (pid == 0) {
    execvp(argv[0], argv);
    _exit(127);
  }
  child_pid = pid;

  write_json("{\"t\":\"wrapper_ready\"}");

  char buf[4096];
  useconds_t grace_us = 800 * 1000;  // ajustar vía env (p.ej. SAD_SHUTDOWN_MS)

  while (1) {
    int status;
    pid_t r = waitpid(child_pid, &status, WNOHANG);
    if (r == child_pid) {
      do_stop_sequence(grace_us);
    }

    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf) - 1);
    if (n == 0) {
      // EOF => BEAM/port cerrado
      do_stop_sequence(grace_us);
    }
    if (n < 0) {
      if (errno == EINTR) continue;
      do_stop_sequence(grace_us);
    }
    buf[n] = 0;

    if (strstr(buf, "\"t\":\"stop\"") != NULL) {
      do_stop_sequence(grace_us);
    }
  }
  return 0;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: wrapper <cmd> [args...]\n");
    return 2;
  }

  const int STACK_SZ = 1024 * 1024;
  void* stack = malloc(STACK_SZ);
  void* stack_top = (char*)stack + STACK_SZ;

  // Nuevo PID namespace + user namespace para rootless.
  int flags = CLONE_NEWPID | CLONE_NEWUSER | SIGCHLD;
  pid_t pid = clone(ns_init_main, stack_top, flags, &argv[1]);
  if (pid < 0) {
    perror("clone");
    return 1;
  }

  int st;
  waitpid(pid, &st, 0);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

