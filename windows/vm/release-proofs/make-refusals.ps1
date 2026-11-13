# make-refusals.ps1: from a good build's zip, a zip whose Founderizer.Core.dll another trusted certificate signed,
# and one whose Founderizer.Core.dll has no signature (the app's publish output, before the build script signs it).
param([string]$Zip, [string]$Unsigned, [string]$Out)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$subject = 'CN=Founderizer Other Signer (build VM)'
$other = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert | Where-Object Subject -eq $subject | Select-Object -First 1
if (-not $other) {
    $other = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation Cert:\LocalMachine\My `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddMonths(3)
    $cer = Join-Path $env:TEMP 'founderizer-other-signer.cer'
    Export-Certificate -Cert $other -FilePath $cer | Out-Null
    foreach ($store in 'Root', 'TrustedPublisher') { & certutil.exe -f -addstore $store $cer | Out-Null }
}
"other signer: $($other.Subject) $($other.Thumbprint), trusted in Root and TrustedPublisher of this VM"
$work = Join-Path $env:TEMP ('refusals-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$archive = [IO.Compression.ZipFile]::OpenRead($Zip)
try { [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.GetEntry('Founderizer.Core.dll'), (Join-Path $work 'Founderizer.Core.dll')) } finally { $archive.Dispose() }
$signedByOther = Join-Path $work 'Founderizer.Core.dll'
$r = Set-AuthenticodeSignature -FilePath $signedByOther -Certificate $other -HashAlgorithm SHA256
"re-signed Founderizer.Core.dll: $($r.Status), signer $($r.SignerCertificate.Subject)"
"unsigned Founderizer.Core.dll: " + (Get-AuthenticodeSignature $Unsigned).Status
$name = Split-Path $Zip -Leaf
foreach ($case in @(@('other-signer', $signedByOther), @('unsigned', $Unsigned))) {
    $target = Join-Path $Out ($case[0] + '-' + $name)
    Copy-Item -Force $Zip $target
    $a = [IO.Compression.ZipFile]::Open($target, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $a.GetEntry('Founderizer.Core.dll').Delete()
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($a, $case[1], 'Founderizer.Core.dll') | Out-Null
    } finally { $a.Dispose() }
    "made $target"
}
Remove-Item -Recurse -Force $work
