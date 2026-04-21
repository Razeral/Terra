# Tests — Per-Task Verification Artefacts

Every coder task (any pipeline, any role) produces a folder here named after the task ID: `tests/<task-id>/`. These artefacts are REQUIRED before a task can be marked `status: done`. Reviewer tasks fail any work whose artefacts are missing or incomplete.

## Required contents

```
tests/
└── <task-id>/
    ├── checklist.md        # filled verification checklist
    ├── build.log           # raw build output (npm run build / tsc -b / pytest --collect-only)
    ├── unit-tests.log      # raw test suite output (npx vitest run / pytest / go test)
    ├── summary.md          # 2–3 sentences for the reviewer
    └── playwright/         # only if the task touched UI
        ├── screenshots/
        │   ├── 01-initial.png
        │   ├── 02-after-action.png
        │   └── …
        └── session.md      # what URLs visited, what was checked, any console errors
```

## `checklist.md` format

Use this template. Tick each item `[x]` or leave `[ ]` with a note.

```markdown
# Verification Checklist — task-<id>

## Build
- [x] `npm run build` passes (see build.log)
- [x] No TypeScript errors
- [x] No new lint warnings introduced

## Unit / component tests
- [x] Existing test suite passes (see unit-tests.log)
- [x] Added tests for new behavior (list below)
  - `foo.test.tsx` covers the new sidebar collapse state
- [ ] Tests for edge case X — deferred because …

## UI (if applicable)
- [x] Primary user flow works end-to-end (see playwright/screenshots/)
- [x] No console errors in the browser (see playwright/session.md)
- [x] Responsive breakpoints checked: 1024 / 1440 / 1920
- [x] Keyboard navigation: Tab / Esc / Enter handled
- [x] Dark and light themes both render correctly

## Integration
- [x] API calls succeed against stg backend
- [x] Existing features not broken (smoke-tested: project list, mode switch, deploy)

## Deployment readiness
- [x] No secrets in client bundle
- [x] No hardcoded dev URLs
- [x] Feature-flagged appropriately (if applicable)

## Known issues / caveats
- None | or list them here

## Screenshots index (if UI task)
- `01-initial.png` — first render of the new surface
- `02-after-action.png` — after clicking the primary CTA
- `03-error-state.png` — invalid input handled
```

## `summary.md` format

```markdown
# Summary — task-<id>

Built <what>. Verified <what>. Known risks: <anything the reviewer should scrutinize>.
```

Two to three sentences. Not a changelog.

## `playwright/session.md` format

```markdown
# Playwright session — task-<id>

URLs visited:
- https://your-app.example.com/
- https://your-app.example.com/#/flow-under-test

Steps:
1. Navigated to hero; clicked "Start a Pitch" → modal opened (screenshots/01-*)
2. Filled step 1 "Headline" → Next button enabled (screenshots/02-*)
3. …

Console errors observed: none | or list them

Accessibility snapshot notes: tab order OK; modal has focus trap; Esc closes.
```

## Why root-level

`tests/` lives at the Terra repo root, NOT inside project subdirectories. This way artefacts survive when sub-mayor auto-merges a worktree — only root-level paths make it through the squash. Put artefacts anywhere else and they'll be lost.

## Size expectations

Keep screenshots under 1 MB each (use `full_page: false` unless the flow requires scrolling). Log files under 100 KB (truncate verbose sections with `# ...truncated...`). Whole folder should stay under 10 MB — budget tight so reviewers can scan quickly and git history stays clean.
