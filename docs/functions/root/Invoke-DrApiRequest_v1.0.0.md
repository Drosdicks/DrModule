
Invoke-DrApiRequest — Function Contract
Status: Active
DocVersion: v1.0.0
LastUpdated: 2026-03-07
Source: Existing DrModuleV3 function (authoritative code retained)
Scope: Core API Handlers / Root Functions


Purpose
Invoke-DrApiRequest is the lowest‑level Syncro API transport function.
It is responsible solely for constructing, sending, and returning HTTP requests to the Syncro MSP API.
This function is a root infrastructure function and does not follow standard DrModuleV3 behavioral rules.


Role Classification

Tier: Root / Core API Handler
Dependency Direction: Inbound only (many callers, no business‑logic dependents)
Stability Requirement: Extremely high


Signature
Invoke-DrApiRequest \
    -Method <GET|POST|PUT|DELETE|PATCH> \
    -Endpoint <string> \
    [-Body <object>] \
    [-DebugOutput]




Parameters
Method

Type: string
Required: Yes
Allowed values: GET, POST, PUT, DELETE, PATCH
Purpose: HTTP verb used for the request
Endpoint

Type: string
Required: Yes
Purpose: API endpoint path (appended to Syncro subdomain base URL)
Notes:Must begin with /
Body

Type: object
Required: No
Purpose: Payload for non‑GET requests
Behavior:Ignored for GET
Serialized using ConvertTo-Json -Depth 10
DebugOutput

Type: switch
Required: No
Purpose: Emits request diagnostics to host output


Dependencies (Hard Requirements)
The following must already exist before calling this function:

$Global:DrApiKey
$Global:DrSubDomain
If either is missing:

The function emits Write-Error
The function returns immediately
No recovery or fallback behavior exists.


Behavior
Request Construction

Base URI format:
https://<DrSubDomain>.syncromsp.com<Endpoint>



Headers:Authorization: Bearer <DrApiKey>
Content-Type: application/json
Accept: application/json
Body Handling

Body is only sent when:Body is supplied
Method is not GET
Body is encoded as UTF‑8 JSON bytes


Response Handling
Normal Case

Uses Invoke-RestMethod
Returns the parsed PowerShell object
String Response Handling
If the response is returned as a raw string:

UTF‑8 BOM is removed
Control characters are stripped
JSON parsing is attempted using:ConvertFrom-Json
Fallback: JavaScriptSerializer
Case‑Collision Resolution

Dictionary keys are processed case‑insensitively
Duplicate keys differing only by case:First value wins
Exception: ticket is canonicalized to lowercase


Error Handling

All HTTP errors are terminating (ErrorAction = Stop)
Failures are surfaced via Write-Error
No structured logging is performed
No retries are attempted


Logging Rules (Explicit Exception)
This function:

Does NOT call Add-LogEntry
Does NOT buffer logs
Does NOT write ticket comments
Rationale:

This function operates at the foundation of the logging and ticketing stack and is invoked by higher-level logging functions (including Add-LogEntry) via intermediate calls; it must therefore remain free of direct logging dependencies to avoid circular initialization.
This function must remain callable in degraded states


Safety Constraints

No parameter validation beyond declared attributes
No rate limiting
No retry logic
No token refresh
These concerns are delegated to higher‑level callers.


Return Contract

Success: Parsed PowerShell object (or array)
Partial failure: Raw string (if JSON parsing fails)
Failure: $null (after Write-Error)


Example Usage
$response = Invoke-DrApiRequest \
    -Method GET \
    -Endpoint '/api/v1/tickets'




Conflicts / Drift

None recorded


ChangeLog

v1.0.0 — Initial contract documentation based on existing implementation
