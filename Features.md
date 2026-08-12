# FEATURES

DrModuleV4 is more than a collection of PowerShell functions. It provides a framework for building automation, maintenance, remediation, diagnostics, reporting, and recommendation-driven processes within SyncroMSP-managed environments.

---

# 🌐 Global Environment

DrModuleV4 uses global variables to share information between the module and any scripts that import it.

Common variables include:

- `$Global:DrCustomer`
- `$Global:DrAsset`
- `$Global:DrTkt`

These variables expose customer, asset, and ticket data throughout the execution of a script or automation process.

---

# 👤 Interactive Development

The module can be used interactively.

When using PowerShell ISE, parameter prompts and tab completion make testing and development easier.

Most functions can be executed directly from the console while developing or troubleshooting automation.

---

# ⚙️ System Variables

System Variables control how the framework behaves.

To view available variables:

```powershell
Get-SysVarList
```

Administrative privileges are required. The function will notify you if elevation is needed.

System variables are initialized with default values and can be modified to customize framework behavior.

---

# 🔑 Creating and Updating System Variables

System variables can be modified or extended using:

```powershell
Set-SysVar -Name 'NewVariable' -Value $true -Type Boolean -Add
```

Parameters:

- `-Name` identifies the variable.
- `-Value` specifies the value.
- `-Type` is optional.
- `-Add` creates a new variable.

When `-Type` is omitted, the framework automatically determines the variable type based on the value provided.

System variables provide a centralized method for controlling framework behavior and operational defaults.

---

# 🧰 Environment Initialization

When the module is imported, `Initialize-Environment` runs automatically.

This function:

- Initializes the framework environment.
- Creates required folders if they do not exist.
- Loads framework settings.
- Establishes recommendation storage locations.
- Configures timer and tracking systems.
- Determines the active ticket context.

If no ticket is available, a unique identifier is generated and used in place of the ticket number for log and temporary working directories.

In most situations, no additional initialization is required after importing the module.

---

# 🎫 Job Management

## 🚀 Initialize-Job

`Initialize-Job` is optional.

This function prepares a process for execution and can:

- Use an existing ticket.
- Create a new ticket.
- Configure job-level settings.
- Override selected system variables.
- Prepare logging and temporary working locations.

If a new ticket is created, existing temporary and log folders are automatically renamed to match the newly assigned ticket number.

To prevent ticket creation:

```powershell
Initialize-Job -NoNewTicket
```

Example:

```powershell
Initialize-Job -Subject "Test Run" -LogToFile:$false
```

The example above disables file logging for the current job.

---

## 🎯 Complete-Job

`Complete-Job` performs end-of-job cleanup operations.

Typical activities include:

- Flushing remaining log buffers.
- Compressing generated log and temporary files.
- Creating a ZIP archive.
- Uploading the archive to the associated Syncro ticket.

If no ticket exists, the archive remains on the local system and can be removed during routine maintenance.

---

# 📋 Logging Framework

## Add-LogEntry

`Add-LogEntry` is one of the core framework functions and serves as the foundation of the logging system.

Basic usage:

```powershell
Add-LogEntry "Message goes here."
```

Framework defaults are controlled through System Variables, allowing logging behavior to be standardized across the environment.

Timestamped entries can be included in ticket comments and log output, providing an execution timeline for troubleshooting, review, and auditing.

---

# 🕶️ Standardized Visual Logging

DrModuleV4 includes a centralized icon system that provides consistent visual indicators across logs, ticket comments, recommendations, reporting, diagnostics, and framework operations.

Examples include:

- 🚀 Job Start (`jobstart`)
- 💽 Disk Operations (`disk`)
- 🧪 Testing and Validation (`chemistry`)
- 🕶️ Review and Investigation (`sunglasses`)
- 🔍 Analysis and Searches (`search`)
- 🛠️ Actions and Remediation (`action`)
- ⚠️ Warnings (`warning`)
- ❌ Failures (`failed`)
- ✅ Successes (`success`)
- 📋 Summaries (`summary`)
- 🎫 Ticket Operations (`ticket`)
- 🛡️ Security Events (`security`)

Rather than embedding emoji directly throughout the codebase, functions reference a standardized icon name. This helps maintain consistency across the framework and makes logs easier to read and troubleshoot.

Because every function uses the same icon dictionary, ticket updates, reports, diagnostics, recommendations, and automation processes all present information in a familiar and consistent format.

---

# 📦 Buffered Logging

DrModuleV4 supports buffered logging, allowing related messages to be collected throughout execution and written as organized ticket updates instead of generating large numbers of individual comments.

Example:

```powershell
Add-LogEntry "Job started."             -Buffers @('Github Demo') -Icon 'jobstart'
Add-LogEntry "Disk analysis completed." -Buffers @('Github Demo') -Icon 'disk'
Add-LogEntry "Experimental validation." -Buffers @('Github Demo') -Icon 'chemistry'
Add-LogEntry "Operation failed."        -Buffers @('Github Demo','Syncro') -Icon 'failed'
Add-LogEntry "Remediation successful."  -Buffers @('Github Demo','Syncro') -Icon 'success'
Add-LogEntry "Verification passed."     -Buffers @('Github Demo','Syncro') -Icon 'ok'
Add-LogEntry "Processing complete."     -Buffers @('Github Demo','Syncro') -Icon 'summary' -FlushBuffer -SubjectIcon 'summary'
```

Resulting ticket comments:

## 📋 Github Demo

2026-08-11 22:40:52 - 🚀 Job started.

2026-08-11 22:41:08 - 💽 Disk analysis completed.

2026-08-11 22:41:32 - 🧪 Experimental validation.

2026-08-11 22:43:11 - ❌ Operation failed.

2026-08-11 22:43:29 - ✅ Remediation successful.

2026-08-11 22:43:58 - ✔️ Verification passed.

2026-08-11 22:44:58 - 📋 Processing complete.

## 📋 Syncro

2026-08-11 22:43:11 - ❌ Operation failed.

2026-08-11 22:43:29 - ✅ Remediation successful.

2026-08-11 22:43:58 - ✔️ Verification passed.

2026-08-11 22:44:58 - 📋 Processing complete.

This example demonstrates:

- Buffered logging
- Timestamped ticket entries
- Multiple buffer destinations
- Standardized visual logging
- Ticket integration
- Summary generation
- Reduced ticket noise

A single message can be written to multiple buffers, allowing one process to feed different reporting streams. When buffers are flushed, the framework creates organized ticket updates that are easier to review than a large collection of individual log entries.

---

# 🔄 Multiple Buffers

The `-Buffers` parameter accepts an array.

This allows a single operation to target multiple buffers simultaneously.

Example:

```powershell
-Buffers @('Validation','Summary','Completed')
```

---

# ✔️ Completed Buffer

A common framework pattern is the use of a `Completed` buffer.

When `Complete-Job` flushes this buffer:

- A completion entry is added.
- Final status information is recorded.
- The ticket can be marked as completed.

---

# 🧹 Flush All Buffers

To operate on every active buffer:

```powershell
-Buffers '*All'
```

This is commonly used by `Complete-Job` to ensure all buffered entries are written and cleared.

---

# 🔗 SyncroMSP Integration

DrModuleV4 is currently designed for SyncroMSP-managed environments.

Framework capabilities include:

- Customer awareness
- Asset awareness
- Ticket awareness
- Ticket-based logging
- Ticket file uploads
- Automated ticket handling
- Job lifecycle management

---

# 🧱 Design Goals

DrModuleV4 is designed around several core principles:

- Standardized automation
- Consistent logging
- Recommendation-driven processes
- Validation before action
- Operational visibility
- Framework extensibility
- Reusable automation components

The objective is not simply to execute scripts.

The objective is to provide a framework for building automation that remains maintainable, auditable, and scalable as it grows.
