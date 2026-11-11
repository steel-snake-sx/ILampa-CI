param(
    [string]$Ipa = "build/codemagic/iLampa-unsigned.ipa",
    [int]$TimeoutSeconds = 300
)

$file = Get-Item -LiteralPath $Ipa
if (-not $file.Exists) {
    Write-Error "IPA not found at $Ipa"
    exit 1
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
Write-Host "Target IPA: $($file.Name) ($($file.Length) bytes, SHA256: $hash)"
Write-Host "Waiting for RyukSign server on local network (open RyukSign on your iPhone)..."

$candidateIps = @("192.168.1.2", "192.168.1.3", "192.168.1.5", "192.168.1.4", "192.168.1.10")
$start = Get-Date

while (($true)) {
    if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
        Write-Warning "Timed out waiting for RyukSign after $TimeoutSeconds seconds."
        exit 1
    }

    foreach ($ip in $candidateIps) {
        $server = "http://${ip}:2424"
        $json = & curl.exe --noproxy '*' --silent --connect-timeout 1 --max-time 2 "$server/api/apps"
        if ($LASTEXITCODE -eq 0 -and $json) {
            Write-Host "`n>>> RyukSign detected at $server! Starting upload..."
            & powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ryuksign-upload.ps1 -Ipa $file.FullName -Server $server
            if ($LASTEXITCODE -eq 0) {
                Write-Host "`nSUCCESS: iLampa successfully uploaded to RyukSign at $server!"
                exit 0
            } else {
                Write-Error "Upload script exited with code $LASTEXITCODE"
                exit 1
            }
        }
    }

    Write-Host -NoNewline "."
    Start-Sleep -Seconds 3
}
