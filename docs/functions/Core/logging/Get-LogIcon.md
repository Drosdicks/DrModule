# Get-LogIcon — Contract

ContractVersion: 1.0.0  
FunctionVersion: 1.0.0  
Status: Active  
Scope: Core Functions / Logging  
Type: Leaf Utility Function  
Audience: RMM / Non-interactive execution  
Authority: Canonical

---

## Purpose

`Get-LogIcon` resolves an **approved icon name** into a **Unicode emoji** used to decorate log messages.

The function exists to improve **log readability and scanability** in automated environments where no interactive user is present.

It performs a **pure lookup** and does not enforce policy, severity, or correctness.

---

## Approved Icon Rule

- Approved icons are defined **exclusively** by keys present in `$Global:DrLogIcons`
- Any key present in the map is approved
- Aliases and duplicates are **intentional and allowed**
- There is no external or implied approval list

---

## Behavior

### Input

- `-Icon` (string)
  - Case-insensitive
  - Any value is accepted

### Output

- Returns the mapped emoji when the icon key exists
- Returns **`❓`** when the icon key is unknown, null, or empty

---

## Guarantees

- Never throws for unknown or invalid icon names
- Always returns a string
- No side effects
- Safe for RMM and automation-only execution

---

## Non-Guarantees

- No semantic validation of icon meaning
- No severity interpretation
- No logging, output, or state mutation

---

## Unknown Icons

Unknown icon names intentionally resolve to:

```
❓
```

This is **by design** and provides a visible indicator of unsupported or misspelled icon names.

Callers that want **no icon** must explicitly suppress icon output (for example, using `-NoIcon` at the call site).

---

## Performance Characteristics

- Icon mappings are stored at **module scope** (`$Global:DrLogIcons`)
- Lookup is O(1)
- No per-call allocation or table construction

---

## Dependencies

### Requires

- `$Global:DrLogIcons` (hashtable)

### Does Not Call

- Any other module functions
- Any external systems or APIs

---

## Change Rules

Allowed changes:
- Adding new icon mappings
- Adding aliases
- Performance or safety improvements

Any change that alters:
- Fallback behavior
- Return type
- Error handling

**Requires contract version increment and review.**

---

## Summary

`Get-LogIcon` is a **pure, forgiving lookup utility**:
- Flexible
- Fast
- Automation-safe

Its responsibility is to return a usable visual indicator **without ever blocking execution**.
