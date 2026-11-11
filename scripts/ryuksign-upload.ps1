param(
    [Parameter(Mandatory = $true)]
    [string]$Ipa,
    [string]$Server = 'http://192.168.1.2:2424',
    [string]$ExpectedSha256 = ''
)

$ErrorActionPreference = 'Stop'
$file = Get-Item -LiteralPath $Ipa
if ($file.PSIsContainer -or $file.Extension -ine '.ipa') {
    throw 'Specify an existing .ipa file.'
}
$uri = [uri]$Server
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https') -or $uri.AbsolutePath -ne '/') {
    throw 'Server must be an HTTP(S) origin, for example http://192.168.1.5:2424'
}
$base = $Server.TrimEnd('/')
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
if ($ExpectedSha256 -and $hash -ine $ExpectedSha256) {
    throw "SHA256 mismatch: $hash"
}
"IPA: $($file.Name) ($($file.Length) bytes)"
"SHA256: $hash"

function Get-RyukApps {
    $json = & curl.exe --noproxy '*' --silent --show-error --fail --connect-timeout 10 --max-time 30 "$base/api/apps"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read RyukSign library. Check the address and keep RyukSign open.' }
    foreach ($app in (ConvertFrom-Json -InputObject ($json -join "`n"))) { $app }
}

$before = @(Get-RyukApps)
$name = [uri]::EscapeDataString($file.Name)
& curl.exe --noproxy '*' --show-error --fail-with-body --connect-timeout 10 --max-time 600 `
    -H 'Content-Type: application/octet-stream' --data-binary "@$($file.FullName)" `
    -w "`nHTTP %{http_code}; uploaded %{size_upload} bytes in %{time_total}s`n" "$base/upload/$name"
if ($LASTEXITCODE -ne 0) {
    throw 'Upload failed. Check the phone before retrying; an interrupted response may still have imported the file.'
}

for ($attempt = 0; $attempt -lt 24; $attempt++) {
    Start-Sleep -Seconds 5
    $newApps = @(Get-RyukApps | Where-Object { $_.uuid -notin @($before.uuid) })
    if ($newApps.Count -gt 0) {
        'New library entries (check the intended app on the phone):'
        $newApps | Select-Object name, version, identifier, signed, uuid | Format-List
        return
    }
}
throw 'Upload accepted, but no new library UUID appeared within 120 seconds. Check RyukSign before retrying.'
