[CmdletBinding()]
param(
    [Parameter()]
    [string] $Destination = ".ci"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CygwinBaseUrl = "https://cygwin.com/ftp/cygwin"
$OpenSslPackage = (
    "noarch/release/mingw64-x86_64-openssl/" +
    "mingw64-x86_64-openssl-3.5.7-1-noarch.tar.zst"
)
$OpenSslPackageSha256 = "3ba6bf73a3c16221760d771949a0b5985e74845c80143114b35794d854d34e8c"
$OpenSslPackageSha512 = (
    "267a9f43890533c0dd77f45d1435aacc9d1b5ae08b48ae6d192422a30e527a5" +
    "e7c211e9bd30af9d5f29e8c3c5fdda93930cf7f65f75f48be6b0f19b3c1a21a58"
)
$ZlibPackage = (
    "noarch/release/mingw64-x86_64-zlib/" +
    "mingw64-x86_64-zlib-1.3.2-1-noarch.tar.zst"
)
$ZlibPackageSha256 = "63a0ccc332653abb9033e6e4cb1072fae6d2076a931ea6a8d4d70196d2e52e63"
$ZlibPackageSha512 = (
    "a58cff59f69b63ec11e3a8de762c9829f61a2034c9d4df084706083bb98dea7a" +
    "dc8f62b011477fd127b9b44531aaec0dc118e7ae2cfb2805a6756e6788531d78"
)
$RuntimeFiles = [ordered]@{
    "libcrypto-3.dll" = "eb33c4ba433640f6c24569047e4f5b9bf0936d5e02b7ca42d2a17cd6f0ecf5a4"
    "libssl-3.dll" = "24ac020e88070417a7c0b8f4f78bf35e786dfaf474a12c697aa1684ba8c51d63"
    "zlib1.dll" = "1b998ab51f16a8e3549c00c69d9ebad34d5dcf41d198e1d665df0ac2c8d737fd"
}
$OpenSslLicenseSha256 = "7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a"
$ZlibLicenseSha256 = "e32ff4e00d9d94930537635291da39e7e612703334bf6fde8c7f1686fe8a45a2"

function Assert-FileHash {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [ValidateSet("SHA256", "SHA512")]
        [string] $Algorithm,
        [Parameter(Mandatory)]
        [string] $Expected
    )

    $Actual = (
        Get-FileHash -LiteralPath $Path -Algorithm $Algorithm
    ).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) {
        throw "$Algorithm mismatch for $Path`: expected $Expected, got $Actual"
    }
}

function Get-VerifiedPackage {
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath,
        [Parameter(Mandatory)]
        [string] $Sha256,
        [Parameter(Mandatory)]
        [string] $Sha512,
        [Parameter(Mandatory)]
        [string] $TemporaryPath
    )

    $PackagePath = Join-Path $TemporaryPath (
        [System.IO.Path]::GetFileName($RelativePath)
    )
    $PackageUrl = "$CygwinBaseUrl/$RelativePath"
    & curl.exe --fail --location --retry 4 --retry-all-errors `
        --output $PackagePath $PackageUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Could not download pinned runtime package: $PackageUrl"
    }
    Assert-FileHash -Path $PackagePath -Algorithm SHA256 -Expected $Sha256
    Assert-FileHash -Path $PackagePath -Algorithm SHA512 -Expected $Sha512
    return $PackagePath
}

function Copy-VerifiedRuntime {
    param(
        [Parameter(Mandatory)]
        [string] $Source,
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Expected,
        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    Assert-FileHash -Path $Source -Algorithm SHA256 -Expected $Expected
    Copy-Item -LiteralPath $Source -Destination (
        Join-Path $DestinationPath $Name
    ) -Force
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$DestinationPath = (Resolve-Path -LiteralPath $Destination).Path
$TemporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) (
    "get-windows-runtime-" + [System.Guid]::NewGuid().ToString("N")
)
New-Item -ItemType Directory -Path $TemporaryPath | Out-Null

try {
    $OpenSslArchive = Get-VerifiedPackage `
        -RelativePath $OpenSslPackage `
        -Sha256 $OpenSslPackageSha256 `
        -Sha512 $OpenSslPackageSha512 `
        -TemporaryPath $TemporaryPath
    $ZlibArchive = Get-VerifiedPackage `
        -RelativePath $ZlibPackage `
        -Sha256 $ZlibPackageSha256 `
        -Sha512 $ZlibPackageSha512 `
        -TemporaryPath $TemporaryPath

    & tar.exe -xf $OpenSslArchive -C $TemporaryPath `
        "usr/x86_64-w64-mingw32/sys-root/mingw/bin/libcrypto-3.dll" `
        "usr/x86_64-w64-mingw32/sys-root/mingw/bin/libssl-3.dll" `
        "usr/share/doc/mingw64-x86_64-openssl/LICENSE.txt"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not extract pinned OpenSSL package"
    }
    & tar.exe -xf $ZlibArchive -C $TemporaryPath `
        "usr/x86_64-w64-mingw32/sys-root/mingw/bin/zlib1.dll" `
        "usr/share/doc/mingw64-x86_64-zlib/LICENSE"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not extract pinned zlib package"
    }

    $RuntimeRoot = Join-Path $TemporaryPath (
        "usr/x86_64-w64-mingw32/sys-root/mingw/bin"
    )
    foreach ($Entry in $RuntimeFiles.GetEnumerator()) {
        Copy-VerifiedRuntime `
            -Source (Join-Path $RuntimeRoot $Entry.Key) `
            -Name $Entry.Key `
            -Expected $Entry.Value `
            -DestinationPath $DestinationPath
    }

    $ExtractedOpenSslLicense = Join-Path $TemporaryPath (
        "usr/share/doc/mingw64-x86_64-openssl/LICENSE.txt"
    )
    $ExtractedZlibLicense = Join-Path $TemporaryPath (
        "usr/share/doc/mingw64-x86_64-zlib/LICENSE"
    )
    Assert-FileHash -Path $ExtractedOpenSslLicense -Algorithm SHA256 `
        -Expected $OpenSslLicenseSha256
    Assert-FileHash -Path $ExtractedZlibLicense -Algorithm SHA256 `
        -Expected $ZlibLicenseSha256

    $RepositoryOpenSslLicense = Join-Path $PSScriptRoot "../licenses/OPENSSL.txt"
    $RepositoryZlibLicense = Join-Path $PSScriptRoot "../licenses/ZLIB.txt"
    Assert-FileHash -Path $RepositoryOpenSslLicense -Algorithm SHA256 `
        -Expected $OpenSslLicenseSha256
    Assert-FileHash -Path $RepositoryZlibLicense -Algorithm SHA256 `
        -Expected $ZlibLicenseSha256
    Copy-Item -LiteralPath $RepositoryOpenSslLicense -Destination (
        Join-Path $DestinationPath "OPENSSL-LICENSE.txt"
    ) -Force
    Copy-Item -LiteralPath $RepositoryZlibLicense -Destination (
        Join-Path $DestinationPath "ZLIB-LICENSE.txt"
    ) -Force
}
finally {
    if (Test-Path -LiteralPath $TemporaryPath) {
        Remove-Item -LiteralPath $TemporaryPath -Recurse -Force
    }
}

Write-Host "Prepared OpenSSL 3.5.7 LTS and zlib 1.3.2 in $DestinationPath"
