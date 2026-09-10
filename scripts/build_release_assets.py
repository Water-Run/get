"""Derive and independently verify public ZIPs from one attested flat ZIP."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
from datetime import datetime
import zipfile

def digest(data):
    return hashlib.sha256(data).hexdigest()

def checksums(data):
    return {line[66:]: line[:64] for line in data.decode().splitlines() if line}

def verify_architecture(data, platform):
    if platform == "linux-x64":
        assert data[:5] == b"\x7fELF\x02" and struct.unpack_from("<H", data, 18)[0] == 62
    elif platform == "windows-x64":
        assert data[:2] == b"MZ"
        offset = struct.unpack_from("<I", data, 60)[0]
        assert data[offset:offset + 4] == b"PE\0\0"
        assert struct.unpack_from("<H", data, offset + 4)[0] == 0x8664
    elif platform == "macos-arm64":
        assert data[:4] == b"\xcf\xfa\xed\xfe"
        assert struct.unpack_from("<I", data, 4)[0] == 0x100000C

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("flat_zip", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.flat_zip) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(set(archive.namelist()))
        assert all(Path(name).name == name for name in archive.namelist())
        flat = {name: archive.read(name) for name in archive.namelist()}
    info = json.loads(flat["BUILDINFO.json"])
    provider = json.loads(flat["PROVIDER_VALIDATION.json"])
    version = info["version"]
    timestamp = datetime.fromisoformat(info["commit_time"].replace("Z", "+00:00")).timetuple()[:6]
    assert info["version"] == version == provider["version"]
    assert info["provider_validation"] == provider
    assert provider["status"] == "passed"
    assert digest(flat["get-linux-x64"]) == provider["linux_payload_sha256"]
    declared = checksums(flat["SHA256SUMS"])
    assert set(declared) == set(flat) - {"SHA256SUMS"}
    assert all(digest(flat[name]) == checksum for name, checksum in declared.items())
    common = ["BUILDINFO.json", "PROVIDER_VALIDATION.json", "CODE_REVIEW-v3.md",
              "LICENSE", "README.md", "README-zh.md", "RELEASE_NOTES.md",
              "VALIDATION.md", "THIRD_PARTY_NOTICES.md",
              "get_ready.py", "get.1"]
    platforms = {
        "linux-x64": ["get-linux-x64"],
        "windows-x64": ["get-windows-x64.exe", "libcrypto-3.dll", "libssl-3.dll",
                        "zlib1.dll", "OPENSSL-LICENSE.txt", "ZLIB-LICENSE.txt"],
        "macos-arm64": ["get-macos-arm64"],
    }
    records = []
    for platform, specific in platforms.items():
        names = sorted(common + specific)
        payload = specific[0]
        verify_architecture(flat[payload], platform)
        content = {name: flat[name] for name in names}
        content["SHA256SUMS"] = "".join(f"{digest(content[name])}  {name}\n" for name in names).encode()
        stem = f"get-v{version}-{platform}"
        path = args.output / (stem + ".zip")
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, data in sorted(content.items()):
                entry = zipfile.ZipInfo(stem + "/" + name, timestamp)
                entry.create_system = 3
                entry.compress_type = zipfile.ZIP_DEFLATED
                mode = 0o755 if name in (payload, "get_ready.py") else 0o644
                entry.external_attr = (0o100000 | mode) << 16
                archive.writestr(entry, data)
        with tempfile.TemporaryDirectory(prefix="get-public-verify-") as temporary:
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None
                assert set(archive.namelist()) == {stem + "/" + name for name in content}
                archive.extractall(temporary)
            extracted = Path(temporary) / stem
            assert {p.name for p in extracted.iterdir()} == set(content)
            for name, checksum in checksums((extracted / "SHA256SUMS").read_bytes()).items():
                assert digest((extracted / name).read_bytes()) == checksum
                assert (extracted / name).read_bytes() == flat[name]
            verify_architecture((extracted / payload).read_bytes(), platform)
        records.append({"filename": path.name, "bytes": path.stat().st_size,
                        "sha256": digest(path.read_bytes()), "platform": platform,
                        "version": version, "commit": info["commit"], "root": stem,
                        "payload": payload, "payload_sha256": digest(flat[payload]),
                        "files": sorted(content), "verification": "file set, ZIP integrity, inner checksums, payload architecture and flat-package byte identity passed"})
    (args.output / f"SHA256SUMS-v{version}.txt").write_text(
        "".join(f"{row['sha256']}  {row['filename']}\n" for row in records))
    manifest = {"schema_version": 1, "version": version, "commit": info["commit"],
                "workflow_run": info["workflow_run"],
                "flat_package_sha256": digest(args.flat_zip.read_bytes()),
                "provider_validation": provider, "assets": records,
                "installation_validation": {"status": "pending"}}
    (args.output / f"get-v{version}-assets.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"platforms_verified": len(records), "files_verified": sum(len(row["files"]) for row in records), "assets": [{key: row[key] for key in ("filename", "bytes", "sha256")} for row in records]}, indent=2))

if __name__ == "__main__":
    main()
