#region Module Init
# Global-Variables-and-Paths.ps1 (example)

#region Global Variables and Constants

# Module Version (injected at build time)
$Global:DrModuleVersion = '4.0.0'

# Primary Root (Persistent Data)
$Global:DrRoot = 'C:\ProgramData\Syncro\DrOsdicks'
$Global:DrBin = Join-Path $Global:DrRoot 'Bin'

# Module identity (stable)
$Global:DrModulePath = Join-Path $Global:DrBin 'DrModule.psm1'

# Assets
$Global:DrLogo = Join-Path $Global:DrBin 'Logo.jpg'
$Global:DrVarStorePath = Join-Path $Global:DrBin 'variables.xml'
$Global:DrFilePusherPath = 'C:\ProgramData\Syncro\bin\FilePusher.exe'

# External API
$Global:DrRepairTechKabutoApiUrl = 'https://rmm.syncromsp.com'

# Hidden operational root
$Global:DrHiddenRoot = 'C:\DrOsdicks'
$Global:DrLogs = Join-Path $Global:DrHiddenRoot 'DrLogs'
$Global:DrTemp = Join-Path $Global:DrHiddenRoot 'DrTemp'
$Global:DrToolbox = Join-Path $Global:DrHiddenRoot 'Toolbox'
$Global:DrHiddenBin = Join-Path $Global:DrHiddenRoot 'bin'
$Global:DrJobsPath = Join-Path $Global:DrHiddenRoot 'Jobs'

# Runtime-initialized
$Global:DrJobRoot = $Global:DrJobsPath
$Global:DrLogFile = $null
$Global:DrTimers = $null

#endregion
#endregion

#region File: _Find-WinDbg.ps1
function _Find-WinDbg {
        $paths = @(
            "C:\Program Files\Windows Kits\10\Debuggers\x64\windbg.exe",
            "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\windbg.exe",
            "C:\Program Files\Windows Kits\10\Debuggers\x86\windbg.exe",
            "C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\windbg.exe"
        )
        foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
        return $null
    }
#endregion

#region File: Add-DrLocalUser.ps1
function Add-DrLocalUser {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Username,

        [string]$uPassword,

        [string]$FullName,

        [string]$Description,

        [string]$Group,

        [switch]$HideFromLogonScreen,

        [switch]$PasswordNeverExpires,

        # Optional: only forces “must change password at next logon” when you pass it
        [switch]$ForcePasswordReset,

        [switch]$Update,

        [string[]]$Buffer = 'Add-DrLocalUser',
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    if (-not (Assert-IsAdmin @summaryParams)) { return }

    $existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    $isUpdate = [bool]$existingUser
    $verb = if ($isUpdate) { 'update' } else { 'create' }

    # Resolve password (support "*Generate") — does NOT force reset
    $pwdGenerated = $false
    $plainPwd = $null
    if ($uPassword) {
        if ($uPassword -and $uPassword -match '^\*(gen|generate)$') {
            $plainPwd = New-RandomPassword
            $pwdGenerated = $true
        }
        else {
            $plainPwd = $uPassword
        }
    }

    # If forcing reset, never-expires must be OFF (override, no error)
    if ($ForcePasswordReset -and $PasswordNeverExpires) {
        $PasswordNeverExpires = $false
        Add-LogEntry "ForcePasswordReset enabled; PasswordNeverExpires overridden to OFF to avoid Windows hard error." @detailsParams -Icon 'info'
    }

    # Intent validation
    if ($isUpdate -and -not $Update) {
        Add-LogEntry "User '$Username' already exists." @summaryParams -Icon 'error'
        return
    }

    if (-not $isUpdate -and -not $plainPwd) {
        Add-LogEntry "Password is required to create a new user (or use -uPassword '*Generate')." @summaryParams -Icon 'error'
        return
    }

    if ($pwdGenerated) {
        Add-LogEntry "Generated password: $plainPwd" @detailsParams -Icon 'key'
    }
    else {
        Add-LogEntry "Password provided by caller (not logged)" @detailsParams -Icon 'key'
    }

    Add-LogEntry "Options: Update=$isUpdate; ForcePasswordReset=$ForcePasswordReset; PasswordNeverExpires=$PasswordNeverExpires" `
        @detailsParams -Icon 'info'


    try {
        $secPwd = $null
        if ($plainPwd) {
            $secPwd = ConvertTo-SecureString -String $plainPwd -AsPlainText -Force
        }

        # Create or update core properties
        if ($isUpdate) {
            $setParams = @{ Name = $Username }
            if ($FullName) { $setParams['FullName'] = $FullName }
            if ($Description) { $setParams['Description'] = $Description }
            Set-LocalUser @setParams

            if ($secPwd) {
                Set-LocalUser -Name $Username -Password $secPwd
            }
        }
        else {
            $newParams = @{ Name = $Username; Password = $secPwd }
            if ($FullName) { $newParams['FullName'] = $FullName }
            if ($Description) { $newParams['Description'] = $Description }
            New-LocalUser @newParams | Out-Null
        }

        # Password policy actions
        if ($ForcePasswordReset) {
            Set-LocalUser -Name $Username -PasswordNeverExpires $false

            # Force "must change password at next logon" via ADSI
            $adsi = [ADSI]"WinNT://$env:COMPUTERNAME/$Username,user"
            $adsi.PasswordExpired = 1
            $adsi.SetInfo()
        }
        elseif ($PasswordNeverExpires) {
            Set-LocalUser -Name $Username -PasswordNeverExpires $true
        }

        if ($isUpdate) {
            $msg = "Updated user '$Username'."
        }
        else {
            $msg = "Created user '$Username'."
        }

        Add-LogEntry $msg @detailsParams -Icon 'success'
        #Add-LogEntry (if ($isUpdate) { "✅ Updated user '$Username'." } else { "✅ Created user '$Username'." }) @detailsParams -Icon 'success'
    }
    catch {
        $errorMessage = $_.ToString()
        if ($plainPwd) {
            $errorMessage = $errorMessage -replace [regex]::Escape($plainPwd), '*****'
        }
        Write-Host ($summaryParams | Format-List | Out-String)
        Add-LogEntry "❌1 Failed to $verb user '$Username': $errorMessage" @summaryParams -Icon 'error'
        return
    }

    # Group membership (SID-based check; add by SID)
    if ($Group) {
        try {
            $userSid = (Get-LocalUser -Name $Username -ErrorAction Stop).SID

            $alreadyInGroup = Get-LocalGroupMember -Group $Group -ErrorAction SilentlyContinue |
            Where-Object { $_.SID -eq $userSid }

            if (-not $alreadyInGroup) {
                Add-LocalGroupMember -Group $Group -Member $userSid
                Add-LogEntry "✅ Added '$Username' to group '$Group'." @detailsParams -Icon 'success'
            }
            else {
                Add-LogEntry "ℹ️ User '$Username' already in group '$Group'." @detailsParams -Icon 'info'
            }
        }
        catch {
            Add-LogEntry "❌ Failed group action for '$Username' in '$Group': $_" @detailsParams -Icon 'error'
            return
        }
    }

    # Hide from logon (Hide-User already logs + outputs)
    if ($HideFromLogonScreen) {
        try {
            Hide-User -State 'Hide' -Username $Username @detailsParams
        }
        catch {
            Add-LogEntry "❌ Failed to hide user '$Username' from logon screen: $_" @detailsParams -Icon 'error'
        }
    }

    Add-LogEntry "Finished processing user '$Username'." @summaryParams -Icon 'success'
}
#endregion

#region File: Add-DrRecommendation.ps1
function Add-DrRecommendation {
    [CmdletBinding()]
    param (
        [string]   $Message,
        [string]   $SuggestedAction = 'n\a',
        [string]   $Severity = 'Info',
        [string[]] $Tags = @(),
        [string]   $SourceFunction = $MyInvocation.MyCommand.Name,
        [string]   $CommandToRun = 'n\a',
        [bool]     $Approved = $false,
        [int]      $ExecutionOrder = 0,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    $Buffer += 'recommendations'
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $recommendation = [DrRecommendation]::new()
    $recommendation.Message = $Message
    $recommendation.SuggestedAction = $SuggestedAction
    $recommendation.Severity = $Severity
    $recommendation.Tags = $Tags
    $recommendation.SourceFunction = $SourceFunction
    $recommendation.CommandToRun = $CommandToRun
    $recommendation.Approved = $Approved
    $recommendation.ExecutionOrder = $ExecutionOrder

    if (-not $recommendation.Validate()) {
        Add-LogEntry -Message "Recommendation requires a Message or a Suggested Action." -Icon 'error' @summaryParams
        return
    }

    if (-not $recommendation.Save()) {
        Add-LogEntry -Message "Failed to save recommendation [$($recommendation.Message)]." -Icon 'error' @summaryParams 
        return
    }

    Add-LogEntry -Message "Recommendation [$($recommendation.NumericId)]. [$($recommendation.Message)] - [$($recommendation.CommandToRun)] saved." -Icon 'success' @summaryParams
    return $recommendation
}
#endregion

#region File: Add-DrTicketTimerEntry.ps1
function Add-DrTicketTimerEntry {
    [CmdletBinding()]
    param (
        [string]$TicketId = $Global:DrTicketId,
        [string]$StartTime = (Get-Date).ToString("o"),
        [int]$DurationMinutes = 15,
        [string]$Notes = "Timer entry added via script.",
        [string]$UserIdOrEmail = $env:USERNAME,
        [bool]$ChargeTime = $true,
        [switch]$DebugOutput
    )

    if (-not $Global:UUID) {
        Write-Error "Global:UUID is not set. Cannot identify device."
        return
    }

    if (-not $TicketId) {
        Write-Error "TicketId is not set. Cannot add timer entry."
        return
    }

    $endpoint = "/api/syncro_device/tickets/$TicketId/add_timer_entry"
    $body = @{
        uuid             = $Global:UUID
        start_at         = $StartTime
        duration_minutes = $DurationMinutes
        notes            = $Notes
        user_id_or_email = $UserIdOrEmail
        charge_time      = $ChargeTime
    }

    try {
        $response = Invoke-DrApiRequest -Method 'POST' -Endpoint $endpoint -Body $body -DebugOutput:$DebugOutput
        return $response
    }
    catch {
        Write-Error "Failed to add timer entry to ticket ${TicketId}: $_"
    }
}
#endregion

#region File: Add-DrTimerMessage.ps1
function Add-DrTimerMessage {
    param([string]$Name, [string]$Action, [string]$Message)
    if (-not $Global:DrTimers[$Name]) { return }
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Action - $Message"
    $Global:DrTimers[$Name].Messages += $entry
}
#endregion

#region File: Add-DrTimerToTicket.ps1
function Add-DrTimerToTicket {
    param (
        [string]$Name = "*ALL",
        [string]$Notes = "Work logged via timer system",
        [bool]$ChargeTime = $true
    )

    Load-DrTimers
    if (-not $Global:DrTicketId) { return }
    if ($Global:DrTimers.Count -eq 0) { return }

    $targets = if ($Name -eq "*ALL") { $Global:DrTimers.Keys } else { @($Name) }

    foreach ($t in $targets) {
        if (-not $Global:DrTimers[$t]) { continue }
        $timer = $Global:DrTimers[$t]

        if ($timer.AddedToTicket) {
            Add-DrTimerMessage -Name $t -Action 'TicketAddSkipped' -Message "Timer already added to ticket."
            continue
        }

        if ($timer.Status -eq 'Running') {
            Stop-DrTimer -Name $t
        }
        elseif ($timer.Status -eq 'Paused') {
            $timer.Status = 'Stopped'
        }

        $minutes = [math]::Ceiling($timer.Elapsed / 60)
        $messageLog = Get-DrTimerMessagesString -Name $t
        $fullNotes = "$Notes`n`nTimer $t Messages:`n$messageLog"

        try {
            Add-DrTicketTimerEntry -TicketId $Global:DrTicketId `
                -StartTime ([DateTime]$timer.StartTime).ToString("o") `
                -DurationMinutes $minutes `
                -Notes $fullNotes `
                -ChargeTime $ChargeTime

            # ✅ Persist the update in the global hashtable
            $Global:DrTimers[$t].AddedToTicket = $true

            Add-LogEntry -Message "$t - Timer added to ticket." -AddToBody -Icon 'success'
            Add-DrTimerMessage -Name $t -Action 'TicketAddComplete' -Message "Timer added to ticket."
        }
        catch {
            Add-LogEntry -Message "$t - Failed to add timer." -AddToBody -Icon 'error'
            Add-DrTimerMessage -Name $t -Action 'TicketAddFailed' -Message "Failed to add timer."
        }
        Add-LogEntry -Message "end" -AddBody
    }

    Save-DrTimers
}
#endregion

#region File: Add-FilesToZip.ps1
function Add-FilesToZip {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ZipName,

        [Parameter(Mandatory)]
        [string[]]$Paths,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer,

        [ValidateSet("Replace", "Skip")]
        [string]$IfExists = "Replace"
    )

    $Icon = "FileHandling"
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary


    try {
        if (-not $ZipName.EndsWith(".zip")) {
            $ZipName += ".zip"
        }

        $zipFilePath = Join-Path -Path $Global:Drtemp -ChildPath $ZipName

        Add-Type -AssemblyName System.IO.Compression.FileSystem

        if (-not (Test-Path $zipFilePath)) {
            [System.IO.Compression.ZipFile]::Open($zipFilePath, 'Create').Dispose()
            Add-LogEntry -Message "Created new ZIP archive at '$zipFilePath'." -Icon $Icon @detailsParams
        }

        foreach ($path in $Paths) {
            if (-not (Test-Path $path)) {
                Add-LogEntry -Message "Skipped '$path' (not found)." -Icon $Icon @detailsParams
                continue
            }

            $basePath = if ((Get-Item $path).PSIsContainer) { $path } else { Split-Path $path -Parent }
            $files = if ((Get-Item $path).PSIsContainer) {
                Get-ChildItem -Path $path -Recurse -File
            }
            else {
                Get-Item -Path $path
            }

            foreach ($file in $files) {
                $relativePath = $file.FullName.Substring($basePath.Length + 1)
                $tempZip = [System.IO.Compression.ZipFile]::Open($zipFilePath, 'Update')

                $existingEntry = $tempZip.Entries | Where-Object { $_.FullName -eq $relativePath }

                if ($existingEntry) {
                    if ($IfExists -eq "Replace") {
                        $existingEntry.Delete()
                        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($tempZip, $file.FullName, $relativePath)
                        Add-LogEntry -Message "Replaced '$relativePath' in ZIP." -Icon $Icon @detailsParams
                    }
                    else {
                        Add-LogEntry -Message "Skipped '$relativePath' (already exists)." -Icon $Icon @detailsParams
                    }
                }
                else {
                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($tempZip, $file.FullName, $relativePath)
                    Add-LogEntry -Message "Added '$relativePath' to ZIP." -Icon $Icon @detailsParams
                }

                $tempZip.Dispose()
            }
        }

        $Global:DrZipFile = $zipFilePath
        Add-LogEntry -Message "Files added to ZIP archive '$Global:DrZipFile'." -Icon $Icon @detailsParams
    }
    catch {
        Add-LogEntry -Message "Failed to add files to ZIP: $_" -Icon $Icon @summaryParams -Hidden
    }
}
#endregion

#region File: Add-IfActionable.ps1
function Add-IfActionable {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $norm = [System.IO.Path]::GetFullPath(($p.Trim('"').Trim()))

        if (Test-Path -LiteralPath $norm) {
            $item = Get-Item -LiteralPath $norm -ErrorAction SilentlyContinue
            if ($null -eq $item) { return }

            if (-not $item.PSIsContainer) {
                # File: include only if it's a .dmp
                if ($item.Extension -ieq '.dmp' -and -not $paths.Contains($item.FullName)) {
                    $paths.Add($item.FullName)
                }
            }
            else {
                # Folder: include only if it has at least one *.dmp now
                $hasDmp = Get-ChildItem -LiteralPath $item.FullName -Filter *.dmp -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hasDmp -and -not $paths.Contains($item.FullName)) {
                    $paths.Add($item.FullName)
                }
            }
        }
    }
#endregion

#region File: Add-LogEntry.ps1
function Add-LogEntry {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [string]$Message,
        [string]$Icon,
        [switch]$NoIcon,
        [switch]$Timestamp = $Global:DrTimestamp,
        [switch]$LogActivity,
        [switch]$LogToHost = $Global:DrLogToHost,
        [switch]$Hidden,
        [string[]]$Buffer,
        [switch]$FlushBuffer,
        [switch]$SilentFlush,
        [switch]$AddToBody,   # Legacy: accumulate only
        [switch]$AddBody,     # Legacy: accumulate + flush
        [switch]$NoTicketOutput,
        [string]$Subject = "Automation"
    )

    try {
        # Validate message early
        if ([string]::IsNullOrWhiteSpace($Message)) { return }

        # Add icon if applicable (must be an approved icon name)
        if (-not $NoIcon -and $Icon) {
            $iconText = Get-LogIcon -Icon $Icon
            if ($iconText) { $Message = "$iconText $Message" }
        }

        # Add timestamp if enabled
        if ($Timestamp) {
            $Message = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
        }

        # Log activity if enabled (suppress output)
        if ($LogActivity) {
            $null = Log-DrActivity -Message $Message -EventName $Subject -ActivityType $Subject
        }

        # Map legacy switches to buffer logic
        if ($AddToBody) { $Buffer += 'Update' }
        if ($AddBody) { $Buffer += 'Update'; $FlushBuffer = $true }

        # If no buffers specified, log immediately
        if (-not $Buffer -or $Buffer.Count -eq 0) {
            if ($LogToHost) { Write-Host $Message }

            if ($Global:DrLogFile) {
                Add-Content -Path $Global:DrLogFile -Value $Message
            }

            if ($Global:DrTicket -and -not $NoTicketOutput) {
                Add-TicketComment -Body $Message -Subject $Subject -Hidden:$Hidden
            }
            return
        }

        # Handle buffers via Update-LogBuffer
        $buffersDistinct = $Buffer |
        Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

        $ulb = Get-Command -Name Update-LogBuffer -ErrorAction SilentlyContinue
        if (-not $ulb) { throw "Update-LogBuffer not found in the current session." }

        # Prefer canonical 'Buffers'; allow legacy for backward compatibility
        $paramName =
        if ($ulb.Parameters.ContainsKey('Buffers')) { 'Buffers' }
        elseif ($ulb.Parameters.ContainsKey('Buffer')) { 'Buffer' }
        elseif ($ulb.Parameters.ContainsKey('BufferName')) { 'BufferName' }
        else { throw "Update-LogBuffer does not expose 'Buffers', 'Buffer', or 'BufferName'." }

        if ($FlushBuffer) {
            $args = @{
                $paramName     = $buffersDistinct
                Message        = $Message
                Flush          = $true
                SilentFlush    = $SilentFlush
                Hidden         = $Hidden
                LogToHost      = $LogToHost
                LogToFile      = $Global:DrLogToFile
                NoTicketOutput = $NoTicketOutput
            }
            Update-LogBuffer @args
        }
        else {
            $args = @{
                $paramName = $buffersDistinct
                Message    = $Message
            }
            Update-LogBuffer @args
        }

        return
    }
    catch {
        Write-Error "An error occurred in $($MyInvocation.MyCommand.Name): $($_.Exception.Message)"
        return
    }
}
#endregion

#region File: Add-LogEntry1.ps1
function Add-LogEntry1 {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [string]$Message,
        [string]$Icon,
        [switch]$NoIcon,
        [switch]$Timestamp = $Global:DrTimestamp,
        [switch]$LogActivity,
        [switch]$LogToHost = $Global:DrLogToHost,
        [switch]$Hidden,
        [string[]]$Buffer,
        [switch]$FlushBuffer,
        [switch]$AddToBody,   # Legacy: accumulate only
        [switch]$AddBody,     # Legacy: accumulate + flush
        [switch]$NoTicketOutput,
        [string]$Subject = "Automation"
    )

    try {
        # Validate message early
        if ([string]::IsNullOrWhiteSpace($Message)) { return }

        # Add icon if applicable (must be an approved icon name)
        if (-not $NoIcon -and $Icon) {
            $iconText = Get-LogIcon -Icon $Icon
            if ($iconText) { $Message = "$iconText $Message" }
        }

        # Add timestamp if enabled
        if ($Timestamp) {
            $Message = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
        }

        # Log activity if enabled (suppress output)
        if ($LogActivity) {
            $null = Log-DrActivity -Message $Message -EventName $Subject -ActivityType $Subject
        }

        # Map legacy switches to buffer logic
        if ($AddToBody) { $Buffer += 'Update' }
        if ($AddBody) { $Buffer += 'Update'; $FlushBuffer = $true }

        # If no buffers specified, log immediately
        if (-not $Buffer -or $Buffer.Count -eq 0) {
            if ($LogToHost) { Write-Host $Message }

            if ($Global:DrLogFile) {
                Add-Content -Path $Global:DrLogFile -Value $Message
            }

            if ($Global:DrTicket -and -not $NoTicketOutput) {
                Add-TicketComment -Body $Message -Subject $Subject -Hidden:$Hidden
            }
            return
        }

        # Handle buffers via Update-LogBuffer
        $buffersDistinct = $Buffer |
        Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

        $ulb = Get-Command -Name Update-LogBuffer -ErrorAction SilentlyContinue
        if (-not $ulb) { throw "Update-LogBuffer not found in the current session." }

        # Prefer canonical 'Buffers'; allow legacy for backward compatibility
        $paramName =
        if ($ulb.Parameters.ContainsKey('Buffers')) { 'Buffers' }
        elseif ($ulb.Parameters.ContainsKey('Buffer')) { 'Buffer' }
        elseif ($ulb.Parameters.ContainsKey('BufferName')) { 'BufferName' }
        else { throw "Update-LogBuffer does not expose 'Buffers', 'Buffer', or 'BufferName'." }

        if ($FlushBuffer) {
            $splat = @{
                $paramName     = $buffersDistinct
                Message        = $Message
                Flush          = $true
                Hidden         = $Hidden
                LogToHost      = $LogToHost
                LogToFile      = $Global:DrLogToFile
                NoTicketOutput = $NoTicketOutput
            }
            Update-LogBuffer @splat
        }
        else {
            $splat = @{
                $paramName = $buffersDistinct
                Message    = $Message
            }
            Update-LogBuffer @splat
        }

        return
    }
    catch {
        Write-Error "An error occurred in $($MyInvocation.MyCommand.Name): $($_.Exception.Message)"
        return
    }
}
#endregion

#region File: Add-LoggedInUserToAdmins.ps1
function Add-LoggedInUserToAdmins {
    # Get the logged-in user (DOMAIN\Username or COMPUTERNAME\Username)
    $loggedInUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName
    Add-LogEntry -Message "Logged-in user: $loggedInUser" -AddBody -Icon 'user'

    # Extract domain/computer and username
    $accountParts = $loggedInUser -split '\\'
    $accountDomain = $accountParts[0]
    $accountName = $accountParts[1]

    # Check if the user is already a member of the Administrators group
    $group = [ADSI]"WinNT://./Administrators,group"
    $members = @($group.psbase.Invoke("Members")) | ForEach-Object {
        $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null)
    }

    if ($members -contains $accountName) {
        Add-LogEntry -Message "✅ User $loggedInUser is already a member of the Administrators group." -AddBody
    }
    else {
        # Format the full account name for net localgroup
        $fullAccount = "$accountDomain\$accountName"
        $command = "net localgroup Administrators `"$fullAccount`" /add"
        Invoke-Expression $command
        Add-LogEntry -Message "➕ User $fullAccount has been added to the Administrators group." -AddBody
    }
}
#endregion

#region File: Add-ProgressionRule.ps1
function Add-ProgressionRule {
    [CmdletBinding()]
    param (
        [string]   $SourceFunction,
        [string[]] $Executed = @(),
        [bool]     $Success,
        [string]   $Recommend,
        [string]   $Path = $Global:DrProgressions,
        [switch]   $Force
    )

    # Initialize rules array
    $rules = @()

    # Load existing rules if the file exists
    if (Test-Path $Path) {
        try {
            $rulesRaw = Get-Content $Path -Raw | ConvertFrom-Json
            $rules = @($rulesRaw)
        }
        catch {
            Add-LogEntry -Message "⚠️ Failed to parse existing progression rules. Starting fresh." -Icon 'warning'
        }
    }

    # Define new rule
    $newRule = @{
        SourceFunction = $SourceFunction
        Condition      = @{
            Executed = $Executed
            Success  = $Success
        }
        Recommend      = $Recommend
    }

    # Check for existing rule
    $existingIndex = $rules | ForEach-Object -Begin { $i = 0 } -Process {
        if (
            $_.SourceFunction -eq $SourceFunction -and
            ($_.Condition.Executed -join ',') -eq ($Executed -join ',') -and
            $_.Condition.Success -eq $Success -and
            $_.Recommend -eq $Recommend
        ) { return $i }
        $i++
    }

    if ($null -ne $existingIndex) {
        if ($Force) {
            $rules[$existingIndex] = $newRule
            Add-LogEntry -Message "🔁 Progression rule updated: $SourceFunction → $Recommend" -Icon 'info'
        }
        else {
            Add-LogEntry -Message "⚠️ Duplicate progression rule already exists. Use -Force to overwrite." -Icon 'warning'
            return $false
        }
    }
    else {
        $rules += $newRule
        Add-LogEntry -Message "✅ Progression rule added: $SourceFunction → $Recommend" -Icon 'success'
    }

    # Save rules
    try {
        $rules | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
        return $true
    }
    catch {
        Add-LogEntry -Message "❌ Failed to save progression rule: $_" -Icon 'error'
        return $false
    }
}
#endregion

#region File: Add-TicketComment.ps1
function Add-TicketComment {
    [CmdletBinding()]
    param (
        [string] $Subdomain = $Global:DrSubdomain,
        [string] $TicketIdOrNumber = $Global:DrTicket,
        [string] $Subject = '',
        [string] $Body = '',
        [bool]   $Hidden = $false,
        [bool]   $DoNotEmail = $true
        #[string] $display_order = 1
    )


    try {
        $commentData = @{
            uuid         = $Global:UUID
            subject      = $Subject
            body         = $Body
            hidden       = if ($Hidden) { "1" } else { "0" }
            do_not_email = if ($DoNotEmail) { "1" } else { "0" }
            #display_order = $display_order
        }
        return Invoke-DrApiRequest -Method 'POST' -Endpoint "/api/syncro_device/tickets/$TicketIdOrNumber/add_comment" -Body $commentData
    }
    catch {
        return $null
    }
}
#endregion

#region File: Add-TicketFile.ps1
function Add-TicketFile {
    [CmdletBinding()]
    param (
        [string] $TicketID = $Global:DrTicketId,
        [Parameter(Mandatory)]
        [string] $FilePath,
        [string] $FileName,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer,
        [switch] $DeleteAfterUpload
    )

    try {

        $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
        $detailsParams = $logParams.Details
        $summaryParams = $logParams.Summary

        if (-not (Test-Path $FilePath)) {
            Add-LogEntry -Message "File not found: $FilePath" -Icon 'error' @summaryParams
            return
        }

        if (-not $Global:DrFilePusherPath) {
            Add-LogEntry -Message "DrFilePusherPath not set." -Icon 'error' @summaryParams
            return
        }

        if (-not $Global:DrAPIKey) {
            Add-LogEntry -Message "API key not found in $Global:DrAPIKey." -Icon 'error'  @summaryParams
            return
        }

        if (-not $TicketID) {
            Add-LogEntry -Message "Ticket ID not provided and $Global:DrTicketId is not set." -Icon 'error' @summaryParams
            return
        }

        Add-LogEntry -Message "Uploading file for ticket #${TicketID}: $FilePath" -Icon 'upload' @detailsParams

        # Run DrFilePusher and parse output
        $fileJson = try {
            $output = cmd /c "$Global:DrFilePusherPath `"$FilePath`"" 2>&1
            ConvertFrom-Json -InputObject $output
        }
        catch {
            Add-LogEntry -Message "Failed to run DrFilePusher for '$FilePath'" -Icon 'error' @summaryParams
            return
        }

        if (-not $fileJson.url -or -not $fileJson.filename) {
            Add-LogEntry -Message "Invalid file pusher output for '$FilePath'" -Icon 'error' @summaryParams
            return
        }

        $finalName = if ($FileName) { $FileName } else { $fileJson.filename }

        $body = @{
            files = @(
                @{
                    url      = $fileJson.url
                    filename = $finalName
                }
            )
        }

        $endpoint = "/api/v1/tickets/$TicketID/attach_file_url"
        $response = Invoke-DrApiRequest -Method 'POST' -Endpoint $endpoint -Body $body

        if ($response) {
            Add-LogEntry -Message "📎 Attached '$finalName' to ticket #$TicketID." -Icon 'attach' @detailsParams

            if ($DeleteAfterUpload) {
                try {
                    Remove-Item -Path $FilePath -Force
                    Add-LogEntry -Message "Deleted file after upload: $FilePath" -Icon 'cleanup' @detailsParams
                }
                catch {
                    Add-LogEntry -Message "⚠️ Failed to delete file after upload: $FilePath" -Icon 'warning' @detailsParams
                }
            }
        }
        else {
            Add-LogEntry -Message "❌ Failed to confirm attachment of '$finalName' to ticket #$TicketID." -Icon 'TicketHandling' @detailsParams
        }
    }
    catch {
        Add-LogEntry -Message "❌ Exception during ticket file attachment: $_" -Icon 'TicketHandling' @detailsParams
    }
}
#endregion

#region File: Apply-StorageSenseSettings.ps1
function Apply-StorageSenseSettings {
    param (
        [Parameter(Mandatory)]
        $Settings,
        [string[]]$Buffer = @('StorageSenseSettings'),
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $StorageSenseKeys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy\'

    $regMap = @{
        '01'                     = 1
        '04'                     = $Settings.ClearTemporaryFiles
        '08'                     = $Settings.ClearRecycler
        '32'                     = $Settings.ClearDownloads
        '256'                    = $Settings.ClearRecyclerDays
        '512'                    = $Settings.ClearDownloadsDays
        '2048'                   = $Settings.PrefSched
        'CloudfilePolicyConsent' = $Settings.AllowClearOneDriveCache
    }

    foreach ($key in $regMap.Keys) {
        try {
            Set-ItemProperty -Path $StorageSenseKeys -Name $key -Value $regMap[$key] -Type DWord -Force
            Add-LogEntry "Set registry ${key} to $($regMap[$key])" @detailsParams -Icon settings
        }
        catch {
            Add-LogEntry "Failed to set registry ${key}: $_" @detailsParams -Icon settings
        }
    }
    Add-LogEntry "Finished." -Icon 'completed' @summaryParams
}
#endregion

#region File: Approve.ps1
Approve([DrRecommendation[]] $allRecommendations) {
        if (-not $this.CommandToRun -or $this.CommandToRun -eq 'n\a') {
            return $false
        }

        $existing = $allRecommendations | Where-Object {
            $_.CommandToRun -eq $this.CommandToRun -and $_.Approved -eq $true -and $_.NumericId -ne $this.NumericId
        }

        if ($existing.Count -gt 0) {
            return $false
        }

        $this.Approved = $true
        return $this.Save()
    }
#endregion

#region File: Approve-DrRecommendation.ps1
function Approve-DrRecommendation {
    [CmdletBinding()]
    param (
        [int] $NumericId,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $rawList = Get-DrRecommendations
    if (-not $rawList -or $rawList.Count -eq 0) {
        Add-LogEntry -Message "⚪ No recommendations found to approve." -Icon 'SettingsOverride' @summaryParams
        return
    }

    $target = $rawList | Where-Object { $_.NumericId -eq $NumericId }
    if (-not $target) {
        Add-LogEntry -Message "Recommendation [$NumericId] not found." -Icon 'error' @summaryParams
        return
    }

    $alreadyApproved = $rawList | Where-Object {
        $_.CommandToRun -eq $target.CommandToRun -and $_.Approved -eq $true -and $_.NumericId -ne $NumericId
    }

    if ($alreadyApproved.Count -gt 0) {
        Add-LogEntry -Message "Another recommendation with the same command is already approved." -Icon 'warning' @summaryParams
        return
    }

    $target.Approved = $true
    $updatedList = $rawList | Where-Object { $_.NumericId -ne $NumericId }
    $updatedList = @($updatedList + $target)

    try {
        $updatedList | ConvertTo-Json -Depth 5 | Set-Content -Path $Global:DrRecommendations -Encoding UTF8
        Add-LogEntry -Message "Recommendation [$NumericId] approved." -Icon 'success' @summaryParams
    }
    catch {
        Add-LogEntry -Message "Failed to save updated recommendations: $($_.Exception.Message)" -Icon 'error' @summaryParams
    }
}
#endregion

#region File: Assert-InteractiveSession.ps1
function Assert-InteractiveSession {
    <#
    Ensures we are running in an interactive user session suitable for showing UI (WPF).
    Previous implementation used `quser | Out-Null` which can throw if `quser` is not available.
    Strategy:
    - If [Environment]::UserInteractive is false -> not interactive
    - If `quser` exists, run it safely and look for any non-header lines
    - Fallback to checking Win32_ComputerSystem.UserName for a logged-in user
    On failure, log and exit (keeps existing behavior expected by callers).
    #>

    # Fast check
    if (-not [Environment]::UserInteractive) {
        Add-LogEntry -Message "Exiting: No interactive user session detected (Environment.UserInteractive = False). WPF prompt will not be shown." -AddBody -Icon 'error'
        exit 1
    }

    # Prefer `quser` when available - run it safely
    $quserCmd = Get-Command quser -ErrorAction SilentlyContinue
    if ($quserCmd) {
        try {
            $qout = & quser 2>$null
        }
        catch {
            $qout = $null
        }

        if ($qout) {
            # Remove header lines and empty lines
            $sessionLines = $qout | Where-Object { $_ -and ($_.Trim() -ne '') }

            # If session lines include the current user (domain\user or user), assume interactive
            $currentUser = $env:USERNAME
            $foundCurrentUser = $false
            foreach ($line in $sessionLines) {
                if ($line -match [regex]::Escape($currentUser)) { $foundCurrentUser = $true; break }
            }

            if ($foundCurrentUser -or ($sessionLines -and $sessionLines.Count -gt 0)) {
                return $true
            }
            else {
                # Do not exit yet; try WMI fallback below because quser output can be empty or unreliable
                Write-Verbose "quser present but returned no obvious interactive sessions; falling back to WMI check"
            }
        }
        else {
            # quser exists but returned nothing; continue to WMI fallback
            Write-Verbose "quser present but no output; falling back to WMI check"
        }
    }

    # Fallback: check for a logged-in user via WMI
    try {
        $loggedIn = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).UserName
    }
    catch {
        $loggedIn = $null
    }

    if ($loggedIn) { return $true }

    Add-LogEntry -Message "Exiting: No interactive user session detected (no quser and no logged-in user). WPF prompt will not be shown." -AddBody -Icon 'error'
    exit 1
}
#endregion

#region File: Assert-IsAdmin.ps1
function Assert-IsAdmin {
    <#
    .SYNOPSIS
        Checks if the current session has administrative privileges.

    .DESCRIPTION
        Returns $true if elevated/admin.
        If not, logs a message and either exits, returns $false, or throws depending on the switch used.
        If none of the switches are specified, defaults to -Return behavior.

    .PARAMETER Exit
        Exits the script immediately if admin rights are missing.

    .PARAMETER Return
        Returns $false if admin rights are missing. (Default)

    .PARAMETER Throw
        Throws a terminating error if admin rights are missing.

    .PARAMETER Buffer
        Logging buffer passed through to Get-LogEntryParams.

    .PARAMETER FlushBuffer
        Flush behavior passed through to Get-LogEntryParams.
    #>

    [CmdletBinding(DefaultParameterSetName = 'Return')]
    [OutputType([bool])]
    param(
        [Parameter()]
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,

        [Parameter()]
        [switch]$FlushBuffer,

        [Parameter(ParameterSetName = 'Exit')]
        [switch]$Exit,

        [Parameter(ParameterSetName = 'Return')]
        [switch]$Return,

        [Parameter(ParameterSetName = 'Throw')]
        [switch]$Throw
    )

    $caller = if ((Get-PSCallStack).Count -gt 1) { (Get-PSCallStack)[1].FunctionName } else { 'Assert-IsAdmin' }

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary

    if (-not (Test-IsElevated)) {
        $msg = "$caller requires administrative privileges. Please run as administrator."
        Add-LogEntry -Message $msg -Icon 'lock' @summaryParams

        if ($Exit) {
            exit 1
        }
        elseif ($Throw) {
            throw $msg
        }
        else {
            return $false
        }
    }

    return $true
}
#endregion

#region File: Block-PersonalMicrosoftAccounts.ps1
function Block-PersonalMicrosoftAccounts {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('On', 'Off')]
        [string]$State,

        [string]$Domain,

        [switch]$Edge,
        [switch]$System
    )

    if (-not (Assert-IsAdmin @PSBoundParameters)) { return }

    try {
        # 🔐 Validate domain format if supplied
        if ($Domain -and $Domain -notmatch '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
            Add-LogEntry -Message "Invalid domain format: $Domain" -AddBody -Icon 'error'
            return
        }

        if ($System) {
            $Value = if ($State -eq 'On') { 3 } else { 0 }

            # 📁 Ensure registry paths exist
            $Path2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"
            if (-not (Test-Path -Path $Path2)) {
                New-Item -Path $Path2 -Force | Out-Null
            }

            Set-ItemProperty -Path $Path2 -Name BlockMicrosoftAccounts -Value $Value -Force
            $message2 = if ($State -eq 'On') {
                "🛡️ Microsoft accounts blocked for Windows login."
            }
            else {
                "✅ Microsoft accounts unblocked for Windows login."
            }
            Add-LogEntry -Message $message2 -AddToBody

            # 🎯 Apply "Accounts: Block Microsoft accounts" policy
            $PolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
            if (-not (Test-Path -Path $PolicyPath)) {
                New-Item -Path $PolicyPath -Force | Out-Null
            }

            $PolicyValue = if ($State -eq 'On') { 3 } else { 0 }
            Set-ItemProperty -Path $PolicyPath -Name NoConnectedUser -Value $PolicyValue -Force
            $message3 = if ($State -eq 'On') {
                "🔒 'Accounts: Block Microsoft accounts' policy applied."
            }
            else {
                "✅ 'Accounts: Block Microsoft accounts' policy removed."
            }
            Add-LogEntry -Message $message3 -AddToBody
        }

        if ($Edge) {
            # 🧭 Edge domain sign-in restriction
            $EdgePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            if (-not (Test-Path -Path $EdgePath)) {
                New-Item -Path $EdgePath -Force | Out-Null
            }

            $EdgeValue = if ($State -eq 'On') {
                if ($Domain) { "*@$Domain" } else { '""' }
            }
            else {
                "*"
            }

            Set-ItemProperty -Path $EdgePath -Name RestrictSigninToPattern -Value $EdgeValue -Force

            $message = if ($State -eq 'On') {
                if ($Domain) {
                    "🌐 Edge sign-in restricted to domain: $Domain."
                }
                else {
                    "🚫 Edge sign-in restricted to no accounts."
                }
            }
            else {
                "✅ Edge sign-in restriction removed."
            }

            Add-LogEntry -Message $message -AddToBody
        }

        Add-LogEntry -Message "✅ Operation completed successfully." -AddBody
    }
    catch {
        $errorMessage = "An error occurred: $_" 
        Add-LogEntry -Message $errorMessage -AddBody -Icon 'error'
    }
}
#endregion

#region File: Call-KabutoApi.ps1
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
#endregion

#region File: Clean-DrFolder.ps1
function Clean-DrFolder {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$EmptyOnly,
        [switch]$Delete,
        [string[]]$Buffer = @('Clean-DrFolder'),
        [switch]$FlushBuffer,
        [int]$Age = 30  # days; Age=0 means "ignore age"
    )


    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    Log-Invocation -IncludeParameters @detailsParams 

    # -----------------------
    # Validation (accumulate)
    # -----------------------
    $errors = 0
    $resolvedPath = $null

    if (-not $Path) {
        Add-LogEntry "Path not specified." -Icon 'Error' @detailsParams
        $errors++
    }
    elseif (-not (Test-Path -LiteralPath $Path)) {
        Add-LogEntry "Path not found: $Path" -Icon 'Error' @detailsParams
        $errors++
    }
    else {
        try {
            $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        }
        catch {
            Add-LogEntry ("Unable to resolve path: {0} — {1}" -f $Path, $_.Exception.Message) -Icon 'Error' @detailsParams
            $errors++
        }
    }

    if ($Age -lt 0) {
        Add-LogEntry ("Invalid Age: {0}. Age must be >= 0." -f $Age) -Icon 'Error' @detailsParams
        $errors++
    }

    if ($resolvedPath) {
        # Protect exact roots only (equality); no allow-list
        $criticalRoots = @("$env:SystemDrive\", "C:\Windows", "C:\Program Files", "C:\Program Files (x86)")
        $normResolved = ($resolvedPath.Trim()).TrimEnd('\').ToLowerInvariant()
        $criticalNorms = $criticalRoots | ForEach-Object { ($_.Trim()).TrimEnd('\').ToLowerInvariant() }
        if ($criticalNorms -contains $normResolved) {
            Add-LogEntry ("Blocked: {0} is a protected system path." -f $resolvedPath) -Icon 'BlockedAction' @detailsParams
            $errors++
        }
    }

    if ($errors) {
        Add-LogEntry ("Validation failed: {0} error(s)." -f $errors) -Icon 'Error' @summaryParams
        return [PSCustomObject]@{
            Path                = $Path
            EmptyOnly           = [bool]$EmptyOnly
            Delete              = [bool]$Delete
            Age                 = $Age
            PlannedItems        = 0
            ItemsDeleted        = 0
            PlannedFolderDelete = $false
            FolderWasDeleted    = $false
            ItemsStatus         = "items to be deleted"
            FolderStatus        = "folder to be deleted"
            Errors              = $errors
        }
    }

    # -----------------------
    # Execution
    # -----------------------
    $itemsDeleted = 0
    $folderWasDeleted = $false
    $plannedItems = 0
    $plannedFolderDelete = $false

    # Age handling
    $ignoreAge = ($Age -eq 0)
    $cutoff = if ($ignoreAge) { $null } else { (Get-Date).AddDays( - [double]$Age) }

    # Enumerate children; if enumeration fails we still summarize
    try {
        $children = Get-ChildItem -LiteralPath $resolvedPath -Force -ErrorAction Stop
    }
    catch {
        Add-LogEntry ("Error enumerating '{0}': {1}" -f $resolvedPath, $_.Exception.Message) -Icon 'Error' @detailsParams
        $errors++
        $children = @()
    }

    # Evaluate eligibility for all children (accumulate regardless of -Delete)
    foreach ($child in $children) {
        $targetPath = $child.FullName
        $isDir = $child.PSIsContainer
        $attrs = $child.Attributes
        $isReparse = ($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0

        # Age rule: Age=0 -> ignore age (all items eligible), else LastWriteTime <= cutoff
        $isOldEnough = $ignoreAge -or ($child.LastWriteTime -le $cutoff)

        if ($isOldEnough) {
            $plannedItems++

            if ($Delete) {
                try {
                    if ($isReparse -and $isDir) {
                        # Directory junction/symlink: remove link only (no traversal)
                        Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop -Recurse:$false
                    }
                    elseif ($isDir) {
                        Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop -Recurse
                    }
                    else {
                        Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
                    }
                    $itemsDeleted++
                }
                catch {
                    $errors++
                }
            }
        }
    }

    # Root folder eligibility (for potential deletion of the folder itself)
    # Age=0 -> ignore age: root eligible if not EmptyOnly; otherwise use LastWriteTime
    $rootOldEnough = $false
    if (-not $EmptyOnly) {
        if ($ignoreAge) {
            $rootOldEnough = $true
        }
        else {
            try {
                $rootItem = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
                $rootOldEnough = ($rootItem.LastWriteTime -le $cutoff)
            }
            catch {
                Add-LogEntry ("Error reading root item '{0}': {1}" -f $resolvedPath, $_.Exception.Message) -Icon 'Error' @detailsParams
                $errors++
                $rootOldEnough = $false
            }
        }
    }

    if (-not $EmptyOnly -and $rootOldEnough) {
        $plannedFolderDelete = $true
        if ($Delete) {
            try {
                Remove-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop -Recurse:$false
                $folderWasDeleted = $true
            }
            catch {
                $errors++
            }
        }
    }

    # Dynamic wording for clarity (used in log and returned object)
    $itemsStatus = if ($Delete) { "items deleted" } else { "items to be deleted" }
    $folderStatus = if ($Delete) { "folder deleted" } else { "folder to be deleted" }

    # Single final flush (always includes planned + actual)
    Add-LogEntry ("Summary: Clean-DrFolder complete. Path: {0}; EmptyOnly: {1}; Delete: {2}; Age(days): {3}; PlannedItems: {4}; {5}: {6}; PlannedFolderDelete: {7}; {8}: {9}; Errors: {10}" -f `
            $resolvedPath, [bool]$EmptyOnly, [bool]$Delete, $Age, $plannedItems, $itemsStatus, $itemsDeleted, [bool]$plannedFolderDelete, $folderStatus, [bool]$folderWasDeleted, $errors) -Icon 'Status' @summaryParams

    # Return object (includes dynamic wording fields)
    [PSCustomObject]@{
        Path                = $resolvedPath
        EmptyOnly           = [bool]$EmptyOnly
        Delete              = [bool]$Delete
        Age                 = $Age
        PlannedItems        = $plannedItems
        ItemsDeleted        = $itemsDeleted
        PlannedFolderDelete = [bool]$plannedFolderDelete
        FolderWasDeleted    = [bool]$folderWasDeleted
        ItemsStatus         = $itemsStatus
        FolderStatus        = $folderStatus
        Errors              = $errors
    }
}
#endregion

#region File: Clear-BrowserHistory.ps1
function Clear-BrowserHistory {
    param (
        [string]$Browser,
        [switch]$AllBrowsers,
        [switch]$AllUsers
    )

    # Define browser history paths
    $BrowserPaths = @{
        "Edge"    = "\AppData\Local\Microsoft\Edge\User Data\Default\History"
        "Chrome"  = "\AppData\Local\Google\Chrome\User Data\Default\History"
        "Firefox" = "\AppData\Local\Mozilla\Firefox\Profiles"
        "Brave"   = "\AppData\Local\BraveSoftware\Brave-Browser\User Data\Default\History"
        "Opera"   = "\AppData\Roaming\Opera Software\Opera Stable\History"
        "Vivaldi" = "\AppData\Local\Vivaldi\User Data\Default\History"
        "IE"      = "\AppData\Local\Microsoft\Windows\WebCache\WebCacheV01.dat"
    }

    $UsersToProcess = @()

    if ($AllUsers) {
        $UsersToProcess = Get-ChildItem -Path "C:\Users" | Where-Object { $_.PSIsContainer }
    }
    else {
        $UsersToProcess = @([PSCustomObject]@{ FullName = "$env:USERPROFILE"; Name = "$env:USERNAME" })
    }

    $BrowsersToProcess = @()

    if ($AllBrowsers) {
        $BrowsersToProcess = $BrowserPaths.Keys
    }
    elseif ($Browser) {
        $NormalizedBrowser = $BrowserPaths.Keys | Where-Object { $_.ToLower() -eq $Browser.ToLower() }
        if ($NormalizedBrowser) {
            $BrowsersToProcess = @($NormalizedBrowser)
        }
        else {
            Add-LogEntry "❌ Unsupported browser specified: $Browser" -AddToBody
            return
        }
    }
    else {
        Add-LogEntry "⚠️ No browser specified. Use -Browser or -AllBrowsers." -AddToBody
        return
    }

    foreach ($BrowserName in $BrowsersToProcess) {
        foreach ($UserProfile in $UsersToProcess) {
            if ($BrowserName -eq "Firefox") {
                $ProfileRoot = Join-Path $UserProfile.FullName $BrowserPaths[$BrowserName]
                if (Test-Path $ProfileRoot) {
                    $ProfileDirs = Get-ChildItem -Path $ProfileRoot -Directory -ErrorAction SilentlyContinue
                    foreach ($UserProfile in $ProfileDirs) {
                        $HistoryFile = Join-Path $UserProfile.FullName "places.sqlite"
                        if (Test-Path $HistoryFile) {
                            try {
                                Remove-Item -Path $HistoryFile -Force
                                Add-LogEntry "🦊 Deleted Firefox history for user: $($UserProfile.Name), profile: $($UserProfile.Name)" -AddToBody
                            }
                            catch {
                                Add-LogEntry "❗ Failed to delete Firefox history for user: $($UserProfile.Name), profile: $($UserProfile.Name) - $($_.Exception.Message)" -AddToBody
                            }
                        }
                        else {
                            Add-LogEntry "🔍 Firefox history file not found for user: $($UserProfile.Name), profile: $($UserProfile.Name)" -AddToBody
                        }
                    }
                }
            }
            else {
                $FullHistoryPath = "$($UserProfile.FullName)$($BrowserPaths[$BrowserName])"
                if (Test-Path $FullHistoryPath) {
                    try {
                        Remove-Item -Path $FullHistoryPath -Force
                        Add-LogEntry "Deleted $BrowserName history for user: $($UserProfile.Name)" -AddToBody -Icon 'cleanup'
                    }
                    catch {
                        Add-LogEntry "❗ Failed to delete $BrowserName history for user: $($UserProfile.Name) - $($_.Exception.Message)" -AddToBody
                    }
                }
                else {
                    Add-LogEntry "🔍 $BrowserName history path not found for user: $($UserProfile.Name)" -AddToBody
                }
            }
        }
    }

    Add-LogEntry "✅ Browser history clearing process completed." -AddBody
}
#endregion

#region File: Clear-DiskSpace.ps1
function Clear-DiskSpace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [ValidateSet("Internet", "Basic", "System")]
        [string]$Level = "Basic",

        [int]$DaysToKeep = 30,

        [switch]$LogOnly
    )

    try {
        switch ($Level) {
            "Internet" {
                Add-LogEntry "Scanning browser caches and temp internet files..." -AddToBody -Icon Cleanup

                $targets = @(
                    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\*",
                    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache\*",
                    "$env:APPDATA\Mozilla\Firefox\Profiles\*\cache2\*"
                )

                foreach ($path in $targets) {
                    $files = Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue
                    foreach ($file in $files) {
                        if ($LogOnly) {
                            Add-LogEntry "Would delete: $($file.FullName)" -AddToBody -Icon Cleanup
                        }
                        elseif ($PSCmdlet.ShouldProcess($file.FullName, "Remove browser cache")) {
                            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }

            "Basic" {
                Add-LogEntry "Scanning for basic user-level cleanup..." -AddToBody -Icon Cleanup

                $tempPaths = @("$env:TEMP", "$env:LOCALAPPDATA\Temp")
                foreach ($path in $tempPaths) {
                    Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                        $_.LastWriteTime -lt (Get-Date).AddDays(-$DaysToKeep)
                    } | ForEach-Object {
                        if ($LogOnly) {
                            Add-LogEntry "Would delete: $($_.FullName)" -AddToBody -Icon Cleanup
                        }
                        elseif ($PSCmdlet.ShouldProcess($_.FullName, "Remove temp file")) {
                            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }

                if (-not $LogOnly -and $PSCmdlet.ShouldProcess("Recycle Bin", "Clear")) {
                    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                }
                elseif ($LogOnly) {
                    Add-LogEntry "Would clear Recycle Bin" -AddToBody -Icon Cleanup
                }
            }

            "System" {
                if (-not (IsUserAdmin)) {
                    Add-LogEntry "System-level cleanup requires administrative privileges. Skipping..." -AddBody -Icon Cleanup
                    return
                }

                Add-LogEntry "Scanning for system-level cleanup..." -AddToBody -Icon Cleanup

                $systemPaths = @(
                    "C:\Windows\SoftwareDistribution\Download",
                    "C:\Windows\Temp",
                    "C:\Windows\Prefetch"
                )

                foreach ($path in $systemPaths) {
                    Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                        $_.LastWriteTime -lt (Get-Date).AddDays(-$DaysToKeep)
                    } | ForEach-Object {
                        if ($LogOnly) {
                            Add-LogEntry "Would delete: $($_.FullName)" -AddToBody -Icon Cleanup
                        }
                        elseif ($PSCmdlet.ShouldProcess($_.FullName, "Remove system file")) {
                            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }

                $DrLogsPath = Join-Path (Get-SysVal "DrRoot") (Get-SysVal "LogsPath")
                Get-ChildItem $DrLogsPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                    $_.LastWriteTime -lt (Get-Date).AddDays(-$DaysToKeep)
                } | ForEach-Object {
                    if ($LogOnly) {
                        Add-LogEntry "Would delete: $($_.FullName)" -AddToBody -Icon Cleanup
                    }
                    elseif ($PSCmdlet.ShouldProcess($_.FullName, "Remove old log file")) {
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        Add-LogEntry "Disk cleanup completed for level: $Level (Files older than $DaysToKeep days)" -AddBody -Icon Cleanup
    }
    catch {
        Add-LogEntry "Disk cleanup failed: $_" -AddBody -Icon Cleanup
    }
}
#endregion

#region File: Clone.ps1
Clone() {
        $clone = [DrRecommendation]::new()
        $clone.SourceFunction = $this.SourceFunction
        $clone.Message = $this.Message
        $clone.SuggestedAction = $this.SuggestedAction
        $clone.Severity = $this.Severity
        $clone.Tags = $this.Tags
        $clone.CommandToRun = $this.CommandToRun
        $clone.ExecutionOrder = $this.ExecutionOrder
        $clone.Approved = $false
        $clone.Executed = $false
        $clone.Success = $false
        $clone.ExecutionOutput = $null
        $clone.ExecutionTimestamp = $null
        return $clone
    }
#endregion

#region File: Clone-DrRecommendation.ps1
function Clone-DrRecommendation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [int] $NumericId,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $original = Get-Recommendations -NumericId $NumericId
    if (-not $original) {
        Add-LogEntry -Message "❌ Recommendation [$NumericId] not found." -Icon 'System' @summaryParams
        return
    }

    $clone = $original.Clone()
    if (-not $clone.Validate()) {
        Add-LogEntry -Message "⚠️ Cloned recommendation is missing required fields." -Icon 'System' @summaryParams
        return
    }

    if (-not $clone.Save()) {
        Add-LogEntry -Message "❌ Failed to save cloned recommendation." -Icon 'System' @summaryParams
        return
    }

    Add-LogEntry -Message "📋 Cloned recommendation [$NumericId] → New [$($clone.NumericId)]: $($clone.Message)" -Icon 'System' @summaryParams
}
#endregion

#region File: Close-Ticket.ps1
function Close-Ticket {
    param (
        [string[]]$Buffer = 'close-ticket',
        [switch]$FlushBuffer = $true
    )
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    if ($null -ne $Global:DrTicket) {

        # Update ticket status to 'Resolved'
        Update-Ticket -Status "Resolved"

        # Log ticket closure with category for icon mapping
        #Add-LogEntry -Message "Ticket $Global:DrTicket closed." -AddBody -LogActivity -Icon 'TicketClosed' 
        Add-LogEntry -Message "Ticket $Global:DrTicket closed." -LogActivity -Buffer *all -FlushBuffer -Icon 'TicketClosed' 

        if ($Global:DrAsset.asset.properties.Ticket -eq $Global:DrTicket) {
            # Clear ticket from asset
            $Global:DrAsset.asset.properties.Ticket = $null

            # IMPORTANT: Clear $Global:DrTicket before calling Set-AssetTicket
            # because Set-AssetTicket uses this variable to update the asset.
            $Global:DrTicket = $null
            $Global:DrTicketId = $null

            # Update asset ticket field only if match
            #Set-AssetTicket -ticketNumber $null
            write-host Global:DrTicket: $Global:DrTicket
            $null = Set-AssetTicket $null
        }

        # Always clear global ticket variables after everything
        $Global:DrTicket = $null
        $Global:DrTicketId = $null
    }
    else {
        # Log when no active ticket exists
        Add-LogEntry -Message "No active ticket to close." @summaryParams -Icon 'Error'
    }
}
#endregion

#region File: Compare-AccountSnapshots.ps1
function Compare-AccountSnapshots {
    [CmdletBinding()]
    param (
        [string]$BaselinePath = $Global:DrAcctBaselinePath,
        [switch]$UpdateBaseline,
        [string]$DiffReportPath,  # Optional path for exporting the diff report
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        # If baseline doesn't exist, create it
        if (-not (Test-Path $BaselinePath)) {
            Add-LogEntry -Message "📂 No baseline found. Creating initial baseline at $BaselinePath." -Icon "Compare" @summaryParams
            $null = Get-LocalAccountSnapshot -ExportPath $BaselinePath -UpdateBaseline:$true @summaryParams

            return [PSCustomObject]@{
                BaselineCreated   = $true
                BaselineTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Added             = @()
                Removed           = @()
                Changed           = @()
                ChangedDetails    = @()
                AddedCount        = 0
                RemovedCount      = 0
                ChangedCount      = 0
            }
        }

        # Load baseline
        $oldData = Get-Content -Path $BaselinePath -Raw | ConvertFrom-Json
        $oldTimestamp = $oldData.Timestamp
        $oldSnapshot = $oldData.Accounts

        # Current snapshot
        $currentTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $currentAccounts = Get-LocalAccountSnapshot @detailsParams

        # Extract names for Compare-Object
        $oldNames = $oldSnapshot.Name
        $newNames = $currentAccounts.Name

        # Compare for added/removed
        $diff = Compare-Object -ReferenceObject $oldNames -DifferenceObject $newNames
        $addedNames = ($diff | Where-Object { $_.SideIndicator -eq '=>' }).InputObject
        $removedNames = ($diff | Where-Object { $_.SideIndicator -eq '<=' }).InputObject

        # Resolve full objects
        $added = $currentAccounts | Where-Object { $addedNames -contains $_.Name }
        $removed = $oldSnapshot  | Where-Object { $removedNames -contains $_.Name }

        # Detect changed accounts (ignore LastLogon) + capture what changed
        $changedDetails = foreach ($name in ($oldNames | Where-Object { $newNames -contains $_ })) {

            $old = $oldSnapshot     | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            $new = $currentAccounts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($null -eq $old -or $null -eq $new) { continue }

            $diffs = @()

            if ($old.Enabled -ne $new.Enabled) {
                $diffs += "Enabled: $($old.Enabled) -> $($new.Enabled)"
            }

            if ($old.PasswordNeverExpires -ne $new.PasswordNeverExpires) {
                $diffs += "PasswordNeverExpires: $($old.PasswordNeverExpires) -> $($new.PasswordNeverExpires)"
            }

            # Groups might be string or array; normalize for compare output
            $oldGroups = @($old.Groups) -join ','
            $newGroups = @($new.Groups) -join ','

            if ($oldGroups -ne $newGroups) {
                $diffs += "Groups: $oldGroups -> $newGroups"
            }

            if ($old.SecurityFlags -ne $new.SecurityFlags) {
                $diffs += "SecurityFlags: $($old.SecurityFlags) -> $($new.SecurityFlags)"
            }

            if ($diffs.Count) {
                [PSCustomObject]@{
                    Name    = $name
                    Changes = $diffs
                    Old     = $old
                    New     = $new
                }
            }
        }

        # Keep $changed as the "new" objects for your existing return/report shape
        $changed = @($changedDetails | ForEach-Object { $_.New })

        # Determine category for each section
        $addedCategory = if ($added.Count) { "Warning" } else { "Security" }
        $removedCategory = if ($removed.Count) { "Warning" } else { "Security" }
        $changedCategory = if ($changed.Count) { "Warning" } else { "Security" }

        # If any changes detected, log warning summary
        if ($added.Count -or $removed.Count -or $changed.Count) {
            Add-LogEntry -Message "⚠️ Account changes detected since last baseline." -Icon "Warning" @detailsParams
        }

        # Log summary
        Add-LogEntry -Message "✅ Account comparison complete. Baseline: $oldTimestamp → Current: $currentTimestamp" -Icon "Security" @detailsParams
        Add-LogEntry -Message "➕ Added accounts: $($added.Name -join ', ')" -Icon $addedCategory @detailsParams
        Add-LogEntry -Message "➖ Removed accounts: $($removed.Name -join ', ')" -Icon $removedCategory @detailsParams
        Add-LogEntry -Message "✏️ Changed accounts: $($changed.Name -join ', ')" -Icon $changedCategory @detailsParams

        # Log what changed (per account)
        if ($changedDetails.Count) {
            foreach ($c in $changedDetails) {
                Add-LogEntry -Message "Account '$($c.Name)' changes: $($c.Changes -join '; ')" -Icon "Warning" @detailsParams
            }
        }

        # Update baseline if requested
        $baselineUpdated = $false
        if ($UpdateBaseline -and ($added.Count -or $removed.Count -or $changed.Count)) {
            $exportObject = [PSCustomObject]@{ Timestamp = $currentTimestamp; Accounts = $currentAccounts }
            $folder = Split-Path $BaselinePath
            if (-not (Test-Path $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
            $exportObject | ConvertTo-Json -Depth 4 | Set-Content -Path $BaselinePath -Encoding UTF8
            Add-LogEntry -Message "📂 Baseline updated at $BaselinePath on $currentTimestamp." -Icon "Security" @detailsParams
            $baselineUpdated = $true
        }

        # Export diff report if path provided
        if ($DiffReportPath) {
            $reportObject = [PSCustomObject]@{
                BaselineTimestamp = $oldTimestamp
                CurrentTimestamp  = $currentTimestamp
                Added             = $added
                Removed           = $removed
                Changed           = $changed
                ChangedDetails    = $changedDetails
                AddedCount        = $added.Count
                RemovedCount      = $removed.Count
                ChangedCount      = $changed.Count
                BaselineUpdated   = $baselineUpdated
            }

            $folder = Split-Path $DiffReportPath
            if (-not (Test-Path $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
            $reportObject | ConvertTo-Json -Depth 6 | Set-Content -Path $DiffReportPath -Encoding UTF8
            Add-LogEntry -Message "📝 Diff report exported to $DiffReportPath." -Icon "Compare" @detailsParams
        }

        Add-LogEntry -Message "🔚 End of comparison." -Icon "Compare" @summaryParams

        return [PSCustomObject]@{
            BaselineTimestamp = $oldTimestamp
            CurrentTimestamp  = $currentTimestamp
            Added             = $added
            Removed           = $removed
            Changed           = $changed
            ChangedDetails    = $changedDetails
            AddedCount        = $added.Count
            RemovedCount      = $removed.Count
            ChangedCount      = $changed.Count
            BaselineUpdated   = $baselineUpdated
            DiffReportPath    = $DiffReportPath
        }
    }
    catch {
        Add-LogEntry -Message "Failed to compare snapshots: $_" -Icon "Error" @summaryParams
        Write-Error $_
    }
}
#endregion

#region File: Compare-AccountSnapshots1.ps1
function Compare-AccountSnapshots1 {
    [CmdletBinding()]
    param (
        [string]$BaselinePath = $Global:DrAcctBaselinePath,
        [switch]$UpdateBaseline,
        [string]$DiffReportPath,  # Optional path for exporting the diff report
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details


    try {
        # If baseline doesn't exist, create it
        if (-not (Test-Path $BaselinePath)) {
            Add-LogEntry -Message "📂 No baseline found. Creating initial baseline at $BaselinePath." -Icon "Compare" @summaryParams
            $null = Get-LocalAccountSnapshot -ExportPath $BaselinePath -UpdateBaseline:$true @summaryParams
            return [PSCustomObject]@{
                BaselineCreated   = $true
                BaselineTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Added             = @()
                Removed           = @()
                Changed           = @()
                AddedCount        = 0
                RemovedCount      = 0
                ChangedCount      = 0
            }
        }

        # Load baseline
        $oldData = Get-Content -Path $BaselinePath -Raw | ConvertFrom-Json
        $oldTimestamp = $oldData.Timestamp
        $oldSnapshot = $oldData.Accounts

        # Current snapshot
        $currentTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $currentAccounts = Get-LocalAccountSnapshot @detailsParams

        # Extract names for Compare-Object
        $oldNames = $oldSnapshot.Name
        $newNames = $currentAccounts.Name

        # Compare for added/removed
        $diff = Compare-Object -ReferenceObject $oldNames -DifferenceObject $newNames
        $addedNames = ($diff | Where-Object { $_.SideIndicator -eq '=>' }).InputObject
        $removedNames = ($diff | Where-Object { $_.SideIndicator -eq '<=' }).InputObject

        # Resolve full objects
        $added = $currentAccounts | Where-Object { $addedNames -contains $_.Name }
        $removed = $oldSnapshot     | Where-Object { $removedNames -contains $_.Name }

        # Detect changed accounts (ignore LastLogon)
        $changed = foreach ($name in ($oldNames | Where-Object { $newNames -contains $_ })) {
            $old = $oldSnapshot | Where-Object { $_.Name -eq $name }
            $new = $currentAccounts | Where-Object { $_.Name -eq $name }
            if ($old.Enabled -ne $new.Enabled -or
                ($old.Groups -join ',') -ne ($new.Groups -join ',') -or
                $old.PasswordNeverExpires -ne $new.PasswordNeverExpires -or
                $old.SecurityFlags -ne $new.SecurityFlags) { $new }
        }

        # Determine category for each section
        $addedCategory = if ($added.Count) { "Warning" } else { "Security" }
        $removedCategory = if ($removed.Count) { "Warning" } else { "Security" }
        $changedCategory = if ($changed.Count) { "Warning" } else { "Security" }

        # If any changes detected, log warning summary
        if ($added.Count -or $removed.Count -or $changed.Count) {
            Add-LogEntry -Message "⚠️ Account changes detected since last baseline." -Icon "Warning" @detailsParams
        }

        # Log summary
        Add-LogEntry -Message "✅ Account comparison complete. Baseline: $oldTimestamp → Current: $currentTimestamp" -Icon "Security" @detailsParams
        Add-LogEntry -Message "➕ Added accounts: $($added.Name -join ', ')" -Icon $addedCategory @detailsParams
        Add-LogEntry -Message "➖ Removed accounts: $($removed.Name -join ', ')" -Icon $removedCategory @detailsParams
        Add-LogEntry -Message "✏️ Changed accounts: $($changed.Name -join ', ')" -Icon $changedCategory @detailsParams

        # Update baseline if requested
        $baselineUpdated = $false
        if ($UpdateBaseline -and ($added.Count -or $removed.Count -or $changed.Count)) {
            $exportObject = [PSCustomObject]@{ Timestamp = $currentTimestamp; Accounts = $currentAccounts }
            $folder = Split-Path $BaselinePath
            if (-not (Test-Path $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
            $exportObject | ConvertTo-Json -Depth 4 | Set-Content -Path $BaselinePath -Encoding UTF8
            Add-LogEntry -Message "📂 Baseline updated at $BaselinePath on $currentTimestamp." -Icon "Security" @detailsParams
            $baselineUpdated = $true
        }

        # Export diff report if path provided
        if ($DiffReportPath) {
            $reportObject = [PSCustomObject]@{
                BaselineTimestamp = $oldTimestamp
                CurrentTimestamp  = $currentTimestamp
                Added             = $added
                Removed           = $removed
                Changed           = $changed
                AddedCount        = $added.Count
                RemovedCount      = $removed.Count
                ChangedCount      = $changed.Count
                BaselineUpdated   = $baselineUpdated
            }
            $folder = Split-Path $DiffReportPath
            if (-not (Test-Path $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
            $reportObject | ConvertTo-Json -Depth 4 | Set-Content -Path $DiffReportPath -Encoding UTF8
            Add-LogEntry -Message "📝 Diff report exported to $DiffReportPath." -Icon "Compare" @detailsParams
        }

        Add-LogEntry -Message "🔚 End of comparison." -Icon "Compare" @summaryParams

        return [PSCustomObject]@{
            BaselineTimestamp = $oldTimestamp
            CurrentTimestamp  = $currentTimestamp
            Added             = $added
            Removed           = $removed
            Changed           = $changed
            AddedCount        = $added.Count
            RemovedCount      = $removed.Count
            ChangedCount      = $changed.Count
            BaselineUpdated   = $baselineUpdated
            DiffReportPath    = $DiffReportPath
        }
    }
    catch {
        Add-LogEntry -Message "Failed to compare snapshots: $_" -Icon "Error" @summaryParams
        Write-Error $_
    }
}
#endregion

#region File: Compare-Version.ps1
function Compare-Version {
    param (
        [version]$specifiedVersion
    )

    if (-not $Global:DrModuleVersion) {
        Add-LogEntry -Message "DrModuleVersion is not set." -AddBody -Icon 'error'
        Send-DrAlert -Category 'DrModuleV3' -Body "DrModuleVersion is not set."
        return
    }

    try {
        $parsedVersion = [version]$Global:DrModuleVersion
    }
    catch {
        Add-LogEntry -Message "Failed to parse DrModuleVersion: '$Global:DrModuleVersion'" -AddBody -Icon 'error'
        Send-DrAlert -Category 'DrModuleV3' -Body "Failed to parse DrModuleVersion: '$Global:DrModuleVersion'"
        return
    }

    if ($parsedVersion -lt $specifiedVersion) {
        Send-DrAlert -Category 'DrModuleV3' -Body "DrModuleV3 is out of date." -AddToBody
        Add-LogEntry -Message "DrModuleV3 is out of date." -AddToBody -Icon 'warning'
        Add-LogEntry "The parsed version ($parsedVersion) is older than the specified version ($specifiedVersion)." -AddToBody -Icon 'warning'
    }
    else {
        Add-LogEntry -Message "DrModuleV3 is current." -AddToBody -Icon 'success'
        Add-LogEntry "The parsed version ($parsedVersion) is the same as or newer than the specified version ($specifiedVersion)." -AddToBody -Icon 'jobcheck'
    }

    Add-LogEntry "End of Compare-Version" -AddBody -Icon 'completed'
}
#endregion

#region File: Complete-Job.ps1
function Complete-Job {
    try {
        # Complete-Job:
        # Prepares logs for ticket attachment, zips them, attaches to ticket,
        # cleans up job root, and closes the ticket if present.

        $logParams = Get-LogEntryParams -Buffer 'Completed' -FlushBuffer
        $detailsParams = $logParams.Details
        $summaryParams = $logParams.Summary


        Log-Invocation -IncludeParameters @detailsParams

        #        Add-LogEntry "Flushing buffers" -Icon 'flush' -Buffer *all -FlushBuffer

        #        Update-LogBuffer -Buffers *all -Flush

        $Global:DrZipFile = $null

        if ($Global:DrTicket) {
            $Global:DrZipFile = "$Global:DrTicket.zip"
        }
        elseif ($Global:DrSessionId) {
            $Global:DrZipFile = "$Global:DrSessionId.zip"
        }

        if ($Global:DrZipFile) {
            Add-LogEntry -Message "📦 Preparing logs for ticket attachment" @detailsParams
            
            if ($Global:DrTicket) {
                Add-FilesToZip -ZipName $Global:DrZipFile -Paths $Global:DrLogs @detailsParams

                Add-LogEntry -Message "📤 Attaching logs to ticket" @detailsParams
                Add-TicketFile -FilePath $Global:DrZipFile @detailsParams
            }
            Add-LogEntry -Message "Cleaning up job root" @detailsParams -Icon 'Cleanup'
            #SearchAndDelete-Items -Path $Global:DrJobRoot -Delete -DeletePath -Age 0
            Clean-DrFolder -Path $Global:DrJobRoot -Delete @detailsParams -Age 0

            if ($Global:DrTicket) {
                #Add-LogEntry -Message "✅ Job ended successfully" @summaryParams -LogActivity
                Close-Ticket @summaryParams 
            }
        }
        else {
            Add-LogEntry -Message "ℹ️ No ticket found, skipping ZIP and cleanup" @summaryParams -LogActivity
        }
    }
    catch {
        Add-LogEntry -Message "Complete-Job failed: $($_.Exception.Message)" -Icon 'Error' @summaryParams -LogActivity
    }
}
#endregion

#region File: Configure-OneDriveStoragePolicy.ps1
function Configure-OneDriveStoragePolicy {
    param (
        [Parameter(Mandatory)]
        $Settings,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        $CurrentUserSID = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        $OneDriveKey = 'HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts\Business1\ScopeIdToMountPointPathCache'
        $CurrentSites = Get-ItemProperty -Path $OneDriveKey -ErrorAction SilentlyContinue |
        Select-Object -Property * -ExcludeProperty PSPath, PSParentPath, PSChildname, PSDrive, PSProvider

        foreach ($site in $CurrentSites.PSObject.Properties.Name) {
            $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy\OneDrive!${CurrentUserSID}!Business1|${site}"
            try {
                New-Item -Path $regPath -Force | Out-Null
                New-ItemProperty -Path $regPath -Name '02' -Value 1 -PropertyType DWord -Force | Out-Null
                New-ItemProperty -Path $regPath -Name '128' -Value $Settings.ClearOneDriveCacheDays -PropertyType DWord -Force | Out-Null
                Add-LogEntry "Configured OneDrive site ${site} with 02=1 and 128=$($Settings.ClearOneDriveCacheDays)" @summaryParams -Icon settings
            }
            catch {
                Add-LogEntry "Failed to configure OneDrive site ${site}: $_" @summaryParams -Icon settings
            }
        }
    }
    catch {
        Add-LogEntry "Failed to enumerate OneDrive sites: $_" @summaryParams -Icon settings
    }
}
#endregion

#region File: Convert-GraphToPs.ps1
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
#endregion

#region File: Convert-PrefixToMask.ps1
function Convert-PrefixToMask {
        param([int]$Prefix)
        if ($Prefix -lt 0 -or $Prefix -gt 32) { return $null }
        $bits = ('1' * $Prefix) + ('0' * (32 - $Prefix))
        $octets = 0..3 | ForEach-Object { [convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }
        return ($octets -join '.')
    }
#endregion

#region File: Count-RegistryEntries.ps1
function Count-RegistryEntries {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$regFilePath
    )

    # Read the content of the .reg file
    $regFileContent = Get-Content -Path $regFilePath

    # Initialize the counter
    $entryCount = 0

    # Loop through each line in the file
    foreach ($line in $regFileContent) {
        # Trim leading and trailing whitespace
        $trimmedLine = $line.Trim()

        # Check if the line is a registry key or value entry (ignoring comments and empty lines)
        if ($trimmedLine -match '^\[.*\]$' -or ($trimmedLine -match '^[^;].*=.*$' -and $trimmedLine -ne '')) {
            $entryCount++
        }
    }

    # Return the count of registry entries
    return $entryCount
}
#endregion

#region File: Debug-DumpFiles.ps1
function Debug-DumpFiles {
    [CmdletBinding()]
    param ()

    if (-not (Assert-IsAdmin @PSBoundParameters)) { return }

    try {
        Add-LogEntry -Message "🛠️ Start processing dump files." -AddToBody

        # Log current dump type
        Get-DumpType -AddToBody

        # Auto-detect dump path(s)
        $dumpPaths = @()
        if (Test-Path "C:\Windows\memory.dmp") {
            $dumpPaths += "C:\Windows\memory.dmp"
            Add-LogEntry -Message "📦 Found memory dump at C:\Windows\memory.dmp." -AddToBody -Icon 'install'
        }
        if (Test-Path "C:\Windows\Minidump") {
            $minidumps = Get-ChildItem -Path "C:\Windows\Minidump" -Filter *.dmp
            if ($minidumps.Count -gt 0) {
                Add-LogEntry -Message "📦 Found $($minidumps.Count) minidump file(s) in C:\Windows\Minidump." -AddToBody
                $dumpPaths += $minidumps.FullName
            }
        }

        # Exit early if no dump files
        if ($dumpPaths.Count -eq 0) {
            Add-LogEntry -Message "📭 No dump files found at default locations." -AddBody
            return
        }

        # Install/update WinDbg only if dumps exist
        Set-StoreApp -AppName 'Windbg' -Install -Update

        # Process each dump file
        foreach ($dumpFile in $dumpPaths) {
            Debug-SingleDumpFile -DumpFilePath $dumpFile -AddToBody
        }

        Add-LogEntry -Message "✅ End of job - Subject: 'Process Dump Files'" -AddBody
    }
    catch {
        Add-LogEntry -Message "❌ Exception during dump processing: $($_.Exception.Message)" -Icon "Error" -AddBody
    }
}
#endregion

#region File: Debug-MinidumpFiles.ps1
function Debug-MinidumpFiles {
    param (
        [string]$minidumpDirectory = "C:\Windows\Minidump",
        [string]$outputDirectory = $Global:DrLogs + "minidump\"
    )

    Add-LogEntry -Message "🛠️ Start processing MINIDump files." -AddToBody

    $minidumpFiles = Get-ChildItem -Path $minidumpDirectory -Filter *.dmp

    if (!(Test-Path -Path $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    }

    if ($minidumpFiles.Count -eq 0) {
        Add-LogEntry -Message "📭 No minidump files to process." -AddToBody
    }
    else {
        foreach ($file in $minidumpFiles) {
            $minidumpPath = $file.FullName
            $outputPath = Join-Path -Path $outputDirectory -ChildPath ("output_" + $file.BaseName + ".txt")

            $windbgCommandLine = "-z $minidumpPath -c `"!analyze -v; qqd`" -logo $outputPath"
            Add-LogEntry -Message "⚙️ Processing: $windbgCommandLine" -AddToBody
            Write-Host "⚙️ $windbgCommandLine"

            try {
                $filePath = Find-File -Path "C:\program files\windowsapps" -Name "DbgX.Shell.exe"
                $process = Start-Process -FilePath "$filePath" -ArgumentList $windbgCommandLine -NoNewWindow -PassThru
                Write-Host "⏳ Sleeping..."

                Start-Sleep -Seconds 60

                if (!$process.HasExited) {
                    Stop-Process -Id $process.Id -Force
                }
            }
            catch {
                Add-LogEntry -Message "Failed to start or stop WinDbg process: $_" -AddToBody -Icon 'error'
                continue
            }

            while ($true) {
                try {
                    $logContent = [System.IO.File]::ReadAllText($outputPath)
                    Add-LogEntry -Message "📄 Output Log:`n$logContent" -AddBody
                    break
                }
                catch [System.IO.IOException] {
                    Start-Sleep -Seconds 5
                }
            }

            $line = Select-String -Path $outputPath -Pattern "BUGCHECK_CODE:"
            $bugcheck = $line.Line.Split(":")[1].Trim()
            Add-LogEntry -Message "🧩 Bug Check Code: $bugcheck" -AddToBody

            $line = Select-String -Path $outputPath -Pattern "PROCESS_NAME:"
            $processName = $line.Line.Split(":")[1].Trim()
            Add-LogEntry -Message "Process Name: $processName" -AddToBody -Icon 'search'
            Write-Output "🔍 Process Name: $processName" 

            $line = Select-String -Path $outputPath -Pattern "MODULE_NAME:"
            $moduleName = $line.Line.Split(":")[1].Trim()
            Add-LogEntry -Message "📦 Module Name: $moduleName" -AddToBody

            try {
                Move-Item -Path $minidumpPath -Destination $outputDirectory
                Add-LogEntry -Message "📁 Moved minidump file: $minidumpPath to $outputDirectory" -AddToBody
            }
            catch {
                Add-LogEntry -Message "❗ Failed to move minidump file: $_" -AddToBody
            }

            Add-LogEntry "------------------------" -AddBody
        }
    }

    Add-LogEntry -Message "✅ End of job - Subject: 'Process Minidump files.'" -AddBody
}
#endregion

#region File: Debug-SingleDumpFile.ps1
function Debug-SingleDumpFile {
    param (
        [string]$DumpFilePath,
        [switch]$AddToBody
    )

    try {
        # Create unique folder for this dump file under DrTemp
        $safeName = ([System.IO.Path]::GetFileNameWithoutExtension($DumpFilePath)) -replace '[^a-zA-Z0-9]', '_'
        $outputDir = Join-Path -Path $Global:DrTemp -ChildPath $safeName
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir | Out-Null
        }

        # Output log path
        $outputPath = Join-Path -Path $outputDir -ChildPath "analysis.txt"

        # Build WinDbg arguments
        $appargs = "-z `"$DumpFilePath`" -c `"!analyze -v; qqd`" -logo `"$outputPath`""
        Add-LogEntry -Message "⚙️ Running WinDbg on $DumpFilePath" -AddToBody:$AddToBody -AddBody:(!$AddToBody)

        # Use FindAndRun to locate and execute WinDbg
        FindAndRun -folder "C:\\Program Files\\WindowsApps" -file "DbgX.Shell.exe" -appargs $appargs -wait -Log

        # Wait for log file to be readable
        while ($true) {
            try {
                $logContent = [System.IO.File]::ReadAllText($outputPath)
                Add-LogEntry -Message "📄 Output Log:`n$logContent" -Hidden
                break
            }
            catch [System.IO.IOException] {
                Start-Sleep -Seconds 5
            }
        }

        # Extract key patterns (3 fields)
        foreach ($pattern in @("BUGCHECK_CODE:", "PROCESS_NAME:", "MODULE_NAME:")) {
            $line = Select-String -Path $outputPath -Pattern $pattern
            if ($line) {
                $value = $line.Line.Split(":")[1].Trim()
                $label = switch ($pattern) {
                    "BUGCHECK_CODE:" { "🧩 Bug Check Code" }
                    "PROCESS_NAME:" { "🔍 Process Name" }
                    "MODULE_NAME:" { "📦 Module Name" }
                }
                Add-LogEntry -Message "${label}: $value" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
            }
        }

        # Move the dump file into its analysis folder
        try {
            $destination = Join-Path -Path $outputDir -ChildPath ([System.IO.Path]::GetFileName($DumpFilePath))
            Move-Item -Path $DumpFilePath -Destination $destination -Force
            Add-LogEntry -Message "📁 Moved dump file to $destination" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        }
        catch {
            Add-LogEntry -Message "❗ Failed to move dump file: $($_.Exception.Message)" -Icon "Warning" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        }

        Add-LogEntry "------------------------" -AddBody
    }
    catch {
        Add-LogEntry -Message "❌ Failed during dump analysis: $($_.Exception.Message)" -Icon "Error" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
    }
}
#endregion

#region File: Delete.ps1
Delete() {
        $path = $Global:DrRecommendations
        if (-not (Test-Path $path)) {
            return $false
        }

        try {
            $existingRaw = Get-Content $path -Raw | ConvertFrom-Json
            $existing = @($existingRaw) | Where-Object { $_.NumericId -ne $this.NumericId }
            $existing | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
            return $true
        }
        catch {
            return $false
        }
    }
#endregion

#region File: DrRecommendation.ps1
DrRecommendation() {
        $this.Id = [guid]::NewGuid().ToString()
        $this.Timestamp = Get-Date
    }
#endregion

#region File: DrSecurityReviewx.ps1
function DrSecurityReviewx {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [switch]$Detailed,
        [switch]$SummaryOnly
    )

    try {
        #Import-Module "C:\ProgramData\Syncro\DrOsdicks\bin\DrModuleV3.psm1" -DisableNameChecking

        $showDetails = -not $SummaryOnly

        if ($showDetails) {
            Add-LogEntry -Message "Starting security review..." -Icon "Info" -AddToBody
        }

        # Secure Boot
        Add-LogEntry -Message "Entering Secure Boot check..." -Icon "Info" -AddToBody
        try {
            $secureBoot = Get-SecureBoot -AddToBody:$showDetails
            if ($secureBoot) {
                if ($showDetails) {
                    Add-LogEntry -Message "Secure Boot Enabled: True" -Icon "Shield" -AddToBody
                }
            }
            else {
                Add-DrRecommendation -Message "Secure Boot is disabled." `
                    -SuggestedAction "Enable Secure Boot in BIOS/UEFI" `
                    -Severity "Critical" `
                    -Tags @("Security", "SecureBoot")
            }
        }
        catch {
            if ($showDetails) {
                Add-LogEntry -Message "Secure Boot check failed: $($_.Exception.Message)" -Icon "Warning" -AddToBody
            }
        }

        # TPM Status
        Add-LogEntry -Message "Entering TPM check..." -Icon "Info" -AddToBody
        try {
            $tpm = Get-TpmStatus -AddToBody:$showDetails
            write-host "TPM Present: $tpm.TpmPresent, Ready: $($tpm.TpmReady)"
            if ($showDetails) {
                Add-LogEntry -Message "TPM Present: $($tpm.TpmPresent), Ready: $($tpm.TpmReady)" -Icon "Lock" -AddToBody
            }
            if (-not $tpm.TpmReady) {
                Add-DrRecommendation -Message "TPM is not ready." `
                    -SuggestedAction "Initialize TPM via TPM Management Console" `
                    -Severity "Critical" `
                    -Tags @("Security", "TPM")
            }
        }
        catch {
            if ($showDetails) {
                Add-LogEntry -Message "TPM check failed: $($_.Exception.Message)" -Icon "Warning" -AddToBody
            }
        }

        # BitLocker
        Add-LogEntry -Message "Entering BitLocker check..." -Icon "Info" -AddToBody
        try {
            $bitlockerVolumes = Get-BitLockerKey -All -AddToBody:$showDetails
            foreach ($vol in $bitlockerVolumes) {
                if ($showDetails) {
                    Add-LogEntry -Message "BitLocker on $($vol.VolumeLetter): ProtectionStatus=$($vol.ProtectionStatus), VolumeType=$($vol.VolumeType), EncryptionMethod=$($vol.EncryptionMethod)" -Icon "Disk" -AddToBody
                }
                if ($vol.ProtectionStatus -ne 'On') {
                    Add-DrRecommendation -Message "BitLocker is off on $($vol.VolumeLetter)." `
                        -SuggestedAction "Enable BitLocker encryption" `
                        -Severity "High" `
                        -Tags @("Security", "BitLocker")
                }
            }
        }
        catch {
            if ($showDetails) {
                Add-LogEntry -Message "BitLocker check failed: $($_.Exception.Message)" -Icon "Warning" -AddToBody
            }
        }

        # Antivirus
        Add-LogEntry -Message "Entering AV check..." -Icon "Info" -AddToBody
        try {
            $avProducts = Get-AVProducts -AddToBody:$showDetails
            if ($avProducts.Count -eq 0) {
                Add-DrRecommendation -Message "No antivirus detected." `
                    -SuggestedAction "Install approved antivirus" `
                    -Severity "Critical" `
                    -Tags @("Security", "Antivirus")
            }
        }
        catch {
            if ($showDetails) {
                Add-LogEntry -Message "AV check failed: $($_.Exception.Message)" -Icon "Warning" -AddToBody
            }
        }

        # Firewall
        Add-LogEntry -Message "Entering Firewall check..." -Icon "Info" -AddToBody
        try {
            $firewallProfiles = Get-NetFirewallProfile
            foreach ($profile in $firewallProfiles) {
                if ($showDetails) {
                    Add-LogEntry -Message "$($profile.Name) Firewall Enabled: $($profile.Enabled)" -Icon "Firewall" -AddToBody
                }
                if (-not $profile.Enabled) {
                    Add-DrRecommendation -Message "Firewall disabled for $($profile.Name)." `
                        -SuggestedAction "Enable firewall profile" `
                        -Severity "Critical" `
                        -Tags @("Security", "Firewall")
                }
            }
        }
        catch {
            if ($showDetails) {
                Add-LogEntry -Message "Firewall check failed: $($_.Exception.Message)" -Icon "Warning" @detailsParams
            }
        }

        # Local Account Comparison
        Add-LogEntry -Message "Entering Local Account check..." -Icon "Info" @detailsParams
        try {
            $accountDifferences = Compare-LocalAccount @detailsParams
            if ($showDetails) {
                if ($accountDifferences -and $accountDifferences.Count -gt 0) {
                    Add-LogEntry -Message "Unexpected local accounts detected: $($accountDifferences -join ', ')" -Icon "User" -AddToBody
                }
                else {
                    Add-LogEntry -Message "Local accounts match baseline." -Icon "User" -AddToBody
                }
            }
            if ($accountDifferences -and $accountDifferences.Count -gt 0) {
                Add-DrRecommendation -Message "Unexpected local accounts detected: $($accountDifferences -join ', ')." `
                    -SuggestedAction "Review and remove unauthorized accounts" `
                    -Severity "High" `
                    -Tags @("Security", "Accounts")
            }
        }
        catch {
            if ($showDetails) {
                Add-LogEntry -Message "Local account comparison failed: $($_.Exception.Message)" -Icon "Warning" -AddToBody
            }
        }

        # Final Summary
        $recommendationCount = (Get-DrRecommendations).Count
        Add-LogEntry -Message "Security review completed. Recommendations: $recommendationCount" -Icon "complete" -AddBody

        # Show all recommendations at the end
        Show-DrRecommendations
    }
    catch {
        Add-LogEntry -Message "Error during security review: $($_.Exception.Message) | $($_.ScriptStackTrace)" -Icon "Error" -AddBody
    }
}
#endregion

#region File: Enable-Minidumps.ps1
function Enable-Minidumps {
    <#
    .SYNOPSIS
        Enables minidump creation on Windows systems.

    .DESCRIPTION
        Creates the Minidump folder if missing and sets the CrashDumpEnabled registry value to enable minidumps.
        Requires administrative privileges.

    .NOTES
        Adheres to DrModuleV3 standards including structured logging via Add-LogEntry and admin checks via IsUserAdmin.
    #>

    [CmdletBinding()]
    param (
        [switch]$AddToBody
    )

    if (-not (Assert-IsAdmin @PSBoundParameters)) { return }

    try {
        IsUserAdmin
        $minidumpPath = "C:\Windows\Minidump"

        if (-not (Test-Path -Path $minidumpPath)) {
            New-Item -ItemType Directory -Path $minidumpPath -Force | Out-Null
            Add-LogEntry -Message "🗂️ Minidump folder created at $minidumpPath." -Icon "FileHandling" -AddToBody
        }
        else {
            Add-LogEntry -Message "🗂️ Minidump folder already exists at $minidumpPath." -Icon "FileHandling" -AddToBody
        }

        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $currentValue = Get-ItemProperty -Path $regPath -Name "CrashDumpEnabled" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CrashDumpEnabled

        if ($currentValue -ne 1) {
            Set-ItemProperty -Path $regPath -Name "CrashDumpEnabled" -Value 1
            Add-LogEntry -Message "⚙️ CrashDumpEnabled changed from $currentValue to 1." -Icon "SettingsOverride" -AddToBody
        }
        else {
            Add-LogEntry -Message "⚙️ CrashDumpEnabled already set to 1. No change needed." -Icon "SettingsOverride" -AddToBody
        }

        Add-LogEntry -Message "📋 Minidump setup complete." -Icon "syncroapi" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
    }
    catch {
        Add-LogEntry -Message "Failed to enable minidumps: $($_.Exception.Message)" -Icon "Error" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
    }
}
#endregion

#region File: Ensure-Folder.ps1
function Ensure-Folder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        [ValidateSet('Hidden', 'ReadOnly', 'System')]
        [string[]]$Attributes = $null,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    # Buffering is optional; default handling is decided by Get-LogEntryParams via *Default / Default buffers
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer  
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    try {
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
            Add-LogEntry -Message "Created folder: $Path" -Icon 'FileHandling' @detailsParams
        }

        # Apply attributes only if provided
        if ($Attributes -and (Test-Path -Path $Path)) {
            $folder = Get-Item -Force $Path
            foreach ($attr in $Attributes) {
                $enumAttr = [System.IO.FileAttributes]::$attr
                if (-not ($folder.Attributes -band $enumAttr)) {
                    $folder.Attributes = $folder.Attributes -bor $enumAttr
                    Add-LogEntry -Message "Applied attribute $attr to: $Path" -Icon 'wrench' @detailsParams
                }
            }
        }

        return $Path
    }
    catch {
        Add-LogEntry -Message "Failed to ensure folder: $Path - $($_.Exception.Message)" -Icon 'Error' @summaryParams
        return $null
    }
}
#endregion

#region File: Evaluate-Progression.ps1
function Evaluate-Progression {
    [CmdletBinding()]
    param (
        [string] $TriggerCommand,
        [DrRecommendation[]] $ExecutionHistory
    )

    $rules = Get-ProgressionRules
    $matchedRules = $rules | Where-Object { $_.Trigger -eq $TriggerCommand }

    foreach ($rule in $matchedRules) {
        $executedOk = $true

        foreach ($cmd in $rule.Condition.Executed) {
            $match = $ExecutionHistory | Where-Object {
                $_.CommandToRun -eq $cmd
            }

            if (-not $match) {
                $executedOk = $false
                break
            }

            if ($rule.Condition.Success -ne $null -and $match.Success -ne $rule.Condition.Success) {
                $executedOk = $false
                break
            }
        }

        if ($executedOk) {
            return $rule.Recommend
        }
    }

    return
}
#endregion

#region File: Export.ps1
Export() {
        return [PSCustomObject]@{
            Id                 = $this.Id
            NumericId          = $this.NumericId
            SourceFunction     = $this.SourceFunction
            Message            = $this.Message
            SuggestedAction    = $this.SuggestedAction
            Severity           = $this.Severity
            Tags               = $this.Tags
            Timestamp          = $this.Timestamp
            Approved           = $this.Approved
            ExecutionOrder     = $this.ExecutionOrder
            CommandToRun       = $this.CommandToRun
            Executed           = $this.Executed
            Success            = $this.Success
            ExecutionOutput    = $this.ExecutionOutput
            ExecutionTimestamp = $this.ExecutionTimestamp
        }
    }
#endregion

#region File: FindAndRun.ps1
function FindAndRun {
    param (
        [string]$folder,
        [string]$file,
        [string]$appargs,
        [switch]$wait = $false,
        [switch]$Log = $false,
        [string[]]$Buffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    # Validate parameters
    if (-not $folder) { throw "Folder parameter is required." }
    if (-not $file) { throw "File parameter is required." }

    if ($Log) {
        Log-Invocation -IncludeParameters @detailsParams 
        #Log-Invocation -IncludeParameters
        Add-LogEntry -Message "Starting FindAndRun with parameters: folder=$folder, file=$file, appargs=$appargs, wait=$wait" @detailsParams 
    }

    try {
        $path = Get-ChildItem -Path $folder -Recurse -Filter $file | Select-Object -First 1 -ExpandProperty FullName

        if ($path) {
            if ($wait) {
                Write-Host $path 
                $processResult = Start-Process -FilePath $path -ArgumentList $appargs.Split(' ') -WindowStyle Hidden -Wait:$wait -PassThru
            }
            else {
                $processResult = Start-Process -FilePath $path -ArgumentList $appargs.Split(' ') -WindowStyle Hidden -PassThru
            }

            # Return the result (if needed)
            if ($processResult) {
                if ($Log) {
                    Add-LogEntry -Message "Process completed successfully." @summaryParams  -Icon 'jobend'
                }
                return $processResult
            }
        }
        else {
            if ($Log) {
                Add-LogEntry -Message "File not found." @detailsParams  -Icon 'error'
            }
        }
    }
    catch {
        if ($Log) {
            Add-LogEntry -Message "Error occurred: $_" @summaryParams -Icon 'error'
        }
        throw
    }

    if ($Log) {
        Add-LogEntry -Message "End of FindAndRun" @summaryParams -Icon 'jobend'
    }
}
#endregion

#region File: Find-File.ps1
function Find-File {
    param (
        [string]$Path,
        [string]$Name
    )

    # Validate parameters
    if (-not (Test-Path -Path $Path)) {
        Write-Error "The specified path does not exist."
        return
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Error "The file name cannot be empty."
        return
    }

    # Search for the file
    try {
        $files = Get-ChildItem -Path $Path -Recurse -File | Where-Object { $_.Name -eq $Name }
        if ($files) {
            $files | Select-Object -ExpandProperty FullName
        }
        else {
            Write-Output "No files found with the name '$Name'."
        }
    }
    catch {
        Write-Error "An error occurred while searching for the file: $_"
    }
}
#endregion

#region File: Find-OrInstall-WinDbg.ps1
function Find-OrInstall-WinDbg {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$AddToBody
    )

    function _Find-WinDbg {
        $paths = @(
            "C:\Program Files\Windows Kits\10\Debuggers\x64\windbg.exe",
            "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\windbg.exe",
            "C:\Program Files\Windows Kits\10\Debuggers\x86\windbg.exe",
            "C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\windbg.exe"
        )
        foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $p } }
        return $null
    }

    Add-LogEntry -Message "WinDbg: starting search..." -Icon "search" -AddToBody
    $found = _Find-WinDbg
    if ($found) {
        Add-LogEntry -Message "WinDbg found: $found" -Icon "summary" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        return $found
    }

    $tempDir = $null
    $installerPath = $null
    try {
        $tempDir = Join-Path $env:TEMP ("WinDbgSDK_" + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $installerPath = Join-Path $tempDir "winsdksetup.exe"
        $downloadUrl = "https://go.microsoft.com/fwlink/?linkid=2083338"

        Add-LogEntry -Message "Downloading SDK installer: $downloadUrl" -Icon "download" -AddToBody
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing

        if (-not (Test-Path -LiteralPath $installerPath)) {
            Add-LogEntry -Message "WinDbg not installed (download failed: $installerPath not found)." -Icon "summary" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
            return $null
        }

        Add-LogEntry -Message "Installing Debugging Tools (silent)..." -Icon "install" -AddToBody
        $proc = Start-Process -FilePath $installerPath `
            -ArgumentList "/features OptionId.WindowsDesktopDebuggers /quiet /norestart" `
            -Wait -NoNewWindow -PassThru
        $exit = if ($proc) { $proc.ExitCode } else { $null }
        Add-LogEntry -Message "Installer exit code: $exit" -Icon "info" -AddToBody
    }
    catch {
        Add-LogEntry -Message "WinDbg not installed (install error: $($_.Exception.Message))." -Icon "summary" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        return $null
    }
    finally {
        try {
            if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                Add-LogEntry -Message "Cleaned temp folder." -Icon "cleanup" -AddToBody
            }
        }
        catch {
            Add-LogEntry -Message "Temp cleanup warning: $($_.Exception.Message)" -Icon "warning" -AddToBody
        }
    }

    $found = _Find-WinDbg
    if ($found) {
        Add-LogEntry -Message "WinDbg installed: $found" -Icon "summary" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        return $found
    }
    else {
        Add-LogEntry -Message "WinDbg not installed (still not found after install attempt)." -Icon "summary" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        return $null
    }
}
#endregion

#region File: Format-Num.ps1
function Format-Num {
        param($Value)
        if ($null -eq $Value) { return $null }
        try {
            if ($Value -is [string]) {
                $s = $Value.Trim()
                if ($s -match '^\d+$') { return ('{0:N0}' -f [int64]$s) }
                else { return $Value }  # e.g., VLAN IDs that may include letters
            }
            else {
                return ('{0:N0}' -f [decimal]$Value)
            }
        }
        catch { return $Value }
    }
#endregion

#region File: Format-Value.ps1
function Format-Value {
                param(
                    [AllowNull()][object]$Value,
                    [switch]$ShowTypes,
                    [int]$TruncateLength = 0,
                    [string]$MaskWith = '***',
                    [switch]$Mask
                )
                if ($Mask) { return $MaskWith }
                if ($null -eq $Value) { return '[null]' }

                if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
                    $typeName = $Value.GetType().FullName
                    $count = @($Value).Count
                    if ($ShowTypes) { return "[${typeName}] ($count items)" }
                    return "($count items)"
                }

                $text = [string]$Value
                if ($TruncateLength -gt 0 -and $text.Length -gt $TruncateLength) {
                    $text = $text.Substring(0, $TruncateLength) + '…'
                }
                if ($ShowTypes) {
                    $typeName = $Value.GetType().FullName
                    return "[$typeName] $text"
                }
                return $text
            }
#endregion

#region File: Get-Alerts.ps1
function Get-Alerts {
    [CmdletBinding()]
    param (
        [string]$Type,
        [int]$AssetID = $Global:DrAsset.id,
        [string]$Status = "active"
    )

    try {
        if (-not $Global:DrApiKey) {
            Add-LogEntry -Message "DrApiKey is not set." -Icon "Error" -AddToBody
            Add-LogEntry -AddBody
            return
        }

        if (-not $Global:DrSubDomain) {
            Add-LogEntry -Message "DrSubDomain is not set." -Icon "Error" -AddToBody
            Add-LogEntry -AddBody
            return
        }

        $endpoint = "/api/v1/rmm_alerts?status=$Status"
        $response = Invoke-DrApiRequest -Method 'GET' -Endpoint $endpoint

        if (-not $response.rmm_alerts) {
            Add-LogEntry -Message "No alerts returned from SyncroMSP." -Icon "Warning" -AddToBody
            Add-LogEntry -AddBody
            return @{}
        }

        $filteredAlerts = $response.rmm_alerts

        if ($AssetID) {
            $filteredAlerts = $filteredAlerts | Where-Object { $_.asset_id -eq $AssetID }
        }

        if ($Type) {
            $filteredAlerts = $filteredAlerts | Where-Object { $_.description -eq $Type }
        }

        Add-LogEntry -Message "📡 Retrieved '$Status' alerts from SyncroMSP." -Icon "monitor" -AddToBody
        return @{ rmm_alerts = $filteredAlerts }
    }
    catch {
        Add-LogEntry -Message "Failed to retrieve alerts: $($_.Exception.Message)" -Icon "Error" -AddToBody
        if ($_.ErrorDetails) {
            Add-LogEntry -Message "📄 ErrorDetails: $($_.ErrorDetails.Message)" -Icon "Error" -AddToBody
        }
        Add-LogEntry -AddBody
        return @{}
    }
}
#endregion

#region File: Get-Asset.ps1
function Get-Asset {
    param (
        [int]$AssetId = $Global:DrAsset.id
    )

    try {
        return Invoke-DrApiRequest `
            -Method 'GET' `
            -Endpoint "/api/v1/customer_assets/$AssetId"
    }
    catch {
        Write-Error "Failed to retrieve asset: $_"
    }
}
#endregion

#region File: Get-AVProducts.ps1
function Get-AVProducts {
    [CmdletBinding()]
    param (
        [string[]]$Buffer = "AV Products",
        [switch]$FlushBuffer,
        [switch]$EmitAlerts,            # log per-product alerts/warnings based on severity
        [switch]$IncludeRecommendations # also return a Recommendations array
    )
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    Log-Invocation -IncludeParameters @detailsParams
    Add-LogEntry -Message 'Getting AV products…' -Icon 'systeminit' @detailsParams

    $productsOut = @()
    $recsOut = @()

    try {
        $products = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue

        if (-not $products) {
            Add-LogEntry -Message 'No antivirus products found.' -Icon 'warning' @detailsParams
        }
        else {
            foreach ($p in $products) {
                $displayName = $p.displayName
                $productState = [int]$p.productState

                # Parse bits (aligned with your current logic)
                $sigStatusOk = (($productState -band 0xFF) -eq 0)        # 0 => signatures OK
                $rtEnabled = (($productState -band 0x1000) -ne 0)      # real-time enabled

                # Split fields
                $approval = if ($displayName -match 'Windows Defender|Webroot SecureAnywhere|OpenText.*Core Endpoint Protection') {
                    'Approved'
                }
                else {
                    'Unapproved'
                }

                # "Installed and running" requires both RT enabled and signatures OK
                $operational = if ($rtEnabled -and $sigStatusOk) { 'Running' } else { 'NotRunning' }

                # Severity + icon (your rules)
                switch ("$approval/$operational") {
                    'Approved/Running' { $severity = 'success'; $icon = 'success' }
                    'Unapproved/NotRunning' { $severity = 'Warning'; $icon = 'warning' }
                    'Unapproved/Running' { $severity = 'Alert'; $icon = 'alert' }
                    default { $severity = 'Warning'; $icon = 'warning' } # e.g., Approved/NotRunning
                }

                # Log each product
                Add-LogEntry -Message ("{0} - {1}/{2}" -f $displayName, $approval, $operational) -Icon $icon @detailsParams

                # Optionally echo alerts/warnings distinctly for multi-product clarity
                if ($EmitAlerts -and ($severity -in @('Alert', 'Warning'))) {
                    Add-LogEntry -Message ("{0} severity: {1}" -f $displayName, $severity) -Icon $icon @detailsParams
                }

                # Output object with split fields + technical bits
                $prodObj = [PSCustomObject]@{
                    AntivirusProduct = $displayName
                    Approval         = $approval
                    Operational      = $operational
                    Severity         = $severity
                    ProductState     = ('0x{0:X6}' -f $productState)
                    RealTimeEnabled  = $rtEnabled
                    SignaturesOK     = $sigStatusOk
                }
                $productsOut += $prodObj

                # Optional recommendations for downstream execution
                if ($IncludeRecommendations) {
                    switch ($severity) {
                        'Alert' {
                            # Unapproved + Running
                            $recsOut += [PSCustomObject]@{
                                Id       = [guid]::NewGuid().Guid
                                Title    = "Unapproved AV running: $displayName"
                                Severity = 'Alert'
                                Priority = 1
                                Approved = $false
                                Message  = "Detected unapproved AV actively running. Review policy; consider uninstalling or standardizing to an approved product."
                                Command  = $null # Fill with your uninstall/standardize cmd when ready
                                Context  = $prodObj
                            }
                        }
                        'Warning' {
                            # Either Unapproved + NotRunning (likely stale) OR Approved + NotRunning (needs fix)
                            if ($approval -eq 'Unapproved' -and $operational -eq 'NotRunning') {
                                $recsOut += [PSCustomObject]@{
                                    Id       = [guid]::NewGuid().Guid
                                    Title    = "Unapproved AV not running (possible stale entry): $displayName"
                                    Severity = 'Warning'
                                    Priority = 2
                                    Approved = $false
                                    Message  = "Unapproved AV detected but not running. Consider removing stale WMI entry or uninstalling remnants."
                                    Command  = $null # e.g., Cleanup-AVWmiStale -DisplayName $displayName
                                    Context  = $prodObj
                                }
                            }
                            elseif ($approval -eq 'Approved' -and $operational -eq 'NotRunning') {
                                # Distinguish fix path by RT vs signatures
                                if (-not $rtEnabled) {
                                    $msg = "Approved AV real-time protection is disabled. Enable RT."
                                }
                                elseif (-not $sigStatusOk) {
                                    $msg = "Approved AV signatures not OK. Update signatures."
                                }
                                else {
                                    $msg = "Approved AV not fully operational. Repair AV."
                                }
                                $recsOut += [PSCustomObject]@{
                                    Id       = [guid]::NewGuid().Guid
                                    Title    = "Approved AV needs attention: $displayName"
                                    Severity = 'Warning'
                                    Priority = 2
                                    Approved = $false
                                    Message  = $msg
                                    Command  = $null # e.g., Repair-ApprovedAV -Name $displayName
                                    Context  = $prodObj
                                }
                            }
                        }
                    }
                }
            }
        }

        # Final flush
        Add-LogEntry -Message 'End of AV products' -Icon 'endoflist' @summaryParams
    }
    catch {
        Add-LogEntry -Message ("Get-AVProducts failed: {0}" -f $_.Exception.Message) -Icon 'error' @summaryParams
        throw
    }

    # Return shape:
    if ($IncludeRecommendations) {
        return [PSCustomObject]@{
            Products        = $productsOut
            Recommendations = $recsOut
        }
    }
    else {
        return $productsOut
    }
}
#endregion

#region File: Get-BitLockerKey.ps1
function Get-BitLockerKey {
    param (
        [string[]]$DriveLetter = @($env:SystemDrive),
        [switch]$All,
        [switch]$CreateFile,
        [string[]]$Buffer = @('BitLocker'),
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    Log-Invocation -IncludeParameters @detailsParams 
    if (-not (Assert-IsAdmin @summaryParams)) { return }

    $drivesToProcess = @()
    $successCount = 0
    $failureCount = 0
    $results = @()

    if ($All) {
        try {
            $drivesToProcess = Get-BitLockerVolume | Select-Object -ExpandProperty MountPoint
        }
        catch {
            Add-LogEntry "Failed to retrieve BitLocker volumes: $($_.Exception.Message)" -Icon 'error' @summaryParams
            return
        }
    }
    else {
        $drivesToProcess = $DriveLetter
    }

    foreach ($Drive in $drivesToProcess) {
        try {
            $bitlockerStatus = Get-BitLockerVolume -MountPoint $Drive
            $protectionStatus = $bitlockerStatus.ProtectionStatus
            $volumeType = $bitlockerStatus.VolumeType
            $encryptionMethod = $bitlockerStatus.EncryptionMethod

            if ($protectionStatus -eq 'On') {
                $recoveryKey = $bitlockerStatus.KeyProtector |
                Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                Select-Object -ExpandProperty RecoveryPassword -ErrorAction SilentlyContinue

                Add-LogEntry "BitLocker is **enabled** on drive $Drive." -Icon 'permission' @detailsParams
                Add-LogEntry "🗝Recovery Key: $recoveryKey" -icon 'key' @detailsParams

                if ($CreateFile) {
                    $fileContent = "BitLocker enabled on $Drive`nRecovery Key: $recoveryKey"
                }
            }
            else {
                Add-LogEntry "BitLocker is **not enabled** on drive $Drive." -icon 'unlocked' @detailsParams
                if ($CreateFile) {
                    $fileContent = "BitLocker not enabled on $Drive"
                }
                $recoveryKey = $null
            }

            # Build output object with extended info
            $obj = [PSCustomObject]@{
                VolumeLetter     = $Drive
                ProtectionStatus = $protectionStatus
                VolumeType       = $volumeType
                EncryptionMethod = $encryptionMethod
                RecoveryKey      = $recoveryKey
            }
            $results += $obj

            $successCount++
        }
        catch {
            Add-LogEntry "Error retrieving BitLocker status for drive ${Drive}: $($_.Exception.Message)" -Icon 'error' @detailsParams
            if ($CreateFile) {
                $fileContent = "Error retrieving BitLocker status for ${Drive}: $($_.Exception.Message)"
            }
            $failureCount++
        }

        if ($CreateFile) {
            $sanitizedDrive = $Drive.Replace(':', '')
            $filePath = Join-Path -Path $GLOBAL:DrLogs -ChildPath "BLI_$sanitizedDrive.txt"
            if (-not (Test-Path -Path $GLOBAL:DrLogs)) {
                New-Item -Path $GLOBAL:DrLogs -ItemType Directory -Force | Out-Null
            }
            $fileContent | Out-File -FilePath $filePath -Force -Encoding UTF8
            Send-DrFile -filePath $filePath @detailsParams
            Add-LogEntry "📄 Created and uploaded file: $filePath" @detailsParams
        }

        Add-LogEntry "✅ Drive $Drive processed." @detailsParams
        Add-LogEntry "===========================" @detailsParams
    }

    $totalCount = $drivesToProcess.Count
    $summary = "📊 Summary: $totalCount drive(s) found, $successCount succeeded, $failureCount failed."

    Add-LogEntry $summary @summaryParams

    return $results
}
#endregion

#region File: Get-BrowserPermissions.ps1
function Get-BrowserPermissions {
    <#
.SYNOPSIS
    Retrieves browser permission settings for Edge and Chrome across user profiles.

.DESCRIPTION
    - Scans Edge and Chrome profiles for permission settings (notifications, camera, mic, etc.).
    - Defaults:
        * -Browser defaults to "*ALL"
        * -User defaults to the logged-in user
        * If logged-in user is SYSTEM, defaults to "*ALL" users
    - Collects browser version info from "Local State" file.
    - Logs detailed permissions and a summary at the end.

.LOGGING RULES
    - Use Add-LogEntry for all messages.
    - Any Add-LogEntry immediately before a return or exit MUST include `-AddBody`
      to ensure the message is added to the buffered log before the function exits.
    - Use `-AddToBody` for intermediate entries to accumulate logs.
    - Use one final `Add-LogEntry ... -AddBody` at the end to flush accumulated logs.
    - Use `-Icon` for severity or type:
        * success   → ✅
        * warning   → ⚠️
        * failed    → ❌
        * task      → 📌
        * info      → ℹ️
        * question  → ❔
#>
    param (
        [string]$Browser = "*ALL",
        [string]$User = $env:USERNAME,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    write-host User: $User
    # If running as SYSTEM, default to all users
    if ($User -eq "SYSTEM") { $User = "*ALL" }

    $visiblePermissionTypes = @(
        'notifications', 'geolocation', 'media_stream_camera', 'media_stream_mic',
        'midi_sysex', 'push_messaging', 'background_sync', 'automatic_downloads',
        'clipboard', 'camera', 'microphone', 'payments', 'sound', 'fullscreen',
        'clipboard-read', 'clipboard-write'
    )

    # Validate browser parameter
    if ($Browser -notin @("Edge", "Chrome", "*ALL")) {
        Add-LogEntry "Invalid browser specified. Please specify 'Edge', 'Chrome', or '*ALL'." -Icon 'failed' @summaryParams
        return
    }

    # Get all loaded user profiles
    $userProfiles = Get-WmiObject -Class Win32_UserProfile |
    Where-Object { $_.Special -eq $false -and $_.Loaded -eq $true }

    if (-not $userProfiles) {
        Add-LogEntry "No loaded user profiles found. Exiting." -Icon 'warning' @summaryParams
        return
    }

    Add-LogEntry "Found user profiles:" -Icon 'info' -AddToBody
    foreach ($UserProfile in $userProfiles) {
        Add-LogEntry "    - $($UserProfile.LocalPath)" -Icon 'info' -AddToBody
    }

    $targets = @()
    $browserVersions = @{}
    $permissionCount = 0

    foreach ($UserProfile in $userProfiles) {
        $userName = $UserProfile.LocalPath.Split('\')[-1]
        if ($User -ne "*ALL" -and $User -ne $userName) { continue }

        $browserList = switch ($Browser.ToUpper()) {
            "EDGE" { @("Edge") }
            "CHROME" { @("Chrome") }
            "*ALL" { @("Edge", "Chrome") }
        }

        foreach ($browserName in $browserList) {
            $userBasePath = switch ($browserName) {
                "Edge" { Join-Path -Path $UserProfile.LocalPath -ChildPath "AppData\Local\Microsoft\Edge\User Data" }
                "Chrome" { Join-Path -Path $UserProfile.LocalPath -ChildPath "AppData\Local\Google\Chrome\User Data" }
            }

            if (-not (Test-Path -Path $userBasePath)) {
                Add-LogEntry "${browserName} data path not found for user ${userName}: ${userBasePath}" -Icon 'warning' @detailsParams
                continue
            }

            # Get browser version from Local State file
            $localStatePath = Join-Path $userBasePath "Local State"
            if (Test-Path $localStatePath) {
                try {
                    $localStateJson = Get-Content -Path $localStatePath -Raw | ConvertFrom-Json
                    $version = $localStateJson.browser.version
                    if ($version) { $browserVersions[$browserName] = $version }
                }
                catch { }
            }

            $profileFolders = Get-ChildItem -Path $userBasePath -Directory -ErrorAction SilentlyContinue

            foreach ($folder in $profileFolders) {
                $preferencesFilePath = Join-Path -Path $folder.FullName -ChildPath "Preferences"
                $targets += [PSCustomObject]@{
                    UserName    = $userName
                    Browser     = $browserName
                    ProfileName = $folder.Name
                    Preferences = $preferencesFilePath
                }
            }
        }
    }

    if (-not $targets) {
        Add-LogEntry "No browser profiles found for specified criteria." -Icon 'warning' @summaryParams
        return
    }

    foreach ($target in $targets) {
        $loggedSomething = $false
        $browser = $target.Browser
        $user = $target.UserName
        $profileName = $target.ProfileName
        $prefPath = $target.Preferences

        if (Test-Path $prefPath) {
            try {
                $jsonRaw = Get-Content -Path $prefPath -Raw -ErrorAction Stop
                try {
                    $json = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    Add-LogEntry "JSON parse failed due to duplicate keys in ${profileName}. Skipping detailed permissions." -Icon 'warning' @detailsParams
                    continue
                }

                if ($json -and $json.profile -and $json.profile.content_settings -and $json.profile.content_settings.exceptions) {
                    foreach ($permType in $visiblePermissionTypes) {
                        if ($json.profile.content_settings.exceptions.PSObject.Properties.Name -contains $permType) {
                            $permEntries = $json.profile.content_settings.exceptions.$permType
                            Add-LogEntry "${browser} (User: ${user}, Profile: ${profileName}) - Permission: $permType" @detailsParams -Icon 'task'
                            $loggedSomething = $true
                            $permissionCount++
                            $bfr = "${user} - ${browser} - ${profileName}"
                            foreach ($entry in $permEntries.PSObject.Properties) {
                                $site = $entry.Name
                                $setting = $entry.Value.setting
                                $iconParam = 'question'; $label = 'Ask'
                                if ($setting -eq 1) { $iconParam = 'success'; $label = 'Allowed' }
                                elseif ($setting -eq 2) { $iconParam = 'failed'; $label = 'Blocked' }

                                Add-LogEntry "$site ($label)" -Buffer $bfr -Icon $iconParam
                            }
                            Add-LogEntry "$permissionCount++ entries." -Icon 'count' -Buffer $bfr -FlushBuffer
                        }
                    }
                }

                if (-not $loggedSomething) {
                    Add-LogEntry "${browser} (User: ${user}, Profile: ${profileName})" @detailsParams -Icon 'task'
                    Add-LogEntry "No user-visible permissions found" @detailsParams -Icon 'warning'
                }

            }
            catch {
                Add-LogEntry "${browser} (User: ${user}, Profile: ${profileName})" @detailsParams -Icon 'task'
                Add-LogEntry "Failed to parse Preferences file: $_" @detailsParams -Icon 'failed'
            }
        }
        else {
            Add-LogEntry "${browser} (User: ${user}, Profile: ${profileName})" @detailsParams -Icon 'task'
            Add-LogEntry "Preferences file not found" @detailsParams -Icon 'warning'
        }

        if ($loggedSomething) {
            Add-LogEntry "— End of profile —" @detailsParams -Icon 'info'
        }
    }

    # Summary
    Add-LogEntry "Scan complete." @detailsParams -Icon 'success'
    Add-LogEntry "Summary:" @detailsParams -Icon 'info'
    Add-LogEntry "Users scanned: $($userProfiles.Count)" @detailsParams -Icon 'info'
    Add-LogEntry "Profiles scanned: $($targets.Count)" @detailsParams -Icon 'info'
    Add-LogEntry "Permissions found: $permissionCount" @detailsParams -Icon 'info'
    foreach ($browserName in $browserVersions.Keys) {
        Add-LogEntry "$browserName version: $($browserVersions[$browserName])" @detailsParams -Icon 'info'
    }

    # ✅ Flush accumulated log entries
    Add-LogEntry "Process complete." @summaryParams -Icon 'success'
}
#endregion

#region File: Get-CPUTemperature.ps1
function Get-CPUTemperature {
    if (-not (Assert-IsAdmin @summaryParams)) { return }

    $temperatureData = Get-WmiObject -Namespace "root\wmi" -Class MSAcpi_ThermalZoneTemperature
    $results = @()
    $counter = 1

    foreach ($temp in $temperatureData) {
        $kelvin = $temp.CurrentTemperature / 10
        $celsius = $kelvin - 273.15
        $fahrenheit = ($celsius * 9 / 5) + 32
        $results += [PSCustomObject]@{
            Name       = "CPU Zone $counter"
            Kelvin     = "{0:N2} K" -f $kelvin
            Celsius    = "{0:N2} °C" -f $celsius
            Fahrenheit = "{0:N2} °F" -f $fahrenheit
        }
        $counter++
    }
    return $results
}
#endregion

#region File: Get-DrAssetIdRegistry.ps1
function Get-DrAssetIdRegistry {
    <#
        .SYNOPSIS
        Reads the stored Syncro asset_id from the registry.

        .DESCRIPTION
        - Loads the asset_id value from:
          HKLM:\SOFTWARE\WOW6432Node\RepairTech\Syncro\DrOsdicks
        - Returns the asset_id as a string (or $null if not present).
        - Performs up-front validation, accumulates diagnostics, and emits one final log entry.

        .NOTES
        Version: 1.1.0
    #>
    [CmdletBinding()]
    param (
        [string]$RegPath = 'HKLM:\SOFTWARE\WOW6432Node\RepairTech\Syncro\DrOsdicks',
        [string]$Name = 'asset_id',
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer,
        [switch]$Quiet
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary


    $issues = New-Object System.Collections.Generic.List[string]
    $diag = New-Object System.Collections.Generic.List[string]

    $assetId = $null
    $action = 'None'
    $pathStr = "$RegPath\$Name"



    try {
        # Validation
        if ([string]::IsNullOrWhiteSpace($RegPath)) { $issues.Add('RegPath is required.') }
        if ([string]::IsNullOrWhiteSpace($Name)) { $issues.Add('Name is required.') }
        if ($issues.Count -gt 0) {
            $diag.Add("Validation failed.")
            return $null
        }

        # Ensure key exists / read value
        if (-not (Test-Path -LiteralPath $RegPath)) {
            $diag.Add("Registry key not found: $RegPath")
            return $null
        }

        try {
            $props = Get-ItemProperty -LiteralPath $RegPath -Name $Name -ErrorAction Stop
            $raw = $props.$Name

            if ($raw -is [string[]]) {
                $assetId = ($raw | Where-Object { $_ -and $_.Trim() }) -join ','
                $diag.Add("Value read as REG_MULTI_SZ; joined to string: $pathStr")
            }
            else {
                $assetId = [string]$raw
                $diag.Add("Value read: $pathStr")
            }

            if ([string]::IsNullOrWhiteSpace($assetId)) {
                $diag.Add("Value is present but empty: $pathStr")
            }
            else {
                $action = 'Loaded'
            }
        }
        catch {
            $diag.Add("Value not found: $pathStr")
            return $null
        }
    }
    catch {
        $issues.Add($_.Exception.Message)
        return $null
    }
    finally {
        if (-not $Quiet) {
            try {
                $summary = if ($assetId) {
                    "Get-DrAssetIdRegistry completed | AssetId: $assetId | Action: $action"
                }
                else {
                    "Get-DrAssetIdRegistry completed | AssetId: [none] | Action: $action"
                }
                $details = @()
                if ($issues.Count -gt 0) { $details += ("Issues: " + ($issues -join ' | ')) }
                if ($diag.Count -gt 0) { $details += ("Diag: " + ($diag -join ' | ')) }
                $msg = if ($details.Count -gt 0) { "$summary || $($details -join ' || ')" } else { $summary }

                Add-LogEntry -Message $msg -Icon 'summary' @summaryParams
            }
            catch { }
        }
    }

    return $assetId
}
#endregion

#region File: Get-DrContent.ps1
function Get-DrContent {
    <#
    .SYNOPSIS
        Reads a redirected console output file with correct encoding.

    .DESCRIPTION
        Detects UTF-8/UTF-16 BOMs. If none, falls back to the current console OEM code page
        (typical for redirected output from console tools like sfc.exe and chkdsk.exe).
        Returns a single string (equivalent to -Raw).

    .PARAMETER Path
        File path to read.

    .PARAMETER Fallback
        Fallback encoding when no BOM exists. Default: 'OEM'.
        Accepts: 'OEM', 'UTF8', 'Unicode', 'BigEndianUnicode', a code page int (e.g., 437, 850, 65001),
        or a .NET encoding name (e.g., 'Windows-1252').

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [ValidateNotNullOrEmpty()]
        [object] $Fallback = 'OEM'
    )

    try {
        if (-not $Path) {
            throw [System.ArgumentException]::new('Path is required.')
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new('File not found.', $Path)
        }

        # Read raw bytes
        $bytes = Get-Content -LiteralPath $Path -Encoding Byte -Raw -ErrorAction Stop
        $len = $bytes.Length

        # Empty file -> empty string
        if ($len -eq 0) {
            return ''
        }

        # BOM detection
        if ($len -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            # UTF-8 with BOM
            return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $len - 3)
        }
        elseif ($len -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            # UTF-16 LE
            return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $len - 2)
        }
        elseif ($len -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            # UTF-16 BE
            return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $len - 2)
        }

        # No BOM -> resolve fallback encoding
        $encoding = $null
        switch -Regex ($Fallback.ToString()) {
            '^(?i)OEM$' {
                # Use current console output code page as typical OEM fallback
                $encoding = [System.Text.Encoding]::GetEncoding([Console]::OutputEncoding.CodePage)
                break
            }
            '^(?i)UTF8$' { $encoding = [System.Text.Encoding]::UTF8; break }
            '^(?i)Unicode$' { $encoding = [System.Text.Encoding]::Unicode; break }            # UTF-16 LE
            '^(?i)BigEndianUnicode$' { $encoding = [System.Text.Encoding]::BigEndianUnicode; break }
            default {
                if ($Fallback -is [int]) {
                    $encoding = [System.Text.Encoding]::GetEncoding([int]$Fallback)
                }
                else {
                    $encoding = [System.Text.Encoding]::GetEncoding([string]$Fallback)
                }
            }
        }

        return $encoding.GetString($bytes)
    }
    catch {
        throw
    }
}
#endregion

#region File: Get-DrCpuAndMemoryInfo.ps1
function Get-DrCpuAndMemoryInfo {
    <#
    .SYNOPSIS
        Logs CPU and Memory details.
    .DESCRIPTION
        Retrieves CPU name, speed, architecture, number of cores, logical processors, memory size, memory speed, and memory type, then logs them using Add-LogEntry.
    .NOTES
        Category: SystemInfo
        Icon: 📶
    #>
    [CmdletBinding()]
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    try {
        # Get CPU details
        $cpu = Get-CimInstance Win32_Processor
        $cpuName = $cpu.Name
        $cores = $cpu.NumberOfCores
        $logical = $cpu.NumberOfLogicalProcessors
        $cpuSpeedMHz = $cpu.MaxClockSpeed
        $architecture = switch ($cpu.Architecture) {
            0 { 'x86' }
            1 { 'MIPS' }
            2 { 'Alpha' }
            3 { 'PowerPC' }
            5 { 'ARM' }
            6 { 'Itanium' }
            9 { 'x64' }
            default { 'Unknown' }
        }

        # Get Memory details
        $compSys = Get-CimInstance Win32_ComputerSystem
        $totalMemGB = [math]::Round($compSys.TotalPhysicalMemory / 1GB, 2)

        # Get Memory speed and type
        $memModules = Get-CimInstance Win32_PhysicalMemory
        $memSpeeds = $memModules | Select-Object -ExpandProperty Speed
        $avgMemSpeed = if ($memSpeeds) { [math]::Round(($memSpeeds | Measure-Object -Average).Average, 0) } else { 'Unknown' }

        # Memory type mapping
        $memTypes = $memModules | ForEach-Object {
            switch ($_.MemoryType) {
                20 { 'DDR' }
                21 { 'DDR2' }
                24 { 'DDR3' }
                26 { 'DDR4' }
                30 { 'DDR5' }
                default { 'Unknown' }
            }
        }
        $uniqueMemTypes = ($memTypes | Sort-Object -Unique) -join ', '

        # Build log body
        Add-LogEntry "CPU: $cpuName | Speed: $cpuSpeedMHz MHz | Arch: $architecture | Cores: $cores | Logical: $logical" -Icon 'cpu' @detailsParams
        #Add-LogEntry "Total Physical Memory: $totalMemGB GB | Avg Memory Speed: $avgMemSpeed MHz | Type: $uniqueMemTypes" -Icon 'memory' -AddToBody
        Add-LogEntry "Total Physical Memory: $totalMemGB GB | Avg Memory Speed: $avgMemSpeed MHz | Type: $uniqueMemTypes" -Icon 'memory' @summaryParams

        # Flush accumulated body
        #Add-LogEntry -Message "CPU and Memory details retrieved successfully." -Icon 'SystemInfo' @summaryParams
    }
    catch {
        Add-LogEntry "Failed to retrieve CPU or Memory info: $($_.Exception.Message)" -Icon 'error' @summaryParams
    }
}
#endregion

#region File: Get-DrCustomer.ps1
function Get-DrCustomer {
    [CmdletBinding()]
    param (
        [int]$CustomerId = $Global:DrAsset.customer.id,
        [switch]$DebugOutput
    )

    try {
        return Invoke-DrApiRequest -Method 'GET' -Endpoint "/api/v1/customers/$CustomerId" -DebugOutput:$DebugOutput
    }
    catch {
        Write-Error "Failed to retrieve customer ID ${CustomerId}: $_"
    }
}
#endregion

#region File: Get-DrDiskInfo.ps1
function Get-DrDiskInfo {
    <#
    .SYNOPSIS
        Retrieves and logs detailed disk and storage information.
    .DESCRIPTION
        Collects disk details including:
        - Device ID
        - Model
        - Serial Number
        - Firmware Revision
        - Disk Type (SSD/HDD)
        - Bus Type
        - Partition Style
        - Size (GB)
        - Free Space (GB)
        - Percent Free
        - Volume Label
        - Health Status

        Logs each property individually under the appropriate category for clarity.
        Returns an array of objects for further processing.
    .PARAMETER AddToBody
        Accumulates log entries instead of flushing immediately.
        Useful when combining multiple hardware info calls into one final log.
    .OUTPUTS
        [PSCustomObject[]] - A list of disk information objects.
    .NOTES
        Category: SystemInfo
        Author: James Drosdick
        Version: 3.0.35
    #>
    [CmdletBinding()]
    param (
        [string[]]$Buffer = @('Disk Details'),
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        # Collect disk info
        $logicalDisks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
        $diskDrives = Get-CimInstance Win32_DiskDrive
        $partitions = Get-CimInstance Win32_DiskPartition
        $diskToPartition = Get-CimInstance Win32_LogicalDiskToPartition
        $getDisk = Get-Disk

        $diskInfoList = @()

        foreach ($logical in $logicalDisks) {
            $deviceID = $logical.DeviceID
            $sizeGB = [math]::Round($logical.Size / 1GB, 2)
            $freeGB = [math]::Round($logical.FreeSpace / 1GB, 2)
            $percentFree = if ($logical.Size -gt 0) { [math]::Round(($logical.FreeSpace / $logical.Size) * 100, 1) } else { 0 }
            $volumeLabel = if ($logical.VolumeName) { $logical.VolumeName } else { 'No Label' }

            # Partition and disk details
            $partitionLink = $diskToPartition | Where-Object { $_.Dependent -like "*$deviceID*" }
            $partitionName = ($partitionLink.Antecedent -split '"')[1]
            $partitionObj = $partitions | Where-Object { $_.DeviceID -eq $partitionName }
            $diskObj = $diskDrives | Where-Object { $_.Index -eq $partitionObj.DiskIndex }
            $diskDetails = $getDisk | Where-Object { $_.Number -eq $partitionObj.DiskIndex }

            # Properties
            $diskInfo = [PSCustomObject]@{
                DeviceID       = $deviceID
                Model          = $diskObj.Model
                SerialNumber   = $diskObj.SerialNumber
                Firmware       = $diskObj.FirmwareRevision
                Type           = if ($diskObj.MediaType -like "*Solid*") { 'SSD' } else { 'HDD' }
                BusType        = $diskDetails.BusType
                PartitionStyle = $diskDetails.PartitionStyle
                SizeGB         = $sizeGB
                FreeGB         = $freeGB
                PercentFree    = $percentFree
                VolumeLabel    = $volumeLabel
                HealthStatus   = $diskDetails.HealthStatus
            }

            # Log each property with conditional category
            foreach ($property in $diskInfo.PSObject.Properties) {
                if ($property.Name -eq 'PercentFree') {
                    if ($property.Value -lt 10) {
                        $Icon = 'error'
                    }
                    elseif ($property.Value -lt 15) {
                        $Icon = 'warning'
                    }
                    else {
                        $Icon = 'success'
                    }
                }
                else {
                    $Icon = 'property'
                }

                Add-LogEntry "$($property.Name) : $($property.Value)" -Icon $Icon @detailsParams
            }

            $diskInfoList += $diskInfo
        }

        # Summary log under 'disk' category
        Add-LogEntry "Found $($diskInfoList.Count) logical disk(s) with full details." -Icon 'disk' @summaryParams


        return $diskInfoList
    }
    catch {
        # Final error log (conditional)
        Add-LogEntry "Failed to retrieve disk info: $($_.Exception.Message)" -Icon 'error' @summaryParams
        return
    }
}
#endregion

#region File: Get-DrMotherboardInfo.ps1
function Get-DrMotherboardInfo {
    <#
    .SYNOPSIS
        Logs motherboard details and BIOS version/date.
    .DESCRIPTION
        Retrieves Manufacturer, Model, Serial Number, BIOS version, and BIOS release date, then logs them using Add-LogEntry.
    .NOTES
        Category: SystemInfo
        Icon: 📶
    #>
    [CmdletBinding()]
    param (
        [string[]]$Buffer = @('Motherboard Info'),
        [switch]$FlushBuffer
    )
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    try {
        # Get motherboard details
        $board = Get-CimInstance Win32_BaseBoard
        $manufacturer = $board.Manufacturer
        $model = $board.Product
        $serial = $board.SerialNumber

        # Get BIOS details
        $bios = Get-CimInstance Win32_BIOS
        $biosVer = $bios.SMBIOSBIOSVersion

        # Validate and convert BIOS date
        $biosDate = 'Unknown'
        if ($bios.ReleaseDate -and $bios.ReleaseDate.Length -ge 8) {
            try {
                $biosDate = [Management.ManagementDateTimeConverter]::ToDateTime($bios.ReleaseDate).ToString('yyyy-MM-dd')
            }
            catch {
                $biosDate = 'Invalid Format'
            }
        }

        # Build log body
        Add-LogEntry "📶 Motherboard: $manufacturer | Model: $model | Serial: $serial" @detailsParams -Icon 'hardware'
        Add-LogEntry "📶 BIOS Version: $biosVer | Release Date: $biosDate" @detailsParams

        # Flush accumulated body
        Add-LogEntry -Message "System board and BIOS details retrieved successfully." -Icon 'SystemInfo' @summaryParams
    }
    catch {
        Add-LogEntry "Failed to retrieve motherboard or BIOS info: $($_.Exception.Message)" -Icon 'error' @summaryParams
    }
}
#endregion

#region File: Get-DrRecommendationResults.ps1
function Get-DrRecommendationResults {
    [CmdletBinding()]
    param (
        [switch] $OnlyExecuted,
        [switch] $OnlyFailed,
        [switch] $OnlySuccessful,
        [string[]]$Buffer = @('Recommendations'),
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $path = $Global:DrRecommendations
    if (-not (Test-Path $path)) {
        Add-LogEntry -Message "Recommendation file not found.1" -Icon 'error' -Buffer $Buffer--FlushBuffer
        return
    }

    try {
        $recs = Get-Content $path -Raw | ConvertFrom-Json
        $recs = @($recs)

        if ($OnlyExecuted) {
            $recs = $recs | Where-Object { $_.Executed -eq $true }
        }
        elseif ($OnlyFailed) {
            $recs = $recs | Where-Object { $_.Executed -eq $true -and $_.Success -eq $false }
        }
        elseif ($OnlySuccessful) {
            $recs = $recs | Where-Object { $_.Executed -eq $true -and $_.Success -eq $true }
        }

        foreach ($rec in $recs) {
            $obj = [DrRecommendation]::new()
            foreach ($prop in $rec.PSObject.Properties) {
                if ($obj.PSObject.Properties.Name -contains $prop.Name) {
                    $obj.$($prop.Name) = $prop.Value
                }
            }
            Add-LogEntry -Message $obj.ToLogEntry() -Icon 'System' @detailsParams
        }
        Add-LogEntry "End of list." @summaryParams -Icon 'summary'
    }
    catch {
        Add-LogEntry -Message "Error retrieving recommendation results: $($_.Exception.Message)" -Icon 'error' @summaryParams
    }
}
#endregion

#region File: Get-DrRecommendations.ps1
function Get-DrRecommendations {
    [CmdletBinding()]
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $path = $Global:DrRecommendations
    $recommendations = @()

    if (-not (Test-Path $path)) {
        Add-LogEntry -Message "⚪ Recommendation file not found at [$path]." -Icon 'SettingsOverride' @detailsParams
        return $recommendations
    }

    try {
        $raw = Get-Content $path -Raw | ConvertFrom-Json
        $items = if ($raw -is [System.Collections.IEnumerable]) { @($raw) } else { @($raw) }

        foreach ($item in $items) {
            $rec = [DrRecommendation]::new()
            foreach ($prop in $item.PSObject.Properties) {
                if ($rec.PSObject.Properties.Name -contains $prop.Name) {
                    $value = $prop.Value

                    if ($prop.Name -in @('Timestamp', 'ExecutionTimestamp')) {
                        if ($null -eq $value) {
                            # Optionally set to [datetime]::MinValue or skip
                            continue
                        }
                        elseif ($value -is [PSCustomObject] -and $value.DateTime) {
                            $rec.$($prop.Name) = [datetime]::Parse($value.DateTime)
                        }
                        elseif ($value -is [string]) {
                            $rec.$($prop.Name) = [datetime]::Parse($value)
                        }
                        else {
                            continue
                        }
                    }
                    else {
                        $rec.$($prop.Name) = $value
                    }
                }
            }
            $recommendations += $rec
        }
    }
    catch {
        Add-LogEntry -Message "Failed to load recommendations: $($_.Exception.Message)" -Icon 'error' @summaryParams
        return @()
    }

    return $recommendations
}
#endregion

#region File: Get-DrRecommendationSummary.ps1
function Get-DrRecommendationSummary {
    [CmdletBinding()]
    param (
        [string] $Severity,
        [bool]   $Approved
    )

    $path = $Global:DrRecommendations
    if (-not (Test-Path $path)) {
        Write-Host "No recommendations file found."
        return
    }

    try {
        $recs = Get-Content $path -Raw | ConvertFrom-Json
        $recs = @($recs)

        if ($Severity) {
            $recs = $recs | Where-Object { $_.Severity -eq $Severity }
        }

        if ($PSBoundParameters.ContainsKey('Approved')) {
            $recs = $recs | Where-Object { $_.Approved -eq $Approved }
        }

        $recs | Sort-Object NumericId | Select-Object NumericId, Severity, Approved, ExecutionOrder, Message, SuggestedAction
    }
    catch {
        Write-Host "Failed to read recommendations: $($_.Exception.Message)"
    }
}
#endregion

#region File: Get-DrTimer.ps1
function Get-DrTimer {
    Load-DrTimers
    foreach ($key in $Global:DrTimers.Keys) {
        $timer = $Global:DrTimers[$key]
        $elapsedMinutes = [math]::Round($timer.Elapsed / 60, 2)
        Add-LogEntry -Message "Timer [$key] Status: $($timer.Status), Elapsed: $elapsedMinutes min, AddedToTicket: $($timer.AddedToTicket), Messages: $($timer.Messages.Count)" -AddToBody
    }
    Add-LogEntry -Message "Summary: $($Global:DrTimers.Count) timer(s) found." -AddBody
}
#endregion

#region File: Get-DrTimerMessagesString.ps1
function Get-DrTimerMessagesString {
    param([string]$Name)
    if (-not $Global:DrTimers[$Name]) { return "" }
    return ($Global:DrTimers[$Name].Messages -join "`n")
}
#endregion

#region File: Get-DrTimers.ps1
function Get-DrTimers {
    Load-DrTimers
    if ($Global:DrTimers.Count -eq 0) {
        Add-LogEntry -Message "No timers found." -AddBody -Icon 'info'
        return
    }

    foreach ($key in $Global:DrTimers.Keys) {
        $timer = $Global:DrTimers[$key]
        $start = [DateTime]$timer.StartTime
        $span = if ($timer.Status -eq 'Running') {
            (Get-Date) - $start
        }
        else {
            [TimeSpan]::FromSeconds($timer.Elapsed)
        }

        $elapsedFormatted = "{0:hh\:mm\:ss}" -f $span

        Add-LogEntry -Message "Timer [$key] Status: $($timer.Status), Elapsed: $elapsedFormatted, AddedToTicket: $($timer.AddedToTicket)" `
            -AddToBody -Icon 'timer'
    }

    Add-LogEntry -Message "Summary: $($Global:DrTimers.Count) timer(s) found." -AddBody -Icon 'summary'
}
#endregion

#region File: Get-DrTimersSummary.ps1
function Get-DrTimersSummary {
    Load-DrTimers
    if ($Global:DrTimers.Count -eq 0) {
        Add-LogEntry -Message "No timers found for summary." -AddBody -Icon 'info'
        return
    }

    $summary = foreach ($key in $Global:DrTimers.Keys) {
        $timer = $Global:DrTimers[$key]
        $elapsedMinutes = [math]::Round($timer.Elapsed / 60, 2)
        [PSCustomObject]@{
            Name          = $key
            Status        = $timer.Status
            ElapsedMin    = $elapsedMinutes
            AddedToTicket = $timer.AddedToTicket
            Messages      = $timer.Messages.Count
        }
    }

    $summary | Format-Table -AutoSize
    Add-LogEntry -Message "Summary generated for $($summary.Count) timers." -AddToBody -Icon 'summary'
}
#endregion

#region File: Get-DumpPaths.ps1
function Get-DumpPaths {
    <#
        Returns only actionable dump paths:
          - File paths: existing *.dmp files.
          - Folder paths: only if they currently contain at least one *.dmp.
        Also appends known Windows dump locations using the same rule.
    #>

    $paths = New-Object System.Collections.Generic.List[string]

    function Add-IfActionable {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $norm = [System.IO.Path]::GetFullPath(($p.Trim('"').Trim()))

        if (Test-Path -LiteralPath $norm) {
            $item = Get-Item -LiteralPath $norm -ErrorAction SilentlyContinue
            if ($null -eq $item) { return }

            if (-not $item.PSIsContainer) {
                # File: include only if it's a .dmp
                if ($item.Extension -ieq '.dmp' -and -not $paths.Contains($item.FullName)) {
                    $paths.Add($item.FullName)
                }
            }
            else {
                # Folder: include only if it has at least one *.dmp now
                $hasDmp = Get-ChildItem -LiteralPath $item.FullName -Filter *.dmp -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hasDmp -and -not $paths.Contains($item.FullName)) {
                    $paths.Add($item.FullName)
                }
            }
        }
    }

    try {
        # 1) Your configured sources (what Set-DumpType writes) — adjust to your store
        $configured = @()
        try {
            $regKey = 'HKLM:\SOFTWARE\Drosdick\DrModuleV3\Dump'
            if (Test-Path $regKey) {
                $val = (Get-ItemProperty -Path $regKey -ErrorAction Stop).Paths
                if ($val) {
                    if ($val -is [string[]]) { $configured += $val }
                    elseif ($val -is [string]) { $configured += ($val -split ';|,') }
                }
            }
        }
        catch { }

        foreach ($p in $configured) { Add-IfActionable $p }

        # 2) Known locations — only if actionable right now
        Add-IfActionable 'C:\Windows\MEMORY.DMP'          # full/kernel dump
        Add-IfActionable 'C:\Windows\Minidump'            # mini kernel dumps
        Add-IfActionable 'C:\Windows\LiveKernelReports'   # live kernel dumps (.dmp only)
        # WER queues/archives sometimes contain .dmp, otherwise ignored
        Add-IfActionable 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue'
        Add-IfActionable 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'

        return , $paths.ToArray()
    }
    catch {
        return , $paths.ToArray()
    }
}
#endregion

#region File: Get-DumpPaths0.ps1
function Get-DumpPaths0 {
    <#
    .SYNOPSIS
        Retrieves configured dump file paths based on system settings.

    .DESCRIPTION
        Reads registry values under CrashControl to return paths for minidumps and full memory dumps.
        Returns an array of paths that exist on disk.

    .NOTES
        Registry keys:
        - CrashDumpEnabled: 1=Complete, 2=Kernel, 3=Minidump, 7=Automatic
        - DumpFile: Full dump path (default C:\Windows\MEMORY.DMP)
        - MinidumpDir: Minidump folder (default C:\Windows\Minidump)
    #>
    [CmdletBinding()]
    param ()

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
    $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue

    if (-not $props) { return @() }

    $dumpType = $props.CrashDumpEnabled
    $dumpFile = $props.DumpFile
    $minidumpDir = $props.MinidumpDir

    $paths = @()

    switch ($dumpType) {
        1 { if ($dumpFile) { $paths += $dumpFile } }      # Complete
        2 { if ($dumpFile) { $paths += $dumpFile } }      # Kernel
        3 { if ($minidumpDir) { $paths += $minidumpDir } }# Minidump
        7 { if ($dumpFile) { $paths += $dumpFile } }      # Automatic
        default {
            if ($minidumpDir) { $paths += $minidumpDir }
        }
    }

    # Return only paths that exist
    return $paths | Where-Object { Test-Path $_ }
}
#endregion

#region File: Get-DumpType.ps1
function Get-DumpType {
    [CmdletBinding()]
    param (
        [switch]$AddToBody
    )

    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $value = Get-ItemProperty -Path $regPath -Name "CrashDumpEnabled" -ErrorAction Stop | Select-Object -ExpandProperty CrashDumpEnabled

        $dumpTypeMap = @{
            1 = "Complete"
            2 = "Kernel"
            3 = "Minidump"
            7 = "Automatic"
        }

        $dumpType = $dumpTypeMap[$value]
        if (-not $dumpType) { $dumpType = "Unknown" }

        Add-LogEntry -Message "📋 Current dump type: $dumpType ($value)" -Icon "syncroapi" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        return $dumpType
    }
    catch {
        Add-LogEntry -Message "❌ Failed to retrieve dump type: $($_.Exception.Message)" -Icon "Error" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
        return $null
    }
}
#endregion

#region File: Get-EncryptedApiKeyFromRegistry.ps1
function Get-EncryptedApiKeyFromRegistry {
    $regPath = "HKLM:\SOFTWARE\WOW6432Node\RepairTech\Syncro\DrOsdicks"
    $keyPath = "C:\ProgramData\Syncro\DrOsdicks\bin\key.bin"
    $valueName = "ApiKey"
    #write-host "C:\ProgramData\Syncro\DrOsdicks\bin\key.bin"
    # Ensure the registry path exists
    if (-not (Test-Path $regPath)) {
        try {
            $null = New-Item -Path $regPath -Force
        }
        catch {
            throw "Failed to create registry path: $_"
        }
    }

    # Ensure the encryption key file exists
    if (-not (Test-Path $keyPath)) {
        throw "Encryption key file not found at $keyPath"
    }

    try {
        $key = [IO.File]::ReadAllBytes($keyPath)
        $encrypted = Get-ItemPropertyValue -Path $regPath -Name $valueName -ErrorAction Stop
        $secure = ConvertTo-SecureString $encrypted -Key $key
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        )
    }
    catch {
        Write-Warning "Failed to load encrypted API key from registry: $_"
        return $null
    }
}
#endregion

#region File: Get-EventLogsByLevelAndTime.ps1
function Get-EventLogsByLevelAndTime {
    <#
    .SYNOPSIS
        Retrieves Windows event log entries constrained by a resolved time window and optional filters.

    .DESCRIPTION
        This function returns raw events (Get-WinEvent objects) from one or more logs using an efficient FilterHashtable.
        Time window selection precedence (as requested):
            1) SinceLastBoot
            2) TimeRange ("X hours" / "X days")
            3) StartTime / EndTime (explicit date range)

        Explicit range validation:
            - StartTime: must be provided (non-null) and valid.
            - EndTime: if null -> defaults to now; else must be valid and after StartTime.

        NOTE: Defaults such as Levels = @(1,2,3) are preserved. This function remains generic; callers decide which logs,
        sources, and event IDs are relevant for their scenario.
    #>
    param (
        [string[]]$LogName,
        [string]$TimeRange,
        [int[]]$Levels = @(1, 2, 3),
        [int[]]$EventIds,
        [switch]$SinceLastBoot,
        [switch]$AllLogs,
        [string[]]$Source,
        [switch]$LogEntries,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    Log-Invocation -IncludeParameters @detailsParams

    # Holds raw events for return
    $results = New-Object System.Collections.Generic.List[object]

    if (-not $LogName -and -not $AllLogs) {
        $LogName = @("System", "Application", "Security")
        Add-LogEntry -Message "Defaulting to primary logs: System, Application, Security" -Icon 'info' @summaryParams 
    }

    # ----- TIME WINDOW RESOLUTION (SinceLastBoot -> TimeRange -> Start/End) -----
    $resolvedSelector = $null

    $hasStart = $PSBoundParameters.ContainsKey('StartTime')
    $hasEnd = $PSBoundParameters.ContainsKey('EndTime')

    # 1) SinceLastBoot
    if ($SinceLastBoot) {
        $resolvedSelector = 'SinceLastBoot'
        try {
            $StartTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
            $EndTime = Get-Date
        }
        catch {
            Add-LogEntry -Message "Failed to resolve last boot time: $_" -Icon 'warningcritical' @summaryParams 
            return $results
        }
    }
    # 2) TimeRange
    elseif ($TimeRange) {
        $resolvedSelector = 'TimeRange'
        $EndTime = Get-Date

        if ($TimeRange -match "^\s*(\d+)\s*hours?\s*$") {
            $StartTime = $EndTime.AddHours( - [int]$matches[1])
        }
        elseif ($TimeRange -match "^\s*(\d+)\s*days?\s*$") {
            $StartTime = $EndTime.AddDays( - [int]$matches[1])
        }
        else {
            Add-LogEntry -Message "Invalid time range format. Use 'X hours' or 'X days'." -Icon 'warningcritical' @summaryParams 
            return $results
        }
    }
    # 3) Explicit Start/End validation
    else {
        # EndTime without StartTime is a show-stopper (keep your existing example, just ensure flush)
        if (-not $hasStart -and $hasEnd) {
            Add-LogEntry "❗ Invalid parameters: -EndTime was provided without -StartTime." -Icon 'warningcritical' @summaryParams
            return $results
        }

        # If no selector provided at all
        if (-not $hasStart -and -not $SinceLastBoot -and -not $TimeRange) {
            Add-LogEntry -Message "You must specify one of: -SinceLastBoot, -TimeRange, or -StartTime (with optional -EndTime)." -Icon 'warningcritical' @summaryParams 
            return $results
        }

        # Validate StartTime
        if (-not $StartTime) {
            if ($LogEntries) { Add-LogEntry -Message "StartTime could not be resolved." -Icon 'warningcritical' @summaryParams }
            return $results
        }

        # EndTime handling
        if (-not $hasEnd -or -not $EndTime) {
            $EndTime = Get-Date
        }
        else {
            # EndTime must be after StartTime
            if ($EndTime -le $StartTime) {
                Add-LogEntry -Message "StartTime must be earlier than EndTime." -Icon 'alert' @summaryParams 
                return $results
            }
        }

        $resolvedSelector = 'DateRange'
    }

    switch ($resolvedSelector) {
        'DateRange' { Add-LogEntry -Message "Scanning logs (DateRange) from $StartTime to $EndTime" -Icon 'scan' @detailsParams }
        'TimeRange' { Add-LogEntry -Message "Scanning logs (TimeRange) from $StartTime to $EndTime" -Icon 'scan' @detailsParams }
        'SinceLastBoot' { Add-LogEntry -Message "Scanning logs since last boot ($StartTime to $EndTime)" -Icon 'scan' @detailsParams }
    }
    # ----- END TIME WINDOW RESOLUTION -----

    $logsToScan = if ($AllLogs) {
        Get-WinEvent -ListLog * | Where-Object { $_.IsEnabled } | Select-Object -ExpandProperty LogName
    }
    else {
        @($LogName)
    }

    $logSummary = @{}

    foreach ($log in $logsToScan) {
        if ($LogEntries) { Add-LogEntry -Message "Checking log: $log" -Icon 'scan' -Buffer $log }
        $filter = @{
            LogName   = $log
            StartTime = $StartTime
            EndTime   = $EndTime
            Level     = $Levels
        }

        if ($EventIds) { $filter['Id'] = $EventIds }
        if ($Source) { $filter['ProviderName'] = $Source }

        try {
            $events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue
        }
        catch {
            if ($LogEntries) { Add-LogEntry -Message "Failed to read log: $log - $_" -Buffer $log -FlushBuffer }
            continue
        }

        $eventCount = 0
        if ($events) {
            foreach ($logEvent in $events) {

                if ($LogEntries) {
                    $entry = "📝 [$($logEvent.TimeCreated)] ID $($logEvent.Id) [$($logEvent.LevelDisplayName)] [$($logEvent.ProviderName)]`n$($logEvent.Message)"
                    Add-LogEntry -Message $entry -Buffer $log
                }

                $results.Add($logEvent) | Out-Null
                $eventCount++
            }
        }
        else {
            Add-LogEntry -Message "📭 No events found in $log" -Buffer $log 
        }

        Add-LogEntry "${log}: $eventCount events" -Icon 'summary' @detailsParams
        $logSummary[$log] = $eventCount
        if ($LogEntries) { Add-LogEntry -Message "Total events in ${log}: $eventCount" -Icon 'numbers' -Buffer $log -FlushBuffer }
    }

    Add-LogEntry -Message "Completed event log scan." -Icon 'completed' @summaryParams

    return $results
}
#endregion

#region File: Get-EventLogsByLevelAndTimex.ps1
function Get-EventLogsByLevelAndTimex {
    <#
    .SYNOPSIS
        Retrieves Windows event log entries constrained by a resolved time window and optional filters.

    .DESCRIPTION
        This function returns raw events (Get-WinEvent objects) from one or more logs using an efficient FilterHashtable.
        Time window selection precedence (as requested):
            1) SinceLastBoot
            2) TimeRange ("X hours" / "X days")
            3) StartTime / EndTime (explicit date range)

        Explicit range validation:
            - StartTime: must be provided (non-null) and valid.
            - EndTime: if null -> defaults to now; else must be valid and after StartTime.

        NOTE: Defaults such as Levels = @(1,2,3) are preserved. This function remains generic; callers decide which logs,
        sources, and event IDs are relevant for their scenario.
    #>
    param (
        [string[]]$LogName,
        [string]$TimeRange,
        [int[]]$Levels = @(1, 2, 3),
        [int[]]$EventIds,
        [switch]$SinceLastBoot,
        [switch]$AllLogs,
        [string[]]$Source,
        [switch]$LogEntries,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    #region LoggingSetup

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details


    #endregion LoggingSetup


    if ($LogEntries) { Log-Invocation -IncludeParameters @detailsParams }

    # Holds raw events for return
    $results = New-Object System.Collections.Generic.List[object]

    if (-not $LogName -and -not $AllLogs) {
        $LogName = @("System", "Application", "Security")
        if ($LogEntries) { Add-LogEntry -Message "ℹDefaulting to primary logs: System, Application, Security" -NoIcon 'info' @detailsParams }
    }

    # ----- TIME WINDOW RESOLUTION (SinceLastBoot -> TimeRange -> Start/End) -----
    $resolvedSelector = $null

    $hasStart = $PSBoundParameters.ContainsKey('StartTime')
    $hasEnd = $PSBoundParameters.ContainsKey('EndTime')

    # 1) SinceLastBoot
    if ($SinceLastBoot) {
        $resolvedSelector = 'SinceLastBoot'
        try {
            $StartTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
            $EndTime = Get-Date
        }
        catch {
            if ($LogEntries) { Add-LogEntry -Message "Failed to resolve last boot time: $_" -Icon 'warningcritical' @summaryParams }
            return $results
        }
    }
    # 2) TimeRange
    elseif ($TimeRange) {
        $resolvedSelector = 'TimeRange'
        $EndTime = Get-Date

        if ($TimeRange -match "^\s*(\d+)\s*hours?\s*$") {
            $StartTime = $EndTime.AddHours( - [int]$matches[1])
        }
        elseif ($TimeRange -match "^\s*(\d+)\s*days?\s*$") {
            $StartTime = $EndTime.AddDays( - [int]$matches[1])
        }
        else {
            if ($LogEntries) { Add-LogEntry -Message "Invalid time range format. Use 'X hours' or 'X days'." -Icon 'warningcritical' @summaryParams }
            return $results
        }
    }
    # 3) Explicit Start/End validation
    else {
        # EndTime without StartTime is a show-stopper (keep your existing example, just ensure flush)
        if (-not $hasStart -and $hasEnd) {
            Add-LogEntry "Invalid parameters: -EndTime was provided without -StartTime." -Icon 'warningcritical' @summaryParams
            return $results
        }

        # If no selector provided at all
        if (-not $hasStart -and -not $SinceLastBoot -and -not $TimeRange) {
            if ($LogEntries) { Add-LogEntry -Message "You must specify one of: -SinceLastBoot, -TimeRange, or -StartTime (with optional -EndTime)." -Icon 'warningcritical' @summaryParams }
            return $results
        }

        # Validate StartTime
        if (-not $StartTime) {
            if ($LogEntries) { Add-LogEntry -Message "StartTime could not be resolved." -Icon 'warningcritical' @summaryParams }
            return $results
        }

        # EndTime handling
        if (-not $hasEnd -or -not $EndTime) {
            $EndTime = Get-Date
        }
        else {
            # EndTime must be after StartTime
            if ($EndTime -le $StartTime) {
                if ($LogEntries) { Add-LogEntry -Message "StartTime must be earlier than EndTime." -Icon 'alert' @summaryParams }
                return $results
            }
        }

        $resolvedSelector = 'DateRange'
    }

    if ($LogEntries) {
        switch ($resolvedSelector) {
            'DateRange' { Add-LogEntry -Message "Scanning logs (DateRange) from $StartTime to $EndTime" -Icon 'scan' @summaryParams }
            'TimeRange' { Add-LogEntry -Message "Scanning logs (TimeRange) from $StartTime to $EndTime" -Icon 'scan' @summaryParams }
            'SinceLastBoot' { Add-LogEntry -Message "Scanning logs since last boot ($StartTime to $EndTime)" -Icon 'scan' @summaryParams }
        }
    }
    # ----- END TIME WINDOW RESOLUTION -----

    $logsToScan = if ($AllLogs) {
        Get-WinEvent -ListLog * | Where-Object { $_.IsEnabled } | Select-Object -ExpandProperty LogName
    }
    else {
        @($LogName)
    }

    $logSummary = @{}

    foreach ($log in $logsToScan) {
        if ($LogEntries) { Add-LogEntry -Message "Checking log: $log" -Icon 'scan' -Buffer $log }

        $filter = @{
            LogName   = $log
            StartTime = $StartTime
            EndTime   = $EndTime
            Level     = $Levels
        }

        if ($EventIds) { $filter['Id'] = $EventIds }
        if ($Source) { $filter['ProviderName'] = $Source }

        try {
            $events = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue
        }
        catch {
            if ($LogEntries) { Add-LogEntry -Message "⚠️ Failed to read log: $log - $_" -Buffer $log -FlushBuffer }
            continue
        }

        $eventCount = 0
        if ($events) {
            foreach ($logEvent in $events) {

                if ($LogEntries) {
                    $entry = "[$($logEvent.TimeCreated)] ID $($logEvent.Id) [$($logEvent.LevelDisplayName)] [$($logEvent.ProviderName)]`n$($logEvent.Message)"
                    Add-LogEntry -Message $entry -Icon 'detil' -Buffer $log
                }

                $results.Add($logEvent) | Out-Null
                $eventCount++
            }
        }
        else {
            if ($LogEntries) { Add-LogEntry -Message "No events found in $log" -icon 'ok' -Buffer $log }
        }

        Add-LogEntry "${log}: $eventCount events" -Icon 'summary' -Buffer 'summary'
        $logSummary[$log] = $eventCount
        if ($LogEntries) { Add-LogEntry -Message "Total events in ${log}: $eventCount" -Icon 'count' -Buffer $log -FlushBuffer }
    }

    #if ($LogEntries) {
    Add-LogEntry -Message "Completed event log scan." -Icon 'completed' -Buffer 'summary' -FlushBuffer
    #}

    return $results
}
#endregion

#region File: Get-EventTimeDifferences.ps1
function Get-EventTimeDifferences {
    param (
        [string]$LogName = 'System'
    )
    Add-LogEntry -Message "Start Get-EventTimeDifferences" -AddToBody

    # Get the events
    $events = Get-WinEvent -LogName $LogName | Where-Object { $_.Id -eq 6006 -or $_.Id -eq 1074 -or $_.Id -eq 6005 }

    # Filter events by instance ID
    $event1074 = $events | Where-Object { $_.Id -eq 1074 } | Select-Object -First 1
    $event6006 = $events | Where-Object { $_.Id -eq 6006 } | Select-Object -First 1
    $event6005 = $events | Where-Object { $_.Id -eq 6005 } | Select-Object -First 1

    # Output the content of the events as a table and store it in a variable
    $eventTable = $event1074, $event6006, $event6005 | Format-Table -Property TimeCreated, Id, LevelDisplayName, Message | Out-String
    write-host Event Table: $eventTable
    Add-LogEntry -Message "$eventTable" -AddToBody
    $Formatted1074 = "Event 1074: `n$($event1074 | Format-List | Out-String)"
    $Formatted6006 = "Event 6006: `n$($event6006 | Format-List | Out-String)"
    $Formatted6005 = "Event 6005: `n$($event6005 | Format-List | Out-String)"
    Add-LogEntry "----------" -AddToBody
    Add-LogEntry -Message $Formatted1074 -AddToBody
    Add-LogEntry -Message $Formatted6006 -AddToBody
    Add-LogEntry -Message $Formatted6005 -AddToBody
    #    write-host $Formatted1074
    #    write-host $Formatted6006
    #    write-host $Formatted6005
    #    Write-Host "Event 1074: `n$($event1074 | Format-List | Out-String)"
    #    Write-Host "Event 6006: `n$($event6006 | Format-List | Out-String)"
    #    Write-Host "Event 6005: `n$($event6005 | Format-List | Out-String)"

    # Calculate time differences
    $timeDiff1074to6006 = New-TimeSpan -Start $event1074.TimeCreated[0] -End $event6006.TimeCreated[0]
    $timeDiff6006to6005 = New-TimeSpan -Start $event6006.TimeCreated[0] -End $event6005.TimeCreated[0]

    # Format time differences
    $formatted1074to6006 = '{0:hh}:{0:mm}:{0:ss}' -f $timeDiff1074to6006
    $formatted6006to6005 = '{0:hh}:{0:mm}:{0:ss}' -f $timeDiff6006to6005

    Add-LogEntry -message "Time between Event 1074 and 6006: $formatted1074to6006" -AddToBody
    Add-LogEntry -message "Time between Event 6006 and 6005: $formatted6006to6005" -AddBody

    # Output results
    [PSCustomObject]@{
        Event1074to6006 = $formatted1074to6006
        Event6006to6005 = $formatted6006to6005
    }
}
#endregion

#region File: Get-FastBootSetting.ps1
function Get-FastBootSetting {
    # Fast Boot is controlled via registry in Windows
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    $valueName = "HiberbootEnabled"
    try {
        $value = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue
        if ($null -ne $value) {
            if ($value.HiberbootEnabled -eq 1) {
                return "On"
            }
            elseif ($value.HiberbootEnabled -eq 0) {
                return "Off"
            }
            else {
                return "Unknown"
            }
        }
        else {
            return "Not Found"
        }
    }
    catch {
        return "Error: $($_.Exception.Message)"
    }
}
#endregion

#region File: Get-LastBootUpTime.ps1
Function Get-LastBootUpTime { 
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    # Get the last boot-up time
    $lastBootUpTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $lastBootUpTime.ToString('MM/dd/yyyy hh:mm:ss tt')
    # Calculate the time since the last boot-up
    $lbt = (Get-Date) - $lastBootUpTime

    # Create the message with icon
    if ($lbt.Days -ge 10) {
        $MsgIcon = '🚨'
        Add-DrRecommendation -Message "System restart required." -SuggestedAction "Restart the computer." -Severity 'High' @detailsParams
    }
    elseif ($lbt.Days -ge 6) {
        $MsgIcon = '❗'
        Add-DrRecommendation -Message "System restart required." -SuggestedAction "Restart the computer." -Severity 'Normal' @detailsParams
    } 
    else { $MsgIcon = '✅' }

    $Msg = $MsgIcon + "It's been " + $lbt.Days + " days, " + $lbt.Hours + " hours, and " + $lbt.Minutes + " minutes since the last boot-up."

    # Add the Msg property to the $lbt object
    $lbt | Add-Member -MemberType NoteProperty -Name Msg -Value $Msg

    # Add the LastBootUpTime property to the $lbt object
    $lbt | Add-Member -MemberType NoteProperty -Name LastBootUpTime -Value $lastBootUpTime

    # Always log the raw timestamp first using @detailsParams
    #Add-LogEntry -Message  "Last boot-up time: $lastBootUpTime" @detailsParams -Icon 'clock'

    # Log the uptime message according to switches
    #Add-LogEntry -Message $Msg @summaryParams -Icon 'clock'
    Add-LogEntry -Message " $lastBootUpTime - $Msg" -Icon 'clock'  @summaryParams

    # Return the $lbt object
    return $lbt
}
#endregion

#region File: Get-LocalAccountBaseline.ps1
function Get-LocalAccountBaseline {
    [CmdletBinding()]
    param (
        [string]$ExportPath = $Global:DrAcctBaselinePath,
        [switch]$Detail,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        if (-not (Test-Path $ExportPath)) {
            Add-LogEntry -Message "Baseline file not found at $ExportPath" -Icon "Error" @summaryParams
            return $null
        }

        $baselineJson = Get-Content -Path $ExportPath -Encoding UTF8 | Out-String
        $baselineObject = $baselineJson | ConvertFrom-Json

        Add-LogEntry -Message "Baseline retrieved from $ExportPath (Timestamp: $($baselineObject.Timestamp), Total users: $($baselineObject.Accounts.Count))" -Icon "Baseline" @summaryParams

        if ($Detail) {
            Write-ObjProperties -InputObject $baselineObject.Accounts -Icon User -Detailed @summaryParams
        }

        return $baselineObject
    }
    catch {
        Add-LogEntry -Message "Failed to retrieve baseline: $_" -Icon "Error" @summaryParams
        return $null
    }
}
#endregion

#region File: Get-LocalAccountSnapshot.ps1
function Get-LocalAccountSnapshot {
    [CmdletBinding()]
    param (
        [string]$ExportPath = $Global:DrAcctBaselinePath,
        [switch]$UpdateBaseline,
        [switch]$Detail,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        $users = Get-LocalUser | Sort-Object Name
        $results = @()

        foreach ($user in $users) {
            $groups = "Standard"
            if (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*\$($user.Name)" }) {
                $groups = "Administrators"
            }

            $flags = @()
            if ($groups -eq "Administrators") { $flags += "Admin" }
            if ($user.PasswordNeverExpires) { $flags += "PwdNeverExpires" }
            if (-not $user.Enabled) { $flags += "Disabled" }

            # Check if hidden from logon
            try {
                $hiddenValue = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList" -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty $user.Name -ErrorAction SilentlyContinue)
                if ($hiddenValue -eq 0) { $flags += "HiddenFromLogon" }
            }
            catch { }

            $results += [PSCustomObject]@{
                Name                 = $user.Name
                FullName             = $user.FullName
                Enabled              = $user.Enabled
                LastLogon            = $user.LastLogon
                PasswordNeverExpires = $user.PasswordNeverExpires
                Groups               = $groups
                SecurityFlags        = ($flags -join ", ")
            }
        }

        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        if ($UpdateBaseline) {
            $folder = Split-Path $ExportPath
            if (-not (Test-Path $folder)) {
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
                Add-LogEntry -Message "Created folder for baseline: $folder" -Icon "FileAction" @detailsParams
            }

            $isNewBaseline = -not (Test-Path $ExportPath)

            $exportObject = [PSCustomObject]@{
                Timestamp = $timestamp
                Accounts  = $results
            }

            $exportObject | ConvertTo-Json -Depth 4 | Set-Content -Path $ExportPath -Encoding UTF8

            if ($isNewBaseline) {
                Add-LogEntry -Message "Initial baseline created at $ExportPath on $timestamp. Total users: $($results.Count)" -Icon "Compare" @summaryParams
            }
            else {
                Add-LogEntry -Message "Baseline updated at $ExportPath on $timestamp. Total users: $($results.Count)" -Icon "Security" @summaryParams
            }
        }
        else {
            Add-LogEntry -Message "Snapshot collected on $timestamp (baseline not updated). Total users: $($results.Count)" -Icon "Security" @summaryParams
        }

        if ($Detail) {
            Write-ObjProperties -InputObject $results -Icon User -Detailed -FlushBuffer
        }

        return $results
    }
    catch {
        Add-LogEntry -Message "Failed to retrieve snapshot: $_" -Icon "Error" @summaryParams
    }
}
#endregion

#region File: Get-LogEntryParams.ps1
function Get-LogEntryParams {
    [CmdletBinding()]
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    # Resolve selector tokens to the correct global buffer list
    if ($Buffer -and $Buffer.Count -gt 0 -and $Buffer.Count -eq 1) {

        $token = $Buffer[0]
        if ($token) { $token = $token.Trim() }

        if ($token -and $token -ieq '*default') {
            $Buffer = $Global:Default
        }
        elseif ($token -and $token -ieq '*defaultsummary') {
            $Buffer = $Global:DrLogSummaryBuffer
        }
        elseif ($token -and $token -ieq '*defaultdetails') {
            $Buffer = $Global:DrLogDetailsBuffer
        }
        elseif ($token -and $token -ieq '*defaulterrors') {
            $Buffer = $Global:DrLogErrorBuffers
        }
    }

    $summaryParams = @{}
    $detailsParams = @{}

    # Only build params when Buffer is present
    if ($Buffer -and $Buffer.Count -gt 0) {

        # Details: buffer only
        $detailsParams['Buffer'] = $Buffer

        # Summary: buffer + ALWAYS include FlushBuffer (true or false)
        $summaryParams['Buffer'] = $Buffer
        $summaryParams['FlushBuffer'] = [bool]$FlushBuffer
    }

    [pscustomobject]@{
        Details = $detailsParams
        Summary = $summaryParams
    }
}
#endregion

#region File: Get-LoggedInUser.ps1
function Get-LoggedInUser {
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    # Buffering is optional; do not set a default buffer here
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    try {
        $LoggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        if ($LoggedInUser) {
            Add-LogEntry -Message "The currently logged-in user is: $LoggedInUser" -Icon 'user'  @summaryParams
        }
        else {
            Add-LogEntry -Message "No user is currently logged in." -Icon 'computer'  @summaryParams
        }
        return $LoggedInUser
    }
    catch {
        Add-LogEntry -Message "Error retrieving logged-in user: $_" -Icon 'error'  @summaryParams
        return $null
    }
}
#endregion

#region File: Get-LogIcon.ps1
function Get-LogIcon {
    param ([string]$Icon)

    $icons = @{}

    # ==== Base mappings (as provided) ====
    $icons['action'] = '🛠️'
    $icons['alert'] = '❗'
    $icons['alertactive'] = '🚨'
    $icons['alertcleared'] = '✅'
    $icons['alertmuted'] = '🔕'
    $icons['api'] = '🔗'
    $icons['attach'] = '📎'
    $icons['backup'] = '💾'
    $icons['baseline'] = '📋'
    $icons['battery'] = '🔋'
    $icons['blocked'] = '🚫'
    $icons['brain'] = '🧠'
    $icons['bugcheck'] = '🧩'
    $icons['canceled'] = '❌'
    $icons['chemistry'] = '🧪'
    $icons['check'] = '✔️'
    $icons['cleanup'] = '🧹'
    $icons['clock1'] = '🕒'
    $icons['clock'] = '🕓'
    $icons['compare'] = '🔍'
    $icons['completed'] = '✔️'
    $icons['computer'] = '🖥'
    $icons['critical'] = '🚨'
    $icons['database'] = '🗃️'
    $icons['debug'] = '🐞'
    $icons['deleted'] = '🗑️'
    $icons['dependency'] = '🪝'
    $icons['detail'] = '📝'
    $icons['details'] = '📝'
    $icons['disk'] = '💽'
    $icons['disk-details'] = '🖴'
    $icons['download'] = '⬇️'
    $icons['drmodule'] = '🧱'
    $icons['endoflist'] = '🔚'
    $icons['endsection'] = '📦'
    $icons['environment'] = '🌐'
    $icons['error'] = '❌'
    $icons['event'] = '📅'
    $icons['eye'] = '👁️'
    $icons['failed'] = '❌'
    $icons['file'] = '📄'
    $icons['fileaction'] = '📄🛠️'
    $icons['filehandling'] = '📄🔄'
    $icons['folder'] = '📂'
    $icons['folderclosed'] = '📁🔒'
    $icons['hardware'] = '🛠️'
    $icons['id'] = '🆔'
    $icons['id2'] = '🪪'
    $icons['inprogress'] = '🔄'
    $icons['info'] = 'ℹ️'
    $icons['install'] = '📦'
    $icons['jobcheck'] = '✔️'
    $icons['jobend'] = '🎯'
    $icons['jobendarrow'] = '🔚'
    $icons['jobfinalized'] = '📦'
    $icons['joblifecycle'] = '🔁'
    $icons['jobprogress'] = '🔄'
    $icons['jobstart'] = '🚀'
    $icons['jobtools'] = '🛠️'
    $icons['key'] = '🔑'
    $icons['license'] = '🧾'
    $icons['list'] = '📋'
    $icons['lock'] = '🔒'
    $icons['lockandkey'] = '🔐'
    $icons['logfile'] = '📄'
    $icons['magnet'] = '🧲'
    $icons['mailbox'] = '📭'
    $icons['module'] = '🧱'
    $icons['monitor'] = '📈'
    $icons['network'] = '🌐'
    $icons['no'] = '🚫'
    $icons['nopermissions'] = '🚫'
    $icons['nopermissionsalt'] = '⛔'
    $icons['note'] = '📝'
    $icons['number'] = '#'
    $icons['numbers'] = '🔢'
    $icons['numberpad'] = '🔢'
    $icons['numpad'] = '🔢'
    $icons['ok'] = '✔️'
    $icons['openfolder'] = '📂'
    $icons['optical'] = '📀'
    $icons['permission'] = '🔐'
    $icons['power'] = '⚡'
    $icons['powercheck'] = '📶'
    $icons['printer'] = '🖨️'
    $icons['process'] = '⚙️'
    $icons['properties'] = '📋'
    $icons['property'] = '📋'
    $icons['received'] = '📥'
    $icons['recordupdate'] = '✏️'
    $icons['recovery'] = '🛟'
    $icons['refresh'] = '🔄'
    $icons['rejected'] = '📛'
    $icons['registry'] = '🧬'
    $icons['repair'] = '🛠️'
    $icons['resolvealert'] = '🧹'
    $icons['restart'] = '🔁'
    $icons['restore'] = '♻️'
    $icons['scan'] = '🔍'
    $icons['schedule'] = '📆'
    $icons['script'] = '📜'
    $icons['search'] = '🔍'
    $icons['searching'] = '🔍'
    $icons['security'] = '🛡️'
    $icons['sendalert'] = '📣'
    $icons['inbox'] = '📤'
    $icons['send'] = '📨'
    $icons['sent'] = '📨'
    $icons['service'] = '🧩'
    $icons['settings'] = '⚙️'
    $icons['settingsoverride'] = '⚙️'
    $icons['shutdown'] = '📴'
    $icons['skipped'] = '⏭️'
    $icons['startup'] = '🚀'
    $icons['status'] = '📶'
    $icons['statusfail'] = '🔴'
    $icons['statusok'] = '🟢'
    $icons['statuswarn'] = '🟡'
    $icons['storage'] = '🗄️'
    $icons['success'] = '✅'
    $icons['syncroapi'] = '🔗'
    $icons['system'] = '🖥️'
    $icons['systemaction'] = '🛠️'
    $icons['systemdecision'] = '🧭'
    $icons['systeminfo'] = '📶'
    $icons['systeminit'] = '🧰'
    $icons['systemlogic'] = '🧮'
    $icons['systemmessage'] = '📶'
    $icons['systemtools'] = '🪛'
    $icons['systemupdate'] = '🔧'
    $icons['summary'] = '📋'
    $icons['task'] = '📌'
    $icons['terminate'] = '💀'
    $icons['terminated'] = '💀'
    $icons['ticket'] = '🎫'
    $icons['ticketclosed'] = '📫'
    $icons['ticketcomment'] = '💬'
    $icons['ticketcreated'] = '🎫'
    $icons['tickethandling'] = '📋'
    $icons['ticketinfo'] = '💳'
    $icons['ticketupdate'] = '🛠️'
    $icons['timeout'] = '⏱️'
    $icons['timer'] = '⏱️'
    $icons['trophy'] = '🏆'
    $icons['uninstall'] = '🗑️'
    $icons['unlocked'] = '🔓'
    $icons['update'] = '🔄'
    $icons['upload'] = '⬆️'
    $icons['ups'] = '🔌'
    $icons['user'] = '👤'
    $icons['voltage'] = '🔌'
    $icons['warning'] = '⚠️'
    $icons['watch'] = '👁️'
    $icons['wrench'] = '🔧'

    # ==== CPU-related mappings ====
    $icons['cpu'] = '🖥️'
    $icons['cpuprocess'] = '🧠'
    $icons['cpuhardware'] = '⚙️'
    $icons['cpublock'] = '🔲'
    $icons['cputrack'] = '🖲️'
    $icons['cpunetwork'] = '🖧'
    $icons['cpucompute'] = '🖩'
    $icons['cputemp'] = '🖥️🌡️'

    # ==== Sensors / temps ====
    $icons['thermometer'] = '🌡️'
    $icons['heat'] = '🔥'
    $icons['cooling'] = '❄️'

    # ==== Totals / counts ====
    $icons['total'] = 'Σ'
    $icons['totals'] = 'Σ'
    $icons['sum'] = '∑'
    $icons['count'] = '#'
    $icons['counts'] = '#'
    $icons['tally'] = 'Σ'

    # ==== NEW: Core warning severities (requested) ====
    # Keep existing: $icons['warning'] = '⚠️'
    $icons['warninglow'] = '🔶'      # Low severity (orange large diamond)
    $icons['warningsevere'] = '‼️'   # Severe (double exclamation)
    $icons['warningcritical'] = '🚨' # Critical-level warning (aligns with global 'critical')

    # ==== NEW: Diamond severity family (same-shape color approach) ====
    $icons['warninglow-diamond'] = '🔶'     # Low (orange large diamond)
    $icons['warning-diamond'] = '🔷'        # Medium / regular (blue large diamond)
    $icons['warningsevere-diamond'] = '♦️'  # Severe (red diamond suit)

    # ==== NEW: Color-circle options ====
    $icons['circle-orange'] = '🟠'
    $icons['circle-yellow'] = '🟡'
    $icons['circle-green'] = '🟢'
    $icons['circle-blue'] = '🔵'
    $icons['circle-purple'] = '🟣'
    $icons['circle-brown'] = '🟤'
    $icons['circle-white'] = '⚪'
    $icons['circle-red'] = '🔴'   # Note: you already use 'statusfail' = 🔴

    # ==== NEW: Bright squares (high visibility) ====
    $icons['square-red'] = '🟥'
    $icons['square-orange'] = '🟧'
    $icons['square-yellow'] = '🟨'
    $icons['square-green'] = '🟩'
    $icons['square-blue'] = '🟦'
    $icons['square-purple'] = '🟪'
    $icons['square-brown'] = '🟫'
    $icons['square-white'] = '⬜'

    # ==== NEW: Diamonds (generic options) ====
    $icons['diamond-orange-large'] = '🔶'
    $icons['diamond-blue-large'] = '🔷'
    $icons['diamond-orange-small'] = '🔸'
    $icons['diamond-blue-small'] = '🔹'

    # ==== NEW: Triangle alternatives ====
    $icons['triangle-up-red'] = '🔺'
    $icons['triangle-down-red'] = '🔻'
    $icons['triangle-up-white'] = '🔼'
    $icons['triangle-down-white'] = '🔽'

    # === New Icons Added ===

    # Memory / RAM
    $icons['memory'] = '🎛️'

    # Generic Usage
    $icons['usage'] = '📊'

    # EC Chip
    $icons['ecchip'] = '📟'

    # Component (alias created earlier)
    $icons['component'] = '📟'

    $icons['pie'] = '◔'
    $icons['piehalf'] = '◑'
    $icons['piefull'] = '◕'
    $icons['chart'] = '◔'

    # ==== NEW: Recycling / sustainability (added) ====
    $icons['recycle'] = '♻️'
    $icons['recycling'] = '♻️'
    $icons['recyclebin'] = '♻️'
    $icons['reuse'] = '🔄'
    $icons['cycle'] = '🔄'
    $icons['circulararrows'] = '🔄'
    $icons['circular-arrows'] = '🔄'
    $icons['sustainability'] = '🌱'
    $icons['eco'] = '🌱'
    $icons['green'] = '🌱'

    $lowerIcon = $Icon.ToLowerInvariant()
    if ($icons.ContainsKey($lowerIcon)) {
        return $icons[$lowerIcon]
    }
    else {
        return '❓'
    }
}
#endregion

#region File: Get-NetworkAdapters.ps1
function Get-NetworkAdapters {
    [CmdletBinding()]
    param (
        [string]$ComputerName = $env:COMPUTERNAME,
        [switch]$ConnectedOnly,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    $iBuffer = @('Network Adapter')
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    Log-Invocation -IncludeParameters @detailsParams  

    try {
        $networkAdapters = Get-WmiObject -Class Win32_NetworkAdapter -ComputerName $ComputerName -ErrorAction Stop
        $filteredAdapters = @()

        foreach ($adapter in $networkAdapters) {
            $status = switch ($adapter.NetConnectionStatus) {
                0 { "Disconnected" }
                1 { "Connecting" }
                2 { "Connected" }
                3 { "Disconnecting" }
                4 { "Hardware not present" }
                5 { "Hardware disabled" }
                6 { "Hardware malfunction" }
                7 { "Media disconnected" }
                8 { "Authenticating" }
                default { "Unknown" }
            }

            if ($ConnectedOnly -and $status -ne "Connected") {
                continue
            }

            $mediaType = switch ($adapter.AdapterType) {
                "Ethernet 802.3" { "Ethernet" }
                "Wireless" { "Wi-Fi" }
                "Bluetooth" { "Bluetooth" }
                default { $adapter.AdapterType }
            }

            $connectionSpeed = if ($adapter.Speed) { "$($adapter.Speed / 1MB) Mbps" } else { "Unknown" }

            $filteredAdapters += [PSCustomObject]@{
                Name            = $adapter.Name
                Status          = $status
                MediaType       = $mediaType
                ConnectionSpeed = $connectionSpeed
            }
        }

        if ($filteredAdapters.Count -gt 0) {
            Write-ObjProperties $filteredAdapters -Icon "network" -Detailed -Buffer $iBuffer
            Add-LogEntry -Message "End of list. Total adapters: $($filteredAdapters.Count)" -Buffer $iBuffer -FlushBuffer
            Add-LogEntry -Message "End of list. Total adapters: $($filteredAdapters.Count)" @summaryParams
        }
        else {
            Write-Output "No adapters found."
            Add-LogEntry -Message "No adapters found." -Buffer $iBuffer -FlushBuffer
            Add-LogEntry -Message "No adapters found." @summaryParams
        }
    }
    catch {
        Write-Error "Failed to retrieve network adapters: $_"
        Add-LogEntry -Message "Failed to retrieve network adapters: $_" -Buffer $iBuffer -FlushBuffer
        Add-LogEntry -Message "Failed to retrieve network adapters: $_" @summaryParams
    }
}
#endregion

#region File: Get-NetworkInfo.ps1
function Get-NetworkInfo {
    [CmdletBinding()]
    param(
        [switch]$DottedSubnet,  # Optional: convert PrefixLength (CIDR) to dotted mask
        [string[]]$Buffer = 'network info',
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    # Helper: CIDR prefix -> dotted mask
    function Convert-PrefixToMask {
        param([int]$Prefix)
        if ($Prefix -lt 0 -or $Prefix -gt 32) { return $null }
        $bits = ('1' * $Prefix) + ('0' * (32 - $Prefix))
        $octets = 0..3 | ForEach-Object { [convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }
        return ($octets -join '.')
    }

    # Helper: format numbers with thousands separators; keep non-numeric strings as-is
    function Format-Num {
        param($Value)
        if ($null -eq $Value) { return $null }
        try {
            if ($Value -is [string]) {
                $s = $Value.Trim()
                if ($s -match '^\d+$') { return ('{0:N0}' -f [int64]$s) }
                else { return $Value }  # e.g., VLAN IDs that may include letters
            }
            else {
                return ('{0:N0}' -f [decimal]$Value)
            }
        }
        catch { return $Value }
    }

    # Helper: Parse netsh wlan show interfaces for SSID/BSSID/etc.
    function Get-WlanInterfaceInfo {
        $map = @{}
        try {
            $text = netsh wlan show interfaces 2>$null
            if (-not $text) { return $map }
            $current = $null
            foreach ($line in $text) {
                $line = $line.Trim()
                if ($line -match '^Name\s*:\s*(.+)$') {
                    $name = $Matches[1].Trim()
                    $current = [ordered]@{ Name = $name }
                    $map[$name] = $current
                    continue
                }
                if (-not $current) { continue }
                if ($line -match '^SSID\s*:\s*(.+)$') { $current.SSID = $Matches[1].Trim(); continue }
                elseif ($line -match '^BSSID\s*:\s*(.+)$') { $current.BSSID = $Matches[1].Trim(); continue }
                elseif ($line -match '^Signal\s*:\s*(.+)$') { $current.Signal = $Matches[1].Trim(); continue }
                elseif ($line -match '^Channel\s*:\s*(.+)$') { $current.Channel = $Matches[1].Trim(); continue }
                elseif ($line -match '^Radio type\s*:\s*(.+)$') { $current.RadioType = $Matches[1].Trim(); continue }
                elseif ($line -match '^Authentication\s*:\s*(.+)$') { $current.Authentication = $Matches[1].Trim(); continue }
                elseif ($line -match '^Cipher\s*:\s*(.+)$') { $current.Cipher = $Matches[1].Trim(); continue }
                elseif ($line -match '^Receive rate \(Mbps\)\s*:\s*(.+)$') { $current.ReceiveRateMbps = $Matches[1].Trim(); continue }
                elseif ($line -match '^Transmit rate \(Mbps\)\s*:\s*(.+)$') { $current.TransmitRateMbps = $Matches[1].Trim(); continue }
            }
        }
        catch { }
        return $map
    }

    # Helper: Detect VLAN state/ID from advanced adapter properties (ID may include letters; keep as string)
    function Get-VlanInfoForAdapter {
        param([string]$AdapterName)
        $vlanEnabled = $false
        $vlanId = $null
        try {
            $adv = Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction SilentlyContinue
            foreach ($p in $adv) {
                if ($p.DisplayName -match 'vlan' -or $p.RegistryKeyword -match 'vlan') {
                    $vlanEnabled = $true
                    if ($p.DisplayName -match 'id' -or $p.RegistryKeyword -match 'id') {
                        $vlanId = ($p.DisplayValue | Out-String).Trim()
                    }
                    elseif (-not $vlanId) {
                        $vlanId = ($p.DisplayValue | Out-String).Trim()
                    }
                }
            }
        }
        catch { }
        [pscustomobject]@{
            VlanEnabled = $vlanEnabled
            VlanId      = $vlanId
        }
    }

    try {
        Add-LogEntry -Message "Starting network info retrieval..." -Icon 'status' @detailsParams

        # Force arrays to handle single-object results cleanly
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
        $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
        $ipConfigs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
        $ipIfaces = @(Get-NetIPInterface -ErrorAction SilentlyContinue)  # for InterfaceMetric & MTU
        $wifiMap = Get-WlanInterfaceInfo

        if (-not $adapters -or $adapters.Count -eq 0) {
            Add-LogEntry -Message "No physical 'Up' adapters found." -Icon 'warning' @detailsParams
            Add-LogEntry -Message "Completed network info retrieval (no adapters)." -Icon 'statusok' @summaryParams
            return @()
        }

        $results = @()

        foreach ($adapter in $adapters) {
            if (-not $adapter.Name) {
                Write-Warning "Skipping adapter with missing name."
                Add-LogEntry -Message "Skipping adapter with missing name." -Icon 'warning' @detailsParams
                continue
            }
            write-host "made it here."

            # Profile matching: prefer InterfaceIndex, fallback Alias; prefer connected
            $profileCandidates = $profiles | Where-Object {
                $_.InterfaceIndex -eq $adapter.InterfaceIndex -or $_.InterfaceAlias -eq $adapter.Name
            }
            $profile = $profileCandidates | Where-Object {
                $_.IPv4Connectivity -ne 'Disconnected' -or $_.IPv6Connectivity -ne 'Disconnected'
            } | Select-Object -First 1
            if (-not $profile) { $profile = $profileCandidates | Select-Object -First 1 }

            # Robust profile name
            $profileName = $null
            if ($profile) {
                $props = $profile.PSObject.Properties.Name
                if ($props -contains 'Name') { $profileName = $profile.Name }
                elseif ($props -contains 'NetworkName') { $profileName = $profile.NetworkName }
            }

            # IP config matching: prefer InterfaceIndex, fallback Alias
            $ipConfig = ($ipConfigs | Where-Object {
                    $_.InterfaceIndex -eq $adapter.InterfaceIndex -or $_.InterfaceAlias -eq $adapter.Name
                } | Select-Object -First 1)

            # IP interface metric & MTU
            $ipIface = ($ipIfaces | Where-Object { $_.InterfaceIndex -eq $adapter.InterfaceIndex } | Select-Object -First 1)
            $ifaceMetric = if ($ipIface) { $ipIface.InterfaceMetric } else { $null }
            $mtu = $null
            if ($ipIface) {
                $ifaceProps = $ipIface.PSObject.Properties.Name
                if ($ifaceProps -contains 'NlMtu') { $mtu = $ipIface.NlMtu }
                elseif ($ifaceProps -contains 'Mtu') { $mtu = $ipIface.Mtu }
            }

            # Adapter statistics (correct property names)
            $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
            $hasStats = $stats -and ($null -ne $stats.SentBytes -or $null -ne $stats.ReceivedBytes)

            if (-not $hasStats) {
                Add-LogEntry -Message "Adapter '$($adapter.Name)' did not return statistics." -Icon 'warning' @detailsParams
                $bytesSent = 0; $bytesReceived = 0
                $packetsSent = 0; $packetsReceived = 0
                $outputErrors = 0; $inputErrors = 0
                $discardOut = 0; $discardIn = 0
            }
            else {
                $bytesSent = $stats.SentBytes
                $bytesReceived = $stats.ReceivedBytes

                # Totals = Unicast + Broadcast + Multicast
                $packetsSent = ($stats.SentUnicastPackets + $stats.SentBroadcastPackets + $stats.SentMulticastPackets)
                $packetsReceived = ($stats.ReceivedUnicastPackets + $stats.ReceivedBroadcastPackets + $stats.ReceivedMulticastPackets)

                # Errors
                $outputErrors = $stats.OutboundPacketErrors
                $inputErrors = $stats.ReceivedPacketErrors

                # Discarded packets
                $discardOut = $stats.OutboundDiscardedPackets
                $discardIn = $stats.ReceivedDiscardedPackets
            }

            # Safe extraction with null guards
            $ipv4Addr = $null
            $ipv6Addr = $null
            $subnetPrefix = $null
            $defaultGateway = $null
            $dnsServers = $null
            $dnsSuffix = $null
            $dhcpEnabled = $false
            if ($ipConfig) {
                if ($ipConfig.IPv4Address) {
                    $ipv4Addr = $ipConfig.IPv4Address.IPAddress
                    $subnetPrefix = $ipConfig.IPv4Address.PrefixLength
                }
                if ($ipConfig.IPv6Address) { $ipv6Addr = $ipConfig.IPv6Address.IPAddress }
                if ($ipConfig.IPv4DefaultGateway) { $defaultGateway = $ipConfig.IPv4DefaultGateway.NextHop }
                if ($ipConfig.DNSServer -and $ipConfig.DNSServer.ServerAddresses) {
                    $dnsServers = ($ipConfig.DNSServer.ServerAddresses) -join ', '
                }
                $dnsSuffix = $ipConfig.DnsSuffix
                $dhcpEnabled = ($ipConfig.Dhcp -eq 'Enabled')
            }

            # Derived values
            $networkType = switch ($adapter.MediaType) {
                '802.3' { 'Wired' }
                'Native 802.11' { 'Wireless' }
                default { 'Unknown' }
            }
            $connectionType = if ($profile) { "$($profile.NetworkCategory)" } else { 'Unknown' }

            # Optional dotted subnet conversion (else format CIDR)
            $subnetMaskOut = $subnetPrefix
            if ($DottedSubnet -and $null -ne $subnetPrefix) { $subnetMaskOut = Convert-PrefixToMask -Prefix $subnetPrefix }

            # VLAN info (ID may have letters; keep as string)
            $vlanInfo = Get-VlanInfoForAdapter -AdapterName $adapter.Name

            # Wi-Fi SSID and radio details
            $wifi = $null
            if ($adapter.MediaType -eq 'Native 802.11') {
                if ($wifiMap.ContainsKey($adapter.Name)) { $wifi = $wifiMap[$adapter.Name] }
                elseif ($profileName -and $wifiMap.ContainsKey($profileName)) { $wifi = $wifiMap[$profileName] }
            }

            # Route info for this interface (sorted by metric then prefix)
            $routesRaw = @(Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue)
            $routesSorted = $routesRaw | Sort-Object -Property RouteMetric, DestinationPrefix
            $routes = @()
            foreach ($r in $routesSorted) {
                $routes += [PSCustomObject]@{
                    DestinationPrefix = "$($r.DestinationPrefix)"
                    NextHop           = "$($r.NextHop)"
                    RouteMetric       = Format-Num $r.RouteMetric
                    Protocol          = "$($r.Protocol)"
                    Store             = "$($r.PolicyStore)"
                }
            }

            # Format numeric fields with thousands separators
            $interfaceIndexFmt = Format-Num $adapter.InterfaceIndex
            $ifaceMetricFmt = Format-Num $ifaceMetric
            $mtuFmt = Format-Num $mtu
            $bytesSentFmt = Format-Num $bytesSent
            $bytesReceivedFmt = Format-Num $bytesReceived
            $packetsSentFmt = Format-Num $packetsSent
            $packetsReceivedFmt = Format-Num $packetsReceived
            $outputErrorsFmt = Format-Num $outputErrors
            $inputErrorsFmt = Format-Num $inputErrors
            $discardOutFmt = Format-Num $discardOut
            $discardInFmt = Format-Num $discardIn
            $wifiChannelFmt = if ($wifi) { Format-Num $wifi.Channel } else { $null }
            $wifiRxFmt = if ($wifi) { Format-Num $wifi.ReceiveRateMbps } else { $null }
            $wifiTxFmt = if ($wifi) { Format-Num $wifi.TransmitRateMbps } else { $null }
            $subnetMaskFmt = if ($DottedSubnet) { $subnetMaskOut } else { Format-Num $subnetMaskOut }  # CIDR formatted if not dotted

            # --- Grouped output object ---
            $adapterGroup = [PSCustomObject]@{
                Adapter      = [PSCustomObject]@{
                    AdapterName       = "$($adapter.Name)"
                    InterfaceIndex    = $interfaceIndexFmt
                    InterfaceGuid     = "$($adapter.InterfaceGuid)"
                    Description       = "$($adapter.InterfaceDescription)"
                    DriverInformation = "$($adapter.DriverInformation)"
                    Status            = "$($adapter.Status)"
                    MACAddress        = "$($adapter.MacAddress)"
                    LinkSpeed         = "$($adapter.LinkSpeed)"   # e.g., "390 Mbps"
                    MediaType         = "$($adapter.MediaType)"
                    NetworkType       = $networkType
                }

                Profile      = [PSCustomObject]@{
                    ProfileName      = $profileName
                    ConnectionType   = $connectionType
                    IPv4Connectivity = if ($profile) { $profile.IPv4Connectivity } else { $null }
                    IPv6Connectivity = if ($profile) { $profile.IPv6Connectivity } else { $null }
                }

                BasicNetwork = [PSCustomObject]@{
                    IPv4Address                 = $ipv4Addr
                    IPv6Address                 = $ipv6Addr
                    SubnetMask                  = $subnetMaskFmt
                    DefaultGateway              = $defaultGateway
                    DNSServers                  = $dnsServers
                    DHCPEnabled                 = $dhcpEnabled
                    ConnectionSpecificDNSSuffix = $dnsSuffix
                }

                Statistics   = [PSCustomObject]@{
                    BytesSent                = $bytesSentFmt
                    BytesReceived            = $bytesReceivedFmt
                    PacketsSent              = $packetsSentFmt
                    PacketsReceived          = $packetsReceivedFmt
                    OutputErrors             = $outputErrorsFmt
                    InputErrors              = $inputErrorsFmt
                    OutboundDiscardedPackets = $discardOutFmt
                    ReceivedDiscardedPackets = $discardInFmt
                }

                Wireless     = if ($adapter.MediaType -eq 'Native 802.11') {
                    [PSCustomObject]@{
                        SSID             = if ($wifi) { $wifi.SSID } else { $null }
                        BSSID            = if ($wifi) { $wifi.BSSID } else { $null }
                        Signal           = if ($wifi) { $wifi.Signal } else { $null } # "85%"
                        Channel          = $wifiChannelFmt
                        RadioType        = if ($wifi) { $wifi.RadioType } else { $null }
                        Authentication   = if ($wifi) { $wifi.Authentication } else { $null }
                        Cipher           = if ($wifi) { $wifi.Cipher } else { $null }
                        ReceiveRateMbps  = $wifiRxFmt
                        TransmitRateMbps = $wifiTxFmt
                    }
                }
                else { $null }

                VLAN         = [PSCustomObject]@{
                    VlanEnabled = $vlanInfo.VlanEnabled
                    VlanId      = $vlanInfo.VlanId  # string; may contain letters
                }

                Advanced     = [PSCustomObject]@{
                    InterfaceMetric = $ifaceMetricFmt
                    MTU             = $mtuFmt
                    Routes          = $routes
                }
            }

            Write-ObjProperties $adapterGroup -Detailed -MaxDepth 5 -Icon 'network' @detailsParams
            Add-LogEntry -Message "Retrieved network info for $($adapter.Name)" -Icon 'status' @detailsParams
            Add-LogEntry -Message "===========================" -Icon 'syncroapi' @detailsParams

            $results += $adapterGroup
        }

        Add-LogEntry -Message "Completed network info retrieval." -Icon 'statusok' @summaryParams
        return $results
    }
    catch {
        Add-LogEntry -Message "Get-NetworkInfo failed: $($_.Exception.Message)" -Icon 'error' @summaryParams
        throw
    }
}
#endregion

#region File: GetNextNumericId.ps1
GetNextNumericId([object[]] $existing) {
        if ($existing.Count -gt 0) {
            return ($existing | Measure-Object -Property NumericId -Maximum).Maximum + 1
        }
        else {
            return 1
        }
    }
#endregion

#region File: Get-NumLockState.ps1
function Get-NumLockState {
    try {
        $key = 'HKCU:\Control Panel\Keyboard'
        $name = 'InitialKeyboardIndicators'
        $value = (Get-ItemProperty -Path $key -Name $name).$name

        switch ($value) {
            2 { return "On" }
            0 { return "Off" }
            default { return "Unknown ($value)" }
        }
    }
    catch {
        Write-Error "Failed to determine Num-lock state: $_" -Icon 'error'
        return "Unknown"
    }
}
#endregion

#region File: Get-ObjId.ps1
function Get-ObjId([object]$o) {
                try {
                    if ($null -eq $o) { return 'null' }
                    $id = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($o)
                    "$($o.GetType().FullName):$id"
                }
                catch {
                    [Guid]::NewGuid().ToString()
                }
            }
#endregion

#region File: Get-PaymentProfiles.ps1
function Get-PaymentProfiles {
    [CmdletBinding()]
    param (
        [string]$CustomerId = $Global:DrAsset.customer_id,
        [switch]$AddToBody
    )

    if (-not $CustomerId) {
        Add-LogEntry -Message "❌ No customer ID provided and \$Global:DrAsset.customer_id is not set." -Icon 'SettingsOverride'
        return
    }

    try {
        $endpoint = "/api/v1/customers/$CustomerId/payment_profiles"
        $response = Invoke-DrApiRequest -Method 'GET' -Endpoint $endpoint

        if ($response) {
            Add-LogEntry -Message "💳 Retrieved payment profiles for customer ID $CustomerId." -Icon 'TicketInfo' -AddToBody:$AddToBody
            return $response
        }
        else {
            Add-LogEntry -Message "⚠️ No payment profiles returned for customer ID $CustomerId." -Icon 'Warning' -AddToBody:$AddToBody
        }
    }
    catch {
        Add-LogEntry -Message "❌ Error retrieving payment profiles for customer ID ${CustomerId}: $_" -Icon 'Failure'
    }
}
#endregion

#region File: Get-PowerSourceInfo.ps1
function Get-PowerSourceInfo {
    param (
        [string[]]$Buffer = 'PowerSourceInfo',
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    <#
    .SYNOPSIS
    Retrieves battery or UPS information and logs it using DrModuleV3 standards.

    .DESCRIPTION
    Detects battery or UPS presence via WMI and logs structured output using Add-LogEntry.
    Includes chemistry and status mapping, elevation check, and UUID tagging.

    .NOTES
    Requires DrModuleV3 and admin rights for UPS queries.
    #>

    #Assert-IsAdmin
    #if (-not $Global:IsAdmin) { return }

    # Build-and-return: prepare an object to mirror all Add-LogEntry fields
    $result = [pscustomobject]@{
        Type                   = $null
        Name                   = $null
        Status                 = $null
        'Charge Remaining'     = $null
        'Estimated Runtime'    = $null
        Chemistry              = $null
        'Design Voltage'       = $null
        'Power Mgmt Supported' = $null
        Availability           = $null
        Message                = $null
    }

    try {
        $batteryInfo = Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue
        $upsInfo = Get-WmiObject -Namespace "ROOT\CIMV2" -Class Win32_UninterruptiblePowerSupply -ErrorAction SilentlyContinue

        $statusMap = @{
            1  = "Discharging"
            2  = "AC Power (Not Charging)"
            3  = "Fully Charged"
            4  = "Low"
            5  = "Critical"
            6  = "Charging"
            7  = "Charging and High"
            8  = "Charging and Low"
            9  = "Charging and Critical"
            10 = "Undefined"
            11 = "Partially Charged"
        }

        $chemistryMap = @{
            1 = "Other"
            2 = "Unknown"
            3 = "Lead Acid"
            4 = "Nickel Cadmium"
            5 = "Nickel Metal Hydride"
            6 = "Lithium-ion"
            7 = "Zinc Air"
            8 = "Lithium Polymer"
        }

        Add-LogEntry -Message "Power source info retrieved" -Icon "powercheck" @detailsParams

        if ($batteryInfo) {
            $runtime = if ($batteryInfo.EstimatedRunTime -gt 10000) { "Unknown" } else { "$($batteryInfo.EstimatedRunTime) min" }
            $statusText = if ($statusMap.ContainsKey($batteryInfo.BatteryStatus)) { $statusMap[$batteryInfo.BatteryStatus] } else { "Unknown ($($batteryInfo.BatteryStatus))" }
            $chemistryText = if ($chemistryMap.ContainsKey($batteryInfo.Chemistry)) { $chemistryMap[$batteryInfo.Chemistry] } else { "Unknown ($($batteryInfo.Chemistry))" }

            Add-LogEntry -Message ("Type".PadRight(28) + ": Battery") -Icon "battery" @detailsParams
            Add-LogEntry -Message ("Name".PadRight(28) + ": $($batteryInfo.Name)") -Icon "id" @detailsParams
            Add-LogEntry -Message ("Status".PadRight(28) + ": $statusText") -Icon "power" @detailsParams
            Add-LogEntry -Message ("Charge Remaining".PadRight(28) + ": $($batteryInfo.EstimatedChargeRemaining)%") -Icon "battery" @detailsParams
            Add-LogEntry -Message ("Estimated Runtime".PadRight(28) + ": $runtime") -Icon "timeout" @detailsParams
            Add-LogEntry -Message ("Chemistry".PadRight(28) + ": $chemistryText") -Icon "Chemistry" @detailsParams
            Add-LogEntry -Message ("Design Voltage".PadRight(28) + ": $($batteryInfo.DesignVoltage) mV") -Icon "voltage" @detailsParams

            # Build object (do not change logging)
            $result.Type = 'Battery'
            $result.Name = $batteryInfo.Name
            $result.Status = $statusText
            $result.'Charge Remaining' = if ($batteryInfo.EstimatedChargeRemaining -ne $null) { "$($batteryInfo.EstimatedChargeRemaining)%" } else { $null }
            $result.'Estimated Runtime' = $runtime
            $result.Chemistry = $chemistryText
            $result.'Design Voltage' = if ($batteryInfo.DesignVoltage -ne $null) { "$($batteryInfo.DesignVoltage) mV" } else { $null }
        }
        elseif ($upsInfo) {
            $runtime = if ($upsInfo.EstimatedRunTime -gt 10000) { "Unknown" } else { "$($upsInfo.EstimatedRunTime) min" }

            Add-LogEntry -Message ("Type".PadRight(28) + ": UPS") -Icon "ups" @detailsParams
            Add-LogEntry -Message ("Name".PadRight(28) + ": $($upsInfo.Name)") -Icon "id" @detailsParams
            Add-LogEntry -Message ("Status".PadRight(28) + ": $($upsInfo.Status)") -Icon "power" @detailsParams
            Add-LogEntry -Message ("Estimated Runtime".PadRight(28) + ": $runtime") -Icon "timeout" @detailsParams
            Add-LogEntry -Message ("Power Mgmt Supported".PadRight(28) + ": $($upsInfo.PowerManagementSupported)") -Icon "ups" @detailsParams
            Add-LogEntry -Message ("Availability".PadRight(28) + ": $($upsInfo.Availability)") -Icon "ups" @detailsParams

            # Build object (do not change logging)
            $result.Type = 'UPS'
            $result.Name = $upsInfo.Name
            $result.Status = $upsInfo.Status
            $result.'Estimated Runtime' = $runtime
            $result.'Power Mgmt Supported' = $upsInfo.PowerManagementSupported
            $result.Availability = $upsInfo.Availability
        }
        else {
            Add-LogEntry -Message ("Type".PadRight(28) + ": None") -Icon "powercheck" @detailsParams
            Add-LogEntry -Message ("Message".PadRight(28) + ": No battery or UPS detected via WMI.") -Icon "powercheck" @detailsParams

            # Build object (do not change logging)
            $result.Type = 'None'
            $result.Message = 'No battery or UPS detected via WMI.'
        }
    }
    catch {
        Add-LogEntry -Message "Failed to retrieve power source info: $_" -Icon "error" @detailsParams

        # Build object (do not change logging)
        $result.Type = 'Error'
        $result.Message = $_.ToString()
    }

    Add-LogEntry -Message "End of PowerSourceInfo" -Icon "endsection" @summaryParams

    # Return the built object (no other changes)
    return $result
}
#endregion

#region File: Get-PrinterStatus.ps1
function Get-PrinterStatus {
    param (
        [string[]]$Buffer = @('Printers'),
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    Add-LogEntry "Getting the list of printers..." -Icon 'eye' @detailsParams 
    $printers = Get-Printer | Select-Object Name, PrinterStatus, Shared, PortName

    if ($printers) {
        #write-output "Printers found: $($printers.Count)"
        Add-LogEntry -Message "Printers found: $($printers.Count)" @detailsParams -Icon 'printer'

        # Log properties of each printer object
        write-ObjProperties -InputObject $printers -Icon printer -Detailed -MaxDepth 5 -Buffer @('Printers') -FlushBuffer
    }
    else {
        #write-output "No printers found."
        Add-LogEntry -Message "No printers found." @summaryParams -Icon 'blocked'
    }

    #Add-LogEntry "End of list." -AddBody -Icon 'endoflist' -=
}
#endregion

#region File: Get-ProgressionRules.ps1
function Get-ProgressionRules {
    [CmdletBinding()]
    param (
        [string] $Path = $Global:DrProgressions
    )

    if (-not (Test-Path $Path)) {
        return @()
    }

    try {
        $json = Get-Content $Path -Raw | ConvertFrom-Json
        return @($json)
    }
    catch {
        Add-LogEntry -Message "Failed to load progression rules: $_" -Icon 'error'
        return @()
    }
}
#endregion

#region File: Get-ReclaimedStorage.ps1
function Get-ReclaimedStorage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [psobject]$Before,

        [Parameter(Mandatory = $true)]
        [psobject]$After,

        [Parameter(Mandatory = $false)]
        [string]$Icon = 'Storage',

        [Parameter(Mandatory = $false)]
        [double]$MinPercentFree,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $reclaimed = $After.TotalFreeGB - $Before.TotalFreeGB
    Add-LogEntry -Message ("Reclaimed Space: {0:N2} GB" -f $reclaimed) -Icon $Icon @detailsParams 

    $meetsThreshold = $null
    if ($PSBoundParameters.ContainsKey('MinPercentFree')) {
        # Normalize threshold: accept 30 (preferred) or 0.30 (legacy) as 30%
        $thresholdPct = if ($MinPercentFree -le 1) { $MinPercentFree * 100 } else { $MinPercentFree }

        # $After.PercentFree is already 0–100
        $meetsThreshold = ($After.PercentFree -ge $thresholdPct)

        Add-LogEntry -Message (
            "After cleanup free space is {0:N2}%. Threshold is {1:N2}%. Meets threshold: {2}" -f $After.PercentFree, $thresholdPct, $meetsThreshold
        ) -Icon $Icon @detailsParams 
    }
    Add-LogEntry "Completed." -Icon 'completed' @summaryParams
    [PSCustomObject]@{
        ReclaimedGB    = [math]::Round($reclaimed, 2)
        MeetsThreshold = $meetsThreshold
    }
}
#endregion

#region File: Get-ReclaimedStorageHealth.ps1
function Get-ReclaimedStorageHealth {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [psobject]$Before,

        [Parameter(Mandatory = $false)]
        [psobject]$After,

        [Parameter(Mandatory = $false)]
        [string]$Profile = 'WindowsClientDefault',

        # Icon mapping (override if your approved names differ)
        [Parameter(Mandatory = $false)]
        [string]$IconBase = 'Storage',
        [Parameter(Mandatory = $false)]
        [string]$IconError = 'Error',
        [Parameter(Mandatory = $false)]
        [string]$IconStrongWarning = 'warningsevere',
        [Parameter(Mandatory = $false)]
        [string]$IconWarning = 'Warning',
        [Parameter(Mandatory = $false)]
        [string]$IconSuccess = 'Success'
    )

    try {
        # -------------------------
        # Validation & preparation
        # -------------------------
        $issues = @()

        # Profiles/tier cutoffs (GB)
        $profiles = @{
            'WindowsClientDefault' = [PSCustomObject]@{
                MinGB    = 35  # bare minimum (below = Error)
                BetterGB = 40  # acceptable
                GreatGB  = 50  # ideal/healthy
            }
        }

        if ([string]::IsNullOrWhiteSpace($Profile) -or -not $profiles.ContainsKey($Profile)) {
            $issues += "Unknown profile '$Profile'."
        }
        if (-not $Before) { $issues += "Parameter 'Before' is required." }
        if (-not $After) { $issues += "Parameter 'After' is required." }

        $requiredProps = @('TotalFreeGB', 'PercentFree')
        if ($Before) {
            foreach ($p in $requiredProps) {
                if (-not ($Before.PSObject.Properties.Name -contains $p)) { $issues += "Before is missing property '$p'." }
            }
        }
        if ($After) {
            foreach ($p in $requiredProps) {
                if (-not ($After.PSObject.Properties.Name -contains $p)) { $issues += "After is missing property '$p'." }
            }
        }

        if ($issues.Count -gt 0) {
            $msg = "Reclaimed Storage validation failed:`n - " + ($issues -join "`n - ")
            Add-LogEntry -Message $msg -Icon $IconError
            return [PSCustomObject]@{
                ReclaimedGB       = 0
                BeforeFreeGB      = $null
                BeforePercentFree = $null
                AfterFreeGB       = $null
                AfterPercentFree  = $null
                Status            = 'Error'
                Icon              = $IconError
                Profile           = $Profile
                MinGB             = $null
                BetterGB          = $null
                GreatGB           = $null
                Drive             = $null
                Notes             = 'Validation failed'
            }
        }

        $tier = $profiles[$Profile]

        # -------------------------
        # Compute reclaimed
        # -------------------------
        $beforeFree = [double]$Before.TotalFreeGB
        $afterFree = [double]$After.TotalFreeGB
        $reclaimed = $afterFree - $beforeFree

        $beforePct = [double]$Before.PercentFree
        $afterPct = [double]$After.PercentFree

        # Try to capture drive label for summary
        $drive = $null
        foreach ($candidate in @('Drive', 'drive', 'DeviceID', 'deviceid')) {
            if ($After.PSObject.Properties.Name -contains $candidate) { $drive = $After.$candidate; break }
            if ($Before.PSObject.Properties.Name -contains $candidate) { $drive = $Before.$candidate; break }
        }
        if (-not $drive) { $drive = $env:SystemDrive }

        # -------------------------
        # Classify AFTER state (reuse if provided)
        # -------------------------
        $status = ''
        $icon = $IconBase

        if ($After.PSObject.Properties.Name -contains 'Status' -and $After.PSObject.Properties.Name -contains 'Icon' -and $After.Status) {
            $status = [string]$After.Status
            $icon = if ($After.Icon) { [string]$After.Icon } else { $IconBase }
        }
        else {
            if ($afterFree -lt $tier.MinGB) { $status = 'Error'; $icon = $IconError }
            elseif ($afterFree -lt $tier.BetterGB) { $status = 'StrongWarning'; $icon = $IconStrongWarning }
            elseif ($afterFree -lt $tier.GreatGB) { $status = 'Warning'; $icon = $IconWarning }
            else { $status = 'Success'; $icon = $IconSuccess }
        }

        # -------------------------
        # Rounding for display/return
        # -------------------------
        $roundedReclaimed = [math]::Round($reclaimed, 2)
        $roundedBeforeGB = [math]::Round($beforeFree, 2)
        $roundedAfterGB = [math]::Round($afterFree, 2)
        $roundedBeforePct = [math]::Round($beforePct, 2)
        $roundedAfterPct = [math]::Round($afterPct, 2)

        # -------------------------
        # Details block (buffered) + final summary
        # -------------------------
        $summary = "Reclaimed Storage ($drive): +$roundedReclaimed GB. After: $roundedAfterGB GB free ($roundedAfterPct%). Status=$status."

        # Details buffer (flush on last)
        Add-LogEntry ("Tier Cutoffs (GB): Error<{0}, Min≥{0}, Better≥{1}, Great≥{2}." -f $tier.MinGB, $tier.BetterGB, $tier.GreatGB) -Icon 'info' -Buffer 'details'
        Add-LogEntry ("Before: {0:N2} GB free ({1:N2}%)" -f $roundedBeforeGB, $roundedBeforePct) -Icon 'details' -Buffer 'details'
        Add-LogEntry ("After : {0:N2} GB free ({1:N2}%)" -f $roundedAfterGB, $roundedAfterPct) -Icon 'details' -Buffer 'details'
        Add-LogEntry ("Profile: {0}" -f $Profile) -Icon 'details' -Buffer 'details'
        Add-LogEntry ("Status : {0}" -f $status) -Icon 'details' -Buffer 'details' -FlushBuffer

        # Summary buffer (single compact line with status icon)
        Add-LogEntry -Message $summary -Icon $icon -Buffer 'summary' -FlushBuffer

        # -------------------------
        # Return object
        # -------------------------
        [PSCustomObject]@{
            Drive             = $drive
            ReclaimedGB       = $roundedReclaimed
            BeforeFreeGB      = $roundedBeforeGB
            BeforePercentFree = $roundedBeforePct
            AfterFreeGB       = $roundedAfterGB
            AfterPercentFree  = $roundedAfterPct
            Status            = $status
            Icon              = $icon
            Profile           = $Profile
            MinGB             = $tier.MinGB
            BetterGB          = $tier.BetterGB
            GreatGB           = $tier.GreatGB
        }
    }
    catch {
        $err = $_.Exception.Message
        Add-LogEntry -Message "Reclaimed Storage: unexpected error: $err" -Icon $IconError
        return [PSCustomObject]@{
            Drive             = $null
            ReclaimedGB       = 0
            BeforeFreeGB      = $null
            BeforePercentFree = $null
            AfterFreeGB       = $null
            AfterPercentFree  = $null
            Status            = 'Error'
            Icon              = $IconError
            Profile           = $Profile
            MinGB             = $null
            BetterGB          = $null
            GreatGB           = $null
            Notes             = 'Exception thrown'
        }
    }
}
#endregion

#region File: Get-Recommendation.ps1
function Get-Recommendation {
    [CmdletBinding()]
    param ()

    return Get-DrRecommendations
}
#endregion

#region File: Get-SecureBoot.ps1
function Get-SecureBoot {
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    # Check for administrative privileges
    if (-not (Assert-IsAdmin @summaryParams)) { return }

    try {

        # Check the status of Secure Boot
        $secboot = Confirm-SecureBootUEFI
        if ($secboot) {
            Add-LogEntry "Secure Boot is ON" -Icon 'lock' @summaryParams
            return $true
        }
        else {
            Add-LogEntry "⚠Secure Boot is OFF or not supported on this platform" -Icon 'warning' @summaryParams
            return $false
        }

    }
    catch {
        Add-LogEntry -Message "Error checking Secure Boot status: $_" @summaryParams -Icon 'error'
        return $null
    }
}
#endregion

#region File: Get-StorageHealth.ps1
function Get-StorageHealth {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Drive,

        [Parameter(Mandatory = $false)]
        [string]$Profile = 'WindowsClientDefault',

        # Icon mapping (override if your approved names differ)
        [Parameter(Mandatory = $false)]
        [string]$IconBase = 'Storage',
        [Parameter(Mandatory = $false)]
        [string]$IconError = 'Error',
        [Parameter(Mandatory = $false)]
        [string]$IconStrongWarning = 'WarningHigh',
        [Parameter(Mandatory = $false)]
        [string]$IconWarning = 'Warning',
        [Parameter(Mandatory = $false)]
        [string]$IconSuccess = 'Success',
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        # -------------------------
        # Validation & preparation
        # -------------------------
        $issues = @()
        $details = @()

        # Profiles/tier cutoffs (GB)
        $profiles = @{
            'WindowsClientDefault' = [PSCustomObject]@{
                MinGB    = 35  # bare minimum (StrongWarning boundary)
                BetterGB = 40  # better
                GreatGB  = 50  # ideal
            }
            # Future profiles can be added here (e.g., 'ServerDefault')
        }

        if ([string]::IsNullOrWhiteSpace($Profile) -or -not $profiles.ContainsKey($Profile)) {
            $issues += "Unknown profile '$Profile'."
        }

        # Normalize drive: default to system drive; accept 'C' → 'C:'
        if ([string]::IsNullOrWhiteSpace($Drive)) {
            $Drive = $env:SystemDrive
        }
        if ($Drive.Length -eq 1) { $Drive = "${Drive}:" }

        # Basic drive format check: 'X:' where X is a letter
        if ($Drive -notmatch '^[A-Za-z]:$') {
            $issues += "Invalid drive format '$Drive'. Use like 'C:' or 'D:'."
        }

        # Stop if validation failed
        if ($issues.Count -gt 0) {
            $msg = "Storage Health validation failed:`n - " + ($issues -join "`n - ")
            Add-LogEntry -Message $msg -Icon $IconError @summaryParams
            return [PSCustomObject]@{
                Drive       = $Drive
                TotalSizeGB = 0
                TotalFreeGB = 0
                PercentFree = 0
                Status      = 'Error'
                Icon        = $IconError
                Profile     = $Profile
                MinGB       = $null
                BetterGB    = $null
                GreatGB     = $null
                Notes       = 'Validation failed'
            }
        }

        $tier = $profiles[$Profile]

        # -------------------------
        # Collect metrics
        # -------------------------
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" | Where-Object { $_.DriveType -eq 3 }
        if (-not $disk) {
            $msg = "Storage Health: Drive '$Drive' not found or not a fixed disk."
            Add-LogEntry -Message $msg -Icon $IconError @summaryParams
            return [PSCustomObject]@{
                Drive       = $Drive
                TotalSizeGB = 0
                TotalFreeGB = 0
                PercentFree = 0
                Status      = 'Error'
                Icon        = $IconError
                Profile     = $Profile
                MinGB       = $tier.MinGB
                BetterGB    = $tier.BetterGB
                GreatGB     = $tier.GreatGB
                Notes       = 'Drive missing'
            }
        }

        $totalSizeGB = [double]($disk.Size / 1GB)
        $totalFreeGB = [double]($disk.FreeSpace / 1GB)
        $percentFree = if ($totalSizeGB -gt 0) { ($totalFreeGB / $totalSizeGB) * 100.0 } else { 0.0 }

        # -------------------------
        # Classify by tiers
        # -------------------------
        $status = ''
        $icon = $IconBase

        if ($totalFreeGB -lt $tier.MinGB) {
            $status = 'Error'
            $icon = $IconError
        }
        elseif ($totalFreeGB -lt $tier.BetterGB) {
            $status = 'StrongWarning'
            $icon = $IconStrongWarning
        }
        elseif ($totalFreeGB -lt $tier.GreatGB) {
            $status = 'Warning'
            $icon = $IconWarning
        }
        else {
            $status = 'Success'
            $icon = $IconSuccess
        }

        # -------------------------
        # Prepare output + single final log line
        # -------------------------
        $roundedTotalFree = [math]::Round($totalFreeGB, 2)
        $roundedTotalSize = [math]::Round($totalSizeGB, 2)
        $roundedPct = [math]::Round($percentFree, 2)

        # Details (compact, single entry as requested)
        $summary = "Storage Health ($Drive): $roundedTotalFree GB free ($roundedPct%). Status=$status."
        $Bfr = $Buffer + 'details'
        Add-LogEntry "Cutoffs (GB): Error<$($tier.MinGB), Min≥$($tier.MinGB), Better≥$($tier.BetterGB), Great≥$($tier.GreatGB)." -Icon 'details' -Buffer $bfr
        Add-LogEntry "Drive: $Drive" -Icon 'details' -Buffer 'details'
        Add-LogEntry ("Total Size: {0:N2} GB" -f $roundedTotalSize) -Icon 'details' -Buffer 'details'
        Add-LogEntry ("Free: {0:N2} GB ({1:N2}%)" -f $roundedTotalFree, $roundedPct) -Icon 'details' -Buffer 'details'
        Add-LogEntry ("Profile: {0}" -f $Profile) -Icon 'details' -Buffer 'details'
        Add-LogEntry ("Tier Cutoffs (GB): Min≥{0}, Better≥{1}, Great≥{2}" -f $tier.MinGB, $tier.BetterGB, $tier.GreatGB) -Icon 'details' -Buffer 'details'
        Add-LogEntry ("Status: {0}" -f $status) -Icon 'details' -Buffer 'details' -FlushBuffer:$FlushBuffer
        $body = $summary + "`n" + ($details -join "`n")

        Add-LogEntry -Message $body -Icon $icon  @summaryParams
        #Add-LogEntry -Message "all done." -Icon $icon  -Buffer 'details' -FlushBuffer

        # Return object for programmatic use
        [PSCustomObject]@{
            Drive       = $Drive
            TotalSizeGB = [math]::Round($totalSizeGB, 2)
            TotalFreeGB = [math]::Round($totalFreeGB, 2)
            PercentFree = [math]::Round($percentFree, 2)
            Status      = $status
            Icon        = $icon
            Profile     = $Profile
            MinGB       = $tier.MinGB
            BetterGB    = $tier.BetterGB
            GreatGB     = $tier.GreatGB
        }
    }
    catch {
        $err = $_.Exception.Message
        Add-LogEntry -Message "Storage Health: unexpected error: $err" -Icon $IconError @summaryParams
        return [PSCustomObject]@{
            Drive       = if ($Drive) { $Drive } else { $env:SystemDrive }
            TotalSizeGB = 0
            TotalFreeGB = 0
            PercentFree = 0
            Status      = 'Error'
            Icon        = $IconError
            Profile     = $Profile
            MinGB       = $null
            BetterGB    = $null
            GreatGB     = $null
            Notes       = 'Exception thrown'
        }
    }
}
#endregion

#region File: Get-StorageHealth0.ps1
function Get-StorageHealth0 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Drive,

        [Parameter(Mandatory = $false)]
        [double]$MinPercentFree
    )

    try {
        $disks = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }

        if ($Drive) {
            # Normalize drive like "C" -> "C:"
            if ($Drive.Length -eq 1) { $Drive = "${Drive}:" }
            $disks = $disks | Where-Object { $_.DeviceID -ieq $Drive }
            if (-not $disks) {
                return [PSCustomObject]@{
                    TotalSizeGB    = 0
                    TotalFreeGB    = 0
                    PercentFree    = 0
                    MeetsThreshold = $false
                }
            }
        }

        $totalSize = ($disks | Measure-Object -Property Size -Sum).Sum / 1GB
        $totalFree = ($disks | Measure-Object -Property FreeSpace -Sum).Sum / 1GB

        # Percent as 0–100 scale
        $percentFree = if ($totalSize -gt 0) { ($totalFree / $totalSize) * 100 } else { 0 }

        # Normalize MinPercentFree: accept 30 (preferred) or 0.30 (legacy) as 30%
        $meetsThreshold = $null
        if ($PSBoundParameters.ContainsKey('MinPercentFree')) {
            $thresholdPct =
            if ($MinPercentFree -le 1) { $MinPercentFree * 100 } else { $MinPercentFree }
            $meetsThreshold = ($percentFree -ge $thresholdPct)
        }

        return [PSCustomObject]@{
            TotalSizeGB    = [math]::Round($totalSize, 2)
            TotalFreeGB    = [math]::Round($totalFree, 2)
            PercentFree    = [math]::Round($percentFree, 2)   # e.g., 75.53
            MeetsThreshold = $meetsThreshold
        }
    }
    catch {
        return [PSCustomObject]@{
            TotalSizeGB    = 0
            TotalFreeGB    = 0
            PercentFree    = 0
            MeetsThreshold = $false
        }
    }
}
#endregion

#region File: Get-StorageMetrics.ps1
function Get-StorageMetrics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Drive,

        [Parameter(Mandatory = $false)]
        [double]$MinPercentFree
    )

    try {
        $disks = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }

        if ($Drive) {
            # Normalize drive like "C" -> "C:"
            if ($Drive.Length -eq 1) { $Drive = "${Drive}:" }
            $disks = $disks | Where-Object { $_.DeviceID -ieq $Drive }
            if (-not $disks) {
                return [PSCustomObject]@{
                    TotalSizeGB    = 0
                    TotalFreeGB    = 0
                    PercentFree    = 0
                    MeetsThreshold = $false
                }
            }
        }

        $totalSize = ($disks | Measure-Object -Property Size -Sum).Sum / 1GB
        $totalFree = ($disks | Measure-Object -Property FreeSpace -Sum).Sum / 1GB

        # Percent as 0–100 scale
        $percentFree = if ($totalSize -gt 0) { ($totalFree / $totalSize) * 100 } else { 0 }

        # Normalize MinPercentFree: accept 30 (preferred) or 0.30 (legacy) as 30%
        $meetsThreshold = $null
        if ($PSBoundParameters.ContainsKey('MinPercentFree')) {
            $thresholdPct =
            if ($MinPercentFree -le 1) { $MinPercentFree * 100 } else { $MinPercentFree }
            $meetsThreshold = ($percentFree -ge $thresholdPct)
        }

        return [PSCustomObject]@{
            TotalSizeGB    = [math]::Round($totalSize, 2)
            TotalFreeGB    = [math]::Round($totalFree, 2)
            PercentFree    = [math]::Round($percentFree, 2)   # e.g., 75.53
            MeetsThreshold = $meetsThreshold
        }
    }
    catch {
        return [PSCustomObject]@{
            TotalSizeGB    = 0
            TotalFreeGB    = 0
            PercentFree    = 0
            MeetsThreshold = $false
        }
    }
}
#endregion

#region File: Get-StorageMetrics0.ps1
function Get-StorageMetrics0 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Drive,

        [Parameter(Mandatory = $false)]
        [double]$MinPercentFree
    )

    try {
        $disks = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        if ($Drive) {
            $disks = $disks | Where-Object { $_.DeviceID -eq $Drive }
            if (-not $disks) {
                return [PSCustomObject]@{ TotalSizeGB = 0; TotalFreeGB = 0; PercentFree = 0; MeetsThreshold = $false }
            }
        }

        $totalSize = ($disks | Measure-Object -Property Size -Sum).Sum / 1GB
        $totalFree = ($disks | Measure-Object -Property FreeSpace -Sum).Sum / 1GB
        $percentFree = if ($totalSize -gt 0) { $totalFree / $totalSize } else { 0 }

        $meetsThreshold = $null
        if ($PSBoundParameters.ContainsKey('MinPercentFree')) {
            $meetsThreshold = ($percentFree -ge $MinPercentFree)
        }

        return [PSCustomObject]@{
            TotalSizeGB    = [math]::Round($totalSize, 2)
            TotalFreeGB    = [math]::Round($totalFree, 2)
            PercentFree    = [math]::Round($percentFree, 4)
            MeetsThreshold = $meetsThreshold
        }
    }
    catch {
        return [PSCustomObject]@{ TotalSizeGB = 0; TotalFreeGB = 0; PercentFree = 0; MeetsThreshold = $false }
    }
}
#endregion

#region File: Get-StorageSenseSettings.ps1
function Get-StorageSenseSettings {
    [CmdletBinding()]
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        $settings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"

        $knownKeys = @{
            "01"                     = @{ Label = "Storage Sense Enabled"; Category = "settings" }
            "02"                     = @{ Label = "Run Storage Sense During Low Free Disk Space"; Category = "settings" }
            "04"                     = @{ Label = "Delete Temporary Files"; Category = "cleanup" }
            "08"                     = @{ Label = "Delete Downloads Folder Files"; Category = "cleanup" }
            "32"                     = @{ Label = "Delete Recycle Bin Files"; Category = "cleanup" }
            "128"                    = @{ Label = "Days to Keep Downloads"; Category = "settings" }
            "256"                    = @{ Label = "Days to Keep Recycle Bin Files"; Category = "settings" }
            "512"                    = @{ Label = "Delete Previous Versions of Windows"; Category = "cleanup" }
            "1024"                   = @{ Label = "Delete OneDrive Content"; Category = "settings" }
            "2048"                   = @{ Label = "OneDrive Cleanup Policy"; Category = "settings" }
            "CloudfilePolicyConsent" = @{ Label = "OneDrive Policy Consent"; Category = "settings" }
        }

        $message = "📦 Storage Sense Settings Retrieved"
        Add-LogEntry -Message $message -Icon 'settings' @detailsParams

        foreach ($property in $settings.PSObject.Properties) {
            $name = $property.Name
            $value = $property.Value

            if ($name -eq "StoragePoliciesLastTrigger" -and $value -is [byte[]] -and $value.Length -eq 8) {
                $filetime = [BitConverter]::ToUInt64($value, 0)
                $datetime = (Get-Date "1601-01-01T00:00:00Z").AddTicks($filetime)
                Add-LogEntry -Message "Last Storage Sense Trigger: $datetime UTC" -Icon "system" @detailsParams
            }
            elseif ($knownKeys.ContainsKey($name)) {
                $entry = $knownKeys[$name]
                Add-LogEntry -Message "$($entry.Label): $value" -Icon $entry.Category @detailsParams
            }
            elseif ($name -like "PS*") {
                continue
            }
            else {
                Add-LogEntry -Message "${name}: $value" -Icon "settings" @detailsParams
            }
        }

    }
    catch {
        Add-LogEntry -Message "❌ Failed to retrieve Storage Sense settings: $_" -Icon 'system' @summaryParams
    }

    Add-LogEntry -Message "End of settings." -Icon 'settings' @summaryParams
}
#endregion

#region File: Get-StorageSenseSettingsObject.ps1
function Get-StorageSenseSettingsObject {
    param (
        [string]$PrefSched,
        [switch]$ClearTemporaryFiles,
        [switch]$ClearRecycler,
        [switch]$ClearDownloads,
        [switch]$AllowClearOneDriveCache,
        [switch]$AddAllOneDrivelocations,
        [int]$ClearRecyclerDays,
        [int]$ClearDownloadsDays,
        [int]$ClearOneDriveCacheDays
    )

    return [PSCustomObject]@{
        PrefSched               = switch ($PrefSched) {
            "LowDiskspace" { 0 }
            "Daily" { 1 }
            "Weekly" { 7 }
            "Monthly" { 30 }
        }
        ClearTemporaryFiles     = [int]$ClearTemporaryFiles.IsPresent
        ClearRecycler           = [int]$ClearRecycler.IsPresent
        ClearDownloads          = [int]$ClearDownloads.IsPresent
        AllowClearOneDriveCache = [int]$AllowClearOneDriveCache.IsPresent
        AddAllOneDrivelocations = $AddAllOneDrivelocations.IsPresent
        ClearRecyclerDays       = $ClearRecyclerDays
        ClearDownloadsDays      = $ClearDownloadsDays
        ClearOneDriveCacheDays  = $ClearOneDriveCacheDays
    }
}
#endregion

#region File: Get-StorageSummary.ps1
function Get-StorageSummary {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Drive
    )

    try {
        $disks = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        if ($Drive) {
            $disks = $disks | Where-Object { $_.DeviceID -eq $Drive }
            if (-not $disks) { return "Drive $Drive not found or is not a fixed disk." }
        }

        $summary = $disks | Select-Object `
            SystemName,
        @{ Name = "Drive"; Expression = { $_.DeviceID } },
        @{ Name = "Size (GB)"; Expression = { "{0:N1}" -f ($_.Size / 1GB) } },
        @{ Name = "FreeSpace (GB)"; Expression = { "{0:N1}" -f ($_.FreeSpace / 1GB) } },
        @{ Name = "PercentFree"; Expression = { "{0:P1}" -f ($_.FreeSpace / $_.Size) } } |
        Format-Table -AutoSize | Out-String

        return $summary
    }
    catch {
        return "Error retrieving storage summary: $_"
    }
}
#endregion

#region File: Get-SyncroAssetByName.ps1
function Get-SyncroAssetByName {
    [CmdletBinding()]
    param(
        [string]$AssetName = $env:COMPUTERNAME
    )

    # Get subdomain from global variable
    $subdomain = $Global:DrSubDomain
    if (-not $subdomain) {
        Write-Host "Subdomain not found in environment variables."
        return
    }

    # Get API key from global variable
    if (-not $Global:DrApiKey) {
        Write-Host "API key could not be retrieved."
        return
    }

    # Build endpoint
    $encodedQuery = [uri]::EscapeDataString($AssetName)
    $endpoint = "/api/v1/customer_assets?query=$encodedQuery"

    try {
        # Call API
        $response = Invoke-DrApiRequest -Method 'GET' -Endpoint $endpoint

        # Normalize: handle single-object vs array response
        $assets = @($response.assets)

        if (-not $assets -or $assets.Count -eq 0) {
            return $null
        }

        # If we have a UUID, prefer an exact UUID match
        if ($Global:UUID) {
            foreach ($asset in $assets) {
                $uuid = $null
                try { $uuid = $asset.properties.kabuto_live_uuid } catch {}
                if ($uuid -and $uuid -eq $Global:UUID) {
                    return $asset
                }
            }
            # UUID specified but no exact match
            return $null
        }

        # No UUID to disambiguate:
        if ($assets.Count -eq 1) {
            return $assets[0]
        }

        # Multiple matches and no UUID to pick the right one
        return $null
    }
    catch {
        Write-Host "Error querying Syncro API: $_"
        return $null
    }
}
#endregion

#region File: Get-SyncroSafeMode.ps1
function Get-SyncroSafeMode {
    try {
        $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Network"
        $services = @("Syncro", "SyncroLive", "SyncroOvermind")

        $existingKeys = $services | Where-Object { Test-Path "$registryPath\$_" }

        if ($existingKeys.Count -eq $services.Count) {
            return "Enabled"
        }
        else {
            return "Disabled"
        }
    }
    catch {
        Write-Error "Failed to determine Syncro Safe Mode state: $_" -Icon 'error'
        return "Unknown"
    }
}
#endregion

#region File: Get-SysVar.ps1
function Get-SysVar {
    param ([string]$Name)

    if (Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue) {
        return (Get-Variable -Name $Name -Scope Global).Value
    }

    $xmlPath = Initialize-VariableStore 
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($xmlPath)

    $var = $xml.SelectSingleNode("//Variable[@Name='$Name']")
    if ($var) {
        $value = $var.GetAttribute("Value")
        $type = $var.GetAttribute("Type")

        $converted = switch ($type) {
            "Boolean" { [System.Convert]::ToBoolean($value) }
            "Number" { [int]$value }
            "Array" { $value | ConvertFrom-Json }
            "Hashtable" { $value | ConvertFrom-Json }
            default { $value }
        }

        Set-Variable -Name $Name -Value $converted -Scope Global
        return $converted
    }

    return $null
}
#endregion

#region File: Get-SysVarList.ps1
function Get-SysVarList {
    $xmlPath = Initialize-VariableStore 
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($xmlPath)

    $xml.SelectNodes("//Variable") | ForEach-Object {
        $name = $_.GetAttribute("Name")
        $type = $_.GetAttribute("Type")
        $value = $_.GetAttribute("Value")

        if (-not (Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue)) {
            $converted = switch ($type) {
                "Boolean" { [System.Convert]::ToBoolean($value) }
                "Number" { [int]$value }
                "Array" { $value | ConvertFrom-Json }
                "Hashtable" { $value | ConvertFrom-Json }
                default { $value }
            }
            Set-Variable -Name $name -Value $converted -Scope Global
        }

        [PSCustomObject]@{
            Name  = $name
            Type  = $type
            Value = (Get-Variable -Name $name -Scope Global).Value
        }
    }
}
#endregion

#region File: Get-Ticket.ps1
function Get-Ticket {
    param (
        [int]$TicketId = $Global:DrTicketId
    )

    try {
        return Invoke-DrApiRequest `
            -Method 'GET' `
            -Endpoint "/api/v1/tickets/$TicketId"
    }
    catch {
        Write-Error "Failed to retrieve ticket: $_"
    }
}
#endregion

#region File: Get-TicketAssetIds.ps1
function Get-TicketAssetIds {
    <#
        .SYNOPSIS
        Return asset_ids from a Syncro ticket as a string array (always an array).

        .DESCRIPTION
        - Accepts a ticket object (preferred) or a TicketId (long numeric ID).
        - Falls back to $Global:DrTicketId if neither is supplied.
        - Normalizes single-value or array-shaped asset_ids into string[].
        - Returns empty string[] if none are present or on failure.
        - Does not accept TicketNumber (short display number).
        
        .NOTES
        Version: 1.1.0
    #>
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true)]
        $Ticket,

        [string]$TicketId = $Global:DrTicketId
    )

    begin {
        $diag = New-Object System.Collections.Generic.List[string]
        $assetIds = @()
    }

    process {
        # Resolve the ticket to use
        $resolvedTicket = $null
        try {
            if ($Ticket) {
                $resolvedTicket = $Ticket
                $diag.Add("Ticket provided via -Ticket.")
            }
            elseif ($TicketId) {
                $diag.Add("Fetching ticket via Get-Ticket by TicketId: $TicketId")
                $resolvedTicket = Get-Ticket -ErrorAction Stop -TicketId $TicketId
            }
            elseif ($Global:DrTicketId) {
                $diag.Add("Fetching ticket via Get-Ticket by Global:DrTicketId: $Global:DrTicketId")
                $resolvedTicket = Get-Ticket -ErrorAction Stop -TicketId $Global:DrTicketId
            }
            else {
                $diag.Add("No -Ticket, -TicketId, or Global:DrTicketId available.")
            }

            if (-not $resolvedTicket) {
                $diag.Add("No ticket object resolved.")
                return
            }

            # Typical Syncro shape: $resolvedTicket.ticket.asset_ids
            $idsCandidate = $null
            if ($resolvedTicket.psobject.Properties.Name -contains 'ticket' -and $resolvedTicket.ticket) {
                $idsCandidate = $resolvedTicket.ticket.asset_ids
            }
            if (-not $idsCandidate) {
                $idsCandidate = $resolvedTicket.asset_ids
            }

            if ($null -eq $idsCandidate) {
                $diag.Add("No asset_ids present on the ticket.")
                return
            }

            # Normalize to string[]
            if ($idsCandidate -is [System.Collections.IEnumerable] -and -not ($idsCandidate -is [string])) {
                $assetIds = @($idsCandidate | ForEach-Object { [string]$_ })
                $diag.Add("asset_ids treated as array; count: $($assetIds.Count).")
            }
            else {
                $assetIds = @([string]$idsCandidate)
                $diag.Add("asset_ids treated as single value.")
            }
        }
        catch {
            $diag.Add("Error: $($_.Exception.Message)")
        }
    }

    end {
        # One compact final log (your style)
        try {
            $summary = if ($assetIds -and $assetIds.Count -gt 0) {
                "AssetIds: " + ($assetIds -join ', ')
            }
            else {
                "AssetIds: [none]"
            }
            $details = $diag -join ' | '
            Add-LogEntry -Message "$summary || $details" -Icon 'diagnostics' -AddBody -Subject "Get-TicketAssetIds"
        }
        catch { }

        # Always return a string[] (possibly empty)
        , $assetIds
    }
}
#endregion

#region File: Get-TicketIdFromNumber.ps1
function Get-TicketIdFromNumber {
    param (
        [int]$TicketNumber = $Global:DrTicket
    )

    try {
        $response = Invoke-DrApiRequest `
            -Method 'GET' `
            -Endpoint "/api/v1/tickets?query=$TicketNumber"

        $ticket = $response.tickets | Where-Object { $_.number -eq $TicketNumber }

        if ($ticket) {
            return $ticket
            #return $ticket.id
        }
        else {
            Write-Warning "Ticket number $TicketNumber not found."
        }
    }
    catch {
        Write-Error "Failed to retrieve ticket ID: $_"
    }
}
#endregion

#region File: Get-TpmStatus.ps1
function Get-TpmStatus {
    param (
        [switch]$Detail,
        [string[]]$Buffer = @('TPM Status'),
        [switch]$FlushBuffer
    )
    $sBuffer = $Global:DrLogSummaryBuffer
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    if (-not (Assert-IsAdmin @summaryParams)) { return }

    try {
        $tpm = Get-Tpm
        if ($null -eq $tpm) {
            Add-LogEntry -Message "TPM not detected on this system." -Icon 'systemmessage' @summaryParams
            #Add-LogEntry -Message "TPM check completed: No TPM present." -Icon 'summary' -AddBody | Out-Null
            return
        }

        # Get SpecVersion from WMI if missing
        $specVersion = if ([string]::IsNullOrWhiteSpace($tpm.SpecVersion)) {
            $wmiTpm = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm
            if ($wmiTpm -and $wmiTpm.SpecVersion) { $wmiTpm.SpecVersion } else { "Not reported" }
        }
        else { $tpm.SpecVersion }

        # Convert ManufacturerID to hex and map to name
        $hexId = '{0:X}' -f $tpm.ManufacturerID
        $manufacturerName = switch ($hexId) {
            '494658FF' { 'Infineon Technologies' }
            '4D534654' { 'Microsoft' }
            '41544D4C' { 'Atmel' }
            '4E534D20' { 'National Semiconductor' }
            '49424D00' { 'IBM' }
            '494E5443' { 'Intel Corporation' }
            '414D4400' { 'AMD' }
            '53544D20' { 'STMicroelectronics' }
            '57494E00' { 'Winbond' }
            '4E545C00' { 'Nuvoton Technology' }
            '534D5343' { 'Samsung' }
            '48535700' { 'Hewlett-Packard' }
            '4D4F5449' { 'Motorola' }
            '4D494C00' { 'Microchip Technology' }
            default { "Unknown ($hexId)" }
        }

        $status = [PSCustomObject]@{
            ManufacturerName    = $manufacturerName
            ManufacturerID      = $tpm.ManufacturerID
            ManufacturerVersion = $tpm.ManufacturerVersion
            SpecVersion         = $specVersion
            TpmPresent          = $tpm.TpmPresent
            TpmReady            = $tpm.TpmReady
            TpmEnabled          = $tpm.TpmEnabled
            TpmActivated        = $tpm.TpmActivated
            TpmOwned            = $tpm.TpmOwned
        }

        Write-Host "TPM Information:"
        $status | Format-Table -AutoSize | Out-Null
        # Determine explanation
        if ($tpm.TpmEnabled) {
            $explanation = 'TPM is enabled and active.'
        }
        elseif (-not $tpm.TpmReady -or -not $tpm.TpmActivated) {
            $Detail = $true
            $explanation = 'TPM present but not ready or not activated.'
        }
        else {
            $Detail = $true
            $explanation = 'TPM is disabled.'
        }

        # Intermediate log
        Add-LogEntry -Message "TPM Status: Vendor=$manufacturerName | SpecVersion=$specVersion | Enabled=$($tpm.TpmEnabled) | $explanation" -Icon 'security' -Buffer $Buffer $sBuffer
        Add-LogEntry -Message "TPM Status: Vendor=$manufacturerName | SpecVersion=$specVersion | Enabled=$($tpm.TpmEnabled) | $explanation" -Icon 'security' @detailsParams

        if ($Detail) {
            Write-ObjProperties $status -Detailed -Icon security @summaryParams
        }
        else {
            # Final flush
            Add-LogEntry -Message "TPM check completed successfully." -Icon 'trophy' @summaryParams
        }

        return $status
    }
    catch {
        # Single flush log for error
        Add-LogEntry -Message "Error retrieving TPM information: $($_.Exception.Message)" -Icon 'error' @summaryParams
        return
    }
}
#endregion

#region File: Get-VlanInfoForAdapter.ps1
function Get-VlanInfoForAdapter {
        param([string]$AdapterName)
        $vlanEnabled = $false
        $vlanId = $null
        try {
            $adv = Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction SilentlyContinue
            foreach ($p in $adv) {
                if ($p.DisplayName -match 'vlan' -or $p.RegistryKeyword -match 'vlan') {
                    $vlanEnabled = $true
                    if ($p.DisplayName -match 'id' -or $p.RegistryKeyword -match 'id') {
                        $vlanId = ($p.DisplayValue | Out-String).Trim()
                    }
                    elseif (-not $vlanId) {
                        $vlanId = ($p.DisplayValue | Out-String).Trim()
                    }
                }
            }
        }
        catch { }
        [pscustomobject]@{
            VlanEnabled = $vlanEnabled
            VlanId      = $vlanId
        }
    }
#endregion

#region File: Get-WifiConnection.ps1
function Get-WifiConnection {
    param (
        [string]$SSID,
        [switch]$RevealPasswords,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $WifiProfiles = @()
    $connectedSSID = $null

    # Get currently connected SSID
    try {
        $connectedSSID = (netsh wlan show interfaces | Select-String -Pattern '^\s*SSID\s*:\s*(.+)$').Matches.Groups[1].Value.Trim()
    }
    catch {
        Add-LogEntry -Message "Error fetching current WiFi connection." -Icon 'error'
    }

    # Determine profile list
    if (-not $SSID) {
        if ($connectedSSID) {
            $WifiProfiles += $connectedSSID
        }
        else {
            $msg = "No active WiFi connection found."
            Add-LogEntry -Message $msg -Icon 'warning' @summaryParams
            return
        }
    }
    elseif ($SSID -eq '*ALL') {
        $WifiProfiles = netsh wlan show profiles | Select-String -Pattern 'All User Profile\s*:\s*(.+)$' | ForEach-Object {
            $_.Matches.Groups[1].Value.Trim()
        }
    }
    else {
        $WifiProfiles += $SSID
    }

    # Process all profiles
    foreach ($WifiProfile in $WifiProfiles) {
        $isConnected = ($WifiProfile -eq $connectedSSID)

        if ($isConnected) {
            Add-LogEntry -Message "🔗━━━━━━━━━━━━━━━━━━━━━━━🔗" -Icon 'note' @detailsParams
            Add-LogEntry -Message "WiFi SSID: $WifiProfile [Connected]" -Icon 'network' @detailsParams
        }
        else {
            Add-LogEntry -Message "📶───────────────📶" -Icon 'note' -AddToBody
            Add-LogEntry -Message "WiFi SSID: $WifiProfile" -Icon 'network' @detailsParams
        }

        try {
            $password = (netsh wlan show profile name="$WifiProfile" key=clear | Select-String -Pattern 'Key Content\s*:\s*(.+)$').Matches.Groups[1].Value.Trim()
        }
        catch {
            #Add-LogEntry -Message "Failed to retrieve password for SSID: $WifiProfile" -Icon 'network' -AddToBody
            $password = $null
        }

        if ($password) {
            $displayPassword = if ($RevealPasswords) { $password } else { '••••••••' }
            Add-LogEntry -Message "WiFi Password: $displayPassword" -Icon 'network' @detailsParams
        }
        else {
            Add-LogEntry -Message "No password found for SSID: $WifiProfile" -Icon 'statusfail' @detailsParams
        }
    }

    Add-LogEntry -Message "Completed WiFi password lookup." -Icon 'task' @summaryParams
}
#endregion

#region File: Get-WindowsVersion.ps1
function Get-WindowsVersion {
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $major = Get-ItemPropertyValue -Path $regPath -Name CurrentMajorVersionNumber
    $minor = Get-ItemPropertyValue -Path $regPath -Name CurrentMinorVersionNumber
    $build = Get-ItemPropertyValue -Path $regPath -Name CurrentBuildNumber
    $ubr = Get-ItemPropertyValue -Path $regPath -Name UBR

    $fullVersion = "$major.$minor.$build.$ubr"
    $buildNumber = [int]$build

    if ($buildNumber -ge 22000) {
        $windowsVersion = "Windows 11"
        $release = switch ($buildNumber) {
            { $_ -ge 24000 } { "24H2"; break }
            { $_ -ge 23000 -and $_ -lt 24000 } { "24H1"; break }
            { $_ -ge 22631 -and $_ -lt 23000 } { "23H2"; break }
            { $_ -ge 22621 -and $_ -lt 22631 } { "22H2"; break }
            default { "Unknown Release" }
        }
    }
    else {
        $windowsVersion = "Windows 10"
        $release = switch ($buildNumber) {
            { $_ -ge 19045 -and $_ -lt 20000 } { "22H2"; break }
            { $_ -ge 19044 -and $_ -lt 19045 } { "21H2"; break }
            { $_ -ge 19043 -and $_ -lt 19044 } { "21H1"; break }
            { $_ -ge 19042 -and $_ -lt 19043 } { "20H2"; break }
            { $_ -ge 19041 -and $_ -lt 19042 } { "20H1"; break }
            default { "Unknown Release" }
        }
    }

    $icon = if ($windowsVersion -like "Unknown*") { "❓" } else { "✅" }
    Add-LogEntry "${icon} Windows Version: ${windowsVersion} ${release} (${fullVersion})" @summaryParams

    return [PSCustomObject]@{
        WindowsVersion = $windowsVersion
        Release        = $release
        FullVersion    = $fullVersion
        BuildNumber    = $buildNumber
    }
}
#endregion

#region File: Get-WlanInterfaceInfo.ps1
function Get-WlanInterfaceInfo {
        $map = @{}
        try {
            $text = netsh wlan show interfaces 2>$null
            if (-not $text) { return $map }
            $current = $null
            foreach ($line in $text) {
                $line = $line.Trim()
                if ($line -match '^Name\s*:\s*(.+)$') {
                    $name = $Matches[1].Trim()
                    $current = [ordered]@{ Name = $name }
                    $map[$name] = $current
                    continue
                }
                if (-not $current) { continue }
                if ($line -match '^SSID\s*:\s*(.+)$') { $current.SSID = $Matches[1].Trim(); continue }
                elseif ($line -match '^BSSID\s*:\s*(.+)$') { $current.BSSID = $Matches[1].Trim(); continue }
                elseif ($line -match '^Signal\s*:\s*(.+)$') { $current.Signal = $Matches[1].Trim(); continue }
                elseif ($line -match '^Channel\s*:\s*(.+)$') { $current.Channel = $Matches[1].Trim(); continue }
                elseif ($line -match '^Radio type\s*:\s*(.+)$') { $current.RadioType = $Matches[1].Trim(); continue }
                elseif ($line -match '^Authentication\s*:\s*(.+)$') { $current.Authentication = $Matches[1].Trim(); continue }
                elseif ($line -match '^Cipher\s*:\s*(.+)$') { $current.Cipher = $Matches[1].Trim(); continue }
                elseif ($line -match '^Receive rate \(Mbps\)\s*:\s*(.+)$') { $current.ReceiveRateMbps = $Matches[1].Trim(); continue }
                elseif ($line -match '^Transmit rate \(Mbps\)\s*:\s*(.+)$') { $current.TransmitRateMbps = $Matches[1].Trim(); continue }
            }
        }
        catch { }
        return $map
    }
#endregion

#region File: Hide-User.ps1
function Hide-User {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Hide', 'Show')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [string]$Username,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer @('initialize-env') -FlushBuffer
    $errorsParams = $logParams.Details
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    #Log-Invocation -IncludeParameters @detailsParams 

    try {
        $Value = if ($State -eq 'Hide') { 0 } else { 1 }

        $Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force
        }
        Set-ItemProperty -Path $Path -Name $Username -Value $Value -Force

        $message = "User '$Username' has been set to $State on the logon screen."

        Add-LogEntry -Message $message @summaryParams
        #Write-Output $message
    }
    catch {
        $errorMessage = "An error occurred: $_"
        #Write-Error $errorMessage
        Add-LogEntry -Message $errorMessage @summaryParams    
    }
}
#endregion

#region File: Initialize-Environment.ps1
function Initialize-Environment {
    try {
        # Reset globals
        $Global:DrLogFile = $null
        $Global:DrBody = $null
        $Global:DrTicketId = $null
        $Global:DrTimerFile = $null

        $logParams = Get-LogEntryParams -buffer  "Initialize-Env" -FlushBuffer
        $detailsParams = $logParams.Details
        $summaryParams = $logParams.Summary


        # Load system variables
        Initialize-SysVarsFromFile @detailsParams

        # Load API key
        try { $Global:DrApiKey = Get-EncryptedApiKeyFromRegistry @detailsParams } catch { $Global:DrApiKey = $null }

        if ( !$Global:DrApiKey ) {
            Send-DrAlert -Category 'APIKeyMissing' -Body 'No API key.' @summaryParams
            #Import-Module $env:SyncroModule
            #Rmm-Alert -Category 'APIKeyMissing' -Body 'No API key.'
            return
        }

        Add-LogEntry -Message "DrModuleVersion: $Global:DrModuleVersion" -Icon 'id'  @detailsParams


        # Load Syncro registry info
        try {
            $SyncroRegKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\RepairTech\Syncro' -Name uuid, shop_subdomain
            $Global:DrSubDomain = $SyncroRegKey.shop_subdomain
            $Global:UUID = $SyncroRegKey.uuid
        }
        catch {
            $Global:DrSubDomain = $null
            $Global:UUID = $null
        }

        # ✅ Get asset info using registry + Get-Asset
        try {
            $Global:DrAssetId = Get-DrAssetIdRegistry -Quiet @detailsParams
            if ($Global:DrAssetId) {
                #Add-LogEntry -Message "DrAssetId loaded from registry: $Global:DrAssetId" -Icon 'id'  @detailsParams
                try {
                    $Global:DrAsset = Get-Asset -AssetId $Global:DrAssetId @detailsParams
                    if ($Global:DrAsset) {
                        $Global:DrCustomerId = $Global:DrAsset.asset.customer_id
                        $Global:DrTicket = $Global:DrAsset.asset.properties.ticket
                        $Global:DrAssetId = $Global:DrAsset.asset.id
                        #Add-LogEntry -Message "Asset retrieved successfully." -Icon 'computer'  @detailsParams
                    }
                    else {
                        Add-LogEntry -Message "Asset retrieval returned null." -Icon 'warning'  @detailsParams
                    }
                }
                catch {
                    Add-LogEntry -Message ("Failed to retrieve asset: {0}" -f $_.Exception.Message) -Icon 'error'  @detailsParams
                    $Global:DrAsset = $null
                    $Global:DrCustomerId = $null
                }
            }
            else {
                Add-LogEntry -Message "DrAssetId not found in registry." -Icon 'warning'  @detailsParams
                $Global:DrAsset = $null
                $Global:DrCustomerId = $null
            }
        }
        catch {
            Add-LogEntry -Message ("Failed to load DrAssetId from registry: {0}" -f $_.Exception.Message) -Icon 'error'  @detailsParams
            $Global:DrAssetId = $null
            $Global:DrAsset = $null
            $Global:DrCustomerId = $null
        }

        if (-not $Global:DrAsset) {

            # Get asset info
            $DrAsset = Get-SyncroAssetByName
            $Global:DrAsset = Get-Asset -AssetId $DrAsset.id
            $Global:DrCustomerId = $Global:DrAsset.asset.customer_id
            $Global:DrTicket = $Global:DrAsset.asset.properties.ticket
            $Global:DrAssetId = $Global:DrAsset.asset.id
            Set-DrAssetIdRegistry -AssetId $Global:DrAssetId  @detailsParams
        }

        if ($Global:DrTicket) {
            $Global:WDrTicket = $Global:DrTicket
            $Global:DrTkt = Get-TicketIdFromNumber -TicketNumber $Global:DrTicket
            $Global:DrTicketId = if ($Global:DrTkt.id ) { $Global:DrTkt.id } else { $null }
            #write-host $Global:DrTicketId
        }
        # Log computer and IDs
        Add-LogEntry -Message "Computer Name: $($env:COMPUTERNAME)"  @detailsParams -Icon 'id'
        Add-LogEntry -Message "DrAsset ID: $($Global:DrAssetId)"  @detailsParams -Icon 'id'
        Add-LogEntry -Message "DrCustomer ID: $($Global:DrCustomerId)"  @detailsParams -Icon 'id'

        # Ticket handling remains unchanged
        $Global:WTicket = if ($Global:DrTicket) { $Global:DrTicket } else { $null }
        #$Global:DrTicket   = $Global:WTicket

        if ($Global:DrTicket) { Update-Ticket -Status "In Progress" }

        $Global:DrSessionId = (New-Guid).Guid.Substring(0, 8)
        $baseId = if ($Global:DrTicket) { $Global:DrTicket.Trim() } else { $Global:DrSessionId.Trim() }

        # ✅ Job paths
        $Global:DrJobsPath = Join-Path $Global:DrHiddenRoot 'Jobs'
        $Global:DrJobRoot = Join-Path $Global:DrJobsPath $baseId
        $Global:DrLogs = Join-Path $Global:DrJobRoot 'DrLogs'
        $Global:DrTemp = Join-Path $Global:DrJobRoot 'DrTemp'

        # ✅ Ensure all base folders
        foreach ($folder in @(
                @{ Path = $Global:DrBin },
                #                @{ Path = $Global:DrHiddenRoot; Attributes = 'Hidden' },
                @{ Path = $Global:DrHiddenBin },
                #                @{ Path = $Global:DrJobsPath },
                @{ Path = $Global:DrJobRoot },
                @{ Path = $Global:DrLogs },
                @{ Path = $Global:DrTemp },
                @{ Path = $Global:DrToolbox }
            )) {
            if ($folder.ContainsKey('Attributes') -and $folder.Attributes) {
                Ensure-Folder -Path $folder.Path -Attributes $folder.Attributes @detailsParams
            }
            else {
                Ensure-Folder -Path $folder.Path @detailsParams
            }
        }

        if ($Global:DrTicket) {
            $Global:DrTimerFile = Join-Path $Global:DrTemp "DrTimers.json"
            Add-LogEntry "Timer system initialized for ticket $Global:DrTicket." -Icon 'timeout'  @detailsParams
        }
        $Global:DrRecommendations = Join-Path $Global:DrHiddenBin 'recommendations.json'
        $Global:DrProgressions = Join-Path $Global:DrHiddenBin 'progressions.json'
        $Global:DrAcctBaselinePath = Join-Path $Global:DrHiddenBin 'account_baseline.json'
        Add-LogEntry -Message "DrRecommendations: $Global:DrRecommendations" -Icon 'file'  @detailsParams
        Add-LogEntry -Message "DrAcctBaselinePath: $Global:DrAcctBaselinePath" -Icon 'file'  @detailsParams
        Add-LogEntry -Message "DrProgressions: $Global:DrProgressions" -Icon 'file'  @detailsParams

        Get-LoggedInUser  @detailsParams
        #$Global:IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $Global:IsAdmin = Test-IsElevated

        # ✅ Log critical globals
        Add-LogEntry -Message "IsAdmin: $Global:IsAdmin"  @detailsParams -Icon 'permission'
        Add-LogEntry -Message "DrApiKey: $(if ($Global:DrApiKey) {'[Loaded]'} else {'[Not Found]'})" -Icon 'key'  @detailsParams
        Add-LogEntry -Message "DrSessionId: $Global:DrSessionId" -Icon 'id'  @detailsParams
        Add-LogEntry -Message "DrTimerFile: $Global:DrTimerFile" -Icon 'timer'  @detailsParams
        Add-LogEntry -Message "DrHiddenRoot: $Global:DrHiddenRoot" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrJobsPath: $Global:DrJobsPath" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrJobRoot: $Global:DrJobRoot" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrLogs: $Global:DrLogs" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrTemp: $Global:DrTemp" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrToolbox: $Global:DrToolbox" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrHiddenBin: $Global:DrHiddenBin" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrBin: $Global:DrBin" -Icon 'folder'  @detailsParams
        Add-LogEntry -Message "DrSubDomain: $Global:DrSubDomain" -Icon 'jobcheck'  @detailsParams
        Add-LogEntry -Message "UUID: $Global:UUID" -Icon 'id'  @detailsParams
        Add-LogEntry -Message "WTicket: $Global:WTicket" -Icon 'ticket'  @detailsParams
        Add-LogEntry -Message "DrTicket: $Global:DrTicket" -Icon 'ticket'  @detailsParams
        Add-LogEntry -Message "DrTicketId: $Global:DrTicketId" -Icon 'id' @detailsParams -Hidden
        if (-not ($Global:DrSuppressInitLog)) {
            Add-LogEntry -Message "Environment initialized." @summaryParams -Subject "Initialize-Environment" -Icon 'systeminit' -Hidden
        }
        else {
            Add-LogEntry -Message "Environment initialized." @summaryParams -Subject "Initialize-Environment" -Icon 'systeminit' -Hidden -NoTicketOutput
        }
    }
    catch {
        Add-LogEntry -Message "❌ Error during Initialize-Environment: $($_.Exception.Message)" @summaryParams -Icon 'error' -Hidden
    }
}
#endregion

#region File: Initialize-Job.ps1
function Initialize-Job {
    param (
        [Parameter(Position = 0)][string]$Subject = "Untitled Job",
        [string]$IssueType = "Automation",
        [string]$InitialIssue = $Subject,
        [bool]$LogToHost = $Global:DrLogToHost,
        [bool]$LogToFile = $Global:DrLogToFile,
        [bool]$LogActivity,
        [bool]$Timestamp = $Global:DrTimestamp,
        [string[]]$Tags = @("PowerShell", "Automated"),
        [switch]$NoNewTicket
    )

    $logParams = Get-LogEntryParams -Buffer "Initialize-Job" -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary
    #Test-ParmValues @detailsParams
    #Test-ParmValues @summaryParams

    Log-Invocation -IncludeParameters @detailsParams

    try {
        if ($Timestamp -ne $Global:DrTimestamp) {
            Add-LogEntry -Message "Timestamp overridden: $Timestamp" -Icon 'timeout' @detailsParams
            $Global:DrTimestamp = $Timestamp
        }

        if ($Global:DrAsset -and $Global:DrAsset.properties.Ticket) {
            $Global:WTicket = $Global:DrAsset.properties.Ticket
            $Global:DrTicket = $Global:WTicket
            Add-LogEntry -Message "WTicket: $Global:WTicket" -Icon 'Ticket' @detailsParams
        }

        if (-not $Global:DrTicket -and -not $NoNewTicket) {
            $ticketParams = @{
                Subject    = $Subject
                IssueType  = $IssueType
                TicketBody = $InitialIssue
                Tags       = $Tags
            }
            $ticket = Open-Ticket @ticketParams @detailsParams
            $Global:DrTkt = $ticket 
        }
        elseif (-not $Global:DrTicket -and $NoNewTicket) {
            Add-LogEntry -Message "NoNewTicket specified. Skipping ticket creation." -Icon 'blocked' @detailsParams
        }
        #write-host Global:DrTicket $Global:DrTicket
        $Global:DrTimerFile = Join-Path $Global:DrTemp "DrTimers.json"
        If ($Global:DrTicket) {
            $res = Update-Ticket -Status "In Progress"

            if (-not $Global:DrAssetId) {
                $Global:DrAssetId = $res.ticket.asset_ids
                Set-DrAssetIdRegistry -AssetId $Global:DrAssetId @detailsParams
            }
        }
        Add-LogEntry -Message "Using ticket number: $Global:DrTicket" -Icon 'ticketinfo' @detailsParams
        Add-LogEntry -Message "DrTimerFile: $Global:DrTimerFile" -Icon 'file' @detailsParams

        # ✅ Ensure log file exists
        if (-not $Global:DrLogFile) {
            $Global:DrLogFile = Join-Path $Global:DrLogs 'Session.txt'
            if (-not (Test-Path $Global:DrLogFile)) {
                New-Item -Path $Global:DrLogFile -ItemType File | Out-Null
            }
            Add-LogEntry -Message "Log file created at: $Global:DrLogFile" -Icon 'script' @detailsParams
        }

        if ($LogToHost -ne $Global:DrLogToHost) {
            Add-LogEntry -Message "LogToHost overridden: $LogToHost" -Icon 'system' @detailsParams
            $Global:DrLogToHost = $LogToHost
        }
        #if ($LogActivity -ne $Global:DrLogActivity) {
        #    Add-LogEntry -Message "LogActivity overridden: $LogActivity" -Icon 'SettingsOverride' -AddToBody
        #    $Global:DrLogActivity = $LogActivity
        #}

        Add-LogEntry -Message "Job initialization complete." -Icon 'jobend' @summaryParams
    }
    catch {
        Add-LogEntry -Message "Error during Initialize-Job: $($_.Exception.Message)" -Icon 'Error' @summaryParams
    }
}
#endregion

#region File: Initialize-SysVarsFromFile.ps1
function Initialize-SysVarsFromFile {
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    $xmlPath = Initialize-VariableStore 
    Write-Host "Using XML path: $xmlPath"

    $xml = New-Object System.Xml.XmlDocument
    try {
        $xml.Load($xmlPath)
        Write-Host "XML loaded successfully."
    }
    catch {
        Write-Host "ERROR: Failed to load XML file. $_"
        return
    }

    $variables = $xml.SelectNodes("//Variable")
    foreach ($var in $variables) {
        $name = $var.GetAttribute("Name")
        $type = $var.GetAttribute("Type")
        $value = $var.GetAttribute("Value")

        if (-not $name) {
            Add-LogEntry "Skipping variable with missing name." @detailsParams
            continue
        }

        $converted = switch ($type) {
            "Boolean" { [System.Convert]::ToBoolean($value) }
            "Number" { [int]$value }
            "Array" { $value | ConvertFrom-Json }
            "Hashtable" { $value | ConvertFrom-Json }
            default { $value }
        }

        Set-Variable -Name $name -Value $converted -Scope Global
        Add-LogEntry "Set $name = $converted" @detailsParams -Icon 'endsection'
    }

    Add-LogEntry "SysVars Initialization complete." @summaryParams -Icon success
}
#endregion

#region File: Initialize-VariableStore.ps1
function Initialize-VariableStore {
    $xmlPath = $Global:DrVarStorePath
    $folderPath = Split-Path $xmlPath

    if (-not (Test-Path $folderPath)) {
        New-Item -Path $folderPath -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $xmlPath)) {
        $xml = New-Object System.Xml.XmlDocument
        $root = $xml.CreateElement("Variables")
        $xml.AppendChild($root) | Out-Null

        $defaults = @(
            @{ Name = "DrTimeStamp"; Type = "Boolean"; Value = $true },
            @{ Name = "DrLogDetailsBuffer"; Type = "Text"; Value = "details" },
            @{ Name = "DrLogErrorBuffer"; Type = "Text"; Value = "error" },
            @{ Name = "DrLogSummaryBuffer"; Type = "Text"; Value = "summary" },
            @{ Name = "DrLogToFile"; Type = "Boolean"; Value = $false },
            @{ Name = "DrLogToHost"; Type = "Boolean"; Value = $true },
            @{ Name = "DrLogActivity"; Type = "Boolean"; Value = $true }
            @{ Name = "DrSuppressInitLog"; Type = "Boolean"; Value = $true }
        )

        foreach ($item in $defaults) {
            $varElement = $xml.CreateElement("Variable")
            $varElement.SetAttribute("Name", $item.Name)
            $varElement.SetAttribute("Type", $item.Type)
            $varElement.SetAttribute("Value", $item.Value.ToString())
            $root.AppendChild($varElement) | Out-Null
        }

        $xml.Save($xmlPath)
    }

    return $xmlPath
}
#endregion

#region File: Install-DrPackage.ps1
function Install-DrPackage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$PackageName = '*ALL',
        [Parameter(Mandatory = $false)]
        [switch]$deleteZip = $False
    )

    $processedCount = 0

    if ($PackageName -eq '*ALL') {
        $zipFiles = Get-ChildItem -Path $GLOBAL:DrToolBox -Filter *.zip
        $packages = $zipFiles | ForEach-Object { $_.BaseName }
    }
    else {
        $packages = @($PackageName)
    }

    foreach ($pkg in $packages) {
        Add-LogEntry -Message "Starting Install-Package for package: $pkg" -AddToBody -Icon install

        $subfolder = Join-Path -Path $GLOBAL:DrToolBox -ChildPath $pkg
        $zipfile = "$subfolder.zip"

        if (Test-Path $zipfile) {
            try {
                if (Test-Path $subfolder) {
                    Remove-Item -Path "$subfolder\*" -Recurse -Force -ErrorAction Stop
                    Add-LogEntry -Message "Directory cleared: $subfolder" -AddToBody -Icon cleanup
                }

                Expand-Archive -Path $zipfile -DestinationPath $subfolder -Force
                Add-LogEntry -Message "📂 $zipfile expanded into: $subfolder" -AddToBody -Icon FileAction

                if ($deleteZip) {
                    Remove-Item -Path $zipfile -ErrorAction Stop
                    Add-LogEntry -Message "$zipfile deleted." -AddToBody -Icon 'deleted'
                }

                $processedCount++
            }
            catch {
                Write-Error "An error occurred: $_"
                Add-LogEntry -Message "An error occurred: $_" -AddToBody -Icon 'error'
            }
        }
        else {
            Write-Error "The zip file $zipfile does not exist."
            Add-LogEntry -Message "⚠️ The zip file $zipfile does not exist." -AddToBody -Icon StatusWarning
        }

        Add-LogEntry -Message "✅ End of Install-Package for package: $pkg" -AddToBody -Icon StatusOK
        Add-LogEntry -Message "------------------------" -AddToBody -Icon syncroapi
    }

    Add-LogEntry -Message "📊 Total packages processed: $processedCount" -AddBody -Icon syncroapi
}
#endregion

#region File: Install-UpdateWinget.ps1
function Install-UpdateWinget {
    [CmdletBinding()]
    param (
        [switch]$ForceUpdate,  # If winget exists, attempt to upgrade App Installer via winget
        [switch]$AddToBody     # Final summary uses: -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
    )

    # Winget "already installed/up-to-date" exit code often seen from winget operations
    [int64]$alreadyInstalledCode = -1978335189

    # Initialize a result object you can consume after call
    $result = [pscustomobject]@{
        WingetPath        = $null
        Installed         = $false
        ForceUpdateTried  = [bool]$ForceUpdate
        UpdateExitCode    = $null
        DownloadUrl       = 'https://aka.ms/getwinget'
        DownloadPath      = $null
        DownloadOk        = $false
        DismExitCode      = $null
        PendingRestartSet = $false
        Message           = $null
    }

    try {
        # Detect winget explicitly (PowerShell 5-safe)
        $wingetCmd = $null
        try {
            $wingetCmd = Get-Command -Name 'winget.exe' -Type Application -ErrorAction SilentlyContinue
        }
        catch { }
        $result.WingetPath = if ($wingetCmd) { $wingetCmd.Source } else { $null }

        if ($result.WingetPath) {
            $result.Installed = $true

            # Installed → optionally update, then emit ONE summary line
            try {
                if ($ForceUpdate) {
                    & "$($result.WingetPath)" upgrade --id Microsoft.AppInstaller -e --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                    $result.UpdateExitCode = $LastExitCode

                    if ($result.UpdateExitCode -eq 0 -or $result.UpdateExitCode -eq $alreadyInstalledCode) {
                        $result.Message = "winget installed and up-to-date"
                    }
                    else {
                        $result.Message = "winget installed; update failed (exit $($result.UpdateExitCode))"
                    }
                }
                else {
                    $result.Message = "winget installed and up-to-date"
                }
            }
            catch {
                $result.Message = "winget installed; update exception: $($_.Exception.Message)"
            }

            Add-LogEntry -Message $result.Message -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
            return $result
        }

        # Not installed → download bundle
        $url = $result.DownloadUrl
        $tempFile = Join-Path $env:TEMP "AppInstaller.msixbundle"
        $result.DownloadPath = $tempFile
        try {
            Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing
            $result.DownloadOk = Test-Path -LiteralPath $tempFile
        }
        catch {
            $result.DownloadOk = $false
        }

        if (-not $result.DownloadOk) {
            $result.Message = "winget not installed; download failed"
            Add-LogEntry -Message $result.Message -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
            return $result
        }

        # Install via DISM (SYSTEM-safe). Single summary line at the end.
        $dismCmd = "DISM /Online /Add-ProvisionedAppxPackage /PackagePath:`"$tempFile`" /SkipLicense"
        try {
            $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $dismCmd" -Wait -PassThru
            $result.DismExitCode = $process.ExitCode

            if ($process.ExitCode -eq 0) {
                # Per your convention, mark pending restart when provisioning succeeds
                Set-PendingRestart -AddToBody:$true
                $result.PendingRestartSet = $true
                $result.Message = "winget installed successfully (pending restart set)"
            }
            else {
                $result.Message = "winget install failed (exit $($process.ExitCode))"
            }
        }
        catch {
            $result.Message = "winget install exception: $($_.Exception.Message)"
        }

        Add-LogEntry -Message $result.Message -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
        return $result
    }
    catch {
        $result.Message = "Install-UpdateWinget unhandled exception: $($_.Exception.Message)"
        Add-LogEntry -Message $result.Message -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
        return $result
    }
}
#endregion

#region File: Invoke-AdwCleaner.ps1
function Invoke-AdwCleaner {
    param (
        [switch]$Clean,
        [switch]$SummaryOnly,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    $iBuffer = @('ADWCleaner')
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $File = "adwcleaner.exe"
    $Folder = $Global:DrToolbox
    $AppArgs = if ($Clean) { "/clean /noreboot" } else { "/scan" }
    $AppArgs += " /eula /Path $Global:DrTemp"

    Add-LogEntry "⚙️ FilePath: $File ArgumentList: $AppArgs" -Icon 'setting' -Buffer $iBuffer
    
    $runParams = @{
        folder  = $Folder
        file    = $File
        appargs = $AppArgs
        wait    = $true
        Log     = $false
    }
    $result = FindAndRun @runParams

    $logDirPath = Join-Path -Path $Global:DrTemp -ChildPath "Adwcleaner\\Logs"
    $logFilePath = Get-ChildItem -Path $logDirPath -Filter *.txt | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $logFilePath) {
        Add-LogEntry -Message "No AdwCleaner log file found." @detailsParams -Icon 'error'
        return
    }

    $logContent = [System.IO.File]::ReadAllText($logFilePath.FullName)

    if (-not $SummaryOnly) {
        Add-LogEntry -Message $logContent -Hidden -Icon info -Buffer 'AdwCleaner result' -FlushBuffer
    }

    Add-LogEntry -Message "🧾 ADWCleaner Summary" -Buffer $iBuffer

    $issuesDetected = $null
    $issuesCleaned = $null

    if ($logContent -match 'Detected:\s+(\d+)') {
        $issuesDetected = [int]$matches[1]
        Add-LogEntry -Message "🔍 Number of issues Detected: $issuesDetected" -Buffer $iBuffer
    }
    else {
        Add-LogEntry -Message "⚠️ The pattern 'Detected: ' followed by a number was not found in the log content." -Buffer $iBuffer
    }

    if ($Clean) {
        if ($logContent -match 'Cleaned:\s+(\d+)') {
            $issuesCleaned = [int]$matches[1]
            Add-LogEntry -Message "Number of issues Cleaned: $issuesCleaned" -Buffer $iBuffer -Icon 'cleanup'
        }
        else {
            Add-LogEntry -Message "The pattern 'Cleaned: ' followed by a number was not found in the log content." -icon 'warninglow' -Buffer $iBuffer
        }
    }

    Add-LogEntry -Message "📄 LogFilePath: $($logFilePath.FullName)" -Buffer $iBuffer
    Add-LogEntry -Message "Invoke-ADWCleaner complete" -Icon jobend -Buffer $iBuffer -FlushBuffer

    return @{
        LogContent     = $logContent
        IssuesDetected = $issuesDetected
        IssuesCleaned  = $issuesCleaned
        LogFilePath    = $logFilePath.FullName
    }
}
#endregion

#region File: Invoke-DrApiRequest.ps1
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
#endregion

#region File: Invoke-DrCleanup.ps1
function Invoke-DrCleanup {
    [CmdletBinding()]
    param (
        [switch]$Aggressive,
        [switch]$Lite,                # Non-admin mode
        [double]$ThresholdPercentFree, # Optional threshold
        [string[]]$Buffer = "Invoke-DrCleanup",
        [switch]$FlushBuffer

    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    Log-Invocation -IncludeParameters @detailsParams 


    # -----------------------
    # Validation (accumulate)
    # -----------------------
    $errors = 0
    if ($ThresholdPercentFree -and ($ThresholdPercentFree -lt 0 -or $ThresholdPercentFree -gt 100)) {
        Add-LogEntry ("Invalid ThresholdPercentFree: {0}. Must be between 0 and 100." -f $ThresholdPercentFree) -Icon 'Error' @detailsParams 
        $errors++
    }

    if (-not $Lite) {
        if (-not (Assert-IsAdmin @PSBoundParameters)) { 
            Add-LogEntry "Invoke-DrCleanup requires admin when not in Lite mode." -Icon 'Error' @summaryParams
            return
        }
    }

    if ($errors) {
        Add-LogEntry ("Validation failed: {0} error(s)." -f $errors) -Icon 'Error' @summaryParams
        return
    }

    $systemDrive = $env:SystemDrive

    # Capture BEFORE state
    $before = Get-StorageHealth -Drive 'C:'          # snapshot before cleanup
    #$beforeSummary = Get-StorageSummary -Drive $systemDrive
    #$beforeMetrics = Get-StorageMetrics -Drive $systemDrive

    #Add-LogEntry -Message "Before Cleanup:" -Icon 'Storage' -AddToBody
    #Add-LogEntry -Message $beforeSummary -Icon 'Storage' -AddToBody

    # --------------------------------------
    # Build raw cleanup items (pre-dedup)
    # --------------------------------------
    $rawItems = New-Object System.Collections.Generic.List[object]
    $rawItems.Add(@{ Path = "$Global:DrLogs"; Action = "Empty" })
    $rawItems.Add(@{ Path = "$Global:DrTemp"; Action = "Empty" })

    # Expand user-level paths
    $userPatterns = @(
        @{ Rel = "AppData\Local\Temp"; Action = "Empty" },
        @{ Rel = "AppData\Local\Microsoft\Windows\INetCache"; Action = "Empty" },
        @{ Rel = "AppData\Local\Microsoft\Windows\WebCache"; Action = "Delete" },
        @{ Rel = "AppData\Local\CrashDumps"; Action = "Delete" },
        @{ Rel = "AppData\Local\Packages\*\TempState"; Action = "Empty" },
        @{ Rel = "AppData\Local\Microsoft\Windows\WER"; Action = "Empty" }
    )

    try {
        $userDirs = Get-ChildItem "C:\Users" -Directory -ErrorAction Stop
    }
    catch {
        Add-LogEntry ("Error enumerating C:\Users: {0}" -f $_.Exception.Message) -Icon 'Error' @detailsParams 
        $userDirs = @()
        $errors++
    }

    foreach ($u in $userDirs) {
        foreach ($p in $userPatterns) {
            $candidate = Join-Path $u.FullName $p.Rel
            $rawItems.Add(@{ Path = $candidate; Action = $p.Action })
        }
    }

    # System-level paths only if NOT Lite
    if (-not $Lite) {
        $rawItems.Add(@{ Path = "C:\Windows\Temp"; Action = "Empty" })
        $rawItems.Add(@{ Path = "C:\Windows\Prefetch"; Action = "Empty" })
        if ($Aggressive) {
            $rawItems.Add(@{ Path = "C:\Windows\SoftwareDistribution\Download"; Action = "Empty" })
            $rawItems.Add(@{ Path = "C:\Windows\SoftwareDistribution\DataStore"; Action = "Empty" })
            $rawItems.Add(@{ Path = "C:\Windows\MEMORY.DMP"; Action = "Delete" })
            $rawItems.Add(@{ Path = "C:\Windows\Minidump"; Action = "Delete" })
            $rawItems.Add(@{ Path = "C:\$WINDOWS.~BT"; Action = "Delete" })
            $rawItems.Add(@{ Path = "C:\$WINDOWS.~WS"; Action = "Delete" })
        }
    }

    # --------------------------------------
    # Normalize, resolve, de-duplicate plan
    # --------------------------------------
    $plan = @{} # key: normalized path (lowercased without trailing \) -> PSCustomObject {Path, Action}
    foreach ($item in $rawItems) {
        $path = $item.Path
        $action = $item.Action

        $resolvedList = @()

        try {
            # Expand wildcards when present, otherwise resolve literally
            if ($path -like '*[*?]*') {
                $resolvedList = Resolve-Path -Path $path -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }
            }
            else {
                if (Test-Path -LiteralPath $path) {
                    $rp = Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue
                    if ($rp) { $resolvedList = $rp.Path }
                }
            }
        }
        catch {
            # Keep silent; missing paths are fine at plan time
        }

        foreach ($r in @($resolvedList)) {
            $norm = ($r.Trim()).TrimEnd('\').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($norm)) { continue }

            if ($plan.ContainsKey($norm)) {
                # Escalate action if any caller wants Delete
                if ($action -eq 'Delete' -or $plan[$norm].Action -eq 'Delete') {
                    $plan[$norm].Action = 'Delete'
                }
            }
            else {
                $plan[$norm] = [PSCustomObject]@{ Path = $r; Action = $action }
            }
        }
    }

    # --------------------------------------
    # Prune children covered by a parent Delete
    # --------------------------------------
    $deleteParents = $plan.GetEnumerator() | Where-Object { $_.Value.Action -eq 'Delete' } | ForEach-Object { $_.Key }

    foreach ($key in @($plan.Keys)) {
        if ($plan[$key].Action -ne 'Delete') {
            foreach ($parent in $deleteParents) {
                if ($key.StartsWith($parent + '\')) {
                    $plan.Remove($key)
                    break
                }
            }
        }
    }

    # --------------------------------------
    # Order the work (smart order)
    # --------------------------------------
    $deleteItems = $plan.GetEnumerator() |
    Where-Object { $_.Value.Action -eq 'Delete' } |
    Sort-Object { $_.Key.Split('\').Count } -Descending |
    ForEach-Object { $_.Value }

    $emptyItems = $plan.GetEnumerator() |
    Where-Object { $_.Value.Action -eq 'Empty' } |
    Sort-Object { $_.Key.Split('\').Count } -Descending |
    ForEach-Object { $_.Value }

    $plannedDeleteCount = $deleteItems.Count
    $plannedEmptyCount = $emptyItems.Count

    # --------------------------------------
    # Execute
    # --------------------------------------
    $itemsDeletedTotal = 0
    $foldersDeletedTotal = 0

    foreach ($it in $deleteItems) {
        try {
            $result = Clean-DrFolder -Path $it.Path -Delete
            $itemsDeletedTotal += ($result.ItemsDeleted)
            $foldersDeletedTotal += ([int]($result.FolderWasDeleted))
        }
        catch {
            Add-LogEntry ("Error deleting '{0}': {1}" -f $it.Path, $_.Exception.Message) -Icon 'Error' @detailsParams 
            $errors++
        }
    }

    foreach ($it in $emptyItems) {
        try {
            $result = Clean-DrFolder -Path $it.Path -EmptyOnly
            $itemsDeletedTotal += ($result.ItemsDeleted)
        }
        catch {
            Add-LogEntry ("Error emptying '{0}': {1}" -f $it.Path, $_.Exception.Message) -Icon 'Error' @detailsParams 
            $errors++
        }
    }

    # Optional admin-only tasks
    if (-not $Lite) {
        try {
            Clear-RecycleBin -DriveLetter $systemDrive.TrimEnd(':') -Force -ErrorAction Stop
        }
        catch {
            Add-LogEntry ("Failed to clear recycle bin: {0}" -f $_.Exception.Message) -Icon 'Error' @detailsParams 
            $errors++
        }

        try {
            Start-ScheduledTask -TaskPath "\Microsoft\Windows\DiskCleanup\" -TaskName "SilentCleanup"

            # Brief wait loop (max ~2 minutes) so we don't spam logs
            $deadline = (Get-Date).AddMinutes(2)
            do {
                Start-Sleep -Seconds 5
                $taskInfo = Get-ScheduledTaskInfo -TaskName "SilentCleanup" -TaskPath "\Microsoft\Windows\DiskCleanup\"
            } while ($taskInfo.State -eq 'Running' -and (Get-Date) -lt $deadline)
        }
        catch {
            Add-LogEntry ("Failed to run Storage Sense (SilentCleanup): {0}" -f $_.Exception.Message) -Icon 'Error' @detailsParams 
            $errors++
        }
    }

    # Capture AFTER state
    $after = Get-StorageHealth -Drive 'C:'          # snapshot after cleanup
    #$afterSummary = Get-StorageSummary -Drive $systemDrive
    #$afterMetrics = Get-StorageMetrics -Drive $systemDrive

    #Add-LogEntry -Message "After Cleanup:" -Icon 'Storage' -AddToBody
    #Add-LogEntry -Message $afterSummary -Icon 'Storage' -AddToBody
    $result = Get-ReclaimedStorageHealth -Before $before -After $after

    # Calculate reclaimed space
    $params = @{
        Before = $beforeMetrics
        After  = $afterMetrics
    }
    if ($ThresholdPercentFree) { $params.MinPercentFree = $ThresholdPercentFree }

    $reclaimedResult = Get-ReclaimedStorage @params

    $thresholdNote = ""
    if ($ThresholdPercentFree) {
        if ($reclaimedResult.MeetsThreshold) {
            $thresholdNote = " (Threshold met)"
        }
        else {
            $thresholdNote = " (Threshold NOT met)"
            Add-LogEntry -Message ("Warning: Threshold of {0}% was not met." -f $ThresholdPercentFree) -Icon 'Warning' @detailsParams 
        }
    }

    # Single final flush (planned vs actual)
    Add-LogEntry ("Summary: Invoke-DrCleanup complete. PlannedDelete: {0}; PlannedEmpty: {1}; ItemsDeleted: {2}; FoldersDeleted: {3}; Errors: {4}; Reclaimed: {5} GB{6}" -f `
            $plannedDeleteCount, $plannedEmptyCount, $itemsDeletedTotal, $foldersDeletedTotal, $errors, $reclaimedResult.ReclaimedGB, $thresholdNote) -Icon 'Status' @summaryParams
}
#endregion

#region File: IsDuplicateCommand.ps1
IsDuplicateCommand([DrRecommendation[]] $allRecommendations) {
        $existing = $allRecommendations | Where-Object {
            $_.CommandToRun -eq $this.CommandToRun -and $_.Approved -eq $true -and $_.NumericId -ne $this.NumericId
        }
        return ($existing.Count -gt 0)
    }
#endregion

#region File: IsUserAdmin.ps1
function IsUserAdmin {
    <#
    .SYNOPSIS
        Checks if the current session has administrative privileges.

    .DESCRIPTION
        Returns $true if the user is an administrator.
        If not, logs a message and either exits, returns $false, or throws an exception depending on the switch used.

    .PARAMETER Exit
        Exits the script immediately if admin rights are missing.

    .PARAMETER Return
        Returns $false if admin rights are missing.

    .PARAMETER Throw
        Throws a terminating error if admin rights are missing.

    .NOTES
        If none of the switches are specified, defaults to -Return behavior.
    #>

    [CmdletBinding(DefaultParameterSetName = 'Return')]
    param (
        [Parameter(ParameterSetName = 'Exit')]
        [switch]$Exit,

        [Parameter(ParameterSetName = 'Return')]
        [switch]$Return,

        [Parameter(ParameterSetName = 'Throw')]
        [switch]$Throw
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Add-LogEntry -Message "This function requires administrative privileges. Please run as administrator." -Icon "permission" -AddBody

        if ($Exit) {
            exit 1
        }
        elseif ($Throw) {
            throw "This function requires administrative privileges."
        }
        else {
            return $false
        }
    }

    return $true
}
#endregion

#region File: Join-ComputerToDomain.ps1
function Join-ComputerToDomain {
    [CmdletBinding()]
    param(
        [string]$DomainName,          # e.g., 'dcelectric.local'
        [string]$AdminUser,           # short or qualified ('jim', 'DOMAIN\jim', 'jim@domain')
        [string]$AdminPassword,       # PLAIN TEXT
        [string]$PrimaryUser,         # OPTIONAL
        [switch]$LocalAdmin,          # add PrimaryUser to local Administrators (if provided)
        [switch]$Restart,             # restart after changes
        [switch]$RemoveAzure,          # remove Azure AD / Workplace connection if present
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    if (-not (Assert-IsAdmin @PSBoundParameters)) { return }

    # --- EARLY EDITION CHECK (abort immediately on Home/Core) ---
    try {
        $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
        if ($edition -match 'Home|Core') {
            Add-LogEntry -Message "Unsupported Windows edition for domain join: '$edition'. Aborting." -Icon 'error' -AddBody
            return
        }
    }
    catch {
        Add-LogEntry -Message "Could not read Windows EditionID: $($_.Exception.Message)" -Icon 'warning' @detailsParams
    }

    Add-LogEntry -Message "Domain join requested. Domain='$DomainName'; AdminUser='$AdminUser'; PrimaryUser='$PrimaryUser'; LocalAdmin=$([bool]$LocalAdmin); Restart=$([bool]$Restart); RemoveAzure=$([bool]$RemoveAzure)" -Icon 'jobstart' @detailsParams

    # --- Validation (log directly; no arrays) ---
    $validationFailed = $false

    if ([string]::IsNullOrWhiteSpace($DomainName)) {
        $validationFailed = $true
        Add-LogEntry "DomainName is required (e.g., 'dcelectric.local')." -Icon 'error' @detailsParams
    }
    elseif ($DomainName -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
        Add-LogEntry "DomainName '$DomainName' does not look like a standard FQDN (proceeding if resolvable)." -Icon 'warning' @detailsParams
    }

    if ([string]::IsNullOrWhiteSpace($AdminUser)) {
        $validationFailed = $true
        Add-LogEntry "AdminUser is required (short or qualified)." -Icon 'error' @detailsParams
    }

    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        $validationFailed = $true
        Add-LogEntry "AdminPassword (plain text) is required." -Icon 'error' -AddToBody
    }

    $alreadyJoined = $false; $currentDomain = $null
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $alreadyJoined = [bool]$cs.PartOfDomain
        $currentDomain = $cs.Domain
        if ($alreadyJoined -and $DomainName -and $currentDomain -ne $DomainName) {
            $validationFailed = $true
            Add-LogEntry "Machine already joined to '$currentDomain'; requested '$DomainName'. This function does not unjoin/rejoin." -Icon 'error' -AddToBody
        }
    }
    catch {
        Add-LogEntry "Could not read current domain state: $($_.Exception.Message)" -Icon 'warning' -AddToBody
    }

    if ($validationFailed) {
        Add-LogEntry -Message "Validation failed. Fix the errors above and run again." -Icon 'error' -AddBody
        return
    }

    # --- Azure AD / Workplace Join detection and optional removal ---
    $azureInitiallyConnected = $false
    $aadInitially = $false
    $wpInitially = $false
    try {
        $dsOut = (& dsregcmd /status) 2>&1
        $aadInitially = $dsOut | Select-String -Pattern 'AzureAdJoined\s*:\s*YES'
        $wpInitially = $dsOut | Select-String -Pattern 'WorkplaceJoined\s*:\s*YES'
        $azureInitiallyConnected = ($aadInitially -or $wpInitially)
        Add-LogEntry -Message "Azure connection status: AzureAdJoined=$aadInitially; WorkplaceJoined=$wpInitially." -Icon 'task' -AddToBody
    }
    catch {
        Add-LogEntry -Message "Could not read Azure connection status: $($_.Exception.Message)" -Icon 'warning' -AddToBody
    }

    if ($azureInitiallyConnected) {
        if ($RemoveAzure) {
            Add-LogEntry -Message "Azure connection detected. -RemoveAzure specified — removing Azure connection before domain join." -Icon 'warning' -AddToBody
            try {
                $null = (& dsregcmd /leave) 2>&1
                Start-Sleep -Seconds 3
                try {
                    $dsOut2 = (& dsregcmd /status) 2>&1
                    $aadNow = $dsOut2 | Select-String -Pattern 'AzureAdJoined\s*:\s*YES'
                    $wpNow = $dsOut2 | Select-String -Pattern 'WorkplaceJoined\s*:\s*YES'
                    if (-not $aadNow -and -not $wpNow) {
                        Add-LogEntry -Message "Azure connection removed successfully." -Icon 'success' -AddToBody
                    }
                    else {
                        Add-LogEntry -Message "Azure connection still present after removal attempt (AzureAdJoined=$aadNow; WorkplaceJoined=$wpNow)." -Icon 'warning' -AddToBody
                    }
                }
                catch {
                    Add-LogEntry -Message "Post-removal Azure status check failed: $($_.Exception.Message)" -Icon 'warning' -AddToBody
                }
            }
            catch {
                Add-LogEntry -Message "Failed to remove Azure connection via 'dsregcmd /leave': $($_.Exception.Message)" -Icon 'error' -AddBody
                return
            }
        }
        else {
            Add-LogEntry -Message "Computer is connected to Azure (Azure AD or Workplace). -RemoveAzure not specified — aborting." -Icon 'error' -AddBody
            return
        }
    }

    # --- Normalize AdminUser to UPN if short ---
    $adminUserUpn = $AdminUser
    if ($AdminUser -and $DomainName -and $AdminUser -notmatch '\\' -and $AdminUser -notmatch '@') {
        $adminUserUpn = "$AdminUser@$DomainName"
        Add-LogEntry -Message "AdminUser normalized to UPN: '$adminUserUpn'." -Icon 'task' -AddToBody
    }

    # --- Domain accessibility ---
    try {
        $null = Resolve-DnsName -Name $DomainName -ErrorAction Stop
        Add-LogEntry -Message "DNS resolution succeeded for '$DomainName'." -Icon 'task' -AddToBody
    }
    catch {
        Add-LogEntry -Message "DNS resolution failed for '$DomainName': $($_.Exception.Message)" -Icon 'error' -AddBody
        return
    }

    try {
        $nl = (& nltest /dsgetdc:$DomainName) 2>&1
        if ($LASTEXITCODE -eq 0) {
            $dcMatch = ($nl | Select-String -Pattern 'DC:\s*(.+)$')
            $dc = if ($dcMatch) { $dcMatch.Matches.Groups[1].Value.Trim() } else { $null }
            Add-LogEntry -Message ("Domain controller discovered" + ($(if ($dc) { ": '$dc'." } else { "." }))) -Icon 'task' -AddToBody
        }
        else {
            Add-LogEntry -Message "NLTEST failed to find a domain controller for '$DomainName'." -Icon 'error' -AddBody
            return
        }
    }
    catch {
        Add-LogEntry -Message "NLTEST error while discovering DC: $($_.Exception.Message)" -Icon 'error' -AddBody
        return
    }

    # --- Credentials (LDAP bind only) ---
    try {
        $de = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DomainName", $adminUserUpn, $AdminPassword)
        $null = $de.NativeObject
        Add-LogEntry -Message "LDAP bind successful for '$adminUserUpn'." -Icon 'success' -AddToBody
    }
    catch {
        Add-LogEntry -Message "LDAP bind failed for '$adminUserUpn': $($_.Exception.Message)" -Icon 'error' -AddBody
        return
    }

    # --- Join domain if needed ---
    if (-not $alreadyJoined) {
        Add-LogEntry -Message "Joining domain '$DomainName'..." -Icon 'systeminit' -AddToBody
        $securePwd = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
        $domainCredential = New-Object System.Management.Automation.PSCredential ($adminUserUpn, $securePwd)

        try {
            Add-Computer -DomainName $DomainName -Credential $domainCredential -PassThru -ErrorAction Stop | Out-Null
            Add-LogEntry -Message "Domain join initiated successfully for '$DomainName'." -Icon 'success' -AddToBody
        }
        catch {
            Add-LogEntry -Message "Aborting: Domain join failed: $($_.Exception.Message)" -Icon 'error' -AddBody
            $excText = ($_.Exception | Out-String).Trim()
            if ($excText) { Add-LogEntry -Message "Exception details:`n$excText" -Icon 'error' -AddBody }
            return
        }

        Start-Sleep -Seconds 2
        try {
            $cs = Get-CimInstance Win32_ComputerSystem
            $alreadyJoined = [bool]$cs.PartOfDomain
            $currentDomain = $cs.Domain
        }
        catch {
            Add-LogEntry -Message "Could not refresh domain state: $($_.Exception.Message)" -Icon 'warning' -AddToBody
        }
    }
    else {
        Add-LogEntry -Message "Machine already joined to '$currentDomain'. Skipping domain join." -Icon 'info' -AddToBody
    }

    # --- Local admin (optional) ---
    $localAdminAdded = $false
    if ($LocalAdmin -and $PrimaryUser) {
        $candidates = @()
        if ($PrimaryUser -match '@' -or $PrimaryUser -match '\\') {
            $candidates += $PrimaryUser
        }
        else {
            $candidates += "$PrimaryUser@$DomainName"
            $candidates += "$DomainName\$PrimaryUser"
        }

        $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $adminsGroup = $adminsSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]

        Add-LogEntry -Message "Adding '$PrimaryUser' to local '$adminsGroup' (candidates: $($candidates -join ', '))..." -Icon 'task' -AddToBody

        $added = $false
        foreach ($id in $candidates) {
            try {
                Add-LocalGroupMember -Group $adminsGroup -Member $id -ErrorAction Stop
                $localAdminAdded = $true; $added = $true
                Add-LogEntry -Message "Added '$id' to local '$adminsGroup'." -Icon 'success' -AddToBody
                break
            }
            catch {
                Add-LogEntry -Message "Add-LocalGroupMember failed for '$id' (will try fallback)." -Icon 'warning' -AddToBody
                Add-LogEntry -Message "Error: $($_.Exception.Message)" -Icon 'warning' -AddToBody
                try {
                    $null = & net localgroup "$adminsGroup" "$id" /add
                    $localAdminAdded = $true; $added = $true
                    Add-LogEntry -Message "Added '$id' to local '$adminsGroup' via 'net localgroup'." -Icon 'success' -AddToBody
                    break
                }
                catch {
                    Add-LogEntry -Message "Fallback failed for '$id': $($_.Exception.Message)" -Icon 'warning' -AddToBody
                }
            }
        }

        if (-not $added) {
            Add-LogEntry -Message "Unable to add '$PrimaryUser' to local administrators after all attempts." -Icon 'error' -AddBody
            return
        }
    }
    elseif ($LocalAdmin -and -not $PrimaryUser) {
        Add-LogEntry -Message "PrimaryUser not specified; skipping local administrator addition." -Icon 'info' -AddToBody
    }

    # --- Summary & restart ---
    $summary = [pscustomobject]@{
        Computer         = $env:COMPUTERNAME
        DomainRequested  = $DomainName
        DomainCurrent    = $currentDomain
        PartOfDomain     = $alreadyJoined
        PrimaryUser      = $PrimaryUser
        LocalAdminAdded  = $localAdminAdded
        RestartRequested = [bool]$Restart
        Timestamp        = (Get-Date)
    }

    # Conditional pending restart flag (only if meaningful changes requested/performed)
    if (-not $alreadyJoined -or $localAdminAdded -or $RemoveAzure) {
        Set-PendingRestart -AddToBody
    }

    # Structured summary logging (append only)
    Log-ObjProperties -InputObject $summary -AddToBody

    # Final status line appended; actual flush occurs below
    Add-LogEntry -Message "Completed. Domain='$currentDomain', LocalAdminAdded=$localAdminAdded." -Icon 'jobend' -AddToBody

    if ($Restart) {
        Add-LogEntry -Message "Restarting computer due to domain join/local admin changes." -Icon 'restart' -AddBody
        Restart-Computer -Force
    }
    else {
        Add-LogEntry -Message "Restart required for changes to take effect." -Icon 'jobend' -AddBody
    }

    return $summary
}
#endregion

#region File: Load-DrTimers.ps1
function Load-DrTimers {
    if (Test-Path $Global:DrTimerFile) {
        $jsonObj = Get-Content -Path $Global:DrTimerFile | ConvertFrom-Json
        $Global:DrTimers = @{}
        foreach ($key in $jsonObj.PSObject.Properties.Name) {
            $Global:DrTimers[$key] = $jsonObj.$key
        }
    }
    else {
        $Global:DrTimers = @{}
    }
}
#endregion

#region File: Locate-File.ps1
function Locate-File {
    param (
        [string]$Path,
        [string]$Name
    )

    # Validate parameters
    if (-not (Test-Path -Path $Path)) {
        Write-Error "The specified path does not exist."
        return
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Error "The file name cannot be empty."
        return
    }

    # Search for the file
    try {
        $files = Get-ChildItem -Path $Path -Recurse -File | Where-Object { $_.Name -eq $Name }
        if ($files) {
            $files | Select-Object -ExpandProperty FullName
        }
        else {
            Write-Output "No files found with the name '$Name'."
        }
    }
    catch {
        Write-Error "An error occurred while searching for the file: $_"
    }
}
#endregion

#region File: Log-DrActivity.ps1
function Log-DrActivity {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [string] $ActivityType,

        [Parameter(Mandatory)]
        [string] $EventName,

        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter()]
        [hashtable] $Data = @{}
    )

    try {
        $payload = @{
            uuid          = $Global:UUID
            activity_type = $ActivityType
            event         = $EventName
            message       = $Message
            data          = $Data
        }

        # ✅ Suppress API response output
        $null = Invoke-DrApiRequest `
            -Method 'POST' `
            -Endpoint "/api/syncro_device/rmm_alerts/log_activity" `
            -Body $payload
    }
    catch {
        Write-Error "🔴 Failed to log activity: $_"
    }

    return $null
}
#endregion

#region File: Log-Invocation.ps1
function Log-Invocation {
    [CmdletBinding()]
    param (
        [switch]$IncludeParameters,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    try {
        $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
        $detailsParams = $logParams.Details
        $summaryParams = $logParams.Summary

        if ($IncludeParameters) {
            # Get the caller's full command line including parameters
            $invocation = (Get-PSCallStack)[1].InvocationInfo.Line
        }
        else {
            # Just the caller's function name
            $invocation = (Get-PSCallStack)[1].FunctionName
        }

        # Log the invocation
        Add-LogEntry -Message "Start: $invocation" -Icon 'startup' @summaryParams
    }
    catch {
        Add-LogEntry -Message "Failed to log invocation: $($_.Exception.Message)" -Icon 'error' @summaryParams
    }
}
#endregion

#region File: Log-ObjProperties.ps1
function Log-ObjProperties {
    <#
        .SYNOPSIS
        Structured logging of object properties with depth control, masking, filters, pipeline support,
        and clean summaries that include the Name and counts.

        .NOTES
        Version: 3.2.8
        - Uses Add-LogEntry only; -Icon defaults to 'property' for normal lines.
        - Warnings/Errors/Summary use explicit icons: 'warning', 'error', 'task'.
        - Pipeline input supported (ValueFromPipeline=$true).
        - Auto-name: prefers last member segment from the invocation (e.g., "$net.Adapter" => "Adapter"),
                     then primitive value, then .Name, then TypeName, then "Object".
        - Summary now appends with -AddToBody (no flush inside this function).
        - Counters: Properties (leaf "name : value" lines) and Entries (array items).
        - Recursion uses & $MyInvocation.MyCommand.Name so renaming the function is safe.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowNull()]
        [Object]$InputObject,

        [int]$MaxDepth = 3,
        [switch]$Detailed,

        # Default icon for normal/property lines
        [string]$Icon = 'property',

        # ----- Display options -----
        [switch]$ShowTypes,
        [int]$TruncateLength = 0,

        # ----- Masking -----
        [string[]]$MaskKeyTerms = @('password', 'secret', 'token', 'apikey', 'key', 'credential'),
        [string]$MaskWith = '***',

        # ----- Property filters -----
        [string[]]$Include,
        [string[]]$Exclude,

        # Root display name (auto-derived if not provided)
        [string]$Name = '',

        # External control (accepted to avoid parameter errors; this function never flushes)
        [switch]$AddToBody,

        # ----- Internal (do not set) -----
        [int]$Depth = 0,
        [System.Collections.Generic.HashSet[string]]$VisitedIds = $(New-Object 'System.Collections.Generic.HashSet[string]'),
        [string[]]$Path = @(),
        [hashtable]$Counters,
        [string]$RootName = '',
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )
    begin {

        $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
        $summaryParams = $logParams.Summary
        $detailsParams = $logParams.Details


        try {
            if (-not $VisitedIds) {
                $VisitedIds = New-Object 'System.Collections.Generic.HashSet[string]'
            }

            function New-Indent([int]$d) { '-' * $d }

            function Should-MaskKey([string]$name, [string[]]$terms) {
                if ([string]::IsNullOrEmpty($name)) { return $false }
                $lname = $name.ToLowerInvariant()
                foreach ($t in $terms) {
                    if ([string]::IsNullOrEmpty($t)) { continue }
                    $lt = $t.ToLowerInvariant()
                    if ($lname -eq $lt -or $lname.Contains($lt)) { return $true }
                }
                return $false
            }

            function Format-Value {
                param(
                    [AllowNull()][object]$Value,
                    [switch]$ShowTypes,
                    [int]$TruncateLength = 0,
                    [string]$MaskWith = '***',
                    [switch]$Mask
                )
                if ($Mask) { return $MaskWith }
                if ($null -eq $Value) { return '[null]' }

                if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
                    $typeName = $Value.GetType().FullName
                    $count = @($Value).Count
                    if ($ShowTypes) { return "[${typeName}] ($count items)" }
                    return "($count items)"
                }

                $text = [string]$Value
                if ($TruncateLength -gt 0 -and $text.Length -gt $TruncateLength) {
                    $text = $text.Substring(0, $TruncateLength) + '…'
                }
                if ($ShowTypes) {
                    $typeName = $Value.GetType().FullName
                    return "[$typeName] $text"
                }
                return $text
            }

            function Get-ObjId([object]$o) {
                try {
                    if ($null -eq $o) { return 'null' }
                    $id = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($o)
                    "$($o.GetType().FullName):$id"
                }
                catch {
                    [Guid]::NewGuid().ToString()
                }
            }

            # Auto-name from invocation line (root only, best-effort)
            if ($Depth -eq 0 -and [string]::IsNullOrWhiteSpace($Name)) {
                try {
                    $line = $MyInvocation.Line
                    $expr = $null

                    if ($line) {
                        # Direct positional or -InputObject
                        if ($line -match '(?i)\bLog-ObjProperties\S*\s+(?:-InputObject\s+)?(?<expr>[^\s-][^\s]*)') {
                            $expr = $Matches['expr'].Trim()
                        }
                        # Pipeline: "<expr> | Log-ObjProperties"
                        if (-not $expr -and ($line -match '^\s*(?<expr>.+?)\s*\|\s*Log-ObjProperties\S*\b')) {
                            $expr = $Matches['expr'].Trim()
                        }
                        if ($expr) {
                            if ($expr.StartsWith('$')) { $expr = $expr.Substring(1) }
                            # Prefer last member segment
                            $last = $expr
                            if ($expr -match '\.') {
                                $parts = $expr -split '\.'
                                $last = $parts[-1]
                            }
                            # Strip trailing "()"
                            $last = $last -replace '\(\)$', ''
                            # Remove indexers [0], ['Key'], ["Key"]
                            $last = $last -replace '\[\s*\d+\s*\]', ''
                            $last = $last -replace "\[\s*'([^']+)'\s*\]", '$1'
                            $last = $last -replace '\[\s*"([^"]+)"\s*\]', '$1'

                            if (-not [string]::IsNullOrWhiteSpace($last)) {
                                $Name = $last
                            }
                            else {
                                $Name = $expr
                            }
                        }
                    }
                }
                catch {
                    # ignore; will derive in process from InputObject
                }
            }
        }
        catch {
            Add-LogEntry -Message "Log-ObjProperties error1: $($_.Exception.Message)" -Icon 'error' @detailsParams
        }
    }

    process {
        try {
            $indent = New-Indent -d $Depth

            # Derive Name from actual InputObject at root if still empty
            if ($Depth -eq 0 -and [string]::IsNullOrWhiteSpace($Name)) {
                try {
                    # Primitive/string → use value itself
                    $isPrimitive = $false
                    if ($null -ne $InputObject) {
                        $t = $InputObject.GetType()
                        $isPrimitive = $t.IsPrimitive -or
                        ($InputObject -is [string]) -or
                        ($InputObject -is [decimal]) -or
                        ($InputObject -is [datetime]) -or
                        ($InputObject -is [guid])
                    }
                    if ($isPrimitive) {
                        $Name = [string]$InputObject
                    }

                    # Object .Name fallback
                    if ([string]::IsNullOrWhiteSpace($Name) -and $InputObject -and ($InputObject | Get-Member -Name Name -ErrorAction SilentlyContinue)) {
                        $Name = [string]$InputObject.Name
                    }

                    # Type / final fallback
                    if ([string]::IsNullOrWhiteSpace($Name)) {
                        try { $Name = $InputObject.GetType().Name } catch { $Name = 'Object' }
                    }
                    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'Object' }
                }
                catch {
                    $Name = 'Object'
                }
            }

            # Ensure internal state exists even if caller manually sets -Depth
            if (-not $Counters) { $Counters = @{ Properties = 0; Entries = 0 } }
            if ([string]::IsNullOrWhiteSpace($RootName)) {
                $RootName = if ([string]::IsNullOrWhiteSpace($Name)) { 'Object' } else { $Name }
            }

            # Initialize root-only helpers
            if ($Depth -eq 0) {
                if (-not $Counters) { $Counters = @{ Properties = 0; Entries = 0 } }
                if ([string]::IsNullOrWhiteSpace($RootName)) { $RootName = $Name }
            }

            if ($null -eq $InputObject) {
                Add-LogEntry -Message "${indent}Invalid or empty input." -Icon 'error' @detailsParams
                if ($Depth -eq 0) {
                    Add-LogEntry -Message "${indent}${RootName}: 0 properties listed." -Icon 'task' -Subject $RootName @detailsParams
                }
                return
            }

            # Root heading
            if ($Depth -eq 0 -and [string]::IsNullOrWhiteSpace($Name) -eq $false) {
                Add-LogEntry -Message "${indent}$Name" -Icon $Icon @detailsParams
            }

            # Cycle protection
            $objId = Get-ObjId -o $InputObject
            if ($VisitedIds.Contains($objId)) {
                Add-LogEntry -Message "${indent}[cycle detected] already visited: $objId" -Icon 'warning' @detailsParams
                return
            }
            else {
                $VisitedIds.Add($objId) | Out-Null
            }

            # Depth guard
            if ($Depth -ge $MaxDepth) {
                Add-LogEntry -Message "${indent}Max object depth ($MaxDepth) reached." -Icon 'warning' @detailsParams
                return
            }

            # Arrays / IEnumerable (non-string)
            if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
                $array = @($InputObject)
                if ($array.Count -eq 0) {
                    Add-LogEntry -Message "${indent}Array is empty." -Icon 'warning' @detailsParams
                    if ($Depth -eq 0) {
                        Add-LogEntry -Message "${indent}${RootName}: 0 entries; 0 properties listed." -Icon 'task' -Subject $RootName @detailsParams
                    }
                    return
                }

                $index = 0
                foreach ($item in $array) {
                    $index++
                    $Counters['Entries']++
                    Add-LogEntry -Message "${indent}#${index} ━━━━━━━━━━━━━━━" -Icon $Icon @detailsParams
                    & $MyInvocation.MyCommand.Name -InputObject $item -Detailed:$Detailed -Icon $Icon -MaxDepth $MaxDepth -ShowTypes:$ShowTypes -TruncateLength $TruncateLength -MaskKeyTerms $MaskKeyTerms -MaskWith $MaskWith -Include $Include -Exclude $Exclude -Name '' -Depth ($Depth + 1) -VisitedIds $VisitedIds -Path ($Path + "#$index") -Counters $Counters -RootName $RootName
                }

                if ($Depth -eq 0) {
                    Add-LogEntry -Message "${indent}${RootName}: $($Counters['Entries']) entries; $($Counters['Properties']) properties listed." -Icon 'task' -Subject $RootName @detailsParams
                }
                return
            }

            # Hashtable / IDictionary
            if ($InputObject -is [System.Collections.IDictionary]) {
                foreach ($key in $InputObject.Keys) {
                    $propName = [string]$key
                    $propValue = $InputObject[$key]

                    if ($Include -and ($Include -notcontains $propName)) { continue }
                    if ($Exclude -and ($Exclude -contains $propName)) { continue }

                    $mask = Should-MaskKey -name $propName -terms $MaskKeyTerms

                    if ($Detailed -and (($propValue -is [PSObject]) -or ($propValue -is [System.Collections.IDictionary]) -or (($propValue -is [System.Collections.IEnumerable]) -and -not ($propValue -is [string])))) {
                        Add-LogEntry -Message "${indent}$propName" -Icon $Icon @detailsParams
                        & $MyInvocation.MyCommand.Name -InputObject $propValue -Detailed:$Detailed -Icon $Icon -MaxDepth $MaxDepth -ShowTypes:$ShowTypes -TruncateLength $TruncateLength -MaskKeyTerms $MaskKeyTerms -MaskWith $MaskWith -Include $Include -Exclude $Exclude -Name '' -Depth ($Depth + 1) -VisitedIds $VisitedIds -Path ($Path + $propName) -Counters $Counters -RootName $RootName
                    }
                    else {
                        $formatted = Format-Value -Value $propValue -ShowTypes:$ShowTypes -TruncateLength $TruncateLength -Mask:$mask -MaskWith $MaskWith
                        Add-LogEntry -Message "${indent}$propName : $formatted" -Icon $Icon @detailsParams
                        $Counters['Properties']++
                    }
                }

                if ($Depth -eq 0) {
                    Add-LogEntry -Message "${indent}${RootName}: $($Counters['Properties']) properties listed." -Icon 'task' -Subject $RootName @detailsParams
                }
                return
            }

            # PSCustomObject / general PSObject
            foreach ($property in $InputObject.PSObject.Properties) {
                $propName = $property.Name
                $propValue = $property.Value

                if ($Include -and ($Include -notcontains $propName)) { continue }
                if ($Exclude -and ($Exclude -contains $propName)) { continue }

                $mask = Should-MaskKey -name $propName -terms $MaskKeyTerms
                $isArray = ($propValue -is [System.Collections.IEnumerable] -and -not ($propValue -is [string]))

                if ($Detailed -and ($propValue -is [PSObject])) {
                    Add-LogEntry -Message "${indent}$propName" -Icon $Icon @detailsParams
                    & $MyInvocation.MyCommand.Name -InputObject $propValue -Detailed:$Detailed -Icon $Icon -MaxDepth $MaxDepth -ShowTypes:$ShowTypes -TruncateLength $TruncateLength -MaskKeyTerms $MaskKeyTerms -MaskWith $MaskWith -Include $Include -Exclude $Exclude -Name '' -Depth ($Depth + 1) -VisitedIds $VisitedIds -Path ($Path + $propName) -Counters $Counters -RootName $RootName
                }
                elseif ($Detailed -and $isArray) {
                    Add-LogEntry -Message "${indent}$propName (Array)" -Icon $Icon @detailsParams
                    $i = 0
                    foreach ($item in $propValue) {
                        Add-LogEntry -Message "${indent}  [$i]" -Icon $Icon @detailsParams
                        $Counters['Entries']++
                        & $MyInvocation.MyCommand.Name -InputObject $item -Detailed:$Detailed -Icon $Icon -MaxDepth $MaxDepth -ShowTypes:$ShowTypes -TruncateLength $TruncateLength -MaskKeyTerms $MaskKeyTerms -MaskWith $MaskWith -Include $Include -Exclude $Exclude -Name '' -Depth ($Depth + 1) -VisitedIds $VisitedIds -Path ($Path + $propName + "[$i]") -Counters $Counters -RootName $RootName
                        $i++
                    }
                }
                else {
                    $formatted = Format-Value -Value $propValue -ShowTypes:$ShowTypes -TruncateLength $TruncateLength -Mask:$mask -MaskWith $MaskWith
                    Add-LogEntry -Message "${indent}$propName : $formatted" -Icon $Icon @detailsParams
                    $Counters['Properties']++
                }
            }

            if ($Depth -eq 0) {
                #Add-LogEntry -Message "${indent}${RootName}: $($Counters['Properties']) properties listed." -Icon 'task' -Subject $RootName @summaryParams
            }
            Add-LogEntry -Message "${indent}${RootName}: $($Counters['Properties']) properties listed." -Icon 'task' -Subject $RootName @summaryParams

        }
        catch {
            Add-LogEntry -Message "Log-ObjProperties error2: $($_.Exception.Message)" -Icon 'error' @summaryParams
            if ($Depth -eq 0) {
                Add-LogEntry -Message "Object listing aborted due to errors." -Icon 'error' -Subject $RootName @summaryParams
            }
        }
    }
}
#endregion

#region File: Manage-Service.ps1
function Manage-Service {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [string]$ServiceName = "MDLCSvc",

        [ValidateSet('Start', 'Stop', 'Restart', 'Delete')]
        [string]$Action = $null,

        [ValidateSet('Automatic', 'Manual', 'Disabled')]
        [string]$StartupType = $null,

        [switch]$ShowStatus,

        [switch]$ErrorOnFailure,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    if (-not (Assert-IsAdmin @summaryParams)) { return }


    Log-Invocation -IncludeParameters @detailsParams 

    # Result object
    $result = [pscustomobject]@{
        Success     = $false
        Action      = $Action
        ServiceName = $ServiceName
        Status      = $null
        StartupType = $null
        Message     = $null
    }

    # Track whether we emitted any intermediate logs (-AddToBody)
    $loggedIntermediate = $false

    try {
        if (-not $ServiceName) {
            $result.Message = "No service name specified."
            # One final line only
            Add-LogEntry -Message "Outcome for '$ServiceName': $($result.Message)" -Icon 'error' @summaryParams
            if ($ErrorOnFailure) {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    ([System.Exception]$result.Message),
                    "ManageService.NoServiceName",
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $ServiceName
                )
                $PSCmdlet.ThrowTerminatingError($err)
            }
            return $result
        }

        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $service -and $Action -ne 'Delete') {
            $result.Message = "Service '$ServiceName' not found."
            # One final line only
            Add-LogEntry -Message "Outcome for '$ServiceName': $($result.Message)" -Icon 'error' @summaryParams
            if ($ErrorOnFailure) {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    ([System.Exception]$result.Message),
                    "ManageService.NotFound",
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $ServiceName
                )
                $PSCmdlet.ThrowTerminatingError($err)
            }
            return $result
        }

        # Capture original state
        $originalStatus = if ($service) { $service.Status } else { 'Unknown' }
        $originalStartMode = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty StartMode)
        if (-not $originalStartMode) { $originalStartMode = "Unknown" }

        if ($ShowStatus) {
            Add-LogEntry -Message "Service '$ServiceName' Current Status: $originalStatus, StartupType: $originalStartMode" -Icon 'info' @detailsParams
            $loggedIntermediate = $true
        }

        $finalStatus = $originalStatus
        $finalStartMode = $originalStartMode
        $actionPerformed = $Action

        if ($Action) {
            switch ($Action) {
                'Start' {
                    if ($service.Status -ne 'Running') {
                        try {
                            Start-Service -Name $ServiceName -ErrorAction Stop
                            $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                            $finalStatus = $service.Status
                            $result.Success = $true
                            $result.Message = "Started."
                            # Minimal: no intermediate “started successfully” line; rely on final line
                        }
                        catch {
                            $finalStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
                            $result.Message = "Failed to start: $($_.Exception.Message)"
                            # Minimal: no intermediate error line; rely on final line
                        }
                    }
                    else {
                        $result.Success = $true
                        $result.Message = "Already running."
                        # Minimal: no intermediate info line
                    }
                }
                'Stop' {
                    if ($service.Status -eq 'Running') {
                        try {
                            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                            $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                            $finalStatus = $service.Status
                            $result.Success = $true
                            $result.Message = "Stopped."
                        }
                        catch {
                            $finalStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
                            $result.Message = "Failed to stop: $($_.Exception.Message)"
                        }
                    }
                    else {
                        $result.Success = $true
                        $result.Message = "Already stopped."
                    }
                }
                'Restart' {
                    try {
                        if ($service.Status -eq 'Running') {
                            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                            if ($PSBoundParameters.Verbose) {
                                Add-LogEntry -Message "Service '$ServiceName' stopped for restart." -Icon 'info' @detailsParams
                                $loggedIntermediate = $true
                            }
                        }
                        Start-Service -Name $ServiceName -ErrorAction Stop
                        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                        $finalStatus = $service.Status
                        $result.Success = $true
                        $result.Message = "Restarted."
                    }
                    catch {
                        $finalStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
                        $result.Message = "Failed to restart: $($_.Exception.Message)"
                    }
                }
                'Delete' {
                    if ($service -and $service.Status -eq 'Running') {
                        try {
                            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                            if ($PSBoundParameters.Verbose) {
                                Add-LogEntry -Message "Service '$ServiceName' stopped before deletion." -Icon 'info' @detailsParams
                                $loggedIntermediate = $true
                            }
                        }
                        catch {
                            $result.Message = "Failed to stop before deletion: $($_.Exception.Message)"
                            $result.Status = $finalStatus
                            $result.StartupType = $finalStartMode
                            # Final line only
                            Add-LogEntry -Message "Outcome for '$ServiceName': $($result.Message)" -Icon 'error' @summaryParams
                            if ($ErrorOnFailure) {
                                $err = [System.Management.Automation.ErrorRecord]::new(
                                    ([System.Exception]$result.Message),
                                    "ManageService.StopBeforeDeleteFailed",
                                    [System.Management.Automation.ErrorCategory]::OperationStopped,
                                    $ServiceName
                                )
                                $PSCmdlet.ThrowTerminatingError($err)
                            }
                            return $result
                        }
                    }
                    try {
                        $deleteResult = sc.exe delete $ServiceName 2>&1
                        if ($deleteResult -match "SUCCESS") {
                            $finalStatus = "Deleted"
                            $finalStartMode = "N/A"
                            $result.Success = $true
                            $result.Message = "Deleted."
                        }
                        else {
                            $result.Message = "Failed to delete: $deleteResult"
                        }
                    }
                    catch {
                        $result.Message = "Exception during delete: $($_.Exception.Message)"
                    }
                }
            }
        }

        if ($StartupType -and $Action -ne 'Delete') {
            try {
                Set-Service -Name $ServiceName -StartupType $StartupType -ErrorAction Stop
                $finalStartMode = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty StartMode)
                if (-not $finalStartMode) { $finalStartMode = "Unknown" }
                if ($PSBoundParameters.Verbose) {
                    Add-LogEntry -Message "StartupType changed: $originalStartMode → $finalStartMode" -Icon 'settings' @detailsParams
                    $loggedIntermediate = $true
                }
            }
            catch {
                if ($PSBoundParameters.Verbose) {
                    Add-LogEntry -Message "Failed to set StartupType: $($_.Exception.Message)" -Icon 'error' @detailsParams
                    $loggedIntermediate = $true
                }
                if (-not $result.Message) { $result.Message = "Failed to set StartupType: $($_.Exception.Message)" }
                # Do not flip Success to false if primary action succeeded.
            }
        }

        # Populate result
        $result.Status = $finalStatus
        $result.StartupType = $finalStartMode

        # Final output line (exactly one)
        if ($loggedIntermediate) {
            # We printed intermediates; finish with a single summary line.
            Add-LogEntry -Message "Summary for '$ServiceName': Action=$actionPerformed, Final Status=$finalStatus, StartupType=$finalStartMode, Success=$($result.Success)" -Icon 'summary' @summaryParams
        }
        else {
            # No intermediate lines; print only the outcome (no summary).
            # Outcome text summarizes without repeating earlier lines.
            Add-LogEntry -Message "Outcome for '$ServiceName': Action=$actionPerformed, Status=$finalStatus, StartupType=$finalStartMode, Result=$($result.Message), Success=$($result.Success)" -Icon 'summary' @summaryParams
        }

        # Throw if requested and action failed
        if ($ErrorOnFailure -and -not $result.Success) {
            $err = [System.Management.Automation.ErrorRecord]::new(
                ([System.Exception]$result.Message),
                "ManageService.ActionFailed",
                [System.Management.Automation.ErrorCategory]::OperationStopped,
                $ServiceName
            )
            $PSCmdlet.ThrowTerminatingError($err)
        }
    }
    catch {
        $result.Message = "Unexpected error managing service '$ServiceName': $($_.Exception.Message)"
        $result.Status = $null
        $result.StartupType = $null

        # Final line only
        Add-LogEntry -Message "Outcome for '$ServiceName': $($result.Message)" -Icon 'error' @summaryParams

        if ($ErrorOnFailure) {
            $err = [System.Management.Automation.ErrorRecord]::new(
                ([System.Exception]$result.Message),
                "ManageService.UnexpectedError",
                [System.Management.Automation.ErrorCategory]::NotSpecified,
                $ServiceName
            )
            $PSCmdlet.ThrowTerminatingError($err)
        }
    }

    return $result
}
#endregion

#region File: Manage-StoreApp.ps1
function Manage-StoreApp {
    [CmdletBinding()]
    param (
        [string]$AppName,
        [string]$AppID,
        [switch]$Install,
        [switch]$Update,
        [switch]$Uninstall,
        [switch]$AddToBody
    )

    # Winget special exit code for 'already installed/up-to-date'
    [int64]$alreadyInstalledCode = -1978335189

    # Ensure winget is present/up-to-date first; minimal output handled inside Install-UpdateWinget
    $wingetResult = $null
    try { $wingetResult = Install-UpdateWinget -AddToBody:$AddToBody } catch { }
    $wingetPath = if ($wingetResult) { $wingetResult.WingetPath } else { $null }

    if (-not $wingetPath) {
        Add-LogEntry -Message "Set-StoreApp: winget unavailable after remediation. Aborting." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
        return
    }
    #write-host appname1: $appName
    try {
        # Resolve app ID/name from Microsoft Store
        $resolvedName = $null
        $appId = $null

        if ($AppID) {
            # Verify AppID exists and get display name
            $showResult = & "$wingetPath" show --id "$AppID" --source=msstore --accept-source-agreements 2>&1
            $retrievedAppName = $null
            foreach ($line in $showResult) {
                if ($line -match "Found\s+(.+)\s+\[\S+\]") { $retrievedAppName = $matches[1].Trim(); break }
            }

            if (-not $retrievedAppName) {
                Add-LogEntry -Message "Set-StoreApp: App ID '$AppID' not found in Microsoft Store." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }
            #write-host appname2: $appName

            if ($AppName -and ($AppName.ToLower() -ne $retrievedAppName.ToLower())) {
                Add-LogEntry -Message "Set-StoreApp: Provided name '$AppName' does not match resolved '$retrievedAppName' for ID '$AppID'." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            $resolvedName = $retrievedAppName
            $appId = $AppID
        }
        else {
            #write-host appname3: $appName

            if (-not $AppName) {
                Add-LogEntry -Message "Set-StoreApp: No AppName or AppID provided." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            # Search Microsoft Store by name
            $searchResult = & "$wingetPath" search -q "$AppName" --source=msstore --accept-source-agreements 2>&1
            #write-host searchResult $searchResult
            # Parse results into Name/ID pairs
            $found = @()
            foreach ($line in $searchResult) {
                if ($line -match "^\s*(.+?)\s+(\S+)\s+\S+") {
                    $nameCandidate = $matches[1].Trim()
                    $idCandidate = $matches[2].Trim()
                    if ($nameCandidate -and $idCandidate -and ($idCandidate -ne 'Id') -and ($nameCandidate -ne 'Name')) {
                        $found += [PSCustomObject]@{ Name = $nameCandidate; Id = $idCandidate }
                    }
                }
            }

            if ($found.Count -eq 0) {
                Add-LogEntry -Message "Set-StoreApp: App ID for '$AppName' not found in Microsoft Store search results." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            if ($found.Count -gt 1) {
                # List matches so the tech can choose the exact AppID, then return
                Add-LogEntry -Message "Multiple matches for '$AppName' found in Microsoft Store:" -Icon 'info' -AddToBody
                foreach ($item in $found) {
                    Add-LogEntry -Message ("  Name='{0}'  ID='{1}'" -f $item.Name, $item.Id) -Icon 'id' -AddToBody
                }
                Add-LogEntry -Message "Set-StoreApp: multiple matches found; rerun with -AppID." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            # Single match → use it
            $resolvedName = $found[0].Name
            $appId = $found[0].Id
        }

        # Execute requested actions: Uninstall -> Install -> Update
        $results = @()

        if ($Uninstall) {
            try {
                & "$wingetPath" uninstall --id "$appId" --source=msstore 2>&1 | Out-Null
                [int64]$code = $LastExitCode
                if ($code -eq 0 -or $code -eq $alreadyInstalledCode) { $results += "Uninstall=Success" }
                else { $results += "Uninstall=Fail($code)" }
            }
            catch {
                $results += "Uninstall=Exception($($_.Exception.Message))"
            }
        }

        if ($Install) {
            try {
                & "$wingetPath" install -e -i --id "$appId" --source=msstore --accept-package-agreements 2>&1 | Out-Null
                [int64]$code = $LastExitCode
                if ($code -eq 0 -or $code -eq $alreadyInstalledCode) {
                    if ($code -eq $alreadyInstalledCode) { $results += "Install=UpToDate" } else { $results += "Install=Success" }
                }
                else { $results += "Install=Fail($code)" }
            }
            catch {
                $results += "Install=Exception($($_.Exception.Message))"
            }
        }

        if ($Update) {
            try {
                & "$wingetPath" upgrade --id "$appId" --source=msstore --accept-package-agreements 2>&1 | Out-Null
                [int64]$code = $LastExitCode
                if ($code -eq 0 -or $code -eq $alreadyInstalledCode) {
                    if ($code -eq $alreadyInstalledCode) { $results += "Update=UpToDate" } else { $results += "Update=Success" }
                }
                else { $results += "Update=Fail($code)" }
            }
            catch {
                $results += "Update=Exception($($_.Exception.Message))"
            }
        }

        # Final minimal summary line
        $actionsSummary = if ($results.Count -gt 0) { $results -join '; ' } else { "NoActionsRequested" }
        Add-LogEntry -Message "Set-StoreApp: Name='$resolvedName' ID='$appId' [$actionsSummary]" -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
    }
    catch {
        Add-LogEntry -Message "Set-StoreApp: Unhandled exception: $($_.Exception.Message)" -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
    }
}
#endregion

#region File: MarkExecuted.ps1
MarkExecuted([bool] $success, [string] $output) {
        $this.Executed = $true
        $this.Success = $success
        $this.ExecutionOutput = $output
        $this.ExecutionTimestamp = Get-Date
    }
#endregion

#region File: New-DrAsset.ps1
function New-DrAsset {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][hashtable]$AssetData,
        [switch]$DebugOutput
    )

    try {
        $response = Invoke-DrApiRequest -Method 'POST' -Endpoint '/api/v1/assets' -Body $AssetData -DebugOutput:$DebugOutput
        return $response
    }
    catch {
        Write-Error "Failed to create asset: $_"
    }
}
#endregion

#region File: New-DrCustomer.ps1
function New-DrCustomer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][hashtable]$CustomerData,
        [switch]$DebugOutput
    )

    try {
        $response = Invoke-DrApiRequest -Method 'POST' -Endpoint '/api/v1/customers' -Body $CustomerData -DebugOutput:$DebugOutput
        return $response
    }
    catch {
        Write-Error "Failed to create customer: $_"
    }
}
#endregion

#region File: New-DrDomainUser.ps1
function New-DrDomainUser {
    [CmdletBinding()]
    param(
        [string]$AdminUser,
        [string]$AdminPassword,
        [string]$NewUser,
        [string]$uPassword,
        [string]$FirstName,
        [string]$LastName
    )

    Import-Module ActiveDirectory -ErrorAction Stop

    $domain = Get-ADDomain -Current LocalComputer -ErrorAction Stop
    $domainName = $domain.DNSRoot
    $usersContainer = $domain.UsersContainer

    # Determine UPN suffix dynamically (no client hardcoding)
    # Order:
    # 1) If AdminUser is UPN form (user@suffix) => use that suffix
    # 2) Else read Admin user's UserPrincipalName from AD and use its suffix
    # 3) Else use first alternative forest UPN suffix (if any)
    # 4) Else fall back to domain DNS root
    $upnSuffix = $domainName

    if ($AdminUser -match '@(.+)$') {
        $upnSuffix = $Matches[1]
    }
    else {
        $adminSam = ($AdminUser -split '\\')[-1]

        try {
            $adminUpn = (Get-ADUser -Identity $adminSam -Properties UserPrincipalName -ErrorAction Stop).UserPrincipalName
            if ($adminUpn -and ($adminUpn -match '@(.+)$')) {
                $upnSuffix = $Matches[1]
            }
        }
        catch {
            # ignore; fall back to forest/domain below
        }

        if ($upnSuffix -eq $domainName) {
            try {
                $forest = Get-ADForest -Current LocalComputer -ErrorAction Stop
                $candidate = @($forest.UPNSuffixes) | Where-Object { $_ -and $_ -ne $domainName } | Select-Object -First 1
                if ($candidate) { $upnSuffix = $candidate }
            }
            catch {
                # ignore; keep $domainName
            }
        }
    }

    if ($uPassword -eq '*Generate') {
        try {
            $plainPassword = new-drpassword 
        }
        finally {
            $rng.Dispose()
        }
    }
    else {
        $plainPassword = $uPassword
    }

    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force

    $displayName = "$FirstName $LastName".Trim()
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $NewUser }

    $newUserParams = @{
        Name                  = $displayName
        GivenName             = $FirstName
        Surname               = $LastName
        DisplayName           = $displayName
        SamAccountName        = $NewUser
        UserPrincipalName     = "$NewUser@$upnSuffix"
        Path                  = $usersContainer
        AccountPassword       = $securePassword
        Enabled               = $true
        ChangePasswordAtLogon = $true
        ErrorAction           = 'Stop'
    }

    New-ADUser @newUserParams

    [pscustomobject]@{
        DomainUser = "$($domain.NetBIOSName)\$NewUser"
        TempPass   = $plainPassword
        Container  = $usersContainer
        Domain     = $domainName
    }
}
#endregion

#region File: New-DrPassword.ps1
function New-DrPassword {
    [CmdletBinding()]
    param()

    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%&*'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $bytes = New-Object byte[] 16
        $rng.GetBytes($bytes)
        return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    }
    finally {
        $rng.Dispose()
    }
}
#endregion

#region File: New-ExportModuleExportArray.ps1
function New-ExportModuleExportArray {
    [CmdletBinding()]
    param([string]$Psm1Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Psm1Path, [ref]$tokens, [ref]$errors)

    $functions = $ast.FindAll(
        { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    ).Name |
    Where-Object { $_ -and ($_ -notmatch '^_') } |
    Sort-Object -Unique

    return , $functions  # ensure array even if single item
}
#endregion

#region File: New-Indent.ps1
function New-Indent([int]$d) { '-' * $d }
#endregion

#region File: New-LogFile.ps1
function New-LogFile {
    [CmdletBinding()]
    param(
        [ValidateSet('Unique', 'Append', 'Daily')]
        [string]$Mode = 'Append',
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    try {
        $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
        $detailsParams = $logParams.Details
        $summaryParams = $logParams.Summary

        # Ensure log directory exists
        $logDir = $Global:DrLogs
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }

        # Use JobId or fallback to 'Session'
        $sessionId = if ($Global:JobId) { $Global:JobId } else { 'Session' }

        # Determine filename based on mode
        switch ($Mode) {
            'Unique' {
                # Session ID + timestamp for uniqueness
                $fileName = "{0}_{1}.txt" -f $sessionId, (Get-Date -Format 'yyyyMMdd_HHmmss')
            }
            'Daily' {
                # Session ID + date for daily logs
                $fileName = "{0}_{1}.txt" -f $sessionId, (Get-Date -Format 'yyyyMMdd')
            }
            'Append' {
                # Single file for entire session
                $fileName = "{0}.txt" -f $sessionId
            }
        }

        $logFilePath = Join-Path $logDir $fileName

        # Create file if it doesn't exist
        if (-not (Test-Path $logFilePath)) {
            New-Item -Path $logFilePath -ItemType File -Force | Out-Null
        }
        add-logentry -Message "Log file created: $logFilePath" -Icon 'logfile' @summaryParams

        return $logFilePath
    }
    catch {
        Add-LogEntry -Message "Failed to create log file: $($_.Exception.Message)" -Icon 'Error' @summaryParams
        return $null
    }
}
#endregion

#region File: New-RandomPassword.ps1
function New-RandomPassword {
    param(
        [int]$Length = 12
    )

    if ($Length -lt 8) { throw "Length must be >= 8." }

    $lower = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $digits = '0123456789'.ToCharArray()
    $special = '!@#$%^&*()'.ToCharArray()

    # Guarantee complexity (one from each set)
    $chars = @(
        (Get-Random -InputObject $lower),
        (Get-Random -InputObject $upper),
        (Get-Random -InputObject $digits),
        (Get-Random -InputObject $special)
    )

    $all = $lower + $upper + $digits + $special

    1..($Length - $chars.Count) | ForEach-Object {
        $chars += Get-Random -InputObject $all
    }

    -join ($chars | Sort-Object { Get-Random })
}
#endregion

#region File: New-RandomPassword1.ps1
function New-RandomPassword1 {
    $length = 12
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()"
    $password = -join ((1..$length) | ForEach-Object { $chars | Get-Random })
    return $password
}
#endregion

#region File: New-Ticket.ps1
function New-Ticket {
    param (
        [string]$Subject = "No subject given.",
        [string]$IssueType = 'Automation',
        [string]$TicketBody = "Created via PowerShell",
        [string]$Status = "New",
        [string]$Priority = "Normal",
        [string]$Tech = "Automation",
        [string[]]$Tags = @($Tech, "PowerShell")
    )

    if (-not $Global:DrCustomerId) {
        Write-Error "$Global:DrCustomerId is not set. Cannot create ticket."
        return
    }

    $body = @{
        subject             = $Subject
        problem_type        = $IssueType
        customer_id         = $Global:DrCustomerId
        status              = $Status
        ticket_body         = $TicketBody
        asset_ids           = @($Global:DrAssetid)
        priority            = $Priority
        tag_list            = $Tags
        comments_attributes = @(
            @{
                subject       = "Initial Issue"
                body          = $TicketBody
                hidden        = $false
                do_not_email  = $true
                tech          = $Tech
                display_order = '1'
            }
        )
    }

    try {
        $response = Invoke-DrApiRequest `
            -Method 'POST' `
            -Endpoint '/api/v1/tickets' `
            -Body $body

        $ticket = if ($response.ticket) { $response.ticket } else { $response }

        #$null = Add-LogEntry "Ticket created successfully. ID: $($ticket.id)"
        return $ticket
    }
    catch {
        Write-Error "Failed to create ticket: $_"
    }
}
#endregion

#region File: Open-Ticket.ps1
function Open-Ticket {
    <#
        .SYNOPSIS
        Create a Syncro **device** ticket (UUID-based) via Invoke-DrApiRequest and perform local setup.

        .DESCRIPTION
        - Uses Initialize-Environment-provided variables (e.g., $UUID).
        - Switches from account endpoint (/api/v1/tickets) to device endpoint (/api/syncro_device/tickets).
        - Sends uuid, subject, problem_type, and status per device endpoint expectations.
        - Maintains your logging conventions and globals.

        .NOTES
        Version: 1.1.5
    #>
    param (
        [string]$Subject = "No subject given.",
        [string]$IssueType = 'Automtion',
        [string]$TicketBody = 'Created via PowerShell',
        [string]$Status = 'New',
        [string]$Priority = 'Normal',
        [string[]]$Tags = @('PowerShell', '$Global:DrModuleVersion'),
        [string[]]$Buffer = 'Open-Ticket',
        [switch]$FlushBuffer

    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    # Validation (no Mandatory)
    try {
        if ([string]::IsNullOrWhiteSpace($Subject)) { throw 'Subject is required.' }
        if ([string]::IsNullOrWhiteSpace($IssueType)) { throw 'IssueType is required.' }
        if (-not $UUID) { throw 'UUID is not set. Run Initialize-Environment.' }
    }
    catch {
        $errorOutput = $_.Exception.Message
        #Write-Error $errorOutput
        Add-LogEntry -Message "Open-Ticket validation failed: $errorOutput" -Icon 'Error' @summaryParams
        return
    }


    # Build payload to match device endpoint pattern (uuid-based)
    $data = @{
        uuid                = $UUID
        subject             = $Subject
        problem_type        = $IssueType
        status              = if ($Status) { $Status } else { 'New' }

        # Include these only if your device endpoint supports them; remove if API returns 400
        #ticket_body         = $TicketBody
        priority            = $Priority
        tag_list            = $Tags
        comments_attributes = @(
            @{
                subject      = 'Initial Issue'
                body         = $TicketBody
                hidden       = $false
                do_not_email = $true
                tech         = 'Scripted Automation'
            }
        )
    }

    try {
        #Add-LogEntry -Message 'Submitting device ticket via Invoke-DrApiRequest…' -Icon 'ApiRequest' -AddToBody
        $ticket = New-Ticket @PSBoundParameters

        # Device endpoint (UUID-based)
        #$response = Invoke-DrApiRequest -Method 'POST' -Endpoint '/api/syncro_device/tickets' -Body $data

        # Normalize response shape
        #$ticket = $null
        #$ticket = if ($response.ticket) { $response.ticket } else { $response }
        if (-not $ticket) { throw 'API returned no ticket object.' }
        #$Global:DrResponse = $ticket
        $Global:DrTicketId = $ticket.id
        $Global:DrTicket = $ticket.number
        
        Add-LogEntry -Message ("Ticket created: {0} (ID: {1})" -f $Global:DrTicket, $Global:DrTicketId) -Icon 'TicketCreated' @detailsParams -LogActivity

        # Optional local asset linkage (kept as-is)
        try {
            if ($Global:DrAsset -and $Global:DrAsset.properties -and $Global:DrTicket) {
                $Global:DrAsset.properties.Ticket = $Global:DrTicket
            }
            $Global:DrAsset = Set-AssetTicket 
        }
        catch {
            Add-LogEntry -Message ("Set-AssetTicket failed: {0}" -f $_.Exception.Message) -Icon 'Warning' @detailsParams
        }

        # Paths & folders
        try { Update-JobPathsAfterTicket @detailsParams } catch { Add-LogEntry -Message ("Update-JobPathsAfterTicket failed: {0}" -f $_.Exception.Message) -Icon 'Warning' @detailsParams }
        foreach ($path in @($Global:DrLogs, $Global:DrTemp)) {
            try {
                if ($path -and -not (Test-Path -LiteralPath $path)) {
                    New-Item -Path $path -ItemType Directory -Force | Out-Null
                    Add-LogEntry -Message ("Created ticket folder: {0}" -f $path) -Icon 'FileHandling' @detailsParams
                }
            }
            catch {
                Add-LogEntry -Message ("Failed to ensure folder {0}: {1}" -f $path, $_.Exception.Message) -Icon 'Warning' @detailsParams
            }
        }

        #Write-Output ("Ticket created successfully. ID: {0}" -f $Global:DrTicketId)
        Add-LogEntry -Message ("Open-Ticket completed | Ticket: {0} | Priority: {1} | Status: {2}" -f $Global:DrTicket, $Priority, $Status) -Icon 'Summary' @summaryParams
        return $ticket
    }
    catch {
        $errorOutput = $_.Exception.Message
        #Write-Error ("Failed to create ticket: {0}" -f $errorOutput)
        Add-LogEntry -Message ("Failed to create ticket: {0}" -f $errorOutput) -Icon 'Error' @summaryParams
    }
}
#endregion

#region File: Optimize-Registry.ps1
function Optimize-Registry {
    param (
        [int]$Loop = 1,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details


    for ($i = 1; $i -le $Loop; $i++) {
        Add-LogEntry -Message "Starting Optimize-Registry iteration $i" @detailsParams -Icon 'cleanup'

        # Locate executable
        $exePath = Locate-File -Path $Global:DrToolbox -Name "WiseRegistryCleanerPortable.exe"
        if (-not $exePath) {
            Add-LogEntry -Message "WiseRegistryCleanerPortable.exe not found in $Global:DrToolbox" @detailsParams -Icon 'error'
            return
        }

        $baseFolder = Split-Path $exePath -Parent
        $BackupFolder = Join-Path $baseFolder "Data\WiseRegistryCleanerAPPDATA\Backup"
        Add-LogEntry -Message "📁 Resolved backup folder: $BackupFolder" @detailsParams

        # Run registry cleaner
        $AppArgs = "-a -safe"
        $command = "FindAndRun -wait -file WiseRegistryCleanerPortable.exe -folder `"$Global:DrToolBox`" -appargs `"$AppArgs`""
        Invoke-Expression $command

        # Handle backups
        $DestinationFolder = $Global:DrLogs
        if (Test-Path $BackupFolder) {
            $backupFiles = Get-ChildItem -Path $BackupFolder -Recurse -File
            if ($backupFiles) {
                foreach ($file in $backupFiles) {
                    Add-LogEntry -Message "📄 Backup file: $($file.FullName)" -Icon 'file' @detailsParams

                    $entryCount = Count-RegistryEntries $file.FullName
                    Add-LogEntry -Message "🔢 Number of registry entries: $entryCount" @detailsParams
                }

                if (-not (Test-Path $DestinationFolder)) {
                    New-Item -ItemType Directory -Path $DestinationFolder | Out-Null
                }

                $backupFiles | Move-Item -Destination $DestinationFolder
                Add-LogEntry -Message "Moved backup files to $DestinationFolder" @detailsParams -Icon 'install'
            }
            else {
                Add-LogEntry -Message "📭 No files found in the backup folder" @detailsParams
            }
        }
        else {
            Add-LogEntry -Message "Backup folder does not exist: $BackupFolder" -icon 'alert' @detailsParams
        }

        Add-LogEntry -Message "End of Optimize-Registry iteration $i" -Icon 'ok' @detailsParams
        Add-LogEntry -Message "------------------------" @detailsParams
    }

    Add-LogEntry -Message "End Of Optimize-Registry" -Icon 'jobend' @summaryParams
}
#endregion

#region File: Pause-DrTimer.ps1
function Pause-DrTimer {
    param([string]$Name)
    Load-DrTimers
    $targets = if ($Name -eq "*ALL") { $Global:DrTimers.Keys } else { @($Name) }

    foreach ($t in $targets) {
        if (-not $Global:DrTimers[$t]) { continue }
        $timer = $Global:DrTimers[$t]
        if ($timer.Status -eq 'Running') {
            $timer.Elapsed += (New-TimeSpan -Start ([DateTime]$timer.StartTime) -End (Get-Date)).TotalSeconds
            $timer.Status = 'Paused'
            Add-DrTimerMessage -Name $t -Action 'Pause' -Message "Timer paused."
        }
    }
    Save-DrTimers
}
#endregion

#region File: Process-DumpFile.ps1
function Process-DumpFile {
    param (
        # Optional: a single dump file path to process
        [string]$dumpFilePath,

        # Configurable timeout in seconds (default 300 = 5 minutes)
        [int]$TimeoutSeconds = 300,

        # NEW: Diagnostics level for WinDbg commands
        [ValidateSet('Minimal', 'Standard', 'Deep')]
        [string]$Diagnostics = 'Standard',

        # NEW: Symbol cache path used by .cachepath
        [string]$SymbolCache = 'C:\DrOsdicks\Symbols'
    )

    Add-LogEntry -Message "Start processing dump files." -Icon "jobstart" -AddToBody

    # Build list of files to process
    $filesToProcess = @()

    if ([string]::IsNullOrWhiteSpace($dumpFilePath)) {
        # Use Get-DumpPaths to dynamically retrieve configured paths (may not exist yet)
        $dumpPaths = Get-DumpPaths
        if (-not $dumpPaths -or $dumpPaths.Count -eq 0) {
            Add-LogEntry -Message "No configured dump paths returned from registry." -Icon "warning" -AddToBody
        }

        foreach ($path in $dumpPaths) {
            if (Test-Path -Path $path) {
                if ((Get-Item $path).PSIsContainer) {
                    # Folder: enumerate *.dmp files
                    $filesToProcess += Get-ChildItem -Path $path -Filter *.dmp -ErrorAction SilentlyContinue
                }
                else {
                    # File: add directly
                    $filesToProcess += Get-Item -Path $path -ErrorAction SilentlyContinue
                }
            }
            else {
                # Path configured but missing (e.g., MEMORY.DMP not yet created)
                Add-LogEntry -Message "Configured dump path not found: $path" -Icon "warning" -AddToBody
            }
        }
    }
    else {
        # Process specified dump file
        if (Test-Path -Path $dumpFilePath) {
            $filesToProcess = , (Get-Item -Path $dumpFilePath)
        }
        else {
            Add-LogEntry -Message "Dump file path not found: $dumpFilePath" -Icon "error" -AddToBody
        }
    }

    # Ensure WinDbg is available (SDK; SYSTEM-safe). One check before processing any files.
    $windbgPath = Find-OrInstall-WinDbg -AddToBody
    if (-not $windbgPath) {
        Add-LogEntry -Message "Cannot process dumps: WinDbg not available." -Icon "summary" -AddBody
        return
    }

    # --- Build WinDbg preamble once per run based on diagnostics level ---
    # Quote the cache path for .cachepath inside the -c string
    $cacheQuoted = ('`"{0}`"' -f $SymbolCache)

    switch ($Diagnostics) {
        'Minimal' {
            $dbgCmds = @(
                ".symfix",
                ".cachepath $cacheQuoted",
                ".reload /f",
                "!analyze -v"
            )
        }
        'Standard' {
            $dbgCmds = @(
                ".symfix",
                ".cachepath $cacheQuoted",
                ".reload /f",
                ".ecxr",
                "!lmi nt",
                "!analyze -v",
                "lmtn"
            )
        }
        'Deep' {
            $dbgCmds = @(
                ".symfix",
                ".cachepath $cacheQuoted",
                ".reload /f",
                "!sym noisy",
                ".ecxr",
                "!lmi nt",
                "!thread",
                "!process 0 1",
                "!locks",
                "!irpfind",
                "!drvobj 0 1",
                "kv 2",
                "!vm 1",
                "!poolused 2",
                "!handle 0 3",
                "!analyze -v",
                "lmtn"
            )
        }
    }

    $preamble = ($dbgCmds -join '; ') + ';'

    if ($filesToProcess.Count -eq 0) {
        Add-LogEntry -Message "No dump files to process." -Icon "info" -AddToBody
    }
    else {
        foreach ($file in $filesToProcess) {
            $dumpPath = $file.FullName

            # --- Per-file destination folder under $Global:DrLogs ---
            $nameIsMemory = ($file.Name -ieq 'MEMORY.DMP')
            if ($nameIsMemory) {
                $stamp = (Get-Date).ToString('yyMMdd-HHmm')
                $shortId = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
                $folderId = "dmp_{0}_{1}" -f $stamp, $shortId
            }
            else {
                # Minidumps carry uniqueness in their BaseName
                $folderId = "dmp_{0}" -f $file.BaseName
            }

            $destFolder = Join-Path $Global:DrLogs $folderId
            if (-not (Test-Path -LiteralPath $destFolder)) {
                New-Item -ItemType Directory -Path $destFolder | Out-Null
                Add-LogEntry -Message "Created folder: $destFolder" -Icon "fileaction" -AddToBody
            }

            # -logo output goes into the per-file folder
            $outputPath = Join-Path -Path $destFolder -ChildPath 'output.txt'

            # --- Build command string for -c (change qqd -> q) ---
            $cmds = "$preamble q"

            # For visibility: show the exact string forms
            $windbgCommandLine = "-z `"$dumpPath`" -c `"$cmds`" -logo `"$outputPath`""
            Write-Host "=== WinDbg Launch Diagnostic ==="
            Write-Host ("Debugger path: {0}" -f $windbgPath)
            Write-Host ("Preamble:      {0}" -f $preamble)
            Write-Host ("Dump path:     {0}" -f $dumpPath)
            Write-Host ("Output path:   {0}" -f $outputPath)
            Write-Host ("Full command:  {0} {1}" -f $windbgPath, $windbgCommandLine)
            try {
                $__debugTokens = $windbgCommandLine -split '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)'
                Write-Host "Argument tokens as PowerShell would split:"
                $__debugTokens | ForEach-Object { Write-Host "  -> $_" }
            }
            catch { }
            Write-Host "================================"

            Add-LogEntry -Message ("LAUNCH DEBUG: {0} {1}" -f $windbgPath, $windbgCommandLine) -Icon "logfile" -Hidden
            Add-LogEntry -Message "Processing: $windbgPath $windbgCommandLine" -Icon "process" -AddToBody

            try {
                # SAFER: pass arguments as an array to avoid parsing surprises
                $argList = @(
                    '-z', $dumpPath,
                    '-c', $cmds,
                    '-logo', $outputPath
                )

                $process = Start-Process -FilePath $windbgPath -ArgumentList $argList -NoNewWindow -PassThru

                # Early-exit logic with max timeout
                try {
                    Wait-Process -Id $process.Id -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue
                }
                catch { }

                if ($process.HasExited) {
                    $elapsed = [math]::Round((New-TimeSpan -Start $process.StartTime -End (Get-Date)).TotalSeconds)
                    Add-LogEntry -Message "WinDbg completed in ${elapsed}s." -Icon "success" -AddToBody
                }
                else {
                    Stop-Process -Id $process.Id -Force
                    Add-LogEntry -Message "Timeout reached ($TimeoutSeconds s). WinDbg process terminated." -Icon "timeout" -AddToBody
                }
            }
            catch {
                Add-LogEntry -Message "Failed to start or stop WinDbg process: $($_.Exception.Message)" -Icon "error" -AddToBody
                Add-LogEntry "------------------------" -Icon "endsection" -AddBody
                continue
            }

            # Wait until output file is readable
            $readOk = $false
            while ($true) {
                try {
                    $logContent = [System.IO.File]::ReadAllText($outputPath)
                    Add-LogEntry -Message "Output Log:`n$logContent" -Icon "logfile" -Hidden
                    $readOk = $true
                    break
                }
                catch [System.IO.IOException] {
                    Start-Sleep -Seconds 5
                }
                catch {
                    break
                }
            }

            if (-not $readOk) {
                Add-LogEntry -Message "WinDbg output not readable: $outputPath" -Icon "warning" -AddToBody
                # Do NOT move the DMP if we didn't get readable output
                Add-LogEntry "------------------------" -Icon "endsection" -AddToBody
                continue
            }

            # Parse key fields from the output
            $line = Select-String -Path $outputPath -Pattern "BUGCHECK_CODE:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $bugcheckCode = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "BUGCHECK_STR:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $bugcheckStr = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "PROCESS_NAME:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $processName = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "MODULE_NAME:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $moduleName = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "IMAGE_NAME:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $imageName = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "Probably caused by :" -ErrorAction SilentlyContinue | Select-Object -First 1
            $probCauseLine = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "FAILURE_BUCKET_ID:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $bucketId = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "DEFAULT_BUCKET_ID:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $defaultBucket = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            $line = Select-String -Path $outputPath -Pattern "ANALYSIS_VERSION:" -ErrorAction SilentlyContinue | Select-Object -First 1
            $analysisVer = if ($line) { $line.Line.Split(":", 2)[1].Trim() } else { $null }

            # Stack summary (top 8 frames)
            $stackLines = Select-String -Path $outputPath -Pattern "^STACK_TEXT:$" -Context 0, 20 -ErrorAction SilentlyContinue
            $stackSummary = $null
            if ($stackLines) {
                $stackSummary = ($stackLines.Context.Post | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -First 8) -join "`n"
            }

            # Track whether we got any results at all
            $gotAny = $false

            # Log extracted info (compact)
            if ($bugcheckCode -or $bugcheckStr) { Add-LogEntry -Message ("Bugcheck: {0} ({1})" -f $bugcheckCode, $bugcheckStr) -Icon "bugcheck" -AddToBody; $gotAny = $true }
            if ($probCauseLine) { Add-LogEntry -Message ("Probable cause: {0}" -f $probCauseLine) -Icon "compare" -AddToBody; $gotAny = $true }
            if ($moduleName -or $imageName) { Add-LogEntry -Message ("Module/Image: {0} / {1}" -f $moduleName, $imageName) -Icon "filehandling" -AddToBody; $gotAny = $true }
            if ($processName) { Add-LogEntry -Message ("Process: {0}" -f $processName) -Icon "process" -AddToBody; $gotAny = $true }
            if ($bucketId) { Add-LogEntry -Message ("Bucket: {0}" -f $bucketId) -Icon "id" -AddToBody; $gotAny = $true }
            if ($defaultBucket) { Add-LogEntry -Message ("Default bucket: {0}" -f $defaultBucket) -Icon "id" -AddToBody; $gotAny = $true }
            if ($analysisVer) { Add-LogEntry -Message ("Analyzer: {0}" -f $analysisVer) -Icon "info" -AddToBody; $gotAny = $true }
            if ($stackSummary) { Add-LogEntry -Message "Stack (top 8):`n$stackSummary" -Icon "script" -AddToBody; $gotAny = $true }

            # Move dump file ONLY if we produced results; move into the per-file folder
            try {
                if ($gotAny) {
                    $destDump = Join-Path $destFolder $file.Name
                    Move-Item -LiteralPath $dumpPath -Destination $destDump
                    Add-LogEntry -Message "Moved dump file to: $destDump" -Icon "fileaction" -AddToBody
                }
                else {
                    Add-LogEntry -Message "No parsed results produced; leaving dump in place: $dumpPath" -Icon "warning" -AddToBody
                }
            }
            catch {
                Add-LogEntry -Message "Failed to move dump file: $($_.Exception.Message)" -Icon "error" -AddToBody
            }

            Add-LogEntry "------------------------" -Icon "endsection" -AddBody
        }
    }

    Add-LogEntry -Message "End of job - Subject: 'Process Dump files.'" -Icon "jobend" -AddBody
}
#endregion

#region File: Process-MinidumpFiles.ps1
function Process-MinidumpFiles {
    param (
        [string]$minidumpDirectory = "C:\Windows\Minidump",
        [string]$outputDirectory = $Global:DrLogs + "minidump\"
    )

    Add-LogEntry -Message "🛠️ Start processing MINIDump files." -AddToBody

    # Resolve WinDbgX cdb.exe
    $cdbPath = $null
    try {
        $pkg = Get-AppxPackage -Name Microsoft.WinDbg -ErrorAction Stop
        $installRoot = $pkg.InstallLocation
        $cdbPath = Join-Path -Path $installRoot -ChildPath 'amd64\cdb.exe'
        if (-not (Test-Path -LiteralPath $cdbPath)) {
            throw "cdb.exe not found at: $cdbPath"
        }
        Add-LogEntry -Message "Using cdb.exe: $cdbPath" -AddToBody
    }
    catch {
        Add-LogEntry -Message "WinDbgX not available: $($_.Exception.Message)" -AddToBody
        Add-LogEntry -Message "Aborting: Microsoft.WinDbg (Store app) must be installed for analysis." -AddToBody
        Add-LogEntry -Message "✅ End of job - Subject: 'Process Minidump files.'" -AddBody
        return
    }

    $minidumpFiles = Get-ChildItem -Path $minidumpDirectory -Filter *.dmp -ErrorAction SilentlyContinue

    if (!(Test-Path -Path $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    }

    if (-not $minidumpFiles -or $minidumpFiles.Count -eq 0) {
        Add-LogEntry -Message "📭 No minidump files to process." -AddToBody
    }
    else {
        foreach ($file in $minidumpFiles) {
            $minidumpPath = $file.FullName
            $outputPath = Join-Path -Path $outputDirectory -ChildPath ("output_" + $file.BaseName + ".txt")

            # Ensure debugger self-quits and show window; no timeout, no forced kill
            $windbgCommandLine = "-z $minidumpPath -c `"!analyze -v; qd`" -logo $outputPath"
            Add-LogEntry -Message "⚙️ Processing: $windbgCommandLine" -AddToBody
            Write-Host "⚙️ $windbgCommandLine"

            try {
                $process = Start-Process -FilePath $cdbPath `
                    -ArgumentList $windbgCommandLine `
                    -WindowStyle Normal `
                    -PassThru
                $process.WaitForExit()
            }
            catch {
                Add-LogEntry -Message "❌ Failed to start/wait for WinDbg process: $_" -AddToBody
                continue
            }

            # Read output (retry on transient lock)
            $logContent = $null
            while ($true) {
                try {
                    $logContent = [System.IO.File]::ReadAllText($outputPath)
                    Add-LogEntry -Message "📄 Output Log:`n$logContent" -AddBody
                    break
                }
                catch [System.IO.IOException] {
                    Start-Sleep -Seconds 5
                }
                catch {
                    Add-LogEntry -Message "❗ Failed reading output log: $_" -AddToBody
                    break
                }
            }

            # --- NEW: Parse useful fields from the log ---
            if ($logContent) {
                # Helper to extract single-line value after 'KeyName:'
                function Try-Extract([string]$pattern) {
                    $m = [regex]::Match($logContent, "(?m)^\s*$pattern\s*:\s*(.+)$")
                    if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null }
                }

                # Helper to extract a multi-line block starting at a header until a blank line or EOF
                function Try-ExtractBlock([string]$header) {
                    $regex = "(?ms)^\s*$([regex]::Escape($header))\s*\r?\n(.*?)(?:\r?\n\s*\r?\n|$)"
                    $m = [regex]::Match($logContent, $regex)
                    if ($m.Success) { return $m.Groups[2].Value.Trim() } else { return $null }
                }

                $bugcheck = Try-Extract 'BUGCHECK_CODE'
                $imageName = Try-Extract 'IMAGE_NAME'
                $moduleName = Try-Extract 'MODULE_NAME'
                $processName = Try-Extract 'PROCESS_NAME'
                $failureBucket = Try-Extract 'FAILURE_BUCKET_ID'
                $failureHash = Try-Extract 'FAILURE_ID_HASH'
                $stackCommand = Try-Extract 'STACK_COMMAND'
                $osVersion = Try-Extract 'OS_VERSION'
                $osName = Try-Extract 'OSNAME'
                $osPlatform = Try-Extract 'OSPLATFORM_TYPE'
                $buildLab = Try-Extract 'BUILDLAB_STR'
                $fileInCab = Try-Extract 'FILE_IN_CAB'
                $faultingModule = Try-Extract 'FAULTING_MODULE'
                $faultingThread = Try-Extract 'FAULTING_THREAD'

                # Arguments: BUGCHECK_Pn (some dumps use these; yours showed P1..P4)
                $p1 = Try-Extract 'BUGCHECK_P1'
                $p2 = Try-Extract 'BUGCHECK_P2'
                $p3 = Try-Extract 'BUGCHECK_P3'
                $p4 = Try-Extract 'BUGCHECK_P4'

                # Blocks
                $stackTextBlock = Try-ExtractBlock 'STACK_TEXT'
                $keyValuesBlock = Try-ExtractBlock 'KEY_VALUES_STRING'

                # Symbol trouble flags
                $symbolWrong = ($logContent -match 'Kernel symbols are WRONG') -or ($logContent -match 'You can run ''\.symfix; \.reload''')
                if ($symbolWrong) {
                    Add-LogEntry -Message "🧭 Symbols not fully resolved (suggested: .symfix; .reload). Results may be limited." -AddToBody
                }

                if ($bugcheck) {
                    Add-LogEntry -Message "🧩 Bug Check Code: $bugcheck" -AddToBody
                }

                if ($p1 -or $p2 -or $p3 -or $p4) {
                    Add-LogEntry -Message "🔢 Bugcheck Args: P1=$p1 P2=$p2 P3=$p3 P4=$p4" -AddToBody
                }

                if ($processName) {
                    Add-LogEntry -Message "🔍 Process Name: $processName" -AddToBody
                    Write-Output "🔍 Process Name: $processName"
                }

                if ($moduleName) {
                    Add-LogEntry -Message "📦 Module Name: $moduleName" -AddToBody
                }

                if ($imageName) {
                    Add-LogEntry -Message "🖼️ Image Name: $imageName" -AddToBody
                }

                if ($failureBucket) {
                    Add-LogEntry -Message "🧺 Failure Bucket: $failureBucket" -AddToBody
                }

                if ($failureHash) {
                    Add-LogEntry -Message "🔑 Failure ID Hash: $failureHash" -AddToBody
                }

                if ($faultingModule) {
                    Add-LogEntry -Message "🏷️ Faulting Module: $faultingModule" -AddToBody
                }

                if ($faultingThread) {
                    Add-LogEntry -Message "🧵 Faulting Thread: $faultingThread" -AddToBody
                }

                if ($stackCommand) {
                    Add-LogEntry -Message "🛠️ Stack Command: $stackCommand" -AddToBody
                }

                if ($osVersion -or $osName -or $osPlatform -or $buildLab) {
                    Add-LogEntry -Message "💻 OS: Version=$osVersion Name=$osName Platform=$osPlatform Build=$buildLab" -AddToBody
                }

                if ($fileInCab) {
                    Add-LogEntry -Message "🗂️ Dump File: $fileInCab" -AddToBody
                }

                if ($keyValuesBlock) {
                    # Keep the most actionable values if present
                    $keyLines = $keyValuesBlock -split "\r?\n" | Where-Object { $_ -match ':' }
                    $pick = @('Analysis.Elapsed.mSec', 'Analysis.CPU.mSec', 'Analysis.Init.Elapsed.mSec', 'Analysis.Version.DbgEng', 'Analysis.Version.Description', 'Analysis.Version.Ext', 'WER.OS.Version', 'WER.OS.Branch')
                    $selected = foreach ($ln in $keyLines) {
                        $parts = $ln.Split(':', 2)
                        if ($parts.Count -eq 2) {
                            $k = $parts[0].Trim()
                            $v = $parts[1].Trim()
                            if ($pick -contains $k) { "${k}: $v" }
                        }
                    }
                    if ($selected -and $selected.Count -gt 0) {
                        Add-LogEntry -Message ("⏱️ Key Metrics:`n" + ($selected -join "`n")) -AddToBody
                    }
                }

                if ($stackTextBlock) {
                    # Clamp to first N lines to avoid overwhelming logs; still very useful
                    $lines = $stackTextBlock -split "\r?\n"
                    $maxLines = 20
                    $snippet = if ($lines.Count -gt $maxLines) { ($lines[0..($maxLines - 1)] + "...(truncated)") -join "`n" } else { $stackTextBlock }
                    Add-LogEntry -Message ("🧱 Stack Text (top):`n$snippet") -AddToBody
                }
            }
            # --- END NEW ---

            try {
                Move-Item -Path $minidumpPath -Destination $outputDirectory
                Add-LogEntry -Message "📁 Moved minidump file: $minidumpPath to $outputDirectory" -AddToBody
            }
            catch {
                Add-LogEntry -Message "❗ Failed to move minidump file: $_" -AddToBody
            }

            Add-LogEntry "------------------------" -AddBody
        }
    }

    Add-LogEntry -Message "✅ End of job - Subject: 'Process Minidump files.'" -AddBody
}
#endregion

#region File: Register-Windows.ps1
function Register-Windows {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProductKey
    )

    # Regular expression to validate the product key format
    $productKeyPattern = '^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$'

    if ($ProductKey -match $productKeyPattern) {
        try {
            # Get the computer name
            $computerName = $env:COMPUTERNAME

            # Install the product key
            slmgr.vbs /ipk $ProductKey

            # Activate Windows
            slmgr.vbs /ato

            Add-LogEntry -Message "Windows has been activated successfully on computer: $computerName with product key: $ProductKey."
        }
        catch {
            Add-LogEntry -Message "An error occurred: $_"
        }
    }
    else {
        Add-LogEntry -Message "Invalid product key format. Please ensure it is in the format XXXXX-XXXXX-XXXXX-XXXXX-XXXXX."
    }
}
#endregion

#region File: Remove-DrRecommendationByNumericId.ps1
function Remove-DrRecommendationByNumericId {
    param(
        [int] $numericId
    )
    try {
        $rec = [DrRecommendation]::new()
        $rec.NumericId = $numericId
        $ok = $rec.Delete()
        if ($ok) {
            "Deleted recommendation [$numericId]."
        }
        else {
            "Delete failed or entry not found for [$numericId]."
        }
    }
    catch {
        "Error deleting recommendation [$numericId]: $($_.Exception.Message)"
    }
}
#endregion

#region File: Remove-DrTimer.ps1
function Remove-DrTimer {
    param([string]$Name = "*ALL")
    Load-DrTimers
    $targets = if ($Name -eq "*ALL") { $Global:DrTimers.Keys } else { @($Name) }

    foreach ($t in $targets) {
        if ($Global:DrTimers.ContainsKey($t)) {
            $Global:DrTimers.Remove($t)
            Add-LogEntry -Message "Timer [$t] removed." -AddToBody -Icon 'warning'
        }
        else {
            Add-LogEntry -Message "Timer [$t] not found." -AddToBody -Icon 'error'
        }
    }
    Save-DrTimers
}
#endregion

#region File: Remove-MaliciousBrowser.ps1
function Remove-MaliciousBrowser {
    param (
        [Parameter(Mandatory)]
        [string[]]$ProcessName,  # Accept multiple names
        [switch]$Stop            # If true, perform cleanup; otherwise, preview only
    )

    # Initialize counters
    $totalProcesses = 0
    $totalFolders = 0
    $totalTasks = 0

    try {
        foreach ($name in $ProcessName) {
            # Get processes for this name
            $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
            $count = if ($procs) { $procs.Count } else { 0 }
            $totalProcesses += $count

            if ($count -eq 0) {
                Add-LogEntry -Message "No processes found for $name. Searching LocalAppData for folders with similar names..." -AddToBody -Icon 'search'
            }
            else {
                Add-LogEntry -Message "Found $count process(es) for $name." -AddToBody -Icon 'terminated'

                # Terminate processes if Stop is set
                if ($Stop) {
                    Stop-Process -Name $name -Force
                    Add-LogEntry -Message "Terminated $count process(es): $name" -AddToBody -Icon 'terminated'
                }
                else {
                    Add-LogEntry -Message "Preview: Would terminate $count process(es): $name" -AddToBody -Icon 'terminated'
                }

                # Debug: Show process paths
                $paths = $procs | Select-Object -ExpandProperty Path
                if ($paths) {
                    Add-LogEntry -Message "Process paths found: $($paths -join ', ')" -AddToBody -Icon 'info'
                }
                else {
                    Add-LogEntry -Message "No process paths found for $name" -AddToBody -Icon 'info'
                }

                # Deduplicate folders from process paths
                $folders = $paths | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique
                if ($folders) {
                    Add-LogEntry -Message "Derived folders from process paths: $($folders -join ', ')" -AddToBody -Icon 'info'
                }
                else {
                    Add-LogEntry -Message "No folders derived from process paths for $name" -AddToBody -Icon 'info'
                }

                foreach ($folder in $folders) {
                    if (Test-Path $folder) {
                        $totalFolders++
                        if ($Stop) {
                            Remove-Item -Path $folder -Recurse -Force
                            Add-LogEntry -Message "Deleted folder: $folder" -AddToBody -Icon 'deleted'
                        }
                        else {
                            Add-LogEntry -Message "Preview: Would delete folder: $folder" -AddToBody -Icon 'deleted'
                        }
                    }
                    else {
                        Add-LogEntry -Message "Folder not found: $folder" -AddToBody -Icon 'warning'
                    }
                }
            }

            # Folder cleanup in LocalAppData (with debug output)
            $searchPaths = @("$env:LOCALAPPDATA")
            foreach ($path in $searchPaths) {
                Add-LogEntry -Message "Searching path: $path for folders matching '$name*'" -AddToBody -Icon 'info'

                if (Test-Path $path) {
                    $similarFolders = Get-ChildItem -Path $path -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "$name*" }

                    if ($similarFolders) {
                        Add-LogEntry -Message "Found matching folders: $($similarFolders.FullName -join ', ')" -AddToBody -Icon 'info'
                    }
                    else {
                        Add-LogEntry -Message "No matching folders found in $path" -AddToBody -Icon 'info'
                    }

                    foreach ($folder in $similarFolders) {
                        $totalFolders++
                        if ($Stop) {
                            Remove-Item -Path $folder.FullName -Recurse -Force
                            Add-LogEntry -Message "Deleted folder: $($folder.FullName)" -AddToBody -Icon 'deleted'
                        }
                        else {
                            Add-LogEntry -Message "Preview: Would delete folder: $($folder.FullName)" -AddToBody -Icon 'deleted'
                        }
                    }
                }
                else {
                    Add-LogEntry -Message "Search path does not exist: $path" -AddToBody -Icon 'warning'
                }
            }

            # Scheduled tasks cleanup (with debug output)
            Add-LogEntry -Message "Searching scheduled tasks for actions containing '$name' or 'SWUpdater.exe'" -AddToBody -Icon 'search'
            $tasks = Get-ScheduledTask | Where-Object {
                $_.Actions | Where-Object { $_.Execute -like "*$name*" -or $_.Execute -like "*SWUpdater.exe*" }
            }

            if ($tasks) {
                Add-LogEntry -Message "Found matching tasks: $($tasks.TaskName -join ', ')" -AddToBody -Icon 'info'
            }
            else {
                Add-LogEntry -Message "No matching scheduled tasks found for $name" -AddToBody -Icon 'info'
            }

            foreach ($task in $tasks) {
                $totalTasks++
                if ($Stop) {
                    Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
                    Add-LogEntry -Message "Removed scheduled task: $($task.TaskName)" -AddToBody -Icon 'deleted'
                }
                else {
                    Add-LogEntry -Message "Preview: Would remove scheduled task: $($task.TaskName)" -AddToBody -Icon 'deleted'
                }
            }

            # Cleanup leftover task folders in System32\Tasks
            $taskRoot = "$env:WINDIR\\System32\\Tasks"
            Add-LogEntry -Message "Searching $taskRoot for folders matching '$name*' or vendor patterns" -AddToBody -Icon 'info'

            if (Test-Path $taskRoot) {
                $taskFolders = Get-ChildItem -Path $taskRoot -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$name*" -or $_.Name -like "*Wavesor Software*" }

                if ($taskFolders) {
                    Add-LogEntry -Message "Found leftover task folders: $($taskFolders.FullName -join ', ')" -AddToBody -Icon 'info'
                }
                else {
                    Add-LogEntry -Message "No leftover task folders found in $taskRoot" -AddToBody -Icon 'info'
                }

                foreach ($folder in $taskFolders) {
                    $totalFolders++
                    if ($Stop) {
                        Remove-Item -Path $folder.FullName -Recurse -Force
                        Add-LogEntry -Message "Deleted leftover task folder: $($folder.FullName)" -AddToBody -Icon 'deleted'
                    }
                    else {
                        Add-LogEntry -Message "Preview: Would delete leftover task folder: $($folder.FullName)" -AddToBody -Icon 'deleted'
                    }
                }
            }
        }

        # Resolve alert if cleanup was performed
        if ($Stop) {
            Resolve-DrAlert -Category 'ps_monitor' -AddToBody
        }

        # Final summary message (flush buffer)
        $mode = if ($Stop) { "Cleanup" } else { "Preview" }
        $summaryMessage = "$mode Summary: Processes=$totalProcesses, Folders=$totalFolders, ScheduledTasks=$totalTasks"
        Add-LogEntry -Message $summaryMessage -AddBody -Icon 'cleanup'

        # Return structured summary
        return [PSCustomObject]@{
            Mode           = $mode
            ProcessesFound = $totalProcesses
            FoldersHandled = $totalFolders
            TasksHandled   = $totalTasks
        }

    }
    catch {
        # Flush buffer on error
        Add-LogEntry -Message "Error during cleanup: $($_.Exception.Message)" -AddBody -Icon 'cleanup'
        return [PSCustomObject]@{
            Mode           = "Error"
            ProcessesFound = $totalProcesses
            FoldersHandled = $totalFolders
            TasksHandled   = $totalTasks
            Error          = $_.Exception.Message
        }
    }
}
#endregion

#region File: Remove-SysVar.ps1
function Remove-SysVar {
    param ([string]$Name)

    if (-not (Assert-IsAdmin @summaryParams)) { return }

    $xmlPath = Initialize-VariableStore 
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($xmlPath)

    $varNode = $xml.SelectSingleNode("//Variable[@Name='$Name']")
    if ($varNode) {
        $xml.DocumentElement.RemoveChild($varNode) | Out-Null
        $xml.Save($xmlPath)
    }

    if (Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue) {
        Remove-Variable -Name $Name -Scope Global
    }
}
#endregion

#region File: Reset-DrRecommendations.ps1
function Reset-DrRecommendations {
    [CmdletBinding()]
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $path = $Global:DrRecommendations
    if (Test-Path $path) {
        Remove-Item $path -Force
        Add-LogEntry -Message "All recommendations cleared." -Icon 'cleanup' @summaryParams
    }
    else {
        Add-LogEntry -Message "ℹNo recommendations file found to reset." -Icon 'information' @summaryParams
    }
}
#endregion

#region File: Reset-DrTimer.ps1
function Reset-DrTimer {
    param([string]$Name)
    Load-DrTimers
    $targets = if ($Name -eq "*ALL") { $Global:DrTimers.Keys } else { @($Name) }

    foreach ($t in $targets) {
        if (-not $Global:DrTimers[$t]) { continue }
        $Global:DrTimers[$t].Elapsed = 0
        $Global:DrTimers[$t].StartTime = (Get-Date).ToString("o")
        $Global:DrTimers[$t].Status = 'Stopped'
        $Global:DrTimers[$t].AddedToTicket = $false
        $Global:DrTimers[$t].Messages = @()
        Add-DrTimerMessage -Name $t -Action 'Reset' -Message "Timer reset."
    }
    Save-DrTimers
}
#endregion

#region File: Reset-ProgressionRules.ps1
function Reset-ProgressionRules {
    [CmdletBinding()]
    param (
        [string] $Path = $Global:DrProgressions
    )

    try {
        '[]' | Set-Content -Path $Path -Encoding UTF8
        Add-LogEntry -Message "Progression rules reset at $Path" -Icon 'cleanup'
        return $true
    }
    catch {
        Add-LogEntry -Message "❌ Failed to reset progression rules: $_" -Icon 'error'
        return $false
    }
}
#endregion

#region File: Reset-WindowsUpdate.ps1
function Reset-WindowsUpdate {
    [CmdletBinding()]
    param (
        [switch]$Aggressive,
        [switch]$FullReset
    )

    # Include Update Orchestrator (UsoSvc) before wuauserv
    $services = @('UsoSvc', 'wuauserv', 'cryptSvc', 'bits', 'trustedinstaller', 'msiserver')

    # Stop services with timeout and fallback kill
    foreach ($svcName in $services) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') {
                Add-LogEntry -Message "🛑 Stopping ${svcName}..." -AddToBody
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                $timeout = 20
                while ($svc.Status -ne 'Stopped' -and $timeout -gt 0) {
                    Start-Sleep -Seconds 1
                    $svc.Refresh()
                    $timeout--
                }
                if ($svc.Status -ne 'Stopped') {
                    # Fallback: Kill the process hosting the service
                    $serviceProcessId = (Get-WmiObject Win32_Service | Where-Object { $_.Name -eq $svcName }).ProcessId
                    if ($serviceProcessId) {
                        Add-LogEntry -Message "⚠️ ${svcName} did not stop, killing PID $serviceProcessId..." -AddToBody
                        Stop-Process -Id $serviceProcessId -Force -ErrorAction SilentlyContinue
                    }
                }
                Add-LogEntry -Message "⏳ ${svcName} stopped (or killed)" -AddToBody
            }
        }
        catch {
            Add-LogEntry -Message "❌ Could not stop ${svcName}: ${_.Exception.Message}" -AddToBody
        }
    }

    # Clean update folders
    $paths = @("$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2")
    foreach ($path in $paths) {
        if (Test-Path $path) {
            Add-LogEntry -Message "🧹 Cleaning ${path}..." -AddToBody
            try {
                if ($Aggressive) {
                    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                }
                else {
                    Remove-Item -Path "${path}\*" -Recurse -Force -ErrorAction SilentlyContinue
                }
                Add-LogEntry -Message "✅ Cleaned ${path}" -AddToBody
            }
            catch {
                Add-LogEntry -Message "❌ Error cleaning ${path}: ${_.Exception.Message}" -AddBody
            }
        }
        else {
            Add-LogEntry -Message "ℹ️ Path ${path} not found, skipping." -AddToBody
        }
    }

    # Full reset steps
    if ($FullReset) {
        Add-LogEntry -Message "🔄 Performing full reset: DLL re-registration and BITS reset..." -AddToBody

        $dlls = 'wuaueng.dll', 'wuapi.dll', 'wups.dll', 'wups2.dll', 'wuwebv.dll', 'wucltux.dll'
        foreach ($dll in $dlls) {
            try {
                Start-Process -FilePath regsvr32.exe -ArgumentList "/s ${dll}" -Wait
                Add-LogEntry -Message "🔄 Re-registered ${dll}" -AddToBody
            }
            catch {
                Add-LogEntry -Message "❌ Failed to re-register ${dll}: ${_.Exception.Message}" -AddBody
            }
        }

        try {
            Get-BitsTransfer -AllUsers | Remove-BitsTransfer -Confirm:$false
            Add-LogEntry -Message "🔄 Reset BITS job queue" -AddToBody
        }
        catch {
            Add-LogEntry -Message "❌ Failed to reset BITS: ${_.Exception.Message}" -AddBody
        }
    }

    # Restart services
    foreach ($svcName in $services) {
        try {
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
            Add-LogEntry -Message "▶️ Started ${svcName}" -AddToBody
        }
        catch {
            Add-LogEntry -Message "❌ Failed to start ${svcName}: ${_.Exception.Message}" -AddBody
        }
    }

    Add-LogEntry -Message "🎉 Windows Update reset complete." -AddBody
}
#endregion

#region File: Resolve-DrAlert.ps1
function Resolve-DrAlert {
    [CmdletBinding()]
    param (
        [string]$Category,
        [bool]$ResolveTicket,
        [switch]$DebugOutput,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer,
        [switch]$NoTicketOutput
    )

    if (-not $Global:UUID) {
        Write-Error "Global:UUID is not set. Cannot identify device."
        return
    }

    $endpoint = "/api/syncro_device/rmm_alerts/clear_alert"
    $body = @{
        uuid           = $Global:UUID
        trigger        = $Category
        resolve_ticket = $ResolveTicket
    }

    try {
        $response = Invoke-DrApiRequest `
            -Method 'POST' `
            -Endpoint $endpoint `
            -Body $body `
            -DebugOutput:$DebugOutput

        # Build logging splats (Summary + Details only)
        $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
        $summaryParams = $logParams.Summary

        Add-LogEntry `
            -Message "Alert resolved: Category: $Category" `
            -Icon resolvealert `
            -LogActivity `
            -NoTicketOutput:$NoTicketOutput `
            @summaryParams

        return $response
    }
    catch {
        Add-LogEntry `
            -Message "Failed to resolve RMM alert: $($_.Exception.Message)" `
            -Icon 'error' `
            @summaryParams
        #Write-Error "Failed to resolve RMM alert: $($_.Exception.Message)"
    }
}
#endregion

#region File: Resolve-ModulePath.ps1
function Resolve-ModulePath([string]$name, [string[]]$searchPaths) {
        if ([System.IO.Path]::IsPathRooted($name) -and (Test-Path -LiteralPath $name)) {
            return (Resolve-Path -LiteralPath $name).Path
        }
        foreach ($p in $searchPaths) {
            $candidate = Join-Path $p $name
            if (Test-Path -LiteralPath $candidate) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
        return $null
    }
#endregion

#region File: Restart-DrComputer.ps1
function Restart-DrComputer {
    param (
        [int]$Delay = 300,
        [string]$Message = "Your computer is scheduled for maintenance. You will be logged out of your computer as indicated below.`n`nIf this is an inconvenient time, please contact support by clicking the Agent icon and opening a Support Ticket or by calling (662) 349-5939.",
        [string]$Reason = "Automation",
        [string]$Contact = "If this is a problem, please contact support at support@drosdicks.com or call 662-349-5939.",
        [switch]$DisableCancel,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    Log-Invocation -IncludeParameters @detailsParams  

    Assert-InteractiveSession

    try {
        Add-LogEntry -Message "Initializing WPF restart prompt..." -Icon "system" @detailsParams

        # Load WPF assemblies
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        Add-Type -AssemblyName System.Xaml

        # XAML for restart prompt
        $XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Systems Maintenance" Height="500" Width="700"
        WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize">
    <Grid Background="{DynamicResource {x:Static SystemColors.WindowBrushKey}}">
        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Top" Margin="20">
            <Image Source="$Global:DrLogo" Width="150" Height="150" Margin="0,10"/>
            <TextBlock Text="$Message" TextWrapping="Wrap" FontSize="16" TextAlignment="Center" Margin="0,10"/>
            <TextBlock x:Name="CountdownLabel" Text="Restarting in..." FontSize="14" TextAlignment="Center" Margin="0,10"/>
            <TextBlock x:Name="TimeLabel" FontSize="24" FontWeight="Bold" Foreground="DarkRed" TextAlignment="Center" Margin="0,5"/>
            <Button x:Name="RestartButton" Content="Restart Now" Width="160" Height="50" FontSize="14" FontWeight="Bold" Margin="0,20"/>
            <TextBlock Text="$Contact" TextWrapping="Wrap" FontSize="12" TextAlignment="Center" Margin="0,10"/>
        </StackPanel>
    </Grid>
</Window>
"@

        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$XAML)
        $window = [Windows.Markup.XamlReader]::Load($reader)

        if (-not $window) {
            Add-LogEntry -Message "Failed to load WPF window from XAML." -Icon "failed" @summaryParams
            return
        }

        $endTime = (Get-Date).AddSeconds($Delay)
        $restartButton = $window.FindName("RestartButton")
        $timeLabel = $window.FindName("TimeLabel")

        # Track restart click
        $script:RestartClicked = $false

        # Restart button click handler
        $restartButton.Add_Click({
                $script:RestartClicked = $true
                Add-LogEntry -Message "🔁 User clicked the 'Restart Now' button." -Icon "SystemAction" @summaryParams
                Start-Process -FilePath "shutdown.exe" -ArgumentList "/r /f /t 5 /c '$Reason'" -NoNewWindow
                $window.Close()
            })

        # Unified Closing handler
        $window.Add_Closing({
                if ($DisableCancel) {
                    $_.Cancel = $true
                    return
                }
                if ($script:RestartClicked) { return }
                Add-LogEntry -Message "Restart prompt canceled by user." -Icon "canceled" @summaryParams
            })

        # Countdown timer
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $timer.Add_Tick({
                $remaining = $endTime - (Get-Date)
                if ($remaining.TotalSeconds -le 0) {
                    $timer.Stop()
                    Add-LogEntry -Message "Countdown expired; restarting." -Icon "timeout" @summaryParams
                    Start-Process -FilePath "shutdown.exe" -ArgumentList "/r /f /t 5 /c '$Reason'" -NoNewWindow
                    $window.Close()
                }
                else {
                    $timeLabel.Text = "{0:D2}:{1:D2}" -f [int]$remaining.Minutes, $remaining.Seconds
                }
            })
        $timer.Start()

        $window.ShowDialog()

        # Final log flush
        #Add-LogEntry -Message "Restart-DrComputer completed." -Icon "SystemAction" -AddBody
    }
    catch {
        Add-LogEntry -Message "Error in Restart-DrComputer: $($_ | Out-String)" -Icon "error" @summaryParams
    }
}
#endregion

#region File: Resume-DrTimer.ps1
function Resume-DrTimer {
    param([string]$Name)
    Load-DrTimers
    $targets = if ($Name -eq "*ALL") { $Global:DrTimers.Keys } else { @($Name) }

    foreach ($t in $targets) {
        if (-not $Global:DrTimers[$t]) { continue }
        $timer = $Global:DrTimers[$t]
        if ($timer.Status -eq 'Paused') {
            $timer.StartTime = (Get-Date).ToString("o")
            $timer.Status = 'Running'
            Add-DrTimerMessage -Name $t -Action 'Resume' -Message "Timer resumed."
        }
    }
    Save-DrTimers
}
#endregion

#region File: Run.ps1
Run() {
        try {
            $output = Invoke-Expression $this.CommandToRun
            $this.MarkExecuted($true, $output)
        }
        catch {
            $this.MarkExecuted($false, $_.Exception.Message)
        }

        return $this.Save()
    }
#endregion

#region File: Run-DISM.ps1
function Run-DISM {
    <#
        .SYNOPSIS
        Runs DISM with specified mode, captures output, interprets results, and logs details.

        .NOTES
        Version: 3.2.16
        Requires administrative privileges for ScanHealth, CheckHealth, RestoreHealth.
        Logging: All entries use -AddToBody; one Summary at end uses -FlushBuffer.
    #>
    [CmdletBinding()]
    param (
        [ValidateSet('ScanHealth', 'CheckHealth', 'RestoreHealth')]
        [string]$Mode = 'ScanHealth',
        [switch]$Repair,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    # --- Validate elevation FIRST; silent exit if not admin ---
    if (-not (Assert-IsAdmin @PSBoundParameters)) {
        return
    }
    Log-Invocation -IncludeParameters @detailsParams  

    try {
        # If -Repair, override Mode to RestoreHealth
        if ($Repair.IsPresent) { $Mode = 'RestoreHealth' }

        # Resolve temp root (fallback if Global not set)
        $tempRoot = $Global:DrTemp
        if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = $env:TEMP }
        if (-not (Test-Path -LiteralPath $tempRoot)) {
            New-Item -ItemType Directory -Path $tempRoot -ErrorAction SilentlyContinue | Out-Null
        }

        # Short timestamp for unique filenames
        $timestamp = (Get-Date -Format 'yyMMdd_HHmm')
        $baseName = "dism_${Mode}_$timestamp"
        $outputFile = Join-Path $tempRoot ($baseName + '.out.txt')
        $errorFile = Join-Path $tempRoot ($baseName + '.err.txt')

        # Start
        #Add-LogEntry -Message "Starting DISM: /Online /Cleanup-Image /$Mode" -Icon 'jobstart' -AddToBody

        # Invoke DISM; redirect streams to files
        $cmdArgs = @('/Online', '/Cleanup-Image', "/$Mode")
        & dism.exe $cmdArgs 1> $outputFile 2> $errorFile
        $exitCode = $LASTEXITCODE


        # Read outputs if they exist
        $output = $null
        $errorOutput = $null
        if (Test-Path -LiteralPath $outputFile) {
            try { $output = Get-Content -Path $outputFile -Raw -Encoding Unicode } catch { }
        }
        if (Test-Path -LiteralPath $errorFile) {
            try { $errorOutput = Get-Content -Path $errorFile -Raw -Encoding Unicode } catch { }
        }


        # Hidden raw logs (still add to body)
        if ($output) { Add-LogEntry -Message "DISM standard output:`n$output" -Icon 'jobprogress' -Hidden -Subject "Output" }
        if ($errorOutput) { Add-LogEntry -Message "DISM error output:`n$errorOutput" -Icon 'error' -Hidden -Subject "error" }

        # Interpret results (case-insensitive)
        $matched = $false
        if ($output) {
            switch -Regex ($output) {
                '(?i)No component store corruption detected' {
                    Add-LogEntry -Message 'No corruption detected in component store.' -Icon 'success' @detailsParams
                    $matched = $true
                }
                '(?i)The component store is repairable' {
                    Add-LogEntry -Message 'Component store is repairable. Consider running RestoreHealth.' -Icon 'warning' @detailsParams
                    Add-DrRecommendation -Message "Repair the component store." -CommandToRun "Run-DISM -Mode RestoreHealth" 
                    $matched = $true
                }
                '(?i)The restore operation completed successfully' {
                    Add-LogEntry -Message 'DISM successfully repaired the component store.' -Icon 'systemaction' @detailsParams
                    Add-DrRecommendation -Message 'DISM successfully repaired the component store.' -SuggestedAction "Run-SFC to repair from the repaired component store. " -CommandToRun "Start-SFC -ScanNow" 
                    Add-DrRecommendation -Message 'DISM successfully repaired the component store.' -SuggestedAction "Restart the system to fianlize the repairs." -CommandToRun "Restart-Computer" 
                    Set-PendingRestart -AddToBody
                    $matched = $true
                }
                '(?i)The operation completed successfully' {
                    Add-LogEntry -Message 'DISM completed successfully.' -Icon 'success' @detailsParams
                    $matched = $true
                }
            }
        }

        if (-not $matched) {
            Add-LogEntry -Message 'DISM output did not match known patterns. Review full output above.' -Icon 'warning' @detailsParams
        }

        # Summary (single flush)
        Add-LogEntry -Message "Summary: Mode=$Mode; ExitCode=$exitCode; Output=$outputFile; Errors=$errorFile" -Icon 'summary' @summaryParams
    }
    catch {
        Add-LogEntry -Message ("DISM failed: " + $_.Exception.Message) -Icon 'error' -AddBody
        #Add-LogEntry -Message 'Summary: DISM encountered an error. See details above.' -Icon 'summary' -AddBody
    }
}
#endregion

#region File: Run-DrRecommendation.ps1
function Run-DrRecommendation {
    [CmdletBinding()]
    param (
        [switch] $OnlyApproved
    )

    $rawList = Get-DrRecommendations
    if (-not $rawList -or $rawList.Count -eq 0) {
        Add-LogEntry -Message "⚪ No recommendations to run." -Icon 'SettingsOverride' -AddBody
        return
    }

    $toRun = $rawList | Where-Object {
        -not $_.Executed -and
        ($OnlyApproved.IsPresent -eq $false -or $_.Approved -eq $true)
    }

    if ($toRun.Count -eq 0) {
        Add-LogEntry -Message "⚪ No unexecuted recommendations match the criteria." -Icon 'SettingsOverride' -AddBody
        return
    }

    foreach ($rec in $toRun | Sort-Object ExecutionOrder) {
        try {
            $output = Invoke-Expression $rec.CommandToRun
            $rec.Executed = $true
            $rec.Success = $true
            $rec.ExecutionOutput = $output
            $rec.ExecutionTimestamp = Get-Date
        }
        catch {
            $rec.Executed = $true
            $rec.Success = $false
            $rec.ExecutionOutput = $_.Exception.Message
            $rec.ExecutionTimestamp = Get-Date
        }

        $rec | ConvertTo-Json -Depth 5 | Out-File -FilePath $Global:DrRecommendations -Encoding UTF8
        Add-LogEntry -Message $rec.ToLogEntry() -Icon 'SettingsOverride' -AddToBody
    }
}
#endregion

#region File: Run-DrRecommendations.ps1
function Run-DrRecommendations {
    [CmdletBinding()]
    param (
        [int]    $Id,
        [switch] $Approved
    )

    $rawList = Get-DrRecommendations
    if (-not $rawList -or $rawList.Count -eq 0) {
        Add-LogEntry -Message "⚪ No recommendations available." -Icon 'SettingsOverride' -AddBody
        return
    }

    $toRun = @()

    if ($Approved) {
        $toRun = $rawList | Where-Object { -not $_.Executed -and $_.Approved }
    }
    elseif ($Id) {
        $target = $rawList | Where-Object { $_.NumericId -eq $Id }
        if (-not $target) {
            Add-LogEntry -Message "❌ Recommendation [$Id] not found." -Icon 'SettingsOverride' -AddBody
            return
        }
        if (-not $target.Approved) {
            Add-LogEntry -Message "⚠️ Recommendation [$Id] is not approved." -Icon 'SettingsOverride' -AddBody
            return
        }
        if ($target.Executed) {
            Add-LogEntry -Message "⚪ Recommendation [$Id] has already been executed." -Icon 'SettingsOverride' -AddBody
            return
        }
        $toRun = @($target)
    }
    else {
        Add-LogEntry -Message "⚠️ You must specify either -Approved or -Id." -Icon 'SettingsOverride' -AddBody
        return
    }

    foreach ($rec in $toRun | Sort-Object ExecutionOrder) {
        try {
            if (Get-Command -Name $rec.CommandToRun -ErrorAction SilentlyContinue) {
                $output = & (Get-Command $rec.CommandToRun)
            }
            else {
                $output = Invoke-Expression "& $($rec.CommandToRun)"
            }
            $rec.MarkExecuted($true, $output)
        }
        catch {
            $rec.MarkExecuted($false, $_.Exception.Message)
        }

        # Safely update the recommendations list
        $updatedList = $rawList | Where-Object { $_.NumericId -ne $rec.NumericId }
        $updatedList = @($updatedList + $rec)

        try {
            $updatedList | ConvertTo-Json -Depth 5 | Set-Content -Path $Global:DrRecommendations -Encoding UTF8
        }
        catch {
            Add-LogEntry -Message "❌ Failed to update recommendation [$($rec.NumericId)] after execution." -Icon 'SettingsOverride' -AddBody
        }

        Add-LogEntry -Message $rec.ToLogEntry() -Icon 'SettingsOverride' -AddToBody
    }
}
#endregion

#region File: Save.ps1
Save() {
        $path = $Global:DrRecommendations
        $existing = @()

        if (Test-Path $path) {
            try {
                $existingRaw = Get-Content $path -Raw | ConvertFrom-Json
                if ($existingRaw -is [System.Collections.IEnumerable]) {
                    $existing = @($existingRaw)
                }
                elseif ($existingRaw -ne $null) {
                    $existing = @($existingRaw)
                }
            }
            catch {
                $existing = @()
            }
        }

        if (-not $this.NumericId -or $this.NumericId -eq 0) {
            $this.NumericId = $this.GetNextNumericId($existing)
        }

        $existing = $existing | Where-Object { $_.NumericId -ne $this.NumericId }

        $exported = $this.Export()

        # Ensure $existing is a valid array before +=
        if ($existing -isnot [System.Collections.IEnumerable]) {
            $existing = @($existing)
        }

        $existing += $exported

        try {
            $existing | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
            return $true
        }
        catch {
            return $false
        }
    }
#endregion

#region File: Save-ApiKey.ps1


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

Import-Module "C:\ProgramData\Syncro\DrOsdicks\bin\DrModuleV3.psm1" -DisableNameChecking

Initialize-Job "v3 Save-ApiKey" -NoNewTicket

Add-LogEntry "API key has been saved." -Icon 'lockandkey' -Buffer $Global:DrLogSummaryBuffer

#Add-LogEntry "ðŸ“¤ DrModuleV3 has been downloaded" -Icon 'download' -Buffer $Global:DrLogSummaryBuffer -
#endregion

#region File: Save-DrTimers.ps1
function Save-DrTimers {
    $json = $Global:DrTimers | ConvertTo-Json -Depth 5
    Set-Content -Path $Global:DrTimerFile -Value $json
}
#endregion

#region File: Save-EncryptedApiKeyToRegistry.ps1
function Save-EncryptedApiKeyToRegistry {
    param (
        [Parameter(Mandatory)]
        [string]$ApiKey
    )
    write-host $script:DrBin
    $regPath = "HKLM:\SOFTWARE\WOW6432Node\RepairTech\Syncro\DrOsdicks"
    $keyPath = "C:\ProgramData\Syncro\DrOsdicks\bin\key.bin"
    $valueName = "ApiKey"
    write-host keypath $keyPath
    # Ensure registry path exists
    if (-not (Test-Path $regPath)) {
        try {
            $null = New-Item -Path $regPath -Force
        }
        catch {
            throw "Failed to create registry path: $_"
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

    $secure = ConvertTo-SecureString $ApiKey -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString $secure -Key $key

    Set-ItemProperty -Path $regPath -Name $valueName -Value $encrypted
    Write-Host "Encrypted API key saved to registry at $regPath\$valueName"
}
#endregion

#region File: SearchAndDelete-Items.ps1
function SearchAndDelete-Items {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [string[]]$ItemNames,
        [Parameter(Mandatory = $false)]
        [switch]$Delete,
        [Parameter(Mandatory = $false)]
        [switch]$DeletePath,
        [Parameter(Mandatory = $false)]
        [switch]$PathOnly,
        [Parameter(Mandatory = $false)]
        [int]$Age = 7,
        [string[]]$Buffer = @('SearchAndDelete'),
        [switch]$FlushBuffer
    )

    $iBuffer = @('SearchAndDelete')
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details



    Add-LogEntry -Message "Start of SearchAndDelete-Items. Age: $Age" @detailsParams
    $foundCount = 0
    $deletedCount = 0
    $cutoffDate = (Get-Date).AddDays(-$Age)
    $items = @()

    # Validate Path
    if (-not $Path) {
        Add-LogEntry -Message "❌ Error: Path parameter is missing." -Icon 'Error' @detailsParams
        #Add-LogEntry -Message "End of SearchAndDelete-Items. Found: $foundCount, Deleted: $deletedCount" -AddBody -Hidden
        return
    }

    if (Test-Path $Path) {
        # SAFETY CHECK for DeletePath
        $criticalPaths = @("$env:SystemDrive\", "C:\Windows", "C:\Program Files", "C:\Program Files (x86)")
        if ($Delete -and $DeletePath) {
            $resolvedPath = (Resolve-Path $Path).Path
            if ($criticalPaths -contains $resolvedPath) {
                Add-LogEntry -Message "🚫 DeletePath blocked: $resolvedPath is a protected system path." -Icon 'BlockedAction' @detailsParams
                Add-LogEntry -Message "End of SearchAndDelete-Items. Found: $foundCount, Deleted: $deletedCount" -AddBody -Hidden
                return
            }

            try {
                Remove-Item -Path $Path -Recurse -Force
                Add-LogEntry -Message "Deleted entire path: $Path" -Icon fileaction @detailsParams -Icon 'deleted'
                $deletedCount++
            }
            catch {
                Add-LogEntry -Message "❌ Failed to delete path: $Path" -Icon error @detailsParams
            }
            Add-LogEntry -Message "End of SearchAndDelete-Items. Found: $foundCount, Deleted: $deletedCount" -AddBody -Hidden
            return
        }

        # Otherwise, search for items
        if ($PathOnly -or ($ItemNames -and $ItemNames.Count -gt 0)) {
            if ($PathOnly) {
                Add-LogEntry -Message "Gathering items in $Path" @detailsParams -Icon fileaction
                $items = Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoffDate }
            }
            else {
                Add-LogEntry -Message "Gathering items..." @detailsParams -Icon fileaction
                foreach ($ItemName in $ItemNames) {
                    $items += Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$ItemName*" -and $_.LastWriteTime -lt $cutoffDate }
                }
            }

            if ($items.Count -gt 0) {
                foreach ($item in $items) {
                    $foundCount++
                    if (-not $Delete) {
                        Add-LogEntry -Message "Found item: $($item.FullName)" -Icon fileaction -Buffer Details 
                    }
                    if ($Delete) {
                        try {
                            Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                            Add-LogEntry -Message "Deleted item: $($item.FullName)" -Icon fileaction -Buffer Details 
                            $deletedCount++
                        }
                        catch {
                            Add-LogEntry -Message "Failed to delete item: $($item.FullName)" -Icon error -Buffer Details 
                        }
                    }
                    #Add-LogEntry "${foundCount} items found. ${deletedCount} items deleted." -Icon 'detail' @detailsParams
                }
            }
            else {
                Add-LogEntry -Message "Nothing to delete." @detailsParams -Icon cleanup
            }
        }
    }
    else {
        Add-LogEntry -Message "❌ Error: Path not found ($Path)." -Icon error @detailsParams
    }

    Add-LogEntry -Message "End of SearchAndDelete-Items. Found: $foundCount, Deleted: $deletedCount" -Buffer Details  -FlushBuffer -Hidden
    Add-LogEntry -Message "End of SearchAndDelete-Items. Found: $foundCount, Deleted: $deletedCount" @summaryParams
}
#endregion

#region File: Send-DrAlert.ps1
function Send-DrAlert {
    [CmdletBinding()]
    param (
        [string]$Category,
        [string]$Body,
        [switch]$DebugOutput,
        [string[]]$Buffer = @('Send-DrAlert'),
        [switch]$FlushBuffer,
        [switch]$NoTicketOutput
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        if ([string]::IsNullOrWhiteSpace($Category) -or [string]::IsNullOrWhiteSpace($Body)) {
            Add-LogEntry -Message "Category and Body are required to send an alert." -Icon 'warning' @summaryParams
            return
        }

        $payload = @{
            device_uuid = $Global:UUID
            trigger     = $Category
            description = $Body
        }

        $response = Call-KabutoApi `
            -Path '/device_api/rmm_alert' `
            -Method POST `
            -Data $payload `
            -DebugOutput:$DebugOutput `
            -ErrorAction Stop

        Add-LogEntry `
            -Message "Alert sent: Category=$Category" `
            -Icon 'sendalert' `
            -LogActivity `
            -NoTicketOutput:$NoTicketOutput `
            @summaryParams

        return $response
    }
    catch {
        Add-LogEntry `
            -Message "Failed to send RMM alert: $($_.Exception.Message)" `
            -Icon 'error' `
            @summaryParams
    }
}
#endregion

#region File: Send-DrEmail.ps1
function Send-DrEmail {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body
    )

    if (-not $Global:UUID) {
        Write-Error "Global:UUID is not set. Cannot send email without device UUID."
        return
    }

    $payload = @{
        uuid    = $Global:UUID
        to      = $To
        subject = $Subject
        body    = $Body
    }

    try {
        return Invoke-DrApiRequest -Method 'POST' -Endpoint '/api/syncro_device/emails/send_adhoc_email' -Body $payload
    }
    catch {
        Write-Error "Failed to send email: $_"
    }
}
#endregion

#region File: Send-DrFile.ps1
function Send-DrFile {
    <#
    .SYNOPSIS
      Uploads a file using DrFilePusher and attaches it to the Syncro asset.

    .DESCRIPTION
      This function runs the external file pusher tool, parses its JSON output,
      and sends the file metadata to Syncro using the original endpoint:
      /api/syncro_device/files/upload_file_from_url

    .PARAMETER filePath
      Required. Full path to the file to be uploaded.

    .PARAMETER DeleteAfterUpload
      Optional. If specified, deletes the file after successful upload.

    .NOTES
      Requires $Global:DrFilePusherPath and $Global:UUID.
      Uses Add-LogEntry for structured logging.
    #>

    param (
        [Parameter(Mandatory)][string]$filePath,
        [switch]$DeleteAfterUpload,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $detailsParams = $logParams.Details
    $summaryParams = $logParams.Summary

    Add-LogEntry -Message "🔧 Starting Upload-File for: $filePath" -Icon 'FileHandling' @detailsParams
    #Write-Host "🔧 DrFilePusherPath: $Global:DrFilePusherPath"
    #Write-Host "🔧 UUID: $Global:UUID"

    # Run file pusher and parse output
    $fileJson = try {
        #Write-Host "🔍 Running file pusher..."
        $output = cmd /c "$Global:DrFilePusherPath `"$filePath`"" 2>&1
        #Write-Host "📄 Raw output from file pusher:`n$output"

        $parsed = ConvertFrom-Json -InputObject $output
        #Write-Host "📦 Parsed JSON:`n$($parsed | Out-String)"
        $parsed
    }
    catch {
        #Write-Host "❌ Exception during file pusher execution: $($_.Exception.Message)"
        Add-LogEntry -Message "Failed to run file pusher for '$filePath'" -Icon 'error' $summaryParams
        return
    }

    # Validate JSON structure
    if (
        -not $fileJson.filename -or -not $fileJson.url -or
        -not ($fileJson.filename.Trim()) -or -not ($fileJson.url.Trim())
    ) {
        #Write-Host "❌ Invalid JSON structure or missing keys"
        Add-LogEntry -Message "Invalid file pusher output for '$filePath'" -Icon 'error' $summaryParams
        return
    }

    $endpoint = "/api/syncro_device/files/upload_file_from_url"
    #$uri = "https://$($Global:DrSubDomain).syncromsp.com$endpoint"
    #Write-Host "🔗 Endpoint: $endpoint"
    #Write-Host "url: $($fileJson.url)"
    #Write-Host "filename: $($fileJson.filename)"
    #Write-Host "🔗 Full URI (for troubleshooting): $uri"

    # Upload file metadata to Syncro
    try {
        $result = Invoke-DrApiRequest `
            -Method 'POST' `
            -Endpoint $endpoint `
            -Body @{
            uuid     = $Global:UUID
            url      = $fileJson.url
            filename = $fileJson.filename
        }

        Write-Host "📨 API response:`n$($result | Out-String)"
        Add-LogEntry -Message "📎 Uploaded '$($fileJson.filename)' to Syncro device $($Global:DrAsset.name)" -Icon 'attach' @detailsParams
        if ($DeleteAfterUpload) {
            try {
                Remove-Item -Path $filePath -Force
                Add-LogEntry -Message "Deleted file after upload: $filePath" -Icon 'cleanup' @detailsParams
            }
            catch {
                Add-LogEntry -Message "Failed to delete file after upload: $filePath" -Icon 'warning' @detailsParams
            }
        }
        Add-LogEntry "File sent." @summaryParams
       
    }
    catch {
        #Write-Host "❌ Failed to upload file metadata to Syncro: $($_.Exception.Message)"
        Add-LogEntry -Message "Failed to attach '$($fileJson.filename)' to Syncro device" -Icon 'error' @detailsParams
    }


}
#endregion

#region File: Set-AssetField.ps1
function Set-AssetField {
    param(
        [string] $Name,
        [object] $Value
    )

    $result = Invoke-DrApiRequest `
        -Method 'POST' `
        -Endpoint "/api/syncro_device/custom_fields/set_asset_field" `
        -Body @{
        uuid        = $Global:UUID
        field_name  = $Name
        field_value = [string]$Value
    }
    #Write-Host Name $Name
    #Write-Host Global:UUID $Global:UUID
    #Write-Host Value $Value
    #Write-Host result $result
    return $result
}
#endregion

#region File: Set-AssetTicket.ps1
function Set-AssetTicket ($ticketNumber = $Global:DrTicket) {
    Set-AssetField  -Name 'Ticket' -Value $ticketNumber
}
#endregion

#region File: Set-DrAssetIdRegistry.ps1
function Set-DrAssetIdRegistry {
    [CmdletBinding()]
    param(
        [string[]]$AssetId,
        [string]$RegPath = 'HKLM:\SOFTWARE\WOW6432Node\RepairTech\Syncro\DrOsdicks',
        [string]$Name = 'asset_id',
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer,
        [switch]$Quiet
    )

    begin {
        $diag = New-Object System.Collections.Generic.List[string]
        $issues = New-Object System.Collections.Generic.List[string]
        $chosen = $null

        $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
        $detailsParams = $logParams.Details
        $summaryParams = $logParams.Summary
    }

    process {
        try {
            # Normalize array (remove null/empty)
            $normalized = @($AssetId | Where-Object { $_ -and $_.Trim() -ne '' })
            $diag.Add("Incoming: $(@($AssetId).Count); normalized: $($normalized.Count)")

            if ($normalized.Count -eq 0) {
                $chosen = ''
                $diag.Add("No non-empty AssetId provided; will write empty string.")
            }
            else {
                $chosen = $normalized[0].Trim()
                if ($normalized.Count -gt 1) {
                    $diag.Add("Multiple ids provided; storing first: '$chosen'")
                }
                else {
                    $diag.Add("Single id provided: '$chosen'")
                }
            }

            if ([string]::IsNullOrWhiteSpace($RegPath)) { $issues.Add('RegPath is required.') }
            if ([string]::IsNullOrWhiteSpace($Name)) { $issues.Add('Name is required.') }
            if ($issues.Count -gt 0) { return }

            if (-not (Test-Path -LiteralPath $RegPath)) {
                New-Item -Path $RegPath -Force | Out-Null
                $diag.Add("Created registry key: $RegPath")
            }

            # REG_SZ to match Get-DrAssetIdRegistry
            New-ItemProperty -Path $RegPath -Name $Name -PropertyType String -Value $chosen -Force | Out-Null
            $diag.Add("Wrote REG_SZ '$Name' at '$RegPath' with value '$chosen'")
        }
        catch {
            $issues.Add($_.Exception.Message)
            throw
        }
    }

    end {
        if (-not $Quiet) {
            try {
                $summary = if ($null -ne $chosen) {
                    "Set-DrAssetIdRegistry completed | AssetId stored: $chosen"
                }
                else {
                    "Set-DrAssetIdRegistry completed | AssetId stored: [none]"
                }
                $details = @()
                if ($issues.Count -gt 0) { $details += ("Issues: " + ($issues -join ' | ')) }
                if ($diag.Count -gt 0) { $details += ("Diag: " + ($diag -join ' | ')) }
                $msg = if ($details.Count -gt 0) { "$summary || $($details -join ' || ')" } else { $summary }

                Add-LogEntry -Message $msg -Icon 'settings' @summaryParams
            }
            catch { }
        }
    }
}
#endregion

#region File: Set-DumpType.ps1
function Set-DumpType {
    [CmdletBinding()]
    param (
        [ValidateSet("Minidump", "Kernel", "Complete", "Automatic", "Active")]
        [string]$DumpType = "Minidump",
        [switch]$AddToBody
    )

    if (-not (Assert-IsAdmin @PSBoundParameters)) { return }

    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"

        $dumpTypeMap = @{
            1 = "Complete"
            2 = "Kernel"
            3 = "Minidump"
            7 = "Automatic"
        }

        $dumpValue = switch ($DumpType) {
            "Complete" { 1 }
            "Kernel" { 2 }
            "Minidump" { 3 }
            "Automatic" { 7 }
            "Active" { 1 }  # Active uses Complete + FilterPages
        }

        if ($DumpType -eq 'Minidump') {
            $minidumpPath = "C:\Windows\Minidump"
            if (-not (Test-Path -Path $minidumpPath)) {
                New-Item -ItemType Directory -Path $minidumpPath -Force | Out-Null
                Add-LogEntry -Message "🗂️ Minidump folder created at $minidumpPath." -Icon "FileHandling" -AddToBody
            }
            else {
                Add-LogEntry -Message "🗂️ Minidump folder already exists at $minidumpPath." -Icon "FileHandling" -AddToBody
            }
        }

        $currentValue = Get-ItemProperty -Path $regPath -Name "CrashDumpEnabled" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CrashDumpEnabled
        $oldTypeName = $dumpTypeMap[$currentValue]
        $newTypeName = $dumpTypeMap[$dumpValue]

        if ($currentValue -ne $dumpValue) {
            Set-ItemProperty -Path $regPath -Name "CrashDumpEnabled" -Value $dumpValue
            Add-LogEntry -Message "⚙️ CrashDumpEnabled changed from $oldTypeName ($currentValue) to $newTypeName ($dumpValue)." -Icon "SettingsOverride" -AddToBody
        }
        else {
            Add-LogEntry -Message "⚙️ CrashDumpEnabled already set to $newTypeName ($dumpValue). No change needed." -Icon "SettingsOverride" -AddToBody
        }

        Add-LogEntry -Message "📋 Dump type '${DumpType}' configuration complete." -Icon "syncroapi" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
    }
    catch {
        Add-LogEntry -Message "❌ Failed to set dump type '${DumpType}': $($_.Exception.Message)" -Icon "Error" -AddToBody:$AddToBody -AddBody:(!$AddToBody)
    }
}
#endregion

#region File: Set-EdgeExtension.ps1
function Set-EdgeExtension {
    param (
        [Parameter(Mandatory = $true)][string]$ExtensionName,
        [string]$ExtensionID,
        [string]$UpdateUrl = 'https://clients2.google.com/service/update2/crx',
        [switch]$Install,
        [switch]$Remove
    )

    # Check for admin rights if Repair is requested
    if (-not (Assert-IsAdmin @PSBoundParameters)) { return }


    # Predefined mapping
    $extensionMap = @{
        "AdGuard"  = "bgnkhhnnamicmpeenaelnjfhikgbkllg"
        "LastPass" = "hdokiejnpimakedhajhdlcegeplioahd"
        # Add more as needed
    }

    if (-not $ExtensionID) {
        if ($extensionMap.ContainsKey($ExtensionName)) {
            $ExtensionID = $extensionMap[$ExtensionName]
            Add-LogEntry -Message "🔍 Resolved ExtensionID for ${ExtensionName}: $ExtensionID" -AddToBody
        }
        else {
            Add-LogEntry -Message "⚠️ Extension name '$ExtensionName' not found in mapping." -AddBody -Icon 'warning'
            return
        }
    }

    # (Rest of the logic same as before)
}
#endregion

#region File: Set-FastBootSetting.ps1
function Set-FastBootSetting {
    param (
        [Parameter(Mandatory = $false, ParameterSetName = 'Enable')]
        [switch]$On,

        [Parameter(Mandatory = $false, ParameterSetName = 'Disable')]
        [switch]$Off,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        if (-not $On -and -not $Off) {
            Add-LogEntry -Message "Invalid parameters: specify -On or -Off." -Icon 'warning' @summaryParams
            return
        }

        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        $name = "HiberbootEnabled"
        #$key = 'HKCU:\Control Panel\Keyboard'
        #$name = 'InitialKeyboardIndicators'
        $currentValue = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name

        $currentState = if ($currentValue -eq 1) { "On" } else { "Off" }
        $desiredState = if ($On) { "On" } else { "Off" }

        $changed = $currentState -ne $desiredState

        if ($changed) {
            $newValue = if ($desiredState -eq "On") { 1 } else { 0 }
            Set-ItemProperty -Path $key -Name $name -Value $newValue -Force -ErrorAction Stop
            $message = "FastBootSetting state changed from $currentState to $desiredState"
            $Icon = "numbers"
        }
        else {
            $message = "FastBootSetting state already set to $desiredState"
            $Icon = "ok"
        }

        Add-LogEntry -Message $message -Icon $Icon @summaryParams
    }
    catch {
        Add-LogEntry -Message "An error occurred while setting FastBootSetting state: $($_.Exception.Message)" -Icon 'warning' @summaryParams
    }
}
#endregion

#region File: Set-NetworkCategory.ps1
function Set-NetworkCategory {
    [CmdletBinding(DefaultParameterSetName = 'None')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Public')]
        [switch]$Public,

        [Parameter(Mandatory = $true, ParameterSetName = 'Private')]
        [switch]$Private
    )
    Log-Invocation -IncludeParameters @detailsParams  

    $desiredCategory = if ($Public) { 'Public' } else { 'Private' }

    $netProfile = Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -ne 'Disconnected' } | Select-Object -First 1

    if (-not $netProfile) {
        Add-LogEntry -Message "⚠️ No active network profile found." -AddBody
        return
    }

    $currentCategory = $netProfile.NetworkCategory
    $interface = $netProfile.InterfaceAlias

    Add-LogEntry -Message "Current network category for '$interface': $currentCategory" -AddToBody -Icon 'jobcheck'

    if ($currentCategory -ne $desiredCategory) {
        try {
            Set-NetConnectionProfile -InterfaceAlias $interface -NetworkCategory $desiredCategory
            Add-LogEntry -Message "Changed network category for '$interface' to $desiredCategory." -AddBody -Icon 'success'
        }
        catch {
            Add-LogEntry -Message "Failed to change network category: $_" -AddBody -Icon 'error'
        }
    }
    else {
        Add-LogEntry -Message "Network category for '$interface' is already $desiredCategory. No change made." -AddBody -Icon 'info'
    }
}
#endregion

#region File: Set-NumLockState.ps1
function Set-NumLockState {
    param (
        [Parameter(Mandatory = $false, ParameterSetName = 'Enable')]
        [switch]$On,

        [Parameter(Mandatory = $false, ParameterSetName = 'Disable')]
        [switch]$Off,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        if (-not $On -and -not $Off) {
            Add-LogEntry -Message "Invalid parameters: specify -On or -Off." -Icon 'warning' @summaryParams
            return
        }

        $key = 'HKCU:\Control Panel\Keyboard'
        $name = 'InitialKeyboardIndicators'
        $currentValue = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name

        $currentState = if ($currentValue -eq 2) { "On" } else { "Off" }
        $desiredState = if ($On) { "On" } else { "Off" }

        $changed = $currentState -ne $desiredState

        if ($changed) {
            $newValue = if ($desiredState -eq "On") { 2 } else { 0 }
            Set-ItemProperty -Path $key -Name $name -Value $newValue -Force -ErrorAction Stop
            $message = "Num-lock state changed from $currentState to $desiredState"
            $Icon = "numbers"
        }
        else {
            $message = "Num-lock state already set to $desiredState"
            $Icon = "ok"
        }

        Add-LogEntry -Message $message -Icon $Icon @summaryParams
    }
    catch {
        Add-LogEntry -Message "An error occurred while setting Num-lock state: $($_.Exception.Message)" -Icon 'warning' @summaryParams
    }
}
#endregion

#region File: Set-PendingRestart.ps1
function Set-PendingRestart {
    [CmdletBinding()]
    param (
        [switch]$Clear,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    # Check for Administrator privileges
    if (-not (Assert-IsAdmin @PSBoundParameters)) { return }

    $keyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"
    $rebootRequiredPath = Join-Path $keyPath "RebootRequired"

    try {
        if ($Clear) {
            if (Test-Path $rebootRequiredPath) {
                Remove-Item -Path $rebootRequiredPath -Force -ErrorAction SilentlyContinue
                Add-LogEntry "Cleared RebootRequired key: $rebootRequiredPath" @detailsParams -Icon 'deleted'
            }
            else {
                Add-LogEntry "ℹ️ No RebootRequired key found to clear." @detailsParams
            }

            Add-LogEntry "✅ System not marked as requiring a restart." @summaryParams

            return [PSCustomObject]@{
                Success = $true
                Action  = "Cleared"
                Path    = $rebootRequiredPath
                Message = "Pending restart flag cleared."
            }
        }
        else {
            # Ensure the parent key exists
            if (-not (Test-Path $keyPath)) {
                New-Item -Path $keyPath -Force | Out-Null
                Add-LogEntry "📁 Created parent registry path: $keyPath" @detailsParams
            }

            # Create the RebootRequired key
            if (-not (Test-Path $rebootRequiredPath)) {
                New-Item -Path $rebootRequiredPath -Force | Out-Null
                Add-LogEntry "🔁 Created RebootRequired key: $rebootRequiredPath" @detailsParams
            }
            else {
                Add-LogEntry "ℹ️ RebootRequired key already exists: $rebootRequiredPath" @detailsParams
            }

            Add-LogEntry "✅ System marked as requiring a restart." @summaryParams

            return [PSCustomObject]@{
                Success = $true
                Action  = "Set"
                Path    = $rebootRequiredPath
                Message = "System marked as requiring a restart."
            }
        }
    }
    catch {
        Add-LogEntry "❌ Failed to update pending restart state: $($_.Exception.Message)" @summaryParams


        return [PSCustomObject]@{
            Success = $false
            Path    = $rebootRequiredPath
            Message = $_.Exception.Message
        }
    }
}
#endregion

#region File: Set-RestartNotification.ps1
function Set-RestartNotification {
    [CmdletBinding(DefaultParameterSetName = 'Enable')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Enable')]
        [switch]$On,

        [Parameter(Mandatory = $true, ParameterSetName = 'Disable')]
        [switch]$Off,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        $State = if ($PSCmdlet.ParameterSetName -eq 'Enable') { 'On' } else { 'Off' }
        $Value = if ($State -eq 'On') { 1 } else { 0 }
        $Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"

        if (-not (Test-Path -Path $Path)) {
            New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX" -Name "Settings" -Force | Out-Null
        }

        $CurrentValue = (Get-ItemProperty -Path $Path -Name RestartNotificationsAllowed2 -ErrorAction SilentlyContinue).RestartNotificationsAllowed2
        $CurrentState = if ($CurrentValue -eq 1) { 'On' } else { 'Off' }

        Set-ItemProperty -Path $Path -Name RestartNotificationsAllowed2 -Value $Value

        $msg = if ($CurrentValue -eq $Value) {
            "✅ Restart Notifications already set to ${State} (value: ${Value})"
        }
        else {
            "🔁 Restart Notifications changed from ${CurrentState} (value: ${CurrentValue}) to ${State} (value: ${Value})"
        }
    }
    catch {
        $msg = "❌ An error occurred in Set-RestartNotification: $($_.Exception.Message)"
    }
    Add-LogEntry -Message $msg -Icon 'summary' @summaryParams

}
#endregion

#region File: Set-StorageSense.ps1
function Set-StorageSense {
    [CmdletBinding()]
    param (
        [switch]$Enable,
        [switch]$ClearTemporaryFiles,
        [switch]$AddAllOneDrivelocations,
        [switch]$AddToBody,
        [switch]$UseHKLM,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        $path = if ($UseHKLM) {
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
        }
        else {
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
        }

        $changes = @()

        if ($UseHKLM -and -not (IsUserAdmin)) {
            Add-LogEntry -Message "❌ Cannot write to HKLM without admin rights." -Icon "settings" @summaryParams
            return
        }

        if ($Enable) {
            Set-ItemProperty -Path $path -Name "01" -Value 1
            $changes += "Storage Sense Enabled"
            Add-LogEntry -Message "Enabled Storage Sense" -Icon "settings" @detailsParams
        }

        if ($ClearTemporaryFiles) {
            Set-ItemProperty -Path $path -Name "04" -Value 1
            $changes += "Clear Temporary Files"
            Add-LogEntry -Message "Enabled deletion of temporary files" -Icon "cleanup" @detailsParams
        }

        if ($AddAllOneDrivelocations) {
            Set-ItemProperty -Path $path -Name "CloudfilePolicyConsent" -Value 1
            Set-ItemProperty -Path $path -Name "2048" -Value 7
            $changes += "Enable OneDrive cleanup policy"
            Add-LogEntry -Message "Enabled OneDrive cleanup policy (CloudfilePolicyConsent + 2048)" -Icon "settings" @detailsParams
        }

        if ($changes.Count -eq 0) {
            Add-LogEntry -Message "No Storage Sense settings were changed." -Icon "note" @summaryParams
        }

    }
    catch {
        Add-LogEntry -Message "❌ Failed to update Storage Sense settings: $_" -Icon "error" @summaryParams
    }
}
#endregion

#region File: Set-StoreApp.ps1
function Set-StoreApp {
    [CmdletBinding()]
    param (
        [string]$AppName,
        [string]$AppID,
        [switch]$Install,
        [switch]$Update,
        [switch]$Uninstall,
        [switch]$AddToBody
    )

    # Winget special exit code for 'already installed/up-to-date'
    [int64]$alreadyInstalledCode = -1978335189

    # Ensure winget is present/up-to-date first; minimal output handled inside Install-UpdateWinget
    $wingetResult = $null
    try { $wingetResult = Install-UpdateWinget -AddToBody:$AddToBody } catch { }
    $wingetPath = if ($wingetResult) { $wingetResult.WingetPath } else { $null }

    if (-not $wingetPath) {
        Add-LogEntry -Message "Set-StoreApp: winget unavailable after remediation. Aborting." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
        return
    }

    try {
        # Resolve app ID/name from Microsoft Store
        $resolvedName = $null
        $appId = $null

        if ($AppID) {
            # Verify AppID exists and get display name
            $showResult = & "$wingetPath" show --id "$AppID" --source=msstore --accept-source-agreements 2>&1
            $retrievedAppName = $null
            foreach ($line in $showResult) {
                if ($line -match "Found\s+(.+)\s+\[\S+\]") { $retrievedAppName = $matches[1].Trim(); break }
            }

            if (-not $retrievedAppName) {
                Add-LogEntry -Message "Set-StoreApp: App ID '$AppID' not found in Microsoft Store." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            if ($AppName -and ($AppName.ToLower() -ne $retrievedAppName.ToLower())) {
                Add-LogEntry -Message "Set-StoreApp: Provided name '$AppName' does not match resolved '$retrievedAppName' for ID '$AppID'." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            $resolvedName = $retrievedAppName
            $appId = $AppID
        }
        else {
            if (-not $AppName) {
                Add-LogEntry -Message "Set-StoreApp: No AppName or AppID provided." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            # Search Microsoft Store by name
            $searchResult = & "$wingetPath" search -q "$AppName" --source=msstore --accept-source-agreements 2>&1

            # Parse results into Name/ID pairs
            $found = @()
            foreach ($line in $searchResult) {
                if ($line -match "^\s*(.+?)\s+(\S+)\s+\S+") {
                    $nameCandidate = $matches[1].Trim()
                    $idCandidate = $matches[2].Trim()
                    if ($nameCandidate -and $idCandidate -and ($idCandidate -ne 'Id') -and ($nameCandidate -ne 'Name')) {
                        $found += [PSCustomObject]@{ Name = $nameCandidate; Id = $idCandidate }
                    }
                }
            }

            if ($found.Count -eq 0) {
                Add-LogEntry -Message "Set-StoreApp: App ID for '$AppName' not found in Microsoft Store search results." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            if ($found.Count -gt 1) {
                # List matches so the tech can choose the exact AppID, then return
                Add-LogEntry -Message "Multiple matches for '$AppName' found in Microsoft Store:" -Icon 'info' -AddToBody
                foreach ($item in $found) {
                    Add-LogEntry -Message ("  Name='{0}'  ID='{1}'" -f $item.Name, $item.Id) -Icon 'id' -AddToBody
                }
                Add-LogEntry -Message "Set-StoreApp: multiple matches found; rerun with -AppID." -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
                return
            }

            # Single match → use it
            $resolvedName = $found[0].Name
            $appId = $found[0].Id
        }

        # Execute requested actions: Uninstall -> Install -> Update
        $results = @()

        if ($Uninstall) {
            try {
                & "$wingetPath" uninstall --id "$appId" --source=msstore 2>&1 | Out-Null
                [int64]$code = $LastExitCode
                if ($code -eq 0 -or $code -eq $alreadyInstalledCode) { $results += "Uninstall=Success" }
                else { $results += "Uninstall=Fail($code)" }
            }
            catch {
                $results += "Uninstall=Exception($($_.Exception.Message))"
            }
        }

        if ($Install) {
            try {
                & "$wingetPath" install -e -i --id "$appId" --source=msstore --accept-package-agreements 2>&1 | Out-Null
                [int64]$code = $LastExitCode
                if ($code -eq 0 -or $code -eq $alreadyInstalledCode) {
                    if ($code -eq $alreadyInstalledCode) { $results += "Install=UpToDate" } else { $results += "Install=Success" }
                }
                else { $results += "Install=Fail($code)" }
            }
            catch {
                $results += "Install=Exception($($_.Exception.Message))"
            }
        }

        if ($Update) {
            try {
                & "$wingetPath" upgrade --id "$appId" --source=msstore --accept-package-agreements 2>&1 | Out-Null
                [int64]$code = $LastExitCode
                if ($code -eq 0 -or $code -eq $alreadyInstalledCode) {
                    if ($code -eq $alreadyInstalledCode) { $results += "Update=UpToDate" } else { $results += "Update=Success" }
                }
                else { $results += "Update=Fail($code)" }
            }
            catch {
                $results += "Update=Exception($($_.Exception.Message))"
            }
        }

        # Final minimal summary line
        $actionsSummary = if ($results.Count -gt 0) { $results -join '; ' } else { "NoActionsRequested" }
        Add-LogEntry -Message "Set-StoreApp: Name='$resolvedName' ID='$appId' [$actionsSummary]" -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
    }
    catch {
        Add-LogEntry -Message "Set-StoreApp: Unhandled exception: $($_.Exception.Message)" -Icon 'summary' -AddToBody:$AddToBody -AddBody:(-not $AddToBody)
    }
}
#endregion

#region File: Set-SyncroSafeMode.ps1
function Set-SyncroSafeMode {
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Enable')]
        [switch]$Enable,

        [Parameter(Mandatory = $true, ParameterSetName = 'Disable')]
        [switch]$Disable,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    if (-not (Assert-IsAdmin @summaryParams)) { return }

    try {
        $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Network"
        $services = @("Syncro", "SyncroLive", "SyncroOvermind", "SplashtopRemoteService")

        $existingKeys = $services | Where-Object { Test-Path "$registryPath\$_" }
        $currentState = if ($existingKeys.Count -eq $services.Count) { "Enabled" } else { "Disabled" }
        $desiredState = if ($Enable) { "Enabled" } elseif ($Disable) { "Disabled" }

        $changed = $currentState -ne $desiredState

        if ($changed) {
            foreach ($service in $services) {
                $keyPath = "$registryPath\$service"
                if ($Enable) {
                    if (-not (Test-Path $keyPath)) {
                        New-Item -Path $keyPath -Force | Out-Null
                    }
                    Set-ItemProperty -Path $keyPath -Name "(Default)" -Value "Service" -Force
                }
                elseif ($Disable) {
                    if (Test-Path $keyPath) {
                        Remove-Item -Path $keyPath -Recurse -Force
                    }
                }
            }

            Add-LogEntry -Message "Syncro Safe Mode changed from $currentState to $desiredState" -Icon 'success' @summaryParams
        }
        else {
            Add-LogEntry -Message "Syncro Safe Mode changed from $currentState to $desiredState" -Icon 'settings' @summaryParams
        }
        Add-LogEntry -Message "Syncro Safe Mode changed from $currentState to $desiredState" -Icon 'success' @summaryParams

    }
    catch {

        Add-LogEntry -Message "An error occurred while setting Syncro Safe Mode: $_" -Icon 'error' @summaryParams
    }
}
#endregion

#region File: Set-SysVar.ps1
function Set-SysVar {
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$Value,

        [ValidateSet("String", "Boolean", "Number", "Array", "Hashtable")]
        [string]$Type = $null,

        [switch]$Add,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    if (-not (Assert-IsAdmin @summaryParams)) { return }

    $xmlPath = Initialize-VariableStore

    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($xmlPath)
    }
    catch {
        # Add-LogEntry -Message "Failed to load XML: $_" -Icon "Failure" -AddToBody
        return
    }

    # Auto-detect type if not provided
    if (-not $Type) {
        $Type = switch ($Value.GetType().Name) {
            "Boolean" { "Boolean" }
            "Int32" { "Number" }
            "Double" { "Number" }
            "String" { "String" }
            "Object[]" { "Array" }
            "Hashtable" { "Hashtable" }
            default { "String" }
        }
    }

    $serializedValue = switch ($Type) {
        "Array" { $Value | ConvertTo-Json -Compress }
        "Hashtable" { $Value | ConvertTo-Json -Compress }
        default { $Value.ToString() }
    }

    $existing = $xml.SelectSingleNode("//Variable[@Name='$Name']")

    if ($existing) {
        if ($Add) { return }
        $existing.SetAttribute("Type", $Type)
        $existing.SetAttribute("Value", $serializedValue)
        # Add-LogEntry -Message "Updated SysVar '$Name'" -Icon "SettingsOverride" -AddToBody
    }
    else {
        $newVar = $xml.CreateElement("Variable")
        $newVar.SetAttribute("Name", $Name)
        $newVar.SetAttribute("Type", $Type)
        $newVar.SetAttribute("Value", $serializedValue)
        $xml.DocumentElement.AppendChild($newVar) | Out-Null
        # Add-LogEntry -Message "Created SysVar '$Name'" -Icon "SettingsOverride" -AddToBody
    }

    try {
        $xml.Save($xmlPath)
    }
    catch {
        # Add-LogEntry -Message "Failed to save XML: $_" -Icon "Failure" -AddToBody
        return
    }

    $converted = switch ($Type) {
        "Boolean" { [System.Convert]::ToBoolean($Value) }
        "Number" { [int]$Value }
        "Array" { $Value }
        "Hashtable" { $Value }
        default { $Value }
    }

    Set-Variable -Name $Name -Value $converted -Scope Global
    return $converted
}
#endregion

#region File: Set-UpdateSettings.ps1
function Set-UpdateSettings {
    param (
        [ValidateSet('On', 'Off')]
        [string]$RestartNotificationState,
        
        [ValidateSet('On', 'Off')]
        [string]$GetMeUpToDateState,
        
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    if (-not $RestartNotificationState -and -not $GetMeUpToDateState) {
        Add-LogEntry "No update settings specified. Exiting function." -Icon 'warning' @summaryParams
        return
    }

    try {
        $RestartNotificationValue = if ($RestartNotificationState -eq 'On') { 1 } else { 0 }
        $GetMeUpToDateValue = if ($GetMeUpToDateState -eq 'On') { 1 } else { 0 }

        $Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"

        if (-not (Test-Path -Path $Path)) {
            New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX" -Name "Settings" -Force | Out-Null
        }

        $CurrentRestartNotificationValue = (Get-ItemProperty -Path $Path -Name RestartNotificationsAllowed2 -ErrorAction SilentlyContinue).RestartNotificationsAllowed2
        $CurrentRestartNotificationState = if ($CurrentRestartNotificationValue -eq 1) { 'On' } else { 'Off' }

        $CurrentGetMeUpToDateValue = (Get-ItemProperty -Path $Path -Name IsExpedited -ErrorAction SilentlyContinue).IsExpedited
        $CurrentGetMeUpToDateState = if ($CurrentGetMeUpToDateValue -eq 1) { 'On' } else { 'Off' }

        if ($RestartNotificationState) {
            Set-ItemProperty -Path $Path -Name RestartNotificationsAllowed2 -Value $RestartNotificationValue -Force
            $msg = if ($CurrentRestartNotificationValue -eq $RestartNotificationValue) {
                "🟢 Restart Notifications already set to ${RestartNotificationState} (value: ${RestartNotificationValue})"
            }
            else {
                "🔁 Restart Notifications changed from ${CurrentRestartNotificationState} (value: ${CurrentRestartNotificationValue}) to ${RestartNotificationState} (value: ${RestartNotificationValue})"
            }
            Add-LogEntry $msg @detailsParams
        }

        if ($GetMeUpToDateState) {
            Set-ItemProperty -Path $Path -Name IsExpedited -Value $GetMeUpToDateValue -Force
            $msg = if ($CurrentGetMeUpToDateValue -eq $GetMeUpToDateValue) {
                "🟢 Get Me Up To Date already set to ${GetMeUpToDateState} (value: ${GetMeUpToDateValue})"
            }
            else {
                "🔁 Get Me Up To Date changed from ${CurrentGetMeUpToDateState} (value: ${CurrentGetMeUpToDateValue}) to ${GetMeUpToDateState} (value: ${GetMeUpToDateValue})"
            }
            Add-LogEntry $msg @detailsParams
        }
    }
    catch {
        Add-LogEntry "An error occurred in Set-UpdateSettings: $_" -Icon 'error' @detailsParams
    }

    Add-LogEntry "End of Set-UpdateSettings" -Icon 'Completed' @summaryParams
}
#endregion

#region File: Should-MaskKey.ps1
function Should-MaskKey([string]$name, [string[]]$terms) {
                if ([string]::IsNullOrEmpty($name)) { return $false }
                $lname = $name.ToLowerInvariant()
                foreach ($t in $terms) {
                    if ([string]::IsNullOrEmpty($t)) { continue }
                    $lt = $t.ToLowerInvariant()
                    if ($lname -eq $lt -or $lname.Contains($lt)) { return $true }
                }
                return $false
            }
#endregion

#region File: Show-DrRecommendations.ps1
function Show-DrRecommendations {
    [CmdletBinding()]
    param (
        [string[]]$Buffer = @('Recommendations'),
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $path = $Global:DrRecommendations
    if (-not (Test-Path $path)) {
        Add-LogEntry -Message "Recommendation file not found.1" -Icon 'error' @summaryParams
        return
    }

    try {
        $recs = Get-Content -Path $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $recs = @($recs)

        $table = $recs | Select-Object @{Name = 'ID'; Expression = { $_.NumericId } },
        @{Name = 'Approved'; Expression = { if ($_.Approved) { '✅' } else { '❌' } } },
        @{Name = 'Executed'; Expression = { if ($_.Executed) { '🟢' } else { '⚪' } } },
        @{Name = 'Command'; Expression = { $_.CommandToRun } },
        @{Name = 'Message'; Expression = {
                if ($_.Message) {
                    if ($_.Message.Length -gt 60) { $_.Message.Substring(0, 57) + '...' } else { $_.Message }
                }
                else {
                    'No message'
                }
            }
        } | Format-Table -AutoSize | Out-String

        $formattedOutput = "`n" + $table.Trim()

        Add-LogEntry -Message "Current Recommendations:" -Icon 'list' @detailsParams
        Add-LogEntry -Message $formattedOutput -Icon 'System' @summaryParams
    }
    catch {
        Add-LogEntry -Message "Error displaying recommendations: $_" -Icon 'error' @summaryParams
    }
}
#endregion

#region File: Show-DrRecommendationsSummary.ps1
function Show-DrRecommendationsSummary {
    [CmdletBinding()]
    param (
        [switch] $OnlyUnexecuted,
        [switch] $OnlyApproved,
        [string[]]$Buffer = @('Recommendations'),
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $rawList = Get-DrRecommendations
    if (-not $rawList -or $rawList.Count -eq 0) {
        Write-Host "⚪ No recommendations found."
        return
    }

    $filtered = $rawList

    if ($OnlyUnexecuted) {
        $filtered = $filtered | Where-Object { -not $_.Executed }
    }

    if ($OnlyApproved) {
        $filtered = $filtered | Where-Object { $_.Approved }
    }

    if ($filtered.Count -eq 0) {
        Write-Host "⚪ No recommendations match the specified filters."
        return
    }

    foreach ($rec in $filtered | Sort-Object ExecutionOrder) {
        if ($rec -isnot [DrRecommendation]) {
            $obj = [DrRecommendation]::new()
            foreach ($prop in $rec.PSObject.Properties) {
                if ($obj.PSObject.Properties.Name -contains $prop.Name) {
                    $value = $prop.Value

                    # Handle datetime conversion
                    if ($prop.Name -in @('Timestamp', 'ExecutionTimestamp') -and $value -is [PSCustomObject] -and $value.DateTime) {
                        $obj.$($prop.Name) = [datetime]::Parse($value.DateTime)
                    }
                    else {
                        $obj.$($prop.Name) = $value
                    }
                }
            }
            $rec = $obj
        }

        Write-Host $rec.ToSummary()
    }
}
#endregion

#region File: Show-HiddenFiles.ps1
function Show-HiddenFiles {
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Enable')]
        [switch]$On,

        [Parameter(Mandatory = $true, ParameterSetName = 'Disable')]
        [switch]$Off,

        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        $Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        $current = Get-ItemProperty -Path $Path -Name Hidden, ShowSuperHidden

        $currentState = if ($current.Hidden -eq 1 -and $current.ShowSuperHidden -eq 1) { "On" } else { "Off" }
        $desiredState = if ($On) { "On" } elseif ($Off) { "Off" }

        $changed = $currentState -ne $desiredState
        $Icon = "Settings"

        if ($changed) {
            if ($desiredState -eq "On") {
                Set-ItemProperty -Path $Path -Name Hidden -Value 1 -Force
                Set-ItemProperty -Path $Path -Name ShowSuperHidden -Value 1 -Force
            }
            else {
                Set-ItemProperty -Path $Path -Name Hidden -Value 2 -Force
                Set-ItemProperty -Path $Path -Name ShowSuperHidden -Value 0 -Force
            }

            Add-LogEntry -Message "✅ Hidden files changed from $currentState to $desiredState" -Icon 'success' @summaryParams
        }
        else {
            Add-LogEntry -Message "ℹ️ Hidden files already set to $desiredState" -Icon 'settings' @summaryParams
        }



        if ($changed) {
            $shellApp = New-Object -ComObject Shell.Application
            $shellApp.Windows() | ForEach-Object { $_.Refresh() }
        }

        Write-Output $message
    }
    catch {
        Add-LogEntry -Message "An error occurred while changing hidden file settings: $_" -Icon 'error' @summaryParams

    }
}
#endregion

#region File: Show-StorageSensePresets.ps1
function Show-StorageSensePresets {
    $presets = @(
        [PSCustomObject]@{
            Name        = 'Default'
            Description = 'Your original default config — minimal cleanup, weekly schedule'
            Settings    = @{
                PrefSched               = 'Weekly'
                ClearTemporaryFiles     = $false
                ClearRecycler           = $false
                ClearDownloads          = $false
                AllowClearOneDriveCache = $false
                AddAllOneDrivelocations = $false
                ClearRecyclerDays       = 60
                ClearDownloadsDays      = 0
                ClearOneDriveCacheDays  = 60
            }
        }
        [PSCustomObject]@{
            Name        = 'Aggressive'
            Description = 'Frequent cleanup of all areas, including OneDrive, with short retention'
            Settings    = @{
                PrefSched               = 'Daily'
                ClearTemporaryFiles     = $true
                ClearRecycler           = $true
                ClearDownloads          = $true
                AllowClearOneDriveCache = $true
                AddAllOneDrivelocations = $true
                ClearRecyclerDays       = 14
                ClearDownloadsDays      = 14
                ClearOneDriveCacheDays  = 14
            }
        }
        [PSCustomObject]@{
            Name        = 'Balanced'
            Description = 'Weekly cleanup of temp files and Recycle Bin, longer retention'
            Settings    = @{
                PrefSched               = 'Weekly'
                ClearTemporaryFiles     = $true
                ClearRecycler           = $true
                ClearDownloads          = $false
                AllowClearOneDriveCache = $false
                AddAllOneDrivelocations = $false
                ClearRecyclerDays       = 30
                ClearDownloadsDays      = 0
                ClearOneDriveCacheDays  = 30
            }
        }
        [PSCustomObject]@{
            Name        = 'Minimal'
            Description = 'Only schedule enabled, no cleanup'
            Settings    = @{
                PrefSched               = 'Monthly'
                ClearTemporaryFiles     = $false
                ClearRecycler           = $false
                ClearDownloads          = $false
                AllowClearOneDriveCache = $false
                AddAllOneDrivelocations = $false
                ClearRecyclerDays       = 60
                ClearDownloadsDays      = 0
                ClearOneDriveCacheDays  = 60
            }
        }
        [PSCustomObject]@{
            Name        = 'OneDriveOnly'
            Description = 'Focused on OneDrive cache cleanup'
            Settings    = @{
                PrefSched               = 'Weekly'
                ClearTemporaryFiles     = $false
                ClearRecycler           = $false
                ClearDownloads          = $false
                AllowClearOneDriveCache = $true
                AddAllOneDrivelocations = $true
                ClearRecyclerDays       = 60
                ClearDownloadsDays      = 0
                ClearOneDriveCacheDays  = 30
            }
        }
        [PSCustomObject]@{
            Name        = 'DownloadsOnly'
            Description = 'Only clean Downloads folder every month'
            Settings    = @{
                PrefSched               = 'Monthly'
                ClearTemporaryFiles     = $false
                ClearRecycler           = $false
                ClearDownloads          = $true
                AllowClearOneDriveCache = $false
                AddAllOneDrivelocations = $false
                ClearRecyclerDays       = 60
                ClearDownloadsDays      = 30
                ClearOneDriveCacheDays  = 60
            }
        }
        [PSCustomObject]@{
            Name        = 'Off'
            Description = 'Disables all cleanup and Storage Sense scheduling'
            Settings    = @{
                PrefSched               = 'LowDiskspace'
                ClearTemporaryFiles     = $false
                ClearRecycler           = $false
                ClearDownloads          = $false
                AllowClearOneDriveCache = $false
                AddAllOneDrivelocations = $false
                ClearRecyclerDays       = 0
                ClearDownloadsDays      = 0
                ClearOneDriveCacheDays  = 0
            }
        }
    )

    foreach ($preset in $presets) {
        Write-Host "`nPreset: $($preset.Name)" -ForegroundColor Cyan
        Write-Host "Description: $($preset.Description)"
        $preset.Settings.GetEnumerator() | ForEach-Object {
            Write-Host ("  {0,-25}: {1}" -f $_.Key, $_.Value)
        }
    }
}
#endregion

#region File: Start-ChkDsk.ps1
function Start-ChkDsk {
    param (
        [Parameter(Mandatory = $false)]
        [string]$driveLetter = (Get-PSDrive -PSProvider FileSystem | Where-Object {
                $_.Root -eq [System.IO.Path]::GetPathRoot([System.Environment]::SystemDirectory)
            }).Root.TrimEnd('\'),
        [switch]$Repair = $false,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    Log-Invocation -IncludeParameters @detailsParams 
    #if ($Repair) {
    if (-not (Assert-IsAdmin @summaryParams)) { return }
    #}


    $outputFile = Join-Path $Global:DrTemp "chkdsk_output.txt"
    $errorFile = Join-Path $Global:DrTemp "chkdsk_error.txt"
    $argument = if ($Repair) { "/r" } else { "/scan" }
    $argumentList = @($driveLetter, $argument)
    $command = "chkdsk.exe $($argumentList -join ' ')"

    #Add-LogEntry -Message "Command-line: $command" @detailsParams -Icon 'systeminit'

    try {
        $process = Start-Process -FilePath "chkdsk.exe" -ArgumentList $argumentList -NoNewWindow `
            -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -PassThru
        $process.WaitForExit()

        $output = Get-DrContent -Path $outputFile 
        $errorOutput = Get-DrContent -Path $errorFile 

        if ($output) {
            Add-LogEntry -Message "CHKDSK result:`n$output" -Hidden -Subject "CHKDSK result" -Icon 'details'
        }

        # Match Start-SFC behavior: log error output only if it's non-empty
        if ($errorOutput) {
            Add-LogEntry -Message "Error Output:`n$errorOutput" -Hidden -Icon 'error' -Buffer 'CHKDSK Errorlog' -FlushBuffer
        }

        # Pattern matching
        if ($output -imatch "Windows has scanned the file system and found no problems") {
            Add-LogEntry -Message "No file system problems found." -Icon 'ok' @summaryParams
        }
        elseif ($output -imatch "Windows made corrections to the file system") {
            Add-LogEntry -Message "File system errors found and corrected." -Icon 'repair' @summaryParams
        }
        elseif ($output -imatch "Failed to transfer logged messages to the event log") {
            Add-LogEntry -Message "CHKDSK completed but failed to log results to the event log." -Icon 'warning' @summaryParams
        }
        else {
            Add-LogEntry -Message "chkdsk output did not match known patterns."  -Icon 'warning' @summaryParams
        }
    }
    catch {
        Add-LogEntry -Message "Failed to run CHKDSK: $_" @summaryParams -Icon 'error'
    }

    #Add-LogEntry -Message "End of Start-ChkDsk - $command" -Icon 'jobend' @summaryParams
}
#endregion

#region File: Start-DrTimer.ps1
function Start-DrTimer {
    param(
        [string]$Name,
        [switch]$Unique
    )
    Load-DrTimers

    if ($Name -eq "*ALL") {
        foreach ($key in $Global:DrTimers.Keys) {
            if ($Global:DrTimers[$key].Status -ne 'Running') {
                $Global:DrTimers[$key].StartTime = (Get-Date).ToString("o")
                $Global:DrTimers[$key].Status = 'Running'
                Add-DrTimerMessage -Name $key -Action 'Start' -Message "Timer started."
            }
        }
        Save-DrTimers
        return
    }

    if ($Unique) {
        $baseName = if ($Global:DrSessionId) { $Global:DrSessionId } else { "session" }
        $counter = 1
        while ($Global:DrTimers.ContainsKey("$baseName-$counter")) {
            $counter++
        }
        $Name = "$baseName-$counter"
    }

    if (-not $Global:DrTimers[$Name]) {
        $Global:DrTimers[$Name] = @{
            StartTime     = (Get-Date).ToString("o")
            Elapsed       = 0
            Status        = 'Running'
            AddedToTicket = $false
            Messages      = @()
        }
    }
    else {
        if ($Global:DrTimers[$Name].Status -ne 'Running') {
            $Global:DrTimers[$Name].StartTime = (Get-Date).ToString("o")
            $Global:DrTimers[$Name].Status = 'Running'
        }
    }

    Add-DrTimerMessage -Name $Name -Action 'Start' -Message "Timer started."
    Save-DrTimers
}
#endregion

#region File: Start-SFC.ps1
function Start-SFC {
    param(
        [switch]$ScanNow = $false,
        [string[]]$Buffer = "Start-SFC",
        #[string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    Log-Invocation -IncludeParameters @detailsParams

    $argument = if ($ScanNow) { "/scannow" } else { "/verifyonly" }
    $command = "sfc.exe $argument"
    $iBuffer = $command
    if (-not (Assert-IsAdmin @summaryParams)) { return }


    # Define the output and error files
    #Write-Host "📁 Global:DrTemp $Global:DrTemp"
    $outputFile = Join-Path $Global:DrTemp "sfc_output.txt"
    $errorFile = Join-Path $Global:DrTemp "sfc_error.txt"
    #Write-Host "📄 Output File: $outputFile"
    #Write-Host "📄 Error File: $errorFile"


    #Add-LogEntry -Message "Command-line: $command" -Buffer $iBuffer -Icon 'systeminit'

    try {
        $process = Start-Process -FilePath "sfc.exe" -ArgumentList $argument -NoNewWindow -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -PassThru
        $process.WaitForExit()

        $Output = Get-Content -Path $outputFile -Raw -Encoding Unicode
        $ErrorOutput = Get-Content -Path $errorFile -Raw -Encoding Unicode
        if ($ErrorOutput) {
            Add-LogEntry -Message "Error Output:`n$ErrorOutput" -Hidden -Icon 'warning' -Subject "ErrorLog" 
        }

        Add-LogEntry -Message "SFC Result:`n$Output" -Icon 'file' -Hidden -Subject "SFC Output" 

        if ($Output.Trim() -imatch "Windows Resource Protection did not find any integrity violations.") {
            Add-LogEntry -Message "No integrity violations found." -Icon 'success' @summaryParams
        } 
        elseif ($Output.Trim() -imatch "Windows Resource Protection found integrity violations.") {
            Add-DrRecommendation -Message "Integrity violations found." -CommandToRun "Start-SFC -ScanNow" 
            Add-LogEntry -Message "Integrity violations found. Run sfc /scannow to attempt repairs." -Icon 'alert' @summaryParams
        }
        elseif ($Output.Trim() -imatch "There is a system repair pending which requires reboot to complete.") {
            Add-DrRecommendation -Message "Integrity violations found." -CommandToRun "Restart-DrComputer -Reason 'Pending repair'" -SuggestedAction "Re-start the computer."
            Add-LogEntry -Message "There is a system repair pending which requires reboot to complete." -Icon 'alert' @summaryParams
        }
        elseif ($Output.Trim() -imatch "Windows Resource Protection found corrupt files and successfully repaired them.") {
            Add-DrRecommendation -Message "Corrupt files found and successfully repaired." -CommandToRun "Restart-DrComputer -Reason 'Pending repair'" -SuggestedAction "Re-start the computer."
            Add-LogEntry -Message "Corrupt files found and successfully repaired." -Icon 'repair' @summaryParams
        }
    }
    catch {
        -Buffer $iBuffer
        Add-LogEntry -Message "Failed to run SFC: $_" -Icon 'error' @summaryParams
    }

    #Add-LogEntry -Message "End of Start-SFC - $command" -Icon 'jobend' @summaryParams
}
#endregion

#region File: Start-SpeedTest.ps1
Function Start-SpeedTest {
    param (
        [int]$Loops = 1,
        [string[]]$Buffer = 'Speed-Test',
        [switch]$FlushBuffer
    )
        
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details
    
    # Log the start of the process
    #Add-LogEntry -Message "🚀 Start Run-SpeedTest -Loops $Loops" -AddToBody
    Log-Invocation -IncludeParameters @detailsParams  

    # Construct the path to Speedtest.exe
    #$SpeedTestPath = Join-Path -Path "C:\DrOsdicks\toolbox\" -ChildPath "Speedtest\Speedtest.exe"
    $SpeedTestPath = Locate-File -Path $Global:DrToolbox -Name "Speedtest.exe"

    # Check if Speedtest.exe exists
    if (-Not (Test-Path $SpeedTestPath)) {
        Write-Error "❌ Speedtest.exe not found at $SpeedTestPath"
        Add-LogEntry -Message "❌ Speedtest.exe not found at $SpeedTestPath" @summaryParams
        return
    }

    $results = @()
    $numericResults = @()

    for ($i = 1; $i -le $Loops; $i++) {
        try {
            # Run the speed test
            $result = & $SpeedTestPath --accept-license --accept-gdpr --format=json

            # Parse the JSON output
            $json = $result | ConvertFrom-Json

            # Extract the relevant information
            $downloadSpeed = $json.download.bandwidth / 125000
            $uploadSpeed = $json.upload.bandwidth / 125000
            $ping = $json.ping.latency

            # Store the results in an array
            $results += [PSCustomObject]@{
                TestNumber    = $i
                DownloadSpeed = "$downloadSpeed Mbps"
                UploadSpeed   = "$uploadSpeed Mbps"
                Ping          = "$ping ms"
            }

            # Store numeric results for averaging
            $numericResults += [PSCustomObject]@{
                DownloadSpeed = $downloadSpeed
                UploadSpeed   = $uploadSpeed
                Ping          = $ping
            }

        }
        catch {
            #Write-Error "⚠️ An error occurred during test ${i}: $_"
            Add-LogEntry -Message "An error occurred during test ${i}: $_" -icon 'error'  @detailsParams 
        }
    }

    if ($results) {
        Add-LogEntry -Message "Test Summary:" -Icon 'summary' @detailsParams 
    }

    # Calculate the averages
    $averageDownloadSpeed = ($numericResults | Measure-Object -Property DownloadSpeed -Average).Average
    $averageUploadSpeed = ($numericResults | Measure-Object -Property UploadSpeed -Average).Average
    $averagePing = ($numericResults | Measure-Object -Property Ping -Average).Average

    # Add the averages to the results
    $results += [PSCustomObject]@{
        TestNumber    = "Average"
        DownloadSpeed = "$averageDownloadSpeed Mbps"
        UploadSpeed   = "$averageUploadSpeed Mbps"
        Ping          = "$averagePing ms"
    }

    # Log the emoji-enhanced summary
    foreach ($r in $results) {
        $icon = if ($r.TestNumber -eq "Average") { "📈" } else { "🧪" }
        Add-LogEntry "$icon Test $($r.TestNumber): ⬇️ $($r.DownloadSpeed), ⬆️ $($r.UploadSpeed), 🕒 $($r.Ping)" @detailsParams 
    }

    Add-LogEntry "End of Run-SpeedTest" @summaryParams -Icon 'jobend' -Subject 'Speedtest results'
}
#endregion

#region File: Start-SpeedTest0.ps1
Function Start-SpeedTest0 {
    param (
        [int]$Loops = 1,
        [string[]]$Buffer = @('SpeedTest'),
        [switch]$FlushBuffer
    )
    $sBuffer = $Global:DrLogSummaryBuffer
    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details
    
    # Log the start of the process
    #Add-LogEntry -Message "🚀 Start Run-SpeedTest -Loops $Loops" -AddToBody
    Log-Invocation -IncludeParameters @detailsParams  

    # Construct the path to Speedtest.exe
    #$SpeedTestPath = Join-Path -Path "C:\DrOsdicks\toolbox\" -ChildPath "Speedtest\Speedtest.exe"
    $SpeedTestPath = Locate-File -Path $Global:DrToolbox -Name "Speedtest.exe"

    # Check if Speedtest.exe exists
    if (-Not (Test-Path $SpeedTestPath)) {
        Write-Error "❌ Speedtest.exe not found at $SpeedTestPath"
        Add-LogEntry -Message "❌ Speedtest.exe not found at $SpeedTestPath" @summaryParams
        return
    }

    $results = @()
    $numericResults = @()

    for ($i = 1; $i -le $Loops; $i++) {
        try {
            # Run the speed test
            $result = & $SpeedTestPath --accept-license --accept-gdpr --format=json

            # Parse the JSON output
            $json = $result | ConvertFrom-Json

            # Extract the relevant information
            $downloadSpeed = $json.download.bandwidth / 125000
            $uploadSpeed = $json.upload.bandwidth / 125000
            $ping = $json.ping.latency

            # Store the results in an array
            $results += [PSCustomObject]@{
                TestNumber    = $i
                DownloadSpeed = "$downloadSpeed Mbps"
                UploadSpeed   = "$uploadSpeed Mbps"
                Ping          = "$ping ms"
            }

            # Store numeric results for averaging
            $numericResults += [PSCustomObject]@{
                DownloadSpeed = $downloadSpeed
                UploadSpeed   = $uploadSpeed
                Ping          = $ping
            }

        }
        catch {
            #Write-Error "⚠️ An error occurred during test ${i}: $_"
            Add-LogEntry -Message "An error occurred during test ${i}: $_" -icon 'error'  @detailsParams 
        }
    }

    if ($results) {
        Add-LogEntry -Message "📋 Test Summary:" -Icon 'summary' @detailsParams 
    }

    # Calculate the averages
    $averageDownloadSpeed = ($numericResults | Measure-Object -Property DownloadSpeed -Average).Average
    $averageUploadSpeed = ($numericResults | Measure-Object -Property UploadSpeed -Average).Average
    $averagePing = ($numericResults | Measure-Object -Property Ping -Average).Average

    # Add the averages to the results
    $results += [PSCustomObject]@{
        TestNumber    = "Average"
        DownloadSpeed = "$averageDownloadSpeed Mbps"
        UploadSpeed   = "$averageUploadSpeed Mbps"
        Ping          = "$averagePing ms"
    }

    # Log the emoji-enhanced summary
    foreach ($r in $results) {
        $icon = if ($r.TestNumber -eq "Average") { "📈" } else { "🧪" }
        Add-LogEntry "$icon Test $($r.TestNumber): ⬇️ $($r.DownloadSpeed), ⬆️ $($r.UploadSpeed), 🕒 $($r.Ping)" @detailsParams 
    }

    Add-LogEntry "End of Run-SpeedTest" @summaryParams -Icon 'jobend' -Subject 'Speedtest results'
}
#endregion

#region File: Stop-DrTimer.ps1
function Stop-DrTimer {
    param([string]$Name)
    Load-DrTimers
    $targets = if ($Name -eq "*ALL") { $Global:DrTimers.Keys } else { @($Name) }

    foreach ($t in $targets) {
        if (-not $Global:DrTimers[$t]) { continue }
        $timer = $Global:DrTimers[$t]
        if ($timer.Status -eq 'Running') {
            $timer.Elapsed += (New-TimeSpan -Start ([DateTime]$timer.StartTime) -End (Get-Date)).TotalSeconds
            $timer.Status = 'Stopped'
            Add-DrTimerMessage -Name $t -Action 'Stop' -Message "Timer stopped."
        }
        elseif ($timer.Status -eq 'Paused') {
            $timer.Status = 'Stopped'
            Add-DrTimerMessage -Name $t -Action 'Stop' -Message "Timer stopped from paused state."
        }
    }
    Save-DrTimers
}
#endregion

#region File: Stop-Processes.ps1
function Stop-Processes {
    param (
        [Parameter(Position = 0)]
        [string[]]$processesToTerminate
    )

    if (-not $processesToTerminate) {
        Add-LogEntry "⚠️ No processes specified to terminate." -AddBody
        return
    }

    # Log the processes to be terminated
    $msg = "Processes to terminate: $($processesToTerminate -join ', ')"
    Add-LogEntry $msg -AddToBody

    $terminatedCount = 0
    $skippedCount = 0

    foreach ($processName in $processesToTerminate) {
        try {
            $processRunning = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($processRunning) {
                # Terminate the process
                Stop-Process -Name $processName -Force
                $msg = "🟢 ${processName} terminated successfully."
                Add-LogEntry $msg -AddToBody
                $terminatedCount++
            }
            else {
                $msg = "⚠️ ${processName} is not running."
                Add-LogEntry $msg -AddToBody
                $skippedCount++
            }
        }
        catch {
            $msg = "❌ Error terminating ${processName}: $($_.Exception.Message)"
            Add-LogEntry $msg -AddToBody
            $skippedCount++
        }
    }

    # Log the completion of the process termination
    $msg = "✅ $terminatedCount processes terminated, ⚠️ $skippedCount processes could not be terminated."
    Add-LogEntry $msg -AddBody
}
#endregion

#region File: Sync-DebugSymbols.ps1
function Sync-DebugSymbols {
    [CmdletBinding()]
    param(
        [string]$CachePath = (Join-Path -Path $Global:DrToolbox -ChildPath 'symbols'),
        [string]$SymbolServer = 'https://msdl.microsoft.com/download/symbols',
        [string[]]$Modules = @('ntoskrnl.exe', 'hal.dll', 'ntdll.dll', 'win32k.sys'),
        [string[]]$ImagePaths = @('C:\Windows', 'C:\Windows\System32', 'C:\Windows\System32\drivers'),
        [string]$DebuggerRoot,
        [switch]$PurgeKernel,
        [int]$TimeoutSeconds = 60
    )

    $valErrors = New-Object System.Collections.Generic.List[string]
    $downloaded = 0
    $failed = 0

    function Resolve-ModulePath([string]$name, [string[]]$searchPaths) {
        if ([System.IO.Path]::IsPathRooted($name) -and (Test-Path -LiteralPath $name)) {
            return (Resolve-Path -LiteralPath $name).Path
        }
        foreach ($p in $searchPaths) {
            $candidate = Join-Path $p $name
            if (Test-Path -LiteralPath $candidate) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
        return $null
    }

    try {
        Add-LogEntry "Starting Sync-DebugSymbols. CachePath='${CachePath}' SymbolServer='${SymbolServer}' Timeout=${TimeoutSeconds}" -AddToBody

        # --- Locate symchk.exe via Debugging Tools (WinDbg Classic) ---
        $symchkCandidates = @()
        $debuggersRoot = $null

        if ($DebuggerRoot) {
            # Caller specified a root; honor it
            $debuggersRoot = $DebuggerRoot
        }
        else {
            # Use your helper to find (or install) WinDbg Classic and derive the root
            try {
                $windbgPath = Find-OrInstall-WinDbg
                if ($windbgPath) {
                    # windbg.exe typically lives under ...\Windows Kits\10\Debuggers\<arch>\windbg.exe
                    # We will probe the same folder and common sibling arch folders for symchk.exe
                    $debuggersRoot = Split-Path -Parent $windbgPath
                }
            }
            catch {
                Add-LogEntry ("Find-OrInstall-WinDbg error: " + $_.Exception.Message) -AddToBody
            }
        }

        if ($debuggersRoot) {
            # Same folder as windbg.exe first
            $symchkCandidates += (Join-Path $debuggersRoot 'symchk.exe')

            # Also probe common sibling arch subfolders relative to the returned folder
            foreach ($arch in @('x64', 'arm64', 'x86')) {
                $symchkCandidates += (Join-Path (Join-Path (Split-Path -Parent $debuggersRoot) $arch) 'symchk.exe')
            }
        }

        # Fallback to standard SDK locations (kept for completeness)
        $symchkCandidates += (Join-Path ${env:ProgramFiles}      'Windows Kits\10\Debuggers\x64\symchk.exe')
        $symchkCandidates += (Join-Path ${env:ProgramFiles}      'Windows Kits\10\Debuggers\arm64\symchk.exe')
        $symchkCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\symchk.exe')
        $symchkCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\arm64\symchk.exe')
        $symchkCandidates += (Join-Path ${env:ProgramFiles}      'Windows Kits\10\Debuggers\x86\symchk.exe')
        $symchkCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x86\symchk.exe')

        $symchkPath = $symchkCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -First 1

        if (-not $symchkPath) {
            $valErrors.Add('symchk.exe not found. Install Debugging Tools for Windows (Win10/11 SDK) or specify -DebuggerRoot.')
        }
        else {
            Add-LogEntry "symchk.exe: ${symchkPath}" -AddToBody
        }
        # --- End symchk location ---

        # Cache path
        if (-not $CachePath) {
            $valErrors.Add('CachePath is empty.')
        }
        else {
            try {
                if (-not (Test-Path -LiteralPath $CachePath)) {
                    New-Item -ItemType Directory -Path $CachePath -Force | Out-Null
                    Add-LogEntry "Created cache path: ${CachePath}" -AddToBody
                }
            }
            catch {
                $valErrors.Add("Could not create cache path: ${CachePath} | $($_.Exception.Message)")
            }
        }

        # Validate symbol server URL
        if (-not $SymbolServer -or $SymbolServer -notmatch '^https?://') {
            $valErrors.Add('SymbolServer must be a valid http/https URL.')
        }

        # Image paths
        $imagePathList = @()
        foreach ($ip in $ImagePaths) {
            if ($ip -and (Test-Path -LiteralPath $ip)) {
                $imagePathList += (Resolve-Path -LiteralPath $ip).Path
            }
        }
        if ($imagePathList.Count -eq 0) {
            $valErrors.Add('No valid entries in ImagePaths.')
        }
        else {
            Add-LogEntry ("Image paths: " + ($imagePathList -join ';')) -AddToBody
        }

        # Resolve modules
        $resolvedModules = @()
        foreach ($m in $Modules) {
            $rp = Resolve-ModulePath -name $m -searchPaths $imagePathList
            if ($rp) {
                $resolvedModules += $rp
            }
            else {
                $valErrors.Add("Module not found: ${m} (searched: $($imagePathList -join ';'))")
            }
        }
        if ($resolvedModules.Count -eq 0) {
            $valErrors.Add('No modules resolved.')
        }
        else {
            Add-LogEntry ("Modules to fetch: " + ($resolvedModules -join ', ')) -AddToBody
        }

        # Stop early if validation failed
        if ($valErrors.Count -gt 0) {
            foreach ($e in $valErrors) { Add-LogEntry $e -AddToBody }
            Add-LogEntry "Sync-DebugSymbols: validation failed." -AddBody

            return [pscustomobject]@{
                Success      = $false
                CachePath    = $CachePath
                SymbolServer = $SymbolServer
                Modules      = $Modules
                Errors       = @($valErrors)
            }
        }

        # Optional purge
        if ($PurgeKernel) {
            try {
                $purgePatterns = @('ntoskrnl*', 'ntkrnlmp*')
                $purged = $false

                foreach ($pat in $purgePatterns) {
                    Get-ChildItem -LiteralPath $CachePath -Recurse -ErrorAction Stop |
                    Where-Object { $_.Name -like $pat } |
                    ForEach-Object {
                        try {
                            if ($_.PSIsContainer) {
                                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                            }
                            else {
                                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                            }
                            $purged = $true
                            Add-LogEntry "Purged cached: $($_.FullName)" -AddToBody
                        }
                        catch {
                            Add-LogEntry ("Purge failed: " + $_.Exception.Message) -AddToBody
                        }
                    }
                }

                if (-not $purged) {
                    Add-LogEntry "PurgeKernel: nothing to purge." -AddToBody
                }
            }
            catch {
                Add-LogEntry ("PurgeKernel error: " + $_.Exception.Message) -AddToBody
            }
        }

        # Build SRV path + env vars
        $srvPath = "srv*${CachePath}*${SymbolServer}"

        $prevEnv = @{
            _NT_SYMBOL_PATH           = $env:_NT_SYMBOL_PATH
            _NT_SYMBOL_CACHE_PATH     = $env:_NT_SYMBOL_CACHE_PATH
            _NT_EXECUTABLE_IMAGE_PATH = $env:_NT_EXECUTABLE_IMAGE_PATH
            _NT_SYMBOL_TIMEOUT        = $env:_NT_SYMBOL_TIMEOUT
        }

        $env:_NT_SYMBOL_PATH = $srvPath
        $env:_NT_SYMBOL_CACHE_PATH = $CachePath
        $env:_NT_EXECUTABLE_IMAGE_PATH = ($imagePathList -join ';')
        $env:_NT_SYMBOL_TIMEOUT = [Math]::Max(5, $TimeoutSeconds)

        Add-LogEntry "SRV path: ${srvPath}" -AddToBody

        # Run symchk for each module
        foreach ($file in $resolvedModules) {
            Add-LogEntry "Fetching symbols: ${file}" -AddToBody

            try {
                $output = & $symchkPath $file '/s' $srvPath '/v' 2>&1
                $ec = $LASTEXITCODE

                if ($ec -eq 0) {
                    $downloaded++
                    Add-LogEntry "Symbols OK: ${file}" -AddToBody
                }
                else {
                    $failed++
                    Add-LogEntry "symchk exit ${ec} for ${file}" -AddToBody
                }

                $tail = ($output | Select-Object -Last 20) -join "`n"
                if ($tail) {
                    Add-LogEntry ("symchk tail [${file}]:`n" + $tail) -AddToBody
                }
            }
            catch {
                $failed++
                Add-LogEntry ("symchk error for ${file} | " + $_.Exception.Message) -AddToBody
            }
        }

        # Restore env vars
        $env:_NT_SYMBOL_PATH = $prevEnv._NT_SYMBOL_PATH
        $env:_NT_SYMBOL_CACHE_PATH = $prevEnv._NT_SYMBOL_CACHE_PATH
        $env:_NT_EXECUTABLE_IMAGE_PATH = $prevEnv._NT_EXECUTABLE_IMAGE_PATH
        $env:_NT_SYMBOL_TIMEOUT = $prevEnv._NT_SYMBOL_TIMEOUT

        Add-LogEntry "Sync-DebugSymbols: ok=${downloaded} failed=${failed} cache='${CachePath}'." -AddBody

        return [pscustomobject]@{
            Success          = ($failed -eq 0)
            CachePath        = $CachePath
            SymbolServer     = $SymbolServer
            ModulesRequested = $Modules
            ModulesResolved  = $resolvedModules
            Downloaded       = $downloaded
            Failed           = $failed
        }
    }
    catch {
        Add-LogEntry ("Unhandled: " + $_.Exception.Message) -AddBody

        return [pscustomobject]@{
            Success      = $false
            CachePath    = $CachePath
            SymbolServer = $SymbolServer
            Modules      = $Modules
            Error        = $_.Exception.Message
        }
    }
}
#endregion

#region File: Test-CPUTemperature.ps1
function Test-CPUTemperature {
    param (
        [double]$ThresholdCelsius = 80,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    Log-Invocation -IncludeParameters @detailsParams 

    $cpuTemps = Get-CPUTemperature

    foreach ($k in $forward.Keys) { if ($k -ne 'Icon') { $forward_NoIcon[$k] = $forward[$k] } }
    $iBuffer = 'CPU Temp'
    # Reference ranges: leave AddToBody alone (no splat; explicit @detailsParams)
    Add-LogEntry -Message "CPU Temperature Reference Ranges:" -Icon 'summary' -Buffer $iBuffer
    Add-LogEntry -Message "Idle / Low Load: 30–50 °C (86–122 °F)" -Icon 'cooling' -Buffer $iBuffer
    Add-LogEntry -Message "Moderate Load: 50–70 °C (122–158 °F)"  -Icon 'thermometer' -Buffer $iBuffer
    Add-LogEntry -Message "High Load: 70–85 °C (158–185 °F)"      -Icon 'thermometer' -Buffer $iBuffer
    Add-LogEntry -Message "Too Hot: >85 °C (>185 °F)"             -Icon 'heat'  -Buffer $iBuffer

    foreach ($temp in $cpuTemps) {
        # Clean and parse Celsius value
        $cleanCelsius = ($temp.Celsius -replace '[^\d\.\-]', '')
        if (-not $cleanCelsius -or -not ($cleanCelsius -as [double])) {
            # Leave AddToBody alone
            Add-LogEntry -Message ("Invalid or missing temperature from {0}: '{1}'. Defaulting to 0 °C." -f $temp.Name, $temp.Celsius) -Icon 'warning' -Buffer $iBuffer
            $numericCelsius = 0
        }
        else {
            $numericCelsius = [double]$cleanCelsius
        }

        # Skip clearly invalid readings (absolute zero or lower)
        if ($numericCelsius -le -273.14) {
            # Leave AddToBody alone
            Add-LogEntry -Message ("Skipping invalid temperature reading from {0}: {1}" -f $temp.Name, $temp.Celsius) -Icon 'warning'  -Buffer $iBuffer
            continue
        }

        # Pick icon based on range
        $rangeIcon = switch ($numericCelsius) {
            { $_ -lt 50 } { 'cooling'; break }
            { $_ -ge 50 -and $_ -lt 70 } { 'thermometer'; break }
            { $_ -ge 70 -and $_ -le 85 } { 'heat'; break }
            default { 'heat' }
        }

        # Per-sensor lines: leave AddToBody alone
        Add-LogEntry -Message ("Name: {0}" -f $temp.Name)             -Icon 'cputemp'     -Buffer $iBuffer
        Add-LogEntry -Message ("Celsius: {0}" -f $temp.Celsius)       -Icon $rangeIcon    -Buffer $iBuffer
        Add-LogEntry -Message ("Fahrenheit: {0}" -f $temp.Fahrenheit) -Icon $rangeIcon    -Buffer $iBuffer

        # Final status per sensor: these were -AddBody previously → use sanitized splat to avoid -Icon collision
        if ($numericCelsius -gt $ThresholdCelsius) {
            Add-LogEntry -Message ("Warning: CPU temperature is too high! ({0})" -f $temp.Celsius) -Icon 'heat' -Buffer $iBuffer -FlushBuffer
            Add-LogEntry -Message ("Warning: CPU temperature is too high! ({0})" -f $temp.Celsius) -Icon 'heat' @summaryParams
        }
        else {
            Add-LogEntry -Message ("CPU temperature is within normal range. ({0})" -f $temp.Celsius) -Icon 'cooling' -Buffer $iBuffer -FlushBuffer
            Add-LogEntry -Message ("CPU temperature is within normal range. ({0})" -f $temp.Celsius) -Icon 'cooling' @summaryParams
        }
    }
}
#endregion

#region File: Test-DrRecommendation.ps1
Function Test-DrRecommendation {
    [CmdletBinding()]
    param ()

    Add-DrRecommendation -Message "No message" -SuggestedAction "Clear the screen" -Severity Warning -CommandToRun "clear-host"
    Add-DrRecommendation -Message "No message" -SuggestedAction "Check system variables" -Severity Warning -CommandToRun "get-sysvarlist"
    Add-DrRecommendation -Message "No message" -SuggestedAction "Check anti-virus" -Severity Warning -CommandToRun "Get-AVProducts"
    Add-DrRecommendation -Message "No message" -SuggestedAction "What version of windows?" -Severity Warning -CommandToRun "Get-WindowsVersion"
    write-host $Global:DrRecommendations
    #return Test-DrRecommendation
}
#endregion

#region File: Test-IsElevated.ps1
function Test-IsElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        if (-not ('DrToken' -as [type])) {
            $null = Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DrToken {
    private const UInt32 TOKEN_QUERY = 0x0008;
    private const int TokenElevation = 20;

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_ELEVATION { public int TokenIsElevated; }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, UInt32 DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern bool GetTokenInformation(
        IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation,
        int TokenInformationLength, out int ReturnLength);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr hObject);

    public static bool IsElevated() {
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, out token)) return false;

            int size = Marshal.SizeOf(typeof(TOKEN_ELEVATION));
            IntPtr p = Marshal.AllocHGlobal(size);
            try {
                int retLen;
                if (!GetTokenInformation(token, TokenElevation, p, size, out retLen)) return false;
                TOKEN_ELEVATION elev = (TOKEN_ELEVATION)Marshal.PtrToStructure(p, typeof(TOKEN_ELEVATION));
                return elev.TokenIsElevated != 0;
            }
            finally { Marshal.FreeHGlobal(p); }
        }
        finally { if (token != IntPtr.Zero) CloseHandle(token); }
    }
}
'@ -ErrorAction Stop
        }

        return [DrToken]::IsElevated()
    }
    catch {
        return $false
    }
}
#endregion

#region File: Test-PendingRestart.ps1
function Test-PendingRestart {
    param (
        [switch]$DeleteEntries,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $pendingReboot = $false
    $reasons = @()

    # Define registry keys and properties to check
    $checks = @(
        @{ Key = "HKLM:\SOFTWARE\Microsoft\Updates"; Property = "UpdateExeVolatile" },
        @{ Key = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"; Property = "PendingFileRenameOperations" },
        @{ Key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"; Property = "RebootRequired" },
        @{ Key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"; Property = "RebootPending" },
        @{ Key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"; Property = "RebootInProgress" },
        @{ Key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"; Property = "PackagesPending" }
    )

    foreach ($check in $checks) {
        $key = $check.Key
        $property = $check.Property
        $propertyPath = "$key\$property"

        if (Test-Path $propertyPath) {
            $pendingReboot = $true
            $reasons += $propertyPath
            Add-LogEntry "Pending reboot detected: $propertyPath" -Icon 'info' @detailsParams

            if ($DeleteEntries) {
                Remove-ItemProperty -Path $key -Name $property -ErrorAction SilentlyContinue
                Add-LogEntry "Deleted entry: $propertyPath" @detailsParams -Icon 'deleted'
            }
        }
    }

    Add-LogEntry "📄 End of registry check." @detailsParams

    if (-not $pendingReboot) {
        Add-LogEntry "No pending reboot detected." -Icon 'success' @summaryParams
    }
    else {
        Add-LogEntry "One or more indicators of a pending reboot were found."-Icon 'warning'  @summaryParams
    }

    return [PSCustomObject]@{
        PendingReboot = $pendingReboot
        Reasons       = $reasons
    }
}
#endregion

#region File: Test-UEFIBoot.ps1
function Test-UEFIBoot {
    [CmdletBinding()]
    param()

    try {
        $fw = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType
        if ($fw -match 'Uefi') { return $true }
        if ($fw -match 'Legacy') { return $false }
        return $null
    }
    catch {
        return $null
    }
}
#endregion

#region File: ToLogEntry.ps1
ToLogEntry() {
        $statusIcon = if ($this.Executed) {
            if ($this.Success) { "🟢" } else { "🔴" }
        }
        else {
            "⚪"
        }

        $timestamp1 = if ($this.ExecutionTimestamp) {
            $this.ExecutionTimestamp.ToString()
        }
        else {
            "Not run"
        }

        return "$statusIcon [$($this.NumericId)] $($this.Message) — Executed: $($this.Executed), Success: $($this.Success), Time: $timestamp1"
    }
#endregion

#region File: ToSummary.ps1
ToSummary() {
        return "[$($this.NumericId)] $($this.Message) → $($this.SuggestedAction)"
    }
#endregion

#region File: Try-Extract.ps1
function Try-Extract([string]$pattern) {
                    $m = [regex]::Match($logContent, "(?m)^\s*$pattern\s*:\s*(.+)$")
                    if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null }
                }
#endregion

#region File: Try-ExtractBlock.ps1
function Try-ExtractBlock([string]$header) {
                    $regex = "(?ms)^\s*$([regex]::Escape($header))\s*\r?\n(.*?)(?:\r?\n\s*\r?\n|$)"
                    $m = [regex]::Match($logContent, $regex)
                    if ($m.Success) { return $m.Groups[2].Value.Trim() } else { return $null }
                }
#endregion

#region File: Unapprove.ps1
Unapprove() {
        if (-not $this.Approved) {
            return $true
        }

        $this.Approved = $false
        return $this.Save()
    }
#endregion

#region File: Unapprove-DrRecommendation.ps1
function Unapprove-DrRecommendation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [int] $NumericId,
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    $rec = Get-Recommendations -NumericId $NumericId
    if (-not $rec) {
        Add-LogEntry -Message "❌ Recommendation [$NumericId] not found." -Icon 'error' @summaryParams
        return
    }

    if (-not $rec.Approved) {
        Add-LogEntry -Message "ℹ️ Recommendation [$NumericId] is already unapproved." -Icon 'info' @summaryParams
        return
    }

    if (-not $rec.Unapprove()) {
        Add-LogEntry -Message "❌ Failed to unapprove recommendation [$NumericId]." -Icon 'failed' @summaryParams
        return
    }

    Add-LogEntry -Message "🚫 Unapproved recommendation [$NumericId]: $($rec.Message)" -Icon 'stop' @summaryParams
}
#endregion

#region File: Update-Asset.ps1
function Update-Asset {
    param (
        [int]$AssetId = $Global:DrAsset.id,
        [hashtable]$PropertiesToUpdate
    )

    if (-not $Global:DrApiKey) {
        Write-Error "Global:DrApiKey is not set. Cannot authenticate."
        return
    }

    if (-not $Global:DrSubDomain) {
        Write-Error "Global:DrSubDomain is not set. Cannot determine Syncro subdomain."
        return
    }

    if (-not $AssetId) {
        Write-Error "AssetId is required."
        return
    }

    if (-not $PropertiesToUpdate -or $PropertiesToUpdate.Count -eq 0) {
        Write-Error "PropertiesToUpdate must contain at least one field to update."
        return
    }

    $endpoint = "/api/v1/customer_assets/$AssetId"

    $bodyObject = @{
        asset = @{
            properties = $PropertiesToUpdate
        }
    }

    try {
        $response = Invoke-DrApiRequest -Method 'PUT' -Endpoint $endpoint -Body $bodyObject
        Write-Host "Asset updated successfully."
        return $response
    }
    catch {
        Write-Error "Failed to update asset: $_"
    }
}
#endregion

#region File: Update-CustomerFields.ps1
function Update-CustomerFields {
    [CmdletBinding(DefaultParameterSetName = 'Hashtable')]
    param (
        [Parameter(ParameterSetName = 'Hashtable')]
        [hashtable]$Fields,

        [Parameter(ParameterSetName = 'SingleField')]
        [string]$FieldName,

        [Parameter(ParameterSetName = 'SingleField')]
        [string]$FieldValue,

        [int]$CustomerId = $Global:DrAsset.customer.id,

        [switch]$DebugOutput
    )

    # Auto-detect CustomerId if not provided
    if (-not $CustomerId) {
        if ($Global:DrAsset.customer.id) {
            $CustomerId = $Global:DrAsset.customer.id
        }
        else {
            Write-Error "CustomerId not provided and Global:DrAsset.customer.id is not set."
            return
        }
    }

    # Build the field data
    switch ($PSCmdlet.ParameterSetName) {
        'SingleField' {
            if (-not $FieldName) {
                Write-Error "FieldName is required when using the SingleField parameter set."
                return
            }
            $Fields = @{ $FieldName = $FieldValue }
        }
        'Hashtable' {
            if (-not $Fields -or -not $Fields.Keys.Count) {
                Write-Warning "No fields provided to update."
                return
            }
        }
    }

    try {
        Update-DrCustomer -CustomerId $CustomerId -CustomerData $Fields -DebugOutput:$DebugOutput
    }
    catch {
        Write-Error "Failed to update customer fields: $_"
    }
}
#endregion

#region File: Update-DrCustomer.ps1
function Update-DrCustomer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][int]$CustomerId,
        [Parameter(Mandatory)][hashtable]$CustomerData,
        [switch]$DebugOutput
    )

    try {
        $response = Invoke-DrApiRequest -Method 'PUT' -Endpoint "/api/v1/customers/$CustomerId" -Body $CustomerData -DebugOutput:$DebugOutput
        return $response
    }
    catch {
        Write-Error "Failed to update customer ID ${CustomerId}: $_"
    }
}
#endregion

#region File: Update-JobPathsAfterTicket.ps1
function Update-JobPathsAfterTicket {
    param (
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    try {
        if (-not $Global:DrTicket) {
            Add-LogEntry -Message "❌ Cannot update paths: DrTicket is not set." -Icon 'Error' @summaryParams
            return
        }

        $oldLogFile = $Global:DrLogFile
        #Add-LogEntry -Message "🔒 Preparing to update paths; current log file: $oldLogFile" -Icon 'FileHandling' @detailsParams

        $oldJobRoot = $Global:DrJobRoot
        $newJobRoot = Join-Path $Global:DrJobsPath $Global:DrTicket

        if (-not $oldJobRoot) {
            Add-LogEntry -Message "Cannot rename job folder: DrJobRoot is not set." -Icon 'Error' @summaryParams
            return
        }

        if (Test-Path $oldJobRoot) {
            Rename-Item -Path $oldJobRoot -NewName $Global:DrTicket
            #Add-LogEntry -Message "Renamed job folder from '$oldJobRoot' to '$newJobRoot'." -Icon 'FileHandling' @detailsParams
        }
        else {
            Add-LogEntry -Message "Job root folder not found: $oldJobRoot" -Icon 'error' @summaryParams
            #return
        }

        $Global:DrJobRoot = $newJobRoot
        $Global:DrLogs = Join-Path $Global:DrJobRoot 'DrLogs'
        $Global:DrTemp = Join-Path $Global:DrJobRoot 'DrTemp'

        if ($oldLogFile) {
            $logFileName = Split-Path $oldLogFile -Leaf
            $Global:DrLogFile = Join-Path $Global:DrLogs $logFileName
            #Add-LogEntry -Message "Updated log file path to: $Global:DrLogFile" -Icon 'FileHandling' -AddToBody
        }

        Add-LogEntry -Message "Updated global paths: DrJobRoot=$Global:DrJobRoot, DrLogs=$Global:DrLogs, DrTemp=$Global:DrTemp" -Icon 'ok' @summaryParams
    }
    catch {
        Add-LogEntry -Message "Error updating job paths after ticket creation: $($_.Exception.Message)" -Icon 'Error' @summaryParams
    }
}
#endregion

#region File: Update-LogBuffer.ps1
function Update-LogBuffer {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [string[]]$Buffers,        # canonical, plural
        [string]$Message,
        [switch]$Flush,
        [switch]$SilentFlush,
        [switch]$Hidden,
        [switch]$NoTicketOutput,
        [switch]$LogToHost = $Global:DrLogToHost,
        [switch]$LogToFile = $Global:DrLogToFile
    )

    try {
        $subjectCase = 'TitleCase'  # or 'lower'

        # Determine target buffers
        $targets = if ($Buffers -contains '*all') {
            Get-Variable -Scope Global | Where-Object { $_.Name -like 'DrBuffer_*' }
        }
        else {
            $Buffers | ForEach-Object { "DrBuffer_$($_.ToLower())" }
        }

        foreach ($buffer in $targets) {
            $varName = if ($buffer -is [System.Management.Automation.PSVariable]) { $buffer.Name } else { $buffer }

            # Ensure buffer exists
            if (-not (Get-Variable -Name $varName -Scope Global -ErrorAction SilentlyContinue)) {
                Set-Variable -Name $varName -Scope Global -Value @()
            }

            # Append message
            if ($Message) {
                $current = (Get-Variable -Name $varName -Scope Global).Value
                $current += $Message
                Set-Variable -Name $varName -Scope Global -Value $current
            }

            # Flush
            if ($Flush -or $SilentFlush) {
                $bufferContent = (Get-Variable -Name $varName -Scope Global).Value -join "`n"

                if (-not $SilentFlush -and -not [string]::IsNullOrWhiteSpace($bufferContent)) {
                    if ($LogToHost) { Write-Host $bufferContent }
                    if ($LogToFile) { Add-Content -Path $Global:DrLogFile -Value $bufferContent }

                    if ($Global:DrTicket -and -not $NoTicketOutput) {
                        $rawSubject = ($varName -replace '^DrBuffer_', '')
                        switch ($subjectCase) {
                            'TitleCase' {
                                $subjectToUse = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.
                                ToTitleCase($rawSubject.ToLower())
                            }
                            'lower' { $subjectToUse = $rawSubject.ToLower() }
                            default { $subjectToUse = $rawSubject }
                        }
                        $null = Add-TicketComment -Body $bufferContent -Subject $subjectToUse -Hidden:$Hidden
                    }
                }

                # Remove buffer after flush
                Remove-Variable -Name $varName -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Verbose "Update-LogBuffer error: $_"
    }
}
#endregion

#region File: Update-LogBuffer1.ps1
function Update-LogBuffer1 {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [string[]]$Buffers,        # canonical, plural
        [string]$Message,
        [switch]$Flush,
        [switch]$SilentFlush,
        [switch]$Hidden,
        [switch]$NoTicketOutput,
        [switch]$LogToHost = $Global:DrLogToHost,
        [switch]$LogToFile = $Global:DrLogToFile
    )

    try {
        # 1) Normalize target variable names to strings only
        $targetNames =
        if ($Buffers -contains '*all') {
            Get-Variable -Scope Global |
            Where-Object { $_.Name -like 'DrBuffer_*' } |
            ForEach-Object { $_.Name }
        }
        else {
            $Buffers | ForEach-Object { "DrBuffer_$($_.ToLower())" }
        }

        foreach ($varName in $targetNames) {

            # Ensure buffer exists (string array)
            if (-not (Get-Variable -Name $varName -Scope Global -ErrorAction SilentlyContinue)) {
                Set-Variable -Name $varName -Scope Global -Value @()
            }

            # 2) Lock buffer content to strings
            if ($Message) {
                $current = (Get-Variable -Name $varName -Scope Global).Value

                if ($null -eq $current) { $current = @() }
                elseif ($current -isnot [object[]]) { $current = @($current) }

                $current += [string]$Message
                Set-Variable -Name $varName -Scope Global -Value $current
            }

            # Flush (destructive by design)
            if ($Flush -or $SilentFlush) {
                $bufferValue = (Get-Variable -Name $varName -Scope Global).Value

                if ($null -eq $bufferValue) { $bufferValue = @() }
                elseif ($bufferValue -isnot [object[]]) { $bufferValue = @($bufferValue) }

                $bufferContent = ($bufferValue | ForEach-Object { [string]$_ }) -join "`n"

                if (-not $SilentFlush -and -not [string]::IsNullOrWhiteSpace($bufferContent)) {
                    if ($LogToHost) { Write-Host $bufferContent }
                    if ($LogToFile) { Add-Content -Path $Global:DrLogFile -Value $bufferContent }

                    if ($Global:DrTicket -and -not $NoTicketOutput) {
                        $rawSubject = ($varName -replace '^DrBuffer_', '')

                        # 3) Hard-coded TitleCase subject for ticket output
                        $subjectToUse = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.
                        ToTitleCase($rawSubject.ToLower())

                        $null = Add-TicketComment -Body $bufferContent -Subject $subjectToUse -Hidden:$Hidden
                    }
                }

                Remove-Variable -Name $varName -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Verbose "Update-LogBuffer error: $_"
    }
}
#endregion

#region File: Update-Ticket.ps1
function Update-Ticket {
    param (
        [int]$TicketId = $Global:DrTicketId,
        [string]$Status,
        [string]$Subject,
        [string]$Priority,
        [string[]]$Tags,
        [switch]$AddTags,
        #[bool]$Hidden = $false,
        [bool]$DoNotEmail = $true
    )

    if (-not $TicketId) {
        Write-Error "TicketId is not set and Global:DrTicketId is not available."
        return
    }

    $body = @{}

    if ($Status) { $body.status = $Status }
    if ($Subject) { $body.subject = $Subject }
    if ($Priority) { $body.priority = $Priority }
    if ($DoNotEmail) { $body.donotemail = $DoNotEmail }

    if ($Tags) {
        if ($AddTags) {
            try {
                $existing = Invoke-DrApiRequest `
                    -Method 'GET' `
                    -Endpoint "/api/v1/tickets/$TicketId"

                $existingTags = $existing.tag_list
                $mergedTags = ($existingTags + $Tags) | Select-Object -Unique
                $body.tag_list = $mergedTags
            }
            catch {
                Write-Warning "Could not retrieve existing tags. Falling back to provided tags only."
                $body.tag_list = $Tags
            }
        }
        else {
            $body.tag_list = $Tags
        }
    }

    # If nothing to update, bail early
    if ($body.Count -eq 0) {
        Write-Warning "No fields provided to update. Specify -Status, -Priority, or -Tags."
        return
    }

    try {
        $response = Invoke-DrApiRequest `
            -Method 'PUT' `
            -Endpoint "/api/v1/tickets/$TicketId" `
            -Body $body

        #Write-Output "Ticket updated successfully. ID: $TicketId"
        return $response
    }
    catch {
        Write-Error "Failed to update ticket: $_"
    }
}
#endregion

#region File: Validate.ps1
Validate() {
        return -not [string]::IsNullOrWhiteSpace($this.Message) -or `
            -not [string]::IsNullOrWhiteSpace($this.SuggestedAction)
    }
#endregion

#region File: Write-ObjProperties.ps1
function Write-ObjProperties {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [object]$InputObject,

        [int]$MaxDepth = 3,
        [switch]$Detailed,
        [string]$Icon = 'detail',
        [string[]]$Buffer = $Global:DrLogSummaryBuffer,
        [switch]$FlushBuffer,

        # indent width per level
        [int]$Depth = 2,
        # INTERNAL: indentation token (was hard-coded spaces before)
        [string]$IndentChar = '🔹',   # change to '-_' if you want that style

        # internal recursion level (DO NOT set manually)
        [int]$Level = 0,
        [ref]$ObjCount = ([ref]0)
    )

    $logParams = Get-LogEntryParams -Buffer $Buffer -FlushBuffer:$FlushBuffer
    $summaryParams = $logParams.Summary
    $detailsParams = $logParams.Details

    # INTERNAL: indentation token (was hard-coded spaces before)
    #$IndentChar = '🔹'   # change to '-_' if you want that style

    if ($null -eq $InputObject) {
        Add-LogEntry -Message "Invalid or empty input." -Icon 'error' @detailsParams
        return
    }

    if ($Depth -lt 0) { $Depth = 0 }
    if ($Level -lt 0) { $Level = 0 }

    $indent = $IndentChar * ($Depth * $Level)

    # Handle array / enumerable input (but not strings)
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $array = @($InputObject)

        if ($array.Count -eq 0) {
            Add-LogEntry -Message "${indent}Array is empty." -Icon 'error' @detailsParams
            return
        }

        $index = 0
        foreach ($item in $array) {
            $index++
            Add-LogEntry -Message "${indent}#$index ━━━━━━━━━━━━━━━" -Icon $Icon @detailsParams

            $childLevel = $Level + 1
            $childIndent = $IndentChar * ($Depth * $childLevel)

            if ($childLevel -le $MaxDepth) {
                if ($Detailed -and ($item -is [psobject] -or $item -is [hashtable])) {
                    Write-ObjProperties -InputObject $item -Detailed:$Detailed -Icon $Icon -MaxDepth $MaxDepth `
                        -Buffer $Buffer -FlushBuffer:$FlushBuffer -Depth $Depth -Level $childLevel -ObjCount $ObjCount
                }
                else {
                    Add-LogEntry -Message "${childIndent}$item" -Icon $Icon @detailsParams
                }
            }
            else {
                Add-LogEntry -Message "${childIndent}Max object depth ($MaxDepth) reached." -Icon $Icon @detailsParams
            }
        }

        Add-LogEntry -Message "${indent}$($array.Count) entries listed." -Icon 'task' @summaryParams
        return
    }

    # Handle single object
    foreach ($property in $InputObject.PSObject.Properties) {
        $ObjCount.Value++
        $name = $property.Name
        $value = $property.Value

        if ($Detailed -and $value -is [psobject]) {
            Add-LogEntry -Message "${indent}$name" -Icon 'id' @detailsParams

            $childLevel = $Level + 1
            $childIndent = $IndentChar * ($Depth * $childLevel)

            if ($childLevel -le $MaxDepth) {
                Write-ObjProperties -InputObject $value -Detailed:$Detailed -Icon $Icon -MaxDepth $MaxDepth `
                    -Buffer $Buffer -FlushBuffer:$FlushBuffer -Depth $Depth -Level $childLevel -ObjCount $ObjCount
            }
            else {
                Add-LogEntry -Message "${childIndent}$name Max object depth ($MaxDepth) reached." -Icon $Icon @detailsParams
            }
        }
        elseif ($Detailed -and $value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            Add-LogEntry -Message "${indent}$name (Array)" -Icon $Icon @detailsParams

            $i = 0
            foreach ($item in $value) {
                $idxLevel = $Level + 1
                $idxIndent = $IndentChar * ($Depth * $idxLevel)

                Add-LogEntry -Message "${idxIndent}[$i]" -Icon $Icon @detailsParams

                $childLevel = $Level + 2
                $childIndent = $IndentChar * ($Depth * $childLevel)

                if ($childLevel -le $MaxDepth) {
                    if ($item -is [psobject] -or $item -is [hashtable]) {
                        Write-ObjProperties -InputObject $item -Detailed:$Detailed -Icon $Icon -MaxDepth $MaxDepth `
                            -Buffer $Buffer -FlushBuffer:$FlushBuffer -Depth $Depth -Level $childLevel -ObjCount $ObjCount
                    }
                    else {
                        Add-LogEntry -Message "${childIndent}$item" -Icon $Icon @detailsParams
                    }
                }
                else {
                    Add-LogEntry -Message "${childIndent}Max object depth ($MaxDepth) reached." -Icon $Icon @detailsParams
                }

                $i++
            }
        }
        else {
            Add-LogEntry -Message "${indent}$name : $value" -Icon $Icon @detailsParams
        }
    }

    if ($Level -eq 0) {
        #Add-LogEntry -Message "Object properties listed." -Icon 'check' @summaryParams
        Add-LogEntry -Message "${indent}$($ObjCount.Value) object properties listed." -Icon 'numbers' @summaryParams
    }
}
#endregion

#region Module End

# At the end of the .psm1:
$ExportFunctions = New-ExportModuleExportArray -Psm1Path $PSCommandPath
Export-ModuleMember -Function $ExportFunctions


# Auto-run initialization when module is imported
Initialize-Environment
#endregion
