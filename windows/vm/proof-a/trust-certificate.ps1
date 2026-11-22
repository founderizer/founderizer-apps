# Trusts the build VM's test certificate in a copy of the clean PC (clean-pc.sh copy), so that Windows and the setup's
# own check find the setup's signature valid. The caller sets $expected, the thumbprint that build-setup.sh read in the
# build VM. Only the public part comes in: a file that holds a private key is refused.
$file = 'C:\fz\proof-a\founderizer-test-signing.cer'
$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $file
if ($certificate.HasPrivateKey) { throw 'the certificate file holds a private key' }
if ($certificate.Thumbprint -ne $expected) { throw "the certificate is $($certificate.Thumbprint), not the build's $expected" }
foreach ($store in 'Root', 'TrustedPublisher') {
    & certutil.exe -f -addstore $store $file | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil could not add the test certificate to $store" }
}
"the test certificate $($certificate.Subject) ($($certificate.Thumbprint)) is trusted (Root, TrustedPublisher); no private key"
