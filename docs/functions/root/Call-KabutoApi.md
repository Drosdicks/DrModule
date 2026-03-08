# Call-KabutoApi

## Overview
`Call-KabutoApi` is a core helper function used to communicate with the Kabuto / Syncro RMM device API. It constructs and sends REST requests to the API host defined in DrModule globals and optionally serializes request data as JSON.

This function is intended to be a low-level API wrapper used by higher-level API callers within DrModule.

---

## Requirements
The following global variables **must** be set before calling this function:

- **`$Global:UUID`**  
  Identifies the current device. If not set, the function exits with an error.

- **`$Global:DrRepairTechKabutoApiUrl`**  
  Base API URL (typically `https://rmm.syncromsp.com`).

---

## Syntax
```powershell
Call-KabutoApi -Method <string> -Path <string> [-Data <object>] [-DebugOutput]
```

---

## Parameters

### `-Method` (Required)
HTTP method to use for the request.

Supported values:
- `GET`
- `POST`
- `PUT`
- `DELETE`

---

### `-Path` (Required)
Relative API path appended to `$Global:DrRepairTechKabutoApiUrl`.

Example:
```text
/device_api/rmm_alert
```

---

### `-Data` (Optional)
Object to be sent as the request body.

- Converted to JSON using `ConvertTo-Json -Depth 5`
- Encoded as UTF-8 bytes
- Sent as the request body

If omitted, no request body is sent.

---

### `-DebugOutput` (Optional)
When specified, writes request diagnostics to the host:

- Full request URI
- HTTP method
- Request headers
- Body type
- Serialized JSON payload

Intended for troubleshooting and API validation.

---

## Behavior
- Validates required global variables before executing
- Automatically sets `Content-Type: application/json`
- Uses `Invoke-RestMethod` for execution
- Returns the deserialized response object on success
- Writes a terminating error message on failure

---

## Output

**Returns:**
- The object returned by `Invoke-RestMethod` on success
- No output if the request fails

---

## Examples

### Send an RMM Alert
```powershell
Call-KabutoApi -Method POST -Path "/device_api/rmm_alert" -Data @{
    uuid    = $Global:UUID
    message = "Test alert"
}
```

---

### GET Request Without a Body
```powershell
Call-KabutoApi -Method GET -Path "/device_api/some_resource"
```

---

### Debugging an API Call
```powershell
Call-KabutoApi -Method POST -Path "/device_api/rmm_alert" -Data @{ test = $true } -DebugOutput
```

---

## Notes
- This function does **not** perform authentication; it relies on the Syncro/Kabuto runtime environment.
- Designed for internal use within DrModule API wrappers.
- Error handling is intentionally minimal; callers should handle failures explicitly if required.
