## Short, crash-released cross-process locks for configuration and logs.
## Sidecar files stay in place: unlinking a lock could create two lock domains.

import std/[monotimes, os, times]
import utils

when defined(windows):
  import std/[widestrs, winlean]

  const
    LOCKFILE_FAIL_IMMEDIATELY = 1
    LOCKFILE_EXCLUSIVE_LOCK = 2

  proc lockFileEx(handle: Handle, flags, reserved, low, high: DWORD,
                 overlapped: POVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "LockFileEx".}
  proc unlockFileEx(handle: Handle, reserved, low, high: DWORD,
                   overlapped: POVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "UnlockFileEx".}
elif defined(posix):
  import std/posix

  proc flock(fd: cint, operation: cint): cint {.importc, header: "<sys/file.h>".}
  var
    lockExclusive {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
    lockNonblocking {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint
    openNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    openCloseOnExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
else:
  {.error: "State locks require Windows or POSIX file locking".}

type
  FileLockError* = object of GetError
  FileLock* = object
    when defined(windows):
      handle: Handle
    else:
      fd: cint

const FILE_LOCK_WAIT_MS* = 5_000

proc acquireFileLock*(path: string, timeoutMs = FILE_LOCK_WAIT_MS): FileLock =
  ## Acquire an exclusive, non-inheritable lock with a monotonic deadline.
  let started = getMonoTime()
  var acquired = false
  when defined(windows):
    let handle = createFileW(newWideCString(path), GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0)
    if handle == INVALID_HANDLE_VALUE:
      raise newException(FileLockError, "cannot open state lock: " & osErrorMsg(osLastError()))
    defer:
      if not acquired: discard closeHandle(handle)
  else:
    let fd = posix.open(path.cstring,
      O_RDWR or O_CREAT or O_NONBLOCK or openNoFollow or openCloseOnExec, Mode(0o600))
    if fd < 0:
      raise newException(FileLockError, "cannot open state lock: " & osErrorMsg(osLastError()))
    defer:
      if not acquired: discard posix.close(fd)
    var info: Stat
    if fstat(fd, info) != 0 or not S_ISREG(info.st_mode) or fchmod(fd, Mode(0o600)) != 0:
      raise newException(FileLockError, "state lock must be a private regular file")

  while true:
    when defined(windows):
      var overlapped: OVERLAPPED
      # Fail immediately on contention; retry only within the common deadline.
      if lockFileEx(handle, LOCKFILE_FAIL_IMMEDIATELY or LOCKFILE_EXCLUSIVE_LOCK,
                    0, 1, 0, addr overlapped) != 0:
        acquired = true
        return FileLock(handle: handle)
      if getLastError() != ERROR_LOCK_VIOLATION:
        raise newException(FileLockError, "cannot acquire state lock: " & osErrorMsg(osLastError()))
    else:
      if flock(fd, lockExclusive or lockNonblocking) == 0:
        acquired = true
        return FileLock(fd: fd)
      if errno notin [EAGAIN, EWOULDBLOCK, EINTR]:
        raise newException(FileLockError, "cannot acquire state lock: " & osErrorMsg(osLastError()))
    if (getMonoTime() - started).inMilliseconds >= timeoutMs:
      raise newException(FileLockError, "configuration or log is busy; retry the operation")
    sleep(10)

proc releaseFileLock*(lock: FileLock) =
  ## Release exactly once, normally from a defer/finally clause.
  when defined(windows):
    var overlapped: OVERLAPPED
    discard unlockFileEx(lock.handle, 0, 1, 0, addr overlapped)
    discard closeHandle(lock.handle)
  else:
    discard posix.close(lock.fd)
