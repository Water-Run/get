# Third-party notices

The Windows x86_64 release of `get` redistributes the following unmodified,
MSVCRT-linked runtime libraries from the Cygwin package repository. These
packages do not require the Cygwin runtime.

## OpenSSL 3.5.7 LTS

- Files: `libcrypto-3.dll` and `libssl-3.dll`
- Upstream: https://github.com/openssl/openssl
- License: Apache License 2.0
- Binary distributor: Cygwin
- Package: `mingw64-x86_64-openssl-3.5.7-1-noarch.tar.zst`
- Package source:
  https://cygwin.com/ftp/cygwin/noarch/release/mingw64-x86_64-openssl/mingw64-x86_64-openssl-3.5.7-1-noarch.tar.zst
- Package SHA-512:
  `267a9f43890533c0dd77f45d1435aacc9d1b5ae08b48ae6d192422a30e527a5e7c211e9bd30af9d5f29e8c3c5fdda93930cf7f65f75f48be6b0f19b3c1a21a58`
- `libcrypto-3.dll` SHA-256:
  `eb33c4ba433640f6c24569047e4f5b9bf0936d5e02b7ca42d2a17cd6f0ecf5a4`
- `libssl-3.dll` SHA-256:
  `24ac020e88070417a7c0b8f4f78bf35e786dfaf474a12c697aa1684ba8c51d63`

The complete license text is distributed as `OPENSSL-LICENSE.txt`.

## zlib 1.3.2

- File: `zlib1.dll`
- Upstream: https://github.com/madler/zlib
- License: zlib License
- Binary distributor: Cygwin
- Package: `mingw64-x86_64-zlib-1.3.2-1-noarch.tar.zst`
- Package source:
  https://cygwin.com/ftp/cygwin/noarch/release/mingw64-x86_64-zlib/mingw64-x86_64-zlib-1.3.2-1-noarch.tar.zst
- Package SHA-512:
  `a58cff59f69b63ec11e3a8de762c9829f61a2034c9d4df084706083bb98dea7adc8f62b011477fd127b9b44531aaec0dc118e7ae2cfb2805a6756e6788531d78`
- `zlib1.dll` SHA-256:
  `1b998ab51f16a8e3549c00c69d9ebad34d5dcf41d198e1d665df0ac2c8d737fd`

The complete license text is distributed as `ZLIB-LICENSE.txt`.

The pinned package hashes above come from the Cygwin x86_64 `setup.ini`
repository metadata. The release workflow additionally checks SHA-256 for
each archive and payload before packaging.
