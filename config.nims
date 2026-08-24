#[
config.nims
https://github.com/Water-Run/get

update at: 2026-04-19
]#

switch("define", "ssl")
switch("threads", "on")

when defined(windows):
  # Nim 2.2 ARC/ORC can race when a process uses async HTTP before spawning
  # osproc workers. The short-lived CLI favors refc's isolated thread heaps
  # until the upstream Windows runtime path is safe under ORC.
  switch("mm", "refc")

when defined(release):
  switch("opt", "size")

when defined(staticBuild):
  # Override dynamic loading of OpenSSL so the linker
  # resolves symbols from static archives instead.
  switch("dynlibOverride", "ssl")
  switch("dynlibOverride", "crypto")
  switch("passL", "-static")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
