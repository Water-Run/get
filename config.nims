switch("define", "ssl")

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