# Prolog Class-Schedule Generator

Generates every valid combination of class sections for a set of subjects and
serves them as a weekly timetable over HTTP. Built on SWI-Prolog (`swipl:stable`, 10.0.2).

## Files

| File | Purpose |
|------|---------|
| `scheduler.pl` | Pure logic: representation, conflict detection, combination generation |
| `server.pl` | HTTP server: serves the frontend, renders every HTML fragment, parses form input |
| `tests.pl` | plunit test suite (11 tests) |
| `2026.json` | The subject catalogue offered by "Load subjects" |

## Running

```bash
docker compose up
# open http://localhost:8000
```

One container, no Dockerfile. `swipl` serves both the frontend and the endpoints,
so there is no reverse proxy, no second image and no `/api` prefix. The image is
pinned to `stable` rather than `latest`, which tracks SWI's odd-minor development
series. The repo is bind-mounted
read-only at `/app` with the working directory `/app/backend`, which is also how
it runs without Docker:

```bash
cd backend
swipl -g "start(8080), thread_get_message(_)" server.pl
```

Restart the container to pick up a `.pl` edit; frontend edits are live on refresh.

Tests:

```bash
cd backend && swipl -g "load_files(tests), run_tests" -t halt
```

## Prolog representation

```prolog
subject(Name, Sections)     % Name: atom, Sections: non-empty list
section(Id, Slots)          % Id: atom, Slots: non-empty list
slot(Day, Start, End)       % Day ∈ {mon,tue,wed,thu,fri,sat,sun}
                            % Start/End: integer minutes since midnight
```

Times are **half-open intervals** `[Start, End)`. A class ending at 10:00 is compatible with one starting at 10:00. Using integer minutes makes overlap detection pure arithmetic and keeps the solver independent of any time-string format (parsing lives entirely in the HTTP layer).

A generated schedule is a list of `class(SubjectName, section(Id, Slots))`.

## Conflict detection

Two slots conflict iff they share a weekday and their intervals intersect:

```prolog
slot_overlap(slot(Day, S1, E1), slot(Day, S2, E2)) :-
    S1 < E2, S2 < E1.
```

Unifying `Day` in both heads handles "same weekday" for free. Two sections conflict if *any* slot of one overlaps *any* slot of the other (`section_conflict/2`). This is what makes constraint 4 hold automatically: a multi-day section is admitted only when every one of its meetings is conflict-free, because a single overlapping slot disqualifies the whole section.

`section_consistent/1` additionally rejects malformed sections whose own slots overlap each other.

## Generating all combinations

```prolog
valid_schedules(Subjects, Schedule) :-
    dedup_subjects(Subjects, Unique),   % constraint 3
    choose(Unique, [], Schedule).

choose([], Acc, Schedule) :- reverse(Acc, Schedule).
choose([subject(Name, Sections)|Rest], Acc, Schedule) :-
    member(Section, Sections),          % constraint 1: pick exactly one
    section_consistent(Section),
    compatible(Section, Acc),           % constraints 2 & 4
    choose(Rest, [class(Name, Section)|Acc], Schedule).
```

`member/2` is the nondeterministic choice point; Prolog's backtracking enumerates the full search tree, and `compatible/2` prunes any branch as soon as a chosen section clashes with one already accumulated — invalid subtrees are never explored. Each solution of `valid_schedules/2` is one valid combination; the HTTP layer collects them all with `findall/3`. Duplicate subject names in the input are collapsed to their first occurrence, so a subject can never be selected twice.

## HTTP interface

Every response is an HTML fragment; there is no JSON API. The browser runs no
custom JavaScript — only htmx and hyperscript.

| Endpoint | Returns |
|----------|---------|
| `GET /` | the frontend, from `../frontend/public` |
| `GET /subjects/fragment` | the catalogue as `<li>` checkboxes |
| `POST /subjects/form` | `subject=Name&...` → form fieldsets for those subjects (`204` if none ticked) |
| `GET /blank/subject`, `/blank/section`, `/blank/slot` | one empty row, for the `+` buttons |
| `POST /schedules/fragment` | the form → one timetable per valid combination |

Form input is validated in `slot_form//1` and `time_minutes/2`; a bad weekday,
a malformed time or `start >= end` comes back as a styled `<div class="error">`
fragment rather than an HTTP error, because it is swapped into the page as-is.

## Test coverage (`tests.pl`)

- **Overlap detection**: same-day overlap, different days, touching intervals (compatible), containment
- **Overlapping schedules**: conflicting section pairs are pruned from results
- **Multi-day sections**: a section is rejected as a whole if any one of its slots conflicts
- **Duplicate subjects**: repeated subject entries yield the subject exactly once
- **No valid combination**: `valid_schedules/2` fails (the page shows the empty-state card)
- **Self-overlapping section** is never selected
- **Exhaustiveness**: 2×2 conflict-free input yields all 4 combinations; empty input yields the empty schedule

---

# Frontend (HTMX + Hyperscript)

## Project layout

```
scheduler/
├── compose.yaml
├── backend/
│   ├── scheduler.pl        # pure logic
│   ├── server.pl           # HTTP server: static files + every fragment
│   ├── tests.pl
│   └── 2026.json           # subject catalogue
└── frontend/
    └── public/
        ├── index.html      # ~90 lines: structure and htmx/hyperscript wiring
        └── style.css
```

## One representation, one place for markup

`server.pl` speaks the same terms as `scheduler.pl` — `subject(Name, Sections)`,
`section(Id, Slots)`, `slot(Day, Start, End)` with times as minutes since
midnight. JSON and `"HH:MM"` exist only at the edges (`catalogue/1` and the two
time predicates), so the catalogue, the blank rows and the filled rows all
render through the same DCGs.

That is why the page has no `<template>` elements: the `+ Add subject`,
`+ section` and `+ slot` buttons fetch their markup from `/blank/*` instead of
cloning a client-side copy that would have to be kept in step with the Prolog.
Hyperscript keeps the work that needs no server — the `×` buttons and the
subject picker's expand/collapse.

**Two htmx attributes are inherited — `hx-target` and `hx-swap`.** Every element
inside a form that sets them must state its own, or its request silently swaps
into the form's target. This is load-bearing: the picker's `<ul>` and each `+`
button sit inside forms that target `#subjects` and `#results`.

## How the frontend works

- **htmx** fetches all markup and submits both forms, swapping HTML into place.
  **htmx >= 2 is required**: v1.x collects form values into an object keyed by
  field name and emits repeated names grouped together, destroying the document
  order the fragment parser depends on; v2.x serializes from `FormData`, which
  preserves DOM order per spec.
- **Hyperscript** removes rows (`on click remove closest <div.slot-row/>`) and
  toggles the subject picker. Hyperscript processes htmx-swapped nodes on
  `htmx:load`, so server-rendered `_` attributes bind exactly like static ones.
- **The picker animates** with a `grid-template-rows: 0fr → 1fr` transition, so
  it eases to the content's real height without a `max-height` guess. Its list
  loads at page load rather than on first click — otherwise the first open
  animates toward an empty box and jumps when the content lands.

## `POST /schedules/fragment` — hypermedia endpoint

Instead of teaching the browser to build JSON, the backend accepts the form
encoding the browser already produces. Field **order** encodes the tree:

```
name=algebra & id=A & day=mon & start=08:00 & end=10:00
             &        day=wed & start=08:00 & end=10:00
             & id=B & day=tue & start=14:00 & end=16:00
name=programming & ...
```

Each `name` opens a subject, each `id` opens a section within it, and each
`day/start/end` triple is a slot. The flat pair list is parsed by a DCG in
`server.pl` (`subjects_form//1`) — the grammar is LL(1) on the field keys, so
no client-side bookkeeping (indices, hidden fields) is needed at all.

The response is an HTML fragment: one `<article class="combo">` per valid
combination, each containing a CSS-grid **weekly timetable** whose cell
positions (`grid-column` / `grid-row`) are computed by Prolog from the slot
times (30-minute rows, bounds derived per combination). Errors come back as a
styled `<div class="error">` fragment; "no valid combination" is a distinct
empty-state card, not an error.
## Verification performed

- All 11 plunit tests pass.
- Every route exercised over HTTP: page, stylesheet, all three `/blank/*` rows,
  the catalogue fragment, `/subjects/form` (including the `204` empty case), and
  `/schedules/fragment`.
- A missing file returns `404`; path traversal (`../`, percent-encoded, and
  `../../etc/passwd`) is rejected by SWI's `http_safe_file` with no content
  leaked — it answers `500` rather than `403`, which is cosmetic.
- Driven end to end in headless Firefox: page-load blank subject, `+ Add
  subject`, `+ section` and `+ slot` each targeting the right container,
  `×` removal, picker open/collapse across repeated and rapid clicks, ticking
  boxes, `Load selected` (2 subjects, 7 and 13 sections, picker auto-closed),
  and `Generate schedules` returning 71 combinations.
- All hyperscript attributes — page and server-rendered — parsed with the real
  `_hyperscript` engine; a silent no-op is the failure mode otherwise.
