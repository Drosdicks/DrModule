# Start Here

This guide helps you prepare a SyncroMSP environment for DrModuleV4.

DrModuleV4 is currently designed for SyncroMSP-managed environments. These steps are intended for initial setup and testing.

---

# Step 1: Create the Ticket Asset Field

Create a custom Syncro Asset Field named:

**Ticket**

DrModuleV4 uses this field to store and reuse ticket numbers between automation runs.

Logging, timers, recommendations, and job activity can continue using the same ticket until the process is completed or the ticket is closed.

---

# Step 2: Configure API Access

Download:

- `Save-ApiKey.ps1`

Edit the script and replace:

```powershell
$ApiKey = 'YOUR_API_KEY_HERE'
```

with your Syncro API key.

Create a Syncro script, paste the contents of `Save-ApiKey.ps1` into the script, and run it on a test machine.

The script stores the API key for future DrModuleV4 operations.

---

# Step 3: Download the Logo

Download:

- `Logo.jpg`

Place the file here:

```text
C:\ProgramData\Syncro\DrOsdicks\Bin\Logo.jpg
```

The logo is used by supported DrModuleV4 reporting, notification, and ticketing functions.

If the folder does not exist yet, create it:

```powershell
New-Item -Path 'C:\ProgramData\Syncro\DrOsdicks\Bin' -ItemType Directory -Force
```

---

# Step 4: Deploy the Module

Download the latest DrModuleV4 module file and place it here:

```text
C:\ProgramData\Syncro\DrOsdicks\Bin\DrModuleV4.psm1
```

This is the expected module path used by the framework.

---

# Step 5: Run a Basic Test

The following test can be performed either:

- Interactively from PowerShell or PowerShell ISE
- Through a Syncro RMM script

Interactive testing is useful during development and troubleshooting.

Syncro scripts are the normal production execution method for most DrModuleV4 workflows.

Example:

```powershell
Import-Module 'C:\ProgramData\Syncro\DrOsdicks\Bin\DrModuleV4.psm1' -Force

Initialize-Job -Subject 'DrModuleV4 Test Run'

Add-LogEntry 'DrModuleV4 test started.' -Icon 'jobstart'

Get-WindowsVersion

Add-LogEntry 'DrModuleV4 test completed.' -Icon 'summary'

Complete-Job
```

Expected Result:

- The module imports successfully.
- `Initialize-Environment` runs automatically during module import and prepares the DrModuleV4 runtime environment.
- `Initialize-Job` creates a new ticket or reuses an existing ticket based on the Ticket asset field and job settings.
- Log entries are generated throughout execution.
- Windows version information is collected and logged.
- `Complete-Job` finalizes the job, compresses all generated logs and working files into a ZIP archive, attaches the archive to the associated Syncro ticket, records completion information, closes the ticket, and removes the temporary files created during the job.

---

# Step 6: Verify System Variables

After the module is imported, you can review available system variables:

```powershell
Get-SysVarList
```

Administrative access is required. If the session is not elevated, the function will report that requirement.

System variables control framework behavior and can be modified using `Set-SysVar`.

Example:

```powershell
Set-SysVar -Name 'NewVariable' -Value $true -Type Boolean -Add
```

If `-Type` is not specified, DrModuleV4 determines the type from the value.

---

# Additional Documentation

After completing the setup steps, review:

- `README.md`
- `FEATURES.md`
- `functions_list.md`

These documents provide:

- Framework overview
- Feature documentation
- Function reference information

---

# Notes

DrModuleV4 can be used interactively for testing and development.

PowerShell ISE is useful during development because it prompts for function parameters as you type.

Most production usage is expected to run through Syncro scripts and automation.
