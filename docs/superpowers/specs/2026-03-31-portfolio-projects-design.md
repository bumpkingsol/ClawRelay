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

### ViewModel
Replace `static let portfolioProjects = [...]` with:
```swift
@Published var portfolioProjects: [String] = []
```

Projects fetched from `GET /context/projects` alongside the existing bridge snapshot poll. On fetch success, assign the returned array. On failure, retain the current value (don't clear it).

### Data Flow
```
Server GET /context/projects
  → MenuBarViewModel.portfolioProjects (polled every 30s)
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
| `mac-helper/.../ViewModels/MenuBarViewModel.swift` | Replace static array with `@Published`, add fetch |
