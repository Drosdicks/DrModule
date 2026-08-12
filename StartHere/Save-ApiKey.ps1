

function Save-ApiKey {
    param (
        [Parameter(Mandatory)]
        [string]$ApiKey
    )

    $regPath = "HKLM:\SOFTWARE\WOW6432Node\RepairTech\Syncro\DrOsdicks"
    $keyPath = "C:\ProgramData\Syncro\DrOsdicks\bin\key.bin"
    $valueName = "ApiKey"

    Write-Host "Key path: $keyPath"

    # Ensure registry path exists
    if (-not (Test-Path $regPath)) {
        try {
            $null = New-Item -Path $regPath -Force
        }
        catch {
            throw "Failed to create registry path: $_"
        }
    }

    # Ensure key directory exists
    $keyDir = Split-Path $keyPath
    if (-not (Test-Path $keyDir)) {
        try {
            New-Item -Path $keyDir -ItemType Directory -Force | Out-Null
        }
        catch {
            throw "Failed to create key directory: $_"
        }
    }

    # Create or load encryption key
    if (-not (Test-Path $keyPath)) {
        $key = New-Object byte[] 32
        [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($key)
        [IO.File]::WriteAllBytes($keyPath, $key)
    }
    else {
        $key = [IO.File]::ReadAllBytes($keyPath)
    }

    # Encrypt and store API key
    $secure = ConvertTo-SecureString $ApiKey -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString $secure -Key $key
    Set-ItemProperty -Path $regPath -Name $valueName -Value $encrypted
    Write-Host "Encrypted API key saved to registry at $regPath\$valueName"
}

$apiKey = 'YOURAPIKEYGOESHERE'

Save-ApiKey -ApiKey $apiKey

Import-Module "C:\ProgramData\Syncro\DrOsdicks\bin\DrModule.psm1" -DisableNameChecking

Initialize-Job `
    -Subject "DrModuleV4 Installation" `
    -IssueType 'Automation' `
    -InitialIssue "Initial DrModuleV4 installation."

Add-LogEntry "API key encrypted and stored successfully." `
    -Icon 'lockandkey'

Add-LogEntry "DrModuleV4 module imported successfully." `
    -Icon 'module'

Add-LogEntry "Initial installation completed." `
    -Icon 'summary'

Complete-Job
