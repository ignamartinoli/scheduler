# Prolog Class-Schedule Generator

Generates every valid combination of class sections for a set of subjects and exposes them over HTTP as JSON. Built on SWI-Prolog (tested with 9.0.4).

## Files

| File | Purpose |
|------|---------|
| `scheduler.pl` | Pure logic: representation, conflict detection, combination generation |
| `server.pl` | HTTP endpoint, JSON parsing/encoding, error handling |
| `tests.pl` | plunit test suite (11 tests) |
| `example.json` | Sample request body |

## Running

```bash
swipl -g "use_module(server), start(8080), thread_get_message(_)"
```

Tests:

```bash
swipl -g "load_files(tests), run_tests" -t halt
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

## HTTP API

### `POST /schedules`

Request (`Content-Type: application/json`):

```json
{
  "subjects": [
    {
      "name": "algebra",
      "sections": [
        { "id": "A",
          "slots": [ { "day": "mon", "start": "08:00", "end": "10:00" },
                     { "day": "wed", "start": "08:00", "end": "10:00" } ] },
        { "id": "B",
          "slots": [ { "day": "tue", "start": "14:00", "end": "16:00" } ] }
      ]
    },
    {
      "name": "programming",
      "sections": [
        { "id": "P1", "slots": [ { "day": "mon", "start": "09:00", "end": "11:00" } ] },
        { "id": "P2", "slots": [ { "day": "thu", "start": "09:00", "end": "11:00" } ] }
      ]
    }
  ]
}
```

- `day`: one of `mon tue wed thu fri sat sun`
- `start`/`end`: `"HH:MM"`, 24-hour, `start < end`

Response `200` (actual output for the request above — `algebra A + programming P1` is excluded because both meet Monday 08:00–10:00 / 09:00–11:00):

```json
{
  "count": 3,
  "schedules": [
    [ { "subject": "algebra", "section": "A",
        "slots": [ { "day": "mon", "start": "08:00", "end": "10:00" },
                   { "day": "wed", "start": "08:00", "end": "10:00" } ] },
      { "subject": "programming", "section": "P2",
        "slots": [ { "day": "thu", "start": "09:00", "end": "11:00" } ] } ],
    [ { "subject": "algebra", "section": "B",
        "slots": [ { "day": "tue", "start": "14:00", "end": "16:00" } ] },
      { "subject": "programming", "section": "P1",
        "slots": [ { "day": "mon", "start": "09:00", "end": "11:00" } ] } ],
    [ { "subject": "algebra", "section": "B",
        "slots": [ { "day": "tue", "start": "14:00", "end": "16:00" } ] },
      { "subject": "programming", "section": "P2",
        "slots": [ { "day": "thu", "start": "09:00", "end": "11:00" } ] } ]
  ]
}
```

When no combination exists, the response is `200` with `{"count": 0, "schedules": []}` — an unsatisfiable timetable is a valid answer, not an error.

### Errors — `400` with `{"error": "..."}`

Verified responses:

| Input | Response |
|-------|----------|
| `"day": "monday"` | `{"error":"unknown weekday: monday"}` |
| `"start": "8am"` | `{"error":"bad time (expected HH:MM): 8am"}` |
| `"start":"10:00","end":"08:00"` | `{"error":"start must precede end (got 10:00 >= 08:00)"}` |
| `{not json` | `{"error":"invalid request: ... Syntax error: json(illegal_json)"}` |
| `{"foo": 1}` | `{"error":"body must be {\"subjects\": [...]}"}` |
| empty `sections` / `slots` | `{"error":"subject has no sections"}` etc. |

### Example requests

```bash
curl -X POST http://localhost:8080/schedules \
     -H 'Content-Type: application/json' -d @example.json

# No valid combination -> {"count":0,"schedules":[]}
curl -X POST http://localhost:8080/schedules \
     -H 'Content-Type: application/json' \
     -d '{"subjects":[
           {"name":"a","sections":[{"id":"A1","slots":[{"day":"mon","start":"08:00","end":"10:00"}]}]},
           {"name":"b","sections":[{"id":"B1","slots":[{"day":"mon","start":"09:00","end":"11:00"}]}]}]}'
```

## Test coverage (`tests.pl`)

- **Overlap detection**: same-day overlap, different days, touching intervals (compatible), containment
- **Overlapping schedules**: conflicting section pairs are pruned from results
- **Multi-day sections**: a section is rejected as a whole if any one of its slots conflicts
- **Duplicate subjects**: repeated subject entries yield the subject exactly once
- **No valid combination**: `valid_schedules/2` fails (HTTP returns `count: 0`)
- **Self-overlapping section** is never selected
- **Exhaustiveness**: 2×2 conflict-free input yields all 4 combinations; empty input yields the empty schedule

---

# Frontend (HTMX + Hyperscript) and Docker Compose

## Project layout

```
horarios/
├── compose.yaml
├── backend/
│   ├── scheduler.pl        # unchanged pure logic
│   ├── server.pl           # + POST /schedules/fragment (HTML endpoint)
│   ├── tests.pl
│   └── example.json
└── frontend/
    ├── nginx.conf          # static files + /api/ reverse proxy
    └── public/
        ├── index.html      # HTMX + Hyperscript, no custom JS
        └── style.css
```

## Running

```bash
docker compose up
# open http://localhost:8000
```

No Dockerfiles: both services run stock images (`swipl:9.2`, `nginx:1.27-alpine`)
with bind mounts. The backend mounts `./backend` read-only at `/app` and
overrides the command; the frontend mounts `nginx.conf` and `public/` into the
stock nginx paths. Edit a `.pl` file and restart the backend container to
reload; frontend edits are live on refresh. Note the swipl image's entrypoint
is `swipl` itself, which is why `compose.yaml` states `entrypoint` explicitly
and passes only arguments in `command`.

nginx serves the page and proxies `/api/` to `backend:8080`, so the browser
talks to a single origin — no CORS. The backend port is not published on the
host; the JSON API remains reachable at `http://localhost:8000/api/schedules`.

## How the frontend works

There is **zero custom JavaScript**. The page is a plain HTML form:

- **Hyperscript** handles the dynamic structure — each "+ Add subject",
  "+ section", "+ slot" button clones a `<template>` (`on click put
  #tpl-slot.content.cloneNode(true) at the end of the first <div.slots/> in
  the closest <div.section/>`), and each `×` removes its closest block.
- **HTMX** submits the form (`hx-post="/api/schedules/fragment"`) with native
  urlencoded serialization and swaps the returned HTML into `#results`.
  **htmx >= 2 is required**: v1.x collects form values into an object keyed by
  field name and emits repeated names grouped together, destroying the
  document order the fragment parser depends on; v2.x serializes from
  `FormData`, which preserves DOM order per spec.

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

- All 11 plunit tests still pass; the JSON endpoint is unchanged.
- Fragment endpoint exercised over HTTP: 3-combination example, no-valid-combination,
  bad time order, empty form.
- The exact `nginx.conf` was run locally (with `backend` → `127.0.0.1`):
  static page, `style.css`, and both `/api/` routes verified through the proxy.
- All 11 Hyperscript attributes parsed with the real `_hyperscript` engine in
  jsdom, and every add/remove interaction simulated with click events —
  structure counts correct after each step.
- `FormData` field order from the live DOM confirmed to match the DCG's
  expected stream: `name,id,day,start,end,id,day,start,end`.

Vue/Nuxt escape hatch: if the form builder ever outgrows this (drag-and-drop,
client-side validation across fields, persistence), the JSON endpoint is
already there for a fat client — nothing about the backend would change.
