function Invoke-DrApiRequest {
    param (
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        [object]$Body,
        [switch]$DebugOutput
    )

    if (-not $Global:DrApiKey) { Write-Error "Global:DrApiKey is not set. Cannot authenticate."; return }
    if (-not $Global:DrSubDomain) { Write-Error "Global:DrSubDomain is not set. Cannot determine Syncro subdomain."; return }

    $uri = "https://$Global:DrSubDomain.syncromsp.com$Endpoint"
    $headers = @{
        Authorization  = "Bearer $Global:DrApiKey"
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }

    $rawJson = $null
    $bodyBytes = $null

    # Only send body for non-GET
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body -and $Method -ne 'GET') {
        $rawJson = $Body | ConvertTo-Json -Depth 10
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($rawJson)
    }

    if ($DebugOutput) {
        Write-Host "URI: $uri"
        Write-Host "Method: $Method"
        Write-Host "Headers:"; $headers.GetEnumerator() | ForEach-Object { Write-Host "  $_" }
        if ($bodyBytes) {
            Write-Host "Body Type: $($bodyBytes.GetType().FullName)"
            Write-Host ($rawJson -replace "`n", ' ')
        }
        else {
            Write-Host "Body: (none)"
        }
        Write-Host "-------------------"
    }

    # Helper: convert parsed graph to PSCustomObject while resolving case-colliding keys
    function Convert-GraphToPs([object]$obj) {
        if ($null -eq $obj) { return $null }

        if ($obj -is [System.Collections.IDictionary]) {
            $ordered = New-Object System.Collections.Specialized.OrderedDictionary
            $seen = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($entry in $obj.GetEnumerator()) {
                $key = [string]$entry.Key
                $lower = $key.ToLowerInvariant()

                # Canonicalize 'ticket' to lowercase; for other keys, first wins
                $canonicalKey = if ($lower -eq 'ticket') { 'ticket' } else { $key }

                if ($seen.ContainsKey($lower)) {
                    # Duplicate by case only
                    if ($lower -eq 'ticket' -and $seen[$lower] -ne 'ticket') {
                        $prevKey = $seen[$lower]
                        $ordered.Remove($prevKey)
                        $ordered.Add('ticket', (Convert-GraphToPs $entry.Value))
                        $seen[$lower] = 'ticket'
                    }
                    else {
                        continue  # first wins
                    }
                }
                else {
                    $ordered.Add($canonicalKey, (Convert-GraphToPs $entry.Value))
                    $seen[$lower] = $canonicalKey
                }
            }

            return [pscustomobject]$ordered
        }

        if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
            $out = @()
            foreach ($item in $obj) { $out += , (Convert-GraphToPs $item) }
            return $out
        }

        return $obj
    }

    try {
        $splat = @{
            Uri         = $uri
            Method      = $Method
            Headers     = $headers
            ErrorAction = 'Stop'
        }
        if ($bodyBytes) { $splat.Body = $bodyBytes }

        $resp = Invoke-RestMethod @splat

        # If response is string (mislabeled content-type), sanitize + parse
        if ($resp -is [string]) {
            $json = $resp -replace '^\uFEFF', ''
            $json = [regex]::Replace($json, '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', '')

            try {
                $resp = $json | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                try {
                    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
                    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                    $ser.MaxJsonLength = 67108864
                    $graph = $ser.DeserializeObject($json)
                    $resp = Convert-GraphToPs $graph
                }
                catch {
                    Write-Warning "Invoke-DrApiRequest1: JSON parse failed; returning raw string. Error: $($_.Exception.Message)"
                    return $resp
                }
            }
        }

        return $resp
    }
    catch {
        Write-Error "API request failed: $($_.Exception.Message)"
    }
}
