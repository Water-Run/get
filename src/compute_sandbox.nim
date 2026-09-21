## Isolated computation is distinct from host inspection. No fallback may run
## this payload in an ordinary host shell when namespace/seccomp setup fails.
import std/os

const COMPUTE_WORKER_FLAG* = "--internal-isolated-compute"

when defined(linux):
  {.emit: """
  #include <errno.h>
  #include <limits.h>
  #include <stddef.h>
  #include <stdint.h>
  #include <stdio.h>
  #include <sys/prctl.h>
  #include <sys/resource.h>
  #include <sys/syscall.h>
  #include <unistd.h>
  #include <linux/audit.h>
  #include <linux/filter.h>
  #include <linux/seccomp.h>
  #include <linux/sched.h>

  #if defined(__x86_64__)
  #define GET_AUDIT_ARCH AUDIT_ARCH_X86_64
  #elif defined(__aarch64__)
  #define GET_AUDIT_ARCH AUDIT_ARCH_AARCH64
  #else
  #define GET_AUDIT_ARCH 0
  #endif
  #define GET_DENY(n) BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_##n, 0, 1), \
                     BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|EPERM)

  static int get_compute_restrict(void) {
    /* Only the dedicated PID namespace entrypoint can enable this worker. */
    if (getpid() != 1 || geteuid() != 65534 || !GET_AUDIT_ARCH) return -1;
    FILE *mapping = fopen("/proc/self/uid_map", "r");
    unsigned long inside, outside, length;
    if (!mapping) return -1;
    int valid = fscanf(mapping, "%lu %lu %lu", &inside, &outside, &length) == 3
                && inside == 65534 && length == 1;
    fclose(mapping);
    if (!valid) return -1;
    /* Bounds compose: at most eight processes, each with 128 MiB address
       space. A fork tree cannot turn a per-process cap into unbounded RAM. */
    struct rlimit memory = {128ULL * 1024 * 1024, 128ULL * 1024 * 1024};
    struct rlimit processes = {8, 8};
    struct rlimit files = {128, 128};
    struct rlimit size = {64ULL * 1024 * 1024, 64ULL * 1024 * 1024};
    struct rlimit cpu = {30, 30};
    struct rlimit core = {0, 0};
    if (setrlimit(RLIMIT_AS, &memory) || setrlimit(RLIMIT_NPROC, &processes) ||
        setrlimit(RLIMIT_NOFILE, &files) || setrlimit(RLIMIT_FSIZE, &size) ||
        setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_CORE, &core)) return -1;
    /* No provider socket or other parent descriptor enters general code. */
    if (syscall(__NR_close_range, 3U, UINT_MAX, 0U) < 0) return -1;
    struct sock_filter filter[] = {
      BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch)),
      BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, GET_AUDIT_ARCH, 1, 0),
      BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_KILL_PROCESS),
      BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),
      /* Reject x32/alternate ABI syscall-number bypasses. */
      BPF_JUMP(BPF_JMP|BPF_JGE|BPF_K, 0x40000000U, 0, 1),
      BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_KILL_PROCESS),
      /* Child user namespaces must not reset process accounting. Ordinary
         fork/thread creation remains available under the shared hard cap. */
      BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_clone, 0, 4),
      BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, args[0])),
      BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, CLONE_NEWUSER|CLONE_NEWPID|CLONE_NEWNET|
        CLONE_NEWNS|CLONE_NEWUTS|CLONE_NEWIPC|CLONE_NEWCGROUP, 0, 1),
      BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|EPERM),
      BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),
      BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_clone3, 0, 1),
      BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|ENOSYS),
      GET_DENY(socket), GET_DENY(connect), GET_DENY(bind), GET_DENY(listen),
      GET_DENY(sendto), GET_DENY(sendmsg), GET_DENY(recvmsg),
      GET_DENY(ptrace), GET_DENY(process_vm_writev), GET_DENY(process_vm_readv),
      GET_DENY(setns), GET_DENY(unshare), GET_DENY(mount), GET_DENY(umount2),
      GET_DENY(pivot_root), GET_DENY(chroot), GET_DENY(bpf),
      GET_DENY(open_by_handle_at), GET_DENY(pidfd_getfd),
      GET_DENY(io_uring_setup), GET_DENY(ioctl), GET_DENY(reboot),
      GET_DENY(keyctl), GET_DENY(add_key), GET_DENY(request_key),
      BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW)
    };
    struct sock_fprog program = {sizeof(filter)/sizeof(filter[0]), filter};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program);
  }
  """.}
  proc restrictCompute(): cint {.importc: "get_compute_restrict", nodecl.}
  proc execProgram(path: cstring, argv: cstringArray): cint {.
    importc: "execv", header: "<unistd.h>".}

proc dispatchComputeWorker*() =
  ## Called before configuration, networking, or query handling in entrypoints.
  if paramCount() == 0 or paramStr(1) != COMPUTE_WORKER_FLAG: return
  when defined(linux):
    if paramCount() < 2 or restrictCompute() != 0:
      stderr.writeLine("isolated computation setup failed")
      quit(125)
    let executable = paramStr(2)
    var args = @[executable]
    for index in 3 .. paramCount(): args.add(paramStr(index))
    let argv = allocCStringArray(args)
    discard execProgram(executable.cstring, argv)
    deallocCStringArray(argv)
    stderr.writeLine("isolated executable could not start")
    quit(127)
  else:
    stderr.writeLine("isolated computation is unavailable on this platform")
    quit(125)

proc computeSandboxArguments*(worker, executable: string, arguments: seq[string],
    directory, scratch: string): seq[string] =
  ## Fixed mounts and namespace options cannot be supplied by the model.
  result = @[
    "--die-with-parent", "--new-session", "--unshare-user", "--uid", "65534",
    "--gid", "65534", "--unshare-pid", "--as-pid-1", "--unshare-net",
    "--unshare-ipc", "--unshare-uts", "--cap-drop", "ALL",
    "--ro-bind", "/", "/", "--proc", "/proc", "--remount-ro", "/proc",
    "--dev", "/dev", "--size", "67108864", "--perms", "0700", "--tmpfs", scratch,
    "--size", "8388608", "--tmpfs", "/dev/shm",
    "--setenv", "TMPDIR", scratch, "--setenv", "TMP", scratch,
    "--setenv", "TEMP", scratch, "--chdir", directory,
    "--", worker, COMPUTE_WORKER_FLAG, executable
  ] & arguments

proc computeRunnerPath*(): string =
  when defined(linux) and (defined(amd64) or defined(arm64)):
    for candidate in ["/usr/bin/bwrap", "/bin/bwrap"]:
      if fileExists(candidate): return candidate
  result = ""
