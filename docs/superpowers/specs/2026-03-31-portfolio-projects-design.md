# Portfolio Projects — Design Spec

**Date:** 2026-03-31
**Status:** Approved

## Goal

Replace the hardcoded `portfolioProjects` array in `MenuBarViewModel` with a real data source fetched from the server. Projects are managed by the operator (read-only from the Mac side).

## Schema

```sql
CREATE TABLE portfolio_projects (
    name TEXT PRIMARY KEY
);
```

Single column — no display_name, no sort_order. `name` is the slug (e.g. `"project-gamma"`). `display_name` is derived client-side by capitalizing the slug (e.g. `"Project Gamma"`).

## Server Changes

### Migration
Add `portfolio_projects` table to the database on server startup.

### Endpoint
```
GET /context/projects
Authorization: Bearer <token>

Response 200:
{ "projects": ["project-alpha", "project-beta", "project-gamma", "project-delta", "openclaw"] }

Response 401:
{ "error": "Unauthorized" }
```

Projects returned sorted alphabetically by `name`.

### Error Handling
- Missing/invalid token → 401
- Database error → 500 with `{ "error": "..." }`

## Mac Changes

### Shell Script
Add `do_fetch_projects` function and `projects` dispatch case to `~/.context-bridge/bin/context-helperctl.sh`. Follows the same pattern as `do_fetch_dashboard` — reads `server-url`, reads auth token from keychain, curls `GET /context/projects`.

```bash
do_fetch_projects() {
  # Reads server-url from $(cb_dir)/server-url
  # Reads auth token from keychain
  # Curl: GET /context/projects
  # Returns: { "projects": [...] } on success, {} on failure
}
```

### ViewModel
Replace `static let portfolioProjects = [...]` with:
```swift
@Published var portfolioProjects: [String] = []
```

Fetched via `runner.runActionWithOutput("projects")` in `refresh()`, on the same 5s poll cycle as everything else. On fetch success, decode `{"projects": [...]}` and assign. On failure, retain the current value.

### Data Flow
```
Server GET /context/projects
  → context-helperctl.sh (projects action)
    → MenuBarViewModel.portfolioProjects (polled every 5s with refresh())
      → MenuBarPopoverView project picker
        → Handoff sends project slug to /handoff on selection
```

### Fallback
If the fetch fails (network error, server down), the picker shows whatever was last loaded — defaulting to `[]` on first launch. No error UI.

## Out of Scope

- Adding/removing projects from the Mac app (read-only)
- Display name customization (derived from slug)
- Project reordering
- Auto-populating from `project_last_seen` or handoff history

## Files Modified

| File | Change |
|------|--------|
| `server/context-receiver.py` | Add migration, `GET /context/projects` endpoint |
| `~/.context-bridge/bin/context-helperctl.sh` | Add `do_fetch_projects` + `projects` dispatch case |
| `mac-helper/.../ViewModels/MenuBarViewModel.swift` | Replace static array with `@Published`, add fetch |
