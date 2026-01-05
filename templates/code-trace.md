# Code Trace: {Operation Name}

> Tracing the path of `{function_call()}` from user code to {outcome}.

## Overview

**Framework**: {Framework Name}
**Operation**: {What we're tracing}
**Files Touched**: {count}

## User Code

```{language}
// The code a user would write
{user_code}
```

## Call Stack

### 1. Entry Point
**File**: `path/to/file.ext:{line}`

```{language}
{relevant_code}
```

**What happens**: {explanation}

---

### 2. {Next Step}
**File**: `path/to/file.ext:{line}`

```{language}
{relevant_code}
```

**What happens**: {explanation}

---

### 3. {Continue as needed...}

---

## Data Flow Diagram

```
User Code
    │
    ▼
┌──────────────┐
│  Function A  │
└──────────────┘
    │
    ▼
┌──────────────┐
│  Function B  │
└──────────────┘
    │
    ▼
{Final Outcome}
```

## Key Observations

1. **Observation 1**: {What's notable about this flow?}
2. **Observation 2**: {Any performance considerations?}
3. **Observation 3**: {Patterns worth adopting or avoiding?}

## Implications for Rust Framework

- {How would you implement this differently?}
- {What can be borrowed directly?}
