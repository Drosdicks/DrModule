function Call-KabutoApi {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Method,         # GET, POST, PUT, DELETE
        [Parameter(Mandatory)][string]$Path,           # e.g., "/device_api/rmm_alert"
        [object]$Data,
        [switch]$DebugOutput
    )

    if (-not $Global:UUID) {
        Write-Error "Global:UUID is not set. Cannot identify device."
        return
    }

    if (-not $Global:DrRepairTechKabutoApiUrl) {
        Write-Error "DrRepairTechKabutoApiUrl is not set. Cannot determine API host."
        return
    }

    $uri = "$($Global:DrRepairTechKabutoApiUrl)$Path"
    $headers = @{
        "Content-Type" = "application/json"
    }

    $bodyJson = $null
    $rawJson = $null

    if ($Data) {
        $rawJson = $Data | ConvertTo-Json -Depth 5
        $bodyJson = [System.Text.Encoding]::UTF8.GetBytes($rawJson)
    }

    if ($DebugOutput) {
        Write-Host "URI: $uri"
        Write-Host "Method: $Method"
        Write-Host "Headers:"
        $headers.GetEnumerator() | ForEach-Object { Write-Host "  $_" }
        Write-Host "Body Type: $($bodyJson.GetType().FullName)"
        Write-Host "Raw JSON:"
        Write-Host ($rawJson -replace "`n", " ")
        Write-Host "-------------------"
    }

    try {
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $bodyJson
    }
    catch {
        Write-Error "Kabuto API request failed: $_"
    }
}
