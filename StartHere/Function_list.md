# Function Reference

This document provides a categorized reference for functions currently available in DrModuleV4.

Module version referenced: `4.0.95`

Descriptions are intentionally short. This file is meant to be a quick reference, not full command documentation.

---

# Core Framework

### Initialize-Environment
Initializes the DrModuleV4 runtime environment, folders, paths, ticket context, timers, and framework defaults.

### Initialize-Job
Starts a job context, optionally creates or associates a Syncro ticket, and configures logging and job-level settings.

### Complete-Job
Finalizes a job, flushes remaining buffers, archives generated files, and uploads output to the associated Syncro ticket when available.

### Initialize-DrFunction
Applies common function startup logic, including metadata-based checks and framework validation.

### Complete-DrFunctionState
Completes tracked function state after execution.

### Fail-DrFunction
Marks the current function state as failed.

### Test-DrFunctionState
Tests framework function state tracking.

### Test-DrOperatingSystem
Validates OS include/exclude restrictions from recommendation metadata.

### Assert-MaintenanceWindow
Checks whether execution is currently allowed based on maintenance window rules.

### Assert-InteractiveSession
Ensures execution is running in an interactive user session when required.

### Assert-IsAdmin
Checks whether the current session has administrative privileges.

### Test-IsElevated
Tests whether the current process token is elevated.

### IsUserAdmin
Checks whether the current user has administrative privileges.

---

# Logging

### Add-LogEntry
Core framework logging function used for host output, file logging, ticket output, buffering, icons, and summaries.

### Update-LogBuffer
Adds to, manages, and flushes named log buffers.

### Add-TicketComment
Adds a comment to a Syncro ticket.

### Log-DrActivity
Records structured activity data.

### Log-Invocation
Logs function invocation details.

### Log-InvocationV2
Enhanced function invocation logging with metadata support.

### New-LogFile
Creates or opens a framework log file.

### Convert-LogIconKey
Converts a configured icon key into the matching visual glyph.

### Get-LogEntryParams
Builds standardized logging parameter sets for details and summary entries.

### Log-ObjProperties
Logs object properties in a structured format.

### Write-ObjProperties
Writes object properties in a readable structured format.

---

# System Variables and Configuration

### Initialize-VariableStore
Initializes the persistent variable store.

### Initialize-SysVarsFromFile
Loads system variables from the variable store.

### Get-SysVar
Returns a system variable by name.

### Get-SysVarList
Lists available system variables.

### Set-SysVar
Creates or updates a system variable.

### Remove-SysVar
Removes a system variable.

### Update-JobPathsAfterTicket
Updates job folder paths after a ticket number becomes available.

---

# Recommendations

### Add-DrRecommendation
Creates a DrModule recommendation.

### Get-DrRecommendations
Returns stored recommendations.

### Get-DrRecommendationExecutionMetadata
Reads execution metadata for a recommendation-capable command.

### Approve-DrRecommendation
Approves one or more recommendations for execution.

### Unapprove-DrRecommendation
Removes approval from a recommendation.

### Run-DrRecommendation
Runs a specific recommendation.

### Run-DrRecommendations
Runs approved recommendations or a selected recommendation.

### Invoke-DrRecommendation
Invokes a recommendation action.

### Invoke-DrRecommendations
Invokes recommendation processing.

### Show-DrRecommendations
Displays recommendation details.

### Show-DrRecommendationsSummary
Displays a recommendation summary.

### Get-DrRecommendationSummary
Returns recommendation counts and summary information.

### Get-DrRecommendationResults
Returns recommendation execution results.

### Complete-DrRecommendation
Marks a recommendation as completed and records execution results.

### Complete-DrRecommendationSummary
Completes recommendation summary reporting.

### Clone-DrRecommendation
Duplicates an existing recommendation.

### Remove-DrRecommendationByNumericId
Removes a recommendation by numeric ID.

### Reset-DrRecommendations
Clears recommendation data.

### Reset-DrRecommendationExecutionMetadata
Resets execution metadata for recommendations.

### Resolve-DrCommandToRun
Builds a runnable command from recommendation data and metadata.

---

# Progression Rules

### Get-ProgressionRules
Returns configured progression rules.

### Add-ProgressionRule
Adds a function progression rule.

### Evaluate-Progression
Evaluates whether a completed action should trigger another recommendation.

### Reset-ProgressionRules
Clears progression rules.

---

# Syncro API and Ticketing

### Invoke-DrApiRequest
Performs Syncro API requests.

### Call-KabutoApi
Calls Syncro RMM API endpoints.

### Send-DrAlert
Creates or sends a Syncro alert.

### Resolve-DrAlert
Resolves a Syncro alert.

### Send-DrEmail
Sends an email through Syncro-related automation.

### Send-DrFile
Uploads a file using the configured file pusher.

### Open-Ticket
Creates and initializes a Syncro ticket.

### New-Ticket
Creates a Syncro ticket.

### Close-Ticket
Closes a Syncro ticket.

### Get-Ticket
Retrieves ticket details.

### Get-TicketIdFromNumber
Resolves a Syncro ticket ID from a ticket number.

### Update-Ticket
Updates ticket fields such as status, subject, priority, or tags.

### Add-TicketFile
Uploads a file to a Syncro ticket.

### Add-DrTicketTimerEntry
Adds a time entry to a Syncro ticket.

### Get-TicketAssetIds
Returns asset IDs associated with a ticket.

### Get-SyncroTicketComments
Retrieves Syncro ticket comments.

### ConvertTo-AITicketComments
Formats ticket comments for AI summary use.

### Log-AITicketSummary
Logs an AI-generated or AI-formatted ticket summary.

---

# Syncro Customers and Assets

### New-DrCustomer
Creates a Syncro customer record.

### Update-DrCustomer
Updates a Syncro customer record.

### Get-DrCustomer
Retrieves Syncro customer information.

### Update-CustomerFields
Updates customer custom fields.

### New-DrAsset
Creates a Syncro asset record.

### Get-Asset
Retrieves asset information.

### Update-Asset
Updates asset information.

### Set-AssetField
Updates a Syncro asset custom field.

### Set-AssetTicket
Stores the current ticket number on the asset.

### Get-DrCustomerAssets
Returns assets for a customer.

### Get-SyncroAssetByName
Finds a Syncro asset by name.

### Set-DrAssetIdRegistry
Stores Syncro asset ID information in the registry.

### Get-DrAssetIdRegistry
Reads stored Syncro asset ID information from the registry.

---

# Job Timers and Duration

### Load-DrTimers
Loads timer data from storage.

### Save-DrTimers
Saves timer data to storage.

### Start-DrTimer
Starts a named timer.

### Pause-DrTimer
Pauses a named timer.

### Resume-DrTimer
Resumes a named timer.

### Stop-DrTimer
Stops a named timer.

### Reset-DrTimer
Resets a named timer.

### Remove-DrTimer
Removes timer data.

### Get-DrTimer
Returns timer details.

### Get-DrTimers
Returns all timers.

### Get-DrTimersSummary
Returns timer summary information.

### Add-DrTimerToTicket
Adds timer information to a Syncro ticket.

### Add-DrTimerMessage
Adds a message to a timer.

### Get-DrTimerMessagesString
Returns timer messages as text.

### Log-Duration
Logs elapsed duration between start and end times.

### Add-DrDurationToTimer
Adds a duration object to timer tracking.

---

# Maintenance Profiles and Schedules

### Set-MaintenanceProfile
Creates or updates a maintenance profile.

### Get-MaintenanceProfile
Returns a maintenance profile by name.

### Get-MaintenanceProfiles
Lists maintenance profiles.

### Remove-MaintenanceProfile
Removes a maintenance profile.

### Log-MaintenanceProfiles
Logs maintenance profile information.

### Ensure-MaintenanceProfiles
Ensures default maintenance profiles exist.

### Initialize-MaintenanceProfiles
Initializes maintenance profile storage and defaults.

### Set-DrAssetMaintenanceProfile
Assigns a maintenance profile to an asset.

### Set-MaintenanceSchedule
Creates or updates a maintenance schedule.

### Get-MaintenanceSchedule
Returns a maintenance schedule.

### Log-MaintenanceSchedule
Logs maintenance schedule information.

### Initialize-MaintenanceSchedules
Initializes maintenance schedule storage and defaults.

### Ensure-MaintenanceSchedules
Ensures maintenance schedules exist.

### Set-DrAssetMaintenanceSchedule
Assigns a maintenance schedule to an asset.

---

# Disk Cleanup and Storage Management

### Get-DrDiskCleanupProfileStore
Returns the disk cleanup profile store path.

### New-DrDiskCleanupProfileObject
Creates a disk cleanup profile object.

### Save-DrDiskCleanupProfile
Saves a disk cleanup profile.

### Get-DrDiskCleanupProfile
Returns a disk cleanup profile by name.

### Get-DrDiskCleanupProfiles
Lists disk cleanup profiles.

### Log-DrDiskCleanupProfiles
Logs disk cleanup profile information.

### Remove-DrDiskCleanupProfile
Removes a disk cleanup profile.

### Ensure-DrDiskCleanupProfiles
Ensures default disk cleanup profiles exist.

### Initialize-DrDiskCleanupProfiles
Initializes disk cleanup profile storage and defaults.

### Get-DrDiskCleanupDecision
Determines which cleanup profile should be used.

### Invoke-DrDiskCleanup
Runs profile-based disk cleanup.

### Invoke-DrDiskCleanupProfile
Executes cleanup using a specified disk cleanup profile.

### Invoke-DrDiskCleanupV2
Runs enhanced disk cleanup with profile logic, validation, and reporting.

### Invoke-DrCleanup
Runs broader cleanup actions using framework cleanup logic.

### Clean-DrFolder
Safely cleans or deletes folder contents according to parameters.

### Clear-DiskSpace
Runs legacy disk cleanup logic.

### SearchAndDelete-Items
Searches for and optionally deletes matching items.

---

# Storage Health and Storage Sense

### Initialize-StorageHealthProfiles
Initializes storage health profiles.

### Set-StorageHealthProfile
Creates or updates a storage health profile.

### Get-StorageHealthProfile
Returns a storage health profile.

### Get-StorageHealthProfiles
Lists storage health profiles.

### Log-StorageHealthProfiles
Logs storage health profile information.

### Ensure-StorageHealthProfiles
Ensures storage health profiles exist.

### Get-StorageHealth
Returns current storage health information.

### Get-StorageHealth1
Earlier storage health function retained in the module.

### Log-StorageHealth
Logs storage health information.

### Get-ReclaimedStorageHealth
Compares before and after storage health results.

### Get-DrDiskInfo
Returns disk information.

### Log-DrDiskInfo
Logs disk information.

### Get-StorageSummary
Returns storage summary information.

### Get-StorageMetrics
Returns detailed storage metrics.

### Get-ReclaimedStorage
Calculates reclaimed storage between before and after measurements.

### Set-StorageSensePolicy
Applies a Storage Sense policy.

### Set-StorageSenseProfile
Creates or updates a Storage Sense profile.

### Get-StorageSenseProfile
Returns a Storage Sense profile.

### Get-StorageSenseProfiles
Lists Storage Sense profiles.

### Remove-StorageSenseProfile
Removes a Storage Sense profile.

### Initialize-StorageSenseProfiles
Initializes Storage Sense profile storage and defaults.

### Ensure-StorageSenseProfiles
Ensures Storage Sense profiles exist.

### Log-StorageSenseProfiles
Logs Storage Sense profile information.

---

# Security and Protection

### Set-AppBrowserControl
Configures App & Browser Control settings.

### Get-AppBrowserControl
Returns App & Browser Control settings.

### Log-AppBrowserControl
Logs App & Browser Control settings.

### Set-WindowsProtection
Configures Windows protection settings.

### Get-WindowsProtection
Returns Windows protection settings.

### Log-WindowsProtection
Logs Windows protection settings.

### Get-AVProducts
Returns antivirus product information.

### Get-AVProductsV2
Returns antivirus product information using alternate logic.

### Log-AVProducts
Logs antivirus product information.

### Verify-AVProducts
Verifies antivirus product state.

### Evaluate-DrAVState
Evaluates antivirus state and potential remediation needs.

### Get-SecureBoot
Returns Secure Boot status.

### Get-TpmStatus
Returns TPM status.

### Log-TpmStatus
Logs TPM status.

### Get-BitLockerKey
Retrieves BitLocker recovery key information.

### Get-WifiPassword
Returns stored Wi-Fi password information when requested.

---

# Windows Repair and System Maintenance

### Start-SFC
Runs System File Checker in verify or repair mode.

### Run-DISM
Runs DISM repair operations.

### Start-ChkDsk
Runs ChkDsk-related checks or repairs.

### Reset-WindowsUpdate
Resets Windows Update components.

### Test-DrWmiRepositoryHealth
Tests WMI repository health.

### Recommend-DrWmiRepositoryRepair
Creates a recommendation to repair WMI repository problems.

### Reset-DrWmiRepository
Repairs or resets the WMI repository.

### Set-PendingRestart
Sets a pending restart indicator.

### Get-PendingRestart
Returns pending restart status and reasons.

### Log-PendingRestart
Logs pending restart status.

### Restart-DrComputer
Schedules or performs a controlled restart.

### Restart-DrComputerInteractive
Runs interactive restart notification behavior.

### Set-RestartNotification
Configures restart notification behavior.

### Set-UpdateSettings
Configures Windows Update-related settings.

### Get-FastBootSetting
Returns Fast Startup setting state.

### Set-FastBootSetting
Configures Fast Startup.

---

# Notifications and User Session

### Show-Notification
Displays a notification.

### Show-UserNotification
Displays a user-session notification.

### Get-InteractiveUser
Returns the active console user.

### Get-LoggedInUser
Returns the current logged-in user context.

### Get-DrLoggedInUserSession
Returns a logged-in user session suitable for user-context execution.

### Invoke-DrUserSessionLauncher
Launches commands in the interactive user session.

### Invoke-DrUserSessionLauncher1
Earlier user-session launch function retained in the module.

---

# Networking

### Get-DnsServerInfo
Returns DNS server information.

### Get-NetworkInfo
Returns network configuration information.

### Log-NetworkInfo
Logs network configuration information.

### Get-NetworkAdapters
Returns network adapter information.

### Set-NetworkCategory
Sets network category such as public or private.

### Get-WifiConnection
Returns Wi-Fi connection details.

### Start-SpeedTest
Runs network speed testing.

---

# Browser and User Experience Settings

### Get-BrowserPermissions
Retrieves browser permission settings for Edge and Chrome profiles.

### Remove-MaliciousBrowser
Removes targeted malicious or unwanted browser components.

### Get-VendorRootsFromBrowserNames
Finds vendor folders associated with targeted browser names.

### Get-AllUserLocalAppData
Returns LocalAppData paths for all real user profiles.

### Get-LocalRootFromExePath
Resolves the local application root from an executable path.

### Get-TaskCacheTreeMatches
Finds scheduled task cache matches.

### Clear-BrowserHistory
Clears browser history according to selected options.

### Show-HiddenFiles
Toggles hidden file visibility.

### Set-HiddenFiles
Configures hidden file settings.

### Set-EdgeExtension
Installs or removes Edge extensions.

---

# Accounts, Identity, and Access

### Get-DrMicrosoftAccounts
Returns Microsoft account-related information.

### Log-DrMicrosoftAccounts
Logs Microsoft account-related information.

### Block-PersonalMicrosoftAccounts
Enables or disables blocking of personal Microsoft accounts.

### Get-LocalAccountSnapshot
Captures local account state.

### Get-LocalAccountBaseline
Returns a local account baseline.

### Compare-AccountSnapshots
Compares current local accounts against a baseline.

### Compare-AccountSnapshots0
Earlier account snapshot comparison function retained in the module.

### Add-LoggedInUserToAdmins
Adds the logged-in user to the local Administrators group.

### Add-DrLocalUser
Creates a local user.

### New-DrDomainUser
Creates a domain user.

### Hide-User
Hides or shows a Windows user account.

### Join-ComputerToDomain
Joins a computer to a domain.

### New-DrPassword
Creates a password.

### New-RandomPassword
Creates a random password.

### New-RandomPassword1
Earlier random password function retained in the module.

### Save-EncryptedApiKeyToRegistry
Stores an encrypted API key in the registry.

### Get-EncryptedApiKeyFromRegistry
Retrieves an encrypted API key from the registry.

---

# Diagnostics, Events, and Dumps

### Get-EventLogsByLevelAndTime
Retrieves Windows event logs by level and time window.

### Get-EventLogsByLevelAndTimex
Alternate event log retrieval function.

### Get-EventTimeDifferences
Analyzes event log time differences.

### Enable-Minidumps
Enables minidump creation.

### Debug-MinidumpFiles
Processes minidump files for debugging.

### Get-DumpType
Returns configured dump type.

### Set-DumpType
Sets dump type configuration.

### Get-DumpPaths
Returns actionable dump file paths.

### Get-DebugTool
Finds an installed supported dump analysis tool.

### Invoke-DumpFileProcessing
Processes dump files using an available debugger.

### Get-DumpFileCount
Counts available dump files.

### Test-DumpFilesExist
Returns whether dump files exist.

### Recommend-DumpFileProcessing
Creates a recommendation to process dump files.

### Get-DrContent
Reads redirected console output content.

---

# Hardware and System Information

### Get-WindowsVersion
Returns Windows version information.

### Get-WindowsVersionV2
Returns Windows version information using registry data.

### Test-WindowsVersion
Tests Windows version and optionally creates a recommendation.

### Log-WindowsVersion
Logs Windows version information.

### Test-Windows11Readiness
Tests readiness for Windows 11.

### Get-LastBootUpTime
Returns last boot time.

### Get-CPUTemperature
Returns CPU temperature information when available.

### Test-CPUTemperature
Tests CPU temperature against a threshold.

### Get-DrMotherboardInfo
Returns motherboard and BIOS information.

### Get-DrCpuAndMemoryInfo
Returns CPU and memory information.

### Get-PowerSourceInfo
Returns power source information.

### Get-PrinterStatus
Returns printer status information.

### Get-NumLockState
Returns Num Lock setting state.

### Set-NumLockState
Configures Num Lock state.

### Get-SyncroSafeMode
Returns Syncro safe mode service state.

### Set-SyncroSafeMode
Configures Syncro safe mode service behavior.

### Test-UEFIBoot
Tests whether the system is using UEFI boot.

---

# Software and Packages

### Install-DrPackage
Installs a DrModule package.

### Install-UpdateWinget
Installs or updates winget/App Installer support.

### Set-StoreApp
Installs, updates, removes, repairs, or resets Microsoft Store applications.

### Manage-Service
Manages Windows services.

### Stop-Processes
Stops selected processes.

### Invoke-AdwCleaner
Runs AdwCleaner-related cleanup.

### Optimize-Registry
Runs registry optimization.

### Register-Windows
Registers Windows using a product key.

---

# File and Folder Utilities

### Ensure-Folder
Ensures that a folder exists.

### Find-File
Finds a file by path and name.

### Locate-File
Locates a file by path and name.

### FindAndRun
Finds and runs a file.

### Add-FilesToZip
Adds files to a ZIP archive.

### Count-RegistryEntries
Counts entries in a registry export file.

---

# Content and Recommendations Settings

### Set-ContentRecommendations
Configures Windows content recommendations.

### Get-ContentRecommendations
Returns Windows content recommendation settings.

### Log-ContentRecommendations
Logs content recommendation settings.

---

# Miscellaneous

### Compare-Version
Compares version values.

### Get-Alerts
Returns Syncro alerts.

### Get-PaymentProfiles
Returns payment profile information.

### Get-TpmStatus
Returns TPM status information.

### DrSecurityReviewx
Runs a security review function retained in the module.

### New-ExportModuleExportArray
Builds the module export function array.

