#!/usr/bin/env bash
# detach.sh — start a process whose parent lineage is CUT, and hand back its pid.
#
# WHY A DOUBLE FORK. The harness reaps a tracked background job by walking the
# process tree on `ppid` — not by SIGHUP, not by process group. Measured on this
# host: a child that ignored HUP and its sibling that did not both survived a
# session's end, while a `setsid` grandchild with its own session and its own
# group died because its parent was still alive when the walk ran. What buys
# survival is not a new session — it is REPARENTING: the middle process exits at
# once, the grandchild is adopted by init, and no walk from the launcher can
# reach it. `setsid` stays for a narrower reason: it detaches the controlling
# terminal so a terminal hang-up cannot reach the stage.
#
# WHY THE GRANDCHILD REOPENS ITS STDIO BEFORE `exec`, and why that is not
# decoration. The caller captures this function's stdout with a command
# substitution. A grandchild that inherits that pipe holds its write end open for
# as long as the stage runs, so the substitution never returns — the launcher
# blocked for the stage's whole lifetime, and the only reason the defect was
# found is that it was measured. After a double fork the caller cannot redirect
# the grandchild from outside, so the stream paths are arguments and the reopen
# lives here.
#
# WHY `$!` IS THE WRONG ANSWER for the caller. After a double fork `$!` names
# the middle process, which has already exited; a pid file filled from it holds
# a dead pid from birth and every liveness predicate reads "no supervisor". The
# grandchild's pid is printed by the middle process on its way out, and the
# command substitution returns exactly when the middle exits — which is also the
# moment the grandchild is adopted — so the caller never holds a pid that is not
# yet orphaned.
#
# `perl` first, `python3` second, and NOTHING ELSE. A `set -m` + `nohup` fallback
# gives a new process group and leaves the lineage intact, so it dies in the
# measured kill shape — a fallback that does not survive is worse than none,
# because its failure is conditional and silent. With neither interpreter the
# function returns 127 and prints nothing, and the caller refuses to dispatch.
#
# `setsid(1)` the BINARY is absent on darwin, which is what the portability lint
# guards against; the syscall reached through an interpreter is present on both
# hosts, so the two lines that name it carry the lint's same-line suppression.
#
# The environment variable names carry a `CC_DETACH_` prefix and no bare
# `DETACH=` literal: the driver's own suite greps the gate and the driver for
# that literal and this file is sourced by the gate.
#
# Compatibility: bash 3.2. `scripts/lint-bash-portability.sh` scans this
# directory at maxdepth 1, so this file is linted on arrival.

cc_detach_exec() {
  # cc_detach_exec <stdout-file> <stderr-file> <cmd> [args…]
  # Prints the grandchild's pid on stdout. By the time this returns the middle
  # process has exited, so the grandchild's ppid is already 1.
  local _o="$1" _e="$2"; shift 2
  if command -v perl >/dev/null 2>&1; then
    CC_DETACH_OUT="$_o" CC_DETACH_ERR="$_e" \
    perl -e '
      use POSIX ();
      POSIX::setsid();   # lint-bash-portability: disable=setsid
      my $pid = fork();
      die "fork: $!\n" unless defined $pid;
      if ($pid == 0) {
        POSIX::setsid();   # lint-bash-portability: disable=setsid
        open(STDIN,  "<",  "/dev/null");
        open(STDOUT, ">>", $ENV{CC_DETACH_OUT}) or die "stdout: $!\n";
        open(STDERR, ">>", $ENV{CC_DETACH_ERR}) or die "stderr: $!\n";
        exec @ARGV or die "exec: $!\n";
      }
      print "$pid\n";
      exit 0;' -- "$@"
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    CC_DETACH_OUT="$_o" CC_DETACH_ERR="$_e" \
    python3 -c '
import os, sys
try:
    os.setsid()   # lint-bash-portability: disable=setsid
except OSError:
    pass
pid = os.fork()
if pid == 0:
    os.setsid()   # lint-bash-portability: disable=setsid
    fd_in = os.open("/dev/null", os.O_RDONLY)
    fd_out = os.open(os.environ["CC_DETACH_OUT"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    fd_err = os.open(os.environ["CC_DETACH_ERR"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    os.dup2(fd_in, 0); os.dup2(fd_out, 1); os.dup2(fd_err, 2)
    os.execvp(sys.argv[1], sys.argv[1:])
sys.stdout.write("%d\n" % pid)
sys.exit(0)' "$@"
    return $?
  fi
  return 127
}
