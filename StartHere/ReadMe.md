# Start Here

This guide helps you prepare a SyncroMSP environment for DrModuleV4.

DrModuleV4 is currently designed for SyncroMSP-managed environments. These steps are intended for initial setup and testing.

---

# Step 1: Create Custom Asset Fields in SyncroMSP

## Location

Navigate to:

**Admin -> Asset Custom Fields -> Syncro Device -> Manage Fields**

## Fields to Create

Create the following custom asset fields under the **Syncro Device** asset type.

| Field Name | Field Type |
|---|---|
| Ticket | Text Field |
| Maintenance Profile | Text Field |
| Maintenance Schedule | Text Field |
| Last Assessment Date | Date Field |
| Last Assessment Status | Text Field |
| On-Boarding Date | Date Field |
| Last Maintenance Date | Date Field |
| Last Maintenance Status | Text Field |

## Verification

After creating the fields, verify that each field appears under the **Syncro Device** asset type and is visible on Syncro asset records.

---

# Step 2: Obtain a Syncro API Key

In SyncroMSP, create or copy the API key that DrModuleV4 will use for Syncro communication.

Keep this key available. It will be added to the setup script in the next step.

---

# Step 3: Create the FirstRun Script

Download:

```text
Save-ApiKey.ps1
```

Edit the script and replace:

```powershell
$ApiKey = 'YOUR_API_KEY_HERE'
```

with your Syncro API key.

Create a new Syncro script named something like:

```text
FirstRun
```

Paste the contents of the modified Save-ApiKey.ps1 file into the Syncro script and save it.

This is the only setup step that requires a Syncro API key and normally only needs to be performed once per endpoint. The script securely encrypts and stores the Syncro API key for future DrModuleV4 operations.

---

# Step 4: Attach Required Files to the FirstRun Script

Attach the required DrModuleV4 files to the Syncro script definition.

Required attached files:

```text
DrModuleV4.psm1
Logo.jpg
```

Expected endpoint file locations after the script runs:

```text
C:\ProgramData\Syncro\DrOsdicks\Bin\DrModuleV4.psm1
C:\ProgramData\Syncro\DrOsdicks\Bin\Logo.jpg
```

No manual folder creation is required.

No manual file placement is required.

The Syncro RMM script handles the folder and file creation process when the script runs.

---

# Step 5: Run the FirstRun Script

Run the Syncro script created in Step 3.

Example script name:

```text
FirstRun
```

The script will:

- Save the Syncro API key.
- Place `DrModuleV4.psm1` in the required endpoint location.
- Place `Logo.jpg` in the required endpoint location.
- Prepare the endpoint for DrModuleV4 operation.

After the script completes, proceed to the installation test.

---

# Step 6: Run an Installation Test

The following test can be performed either:

- Interactively from PowerShell or PowerShell ISE
- Through a Syncro RMM script

Interactive testing is useful during development and troubleshooting.

Syncro scripts are the normal production execution method for most DrModuleV4 workflows.

## Test Script

```powershell
Import-Module 'C:\ProgramData\Syncro\DrOsdicks\Bin\DrModuleV4.psm1' -Force

Initialize-Job -Subject 'DrModuleV4 Installation Test'

Add-LogEntry 'Testing DrModuleV4 installation.' -Icon 'jobstart'

Get-WindowsVersion -FlushBuffer

Add-LogEntry 'Installation test completed.' -Icon 'summary'

Complete-Job
```

## Expected Result

- DrModuleV4 imports successfully.
- `Initialize-Environment` runs automatically during module import and prepares the DrModuleV4 runtime environment.
- `Initialize-Job` creates a new Syncro ticket or reuses an existing ticket based on the Ticket asset field and job settings.
- The Ticket custom asset field is populated or updated as needed.
- Log entries are generated throughout execution.
- Windows version information is collected and flushed to the log output.
- `Complete-Job` finalizes the job, processes generated logs and working files, attaches available job output to the associated Syncro ticket, records completion information, and removes temporary files created during the job.

This test validates that:

1. The module loads correctly.
2. The saved API key works.
3. Syncro communication works.
4. The custom asset fields are available.
5. Ticket creation works.
6. Logging works.
7. Buffered function output works.
8. `Complete-Job` works.

---


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
