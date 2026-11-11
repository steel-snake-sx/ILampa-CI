param(
    [string]$BuildId,
    [string]$Token = $env:CODEMAGIC_API_TOKEN,
    [string]$RyukServer = "http://192.168.1.2:2424",
    [string]$Branch = "integration/2.2.0",
    [string]$WorkflowId = "ilampa-device-diagnostic-ipa"
)

$token = $Token
if (-not $token) { throw "Set CODEMAGIC_API_TOKEN or pass -Token." }
$buildId = $BuildId
$ryukServer = $RyukServer

if (-not $buildId) {
    Write-Host "No -BuildId specified. Triggering $WorkflowId for $Branch..."
    $triggerBody = @{
        appId = "6aec91a2e2fb6e294d92d89a"
        workflowId = $WorkflowId
        branch = $Branch
    } | ConvertTo-Json
    $triggerHeaders = @{
        "x-auth-token" = $token
        "Content-Type" = "application/json"
    }
    $triggerRes = Invoke-RestMethod -Uri "https://api.codemagic.io/builds" -Method POST -Headers $triggerHeaders -Body $triggerBody
    $buildId = $triggerRes.buildId
    Write-Host "Triggered build: $buildId"
}

Write-Host "Monitoring Codemagic build $buildId..."

$maxMinutes = 90
$startTime = Get-Date

while ($true) {
    $now = Get-Date
    if (($now - $startTime).TotalMinutes -gt $maxMinutes) {
        Write-Error "Build timed out after $maxMinutes minutes."
        exit 1
    }

    try {
        $headers = @{ "x-auth-token" = $token }
        $res = Invoke-RestMethod -Uri "https://api.codemagic.io/builds/$buildId" -Headers $headers
        $status = $res.build.status
        $elapsed = [math]::Round(($now - $startTime).TotalSeconds)

        Write-Host "[$elapsed s] Status: $status"

        if ($status -eq "building" -or $status -eq "preparing") {
            foreach ($action in $res.build.buildActions) {
                if ($action.status) {
                    Write-Host "  - $($action.name): $($action.status)"
                }
            }
        }

        if ($status -eq "finished") {
            Write-Host "Build finished successfully!"
            $artefacts = $res.build.artefacts
            Write-Host "Artefacts count: $($artefacts.Count)"
            
            $ipaArtefact = $artefacts | Where-Object { $_.name -like "*.ipa" } | Select-Object -First 1
            if ($ipaArtefact) {
                Write-Host "Found IPA: $($ipaArtefact.name) ($($ipaArtefact.size) bytes)"
                $downloadUrl = $ipaArtefact.url
                
                $outDir = "build/codemagic"
                if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
                $outIpa = "$outDir/iLampa-unsigned.ipa"
                
                Write-Host "Downloading IPA from $downloadUrl..."
                curl.exe -s -L -H "x-auth-token: $token" -o $outIpa "$downloadUrl"
                
                if (Test-Path $outIpa) {
                    $item = Get-Item $outIpa
                    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
                    Write-Host "Downloaded: $($item.FullName) ($($item.Length) bytes, SHA256: $hash)"
                    
                    # Never mistake a test-results ZIP for an installable IPA.
                    # The release verifier checks bundle identity, resources and commit.
                    $expectedCommit = (git rev-parse HEAD).Trim()
                    $versionMatch = Select-String -Path "project.yml" -Pattern 'MARKETING_VERSION: "([^"]+)"' | Select-Object -First 1
                    if (-not $versionMatch) { throw "No version found in project.yml" }
                    $expectedVersion = $versionMatch.Matches.Groups[1].Value
                    python scripts/verify-release-ipa.py $item.FullName --commit $expectedCommit --version $expectedVersion --minimum-build 2009
                    if ($LASTEXITCODE -ne 0) { throw "IPA identity/contents verification failed; upload blocked" }

                    Write-Host "Uploading verified IPA to RyukSign at $ryukServer..."
                    & powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ryuksign-upload.ps1 -Ipa $item.FullName -Server $ryukServer
                    if ($LASTEXITCODE -ne 0) { throw "RyukSign upload failed (exit $LASTEXITCODE)" }
                    Write-Host "SUCCESS: Verified IPA uploaded to RyukSign!"
                    exit 0
                } else {
                    Write-Error "Failed to download IPA."
                    exit 1
                }
            } else {
                Write-Error "No IPA artifact found in finished build."
                exit 1
            }
        } elseif ($status -eq "failed" -or $status -eq "canceled") {
            Write-Error "Build $status!"
            foreach ($action in $res.build.buildActions) {
                if ($action.status -eq "failed") {
                    Write-Host "Failed step: $($action.name)"
                    $stepLogUrl = $action.logUrl
                    if (-not $stepLogUrl -and $action.subactions -and $action.subactions.Count -gt 0) {
                        $stepLogUrl = $action.subactions[0].logUrl
                    }
                    if ($stepLogUrl) {
                        Write-Host "Log URL: $stepLogUrl"
                        $log = curl.exe -s -H "x-auth-token: $token" "$stepLogUrl"
                        Write-Host "Log preview:"
                        Write-Host ($log | Select-Object -Last 30)
                    }
                }
            }
            exit 1
        }
    } catch {
        Write-Warning "Poll error: $_"
    }

    Start-Sleep -Seconds 10
}
