:- module(server, [start/1, stop/1]).

/** <module> HTTP interface for the schedule generator

Endpoint
--------
  POST /schedules            Content-Type: application/json

Request body:
  { "subjects": [
      { "name": "algebra",
        "sections": [
          { "id": "A",
            "slots": [ { "day": "mon", "start": "08:00", "end": "10:00" } ] }
        ] }
  ] }

Response 200:
  { "count": N,
    "schedules": [
      [ { "subject": "algebra", "section": "A",
          "slots": [ { "day": "mon", "start": "08:00", "end": "10:00" } ] } ]
    ] }

Errors:
  400 { "error": Message }   malformed JSON, unknown weekday, bad time
                             string, start >= end, empty sections, etc.
*/

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(scheduler).

:- http_handler(root(schedules), handle_schedules, [method(post)]).

start(Port) :- http_server(http_dispatch, [port(Port)]).
stop(Port)  :- http_stop_server(Port, []).

handle_schedules(Request) :-
    catch(
        ( http_read_json_dict(Request, In),
          parse_subjects(In, Subjects),
          findall(S, valid_schedules(Subjects, S), Schedules),
          maplist(schedule_json, Schedules, Out),
          length(Out, N),
          reply_json_dict(_{count: N, schedules: Out})
        ),
        Error,
        reply_error(Error)).

reply_error(bad_request(Msg)) :- !,
    reply_json_dict(_{error: Msg}, [status(400)]).
reply_error(Error) :-
    message_to_string(Error, Msg),
    string_concat("invalid request: ", Msg, Full),
    reply_json_dict(_{error: Full}, [status(400)]).

%--- request parsing -------------------------------------------------

parse_subjects(Dict, Subjects) :-
    (   is_dict(Dict), get_dict(subjects, Dict, List), is_list(List)
    ->  maplist(parse_subject, List, Subjects)
    ;   throw(bad_request("body must be {\"subjects\": [...]}"))
    ).

parse_subject(D, subject(Name, Sections)) :-
    field(D, name, string, NameS),
    atom_string(Name, NameS),
    field(D, sections, list, SecList),
    (   SecList == []
    ->  throw(bad_request("subject has no sections"))
    ;   maplist(parse_section, SecList, Sections)
    ).

parse_section(D, section(Id, Slots)) :-
    field(D, id, string, IdS),
    atom_string(Id, IdS),
    field(D, slots, list, SlotList),
    (   SlotList == []
    ->  throw(bad_request("section has no slots"))
    ;   maplist(parse_slot, SlotList, Slots)
    ).

parse_slot(D, slot(Day, Start, End)) :-
    field(D, day, string, DayS),
    atom_string(Day, DayS),
    (   weekday(Day) -> true
    ;   format(string(M), "unknown weekday: ~w", [Day]),
        throw(bad_request(M))
    ),
    field(D, start, string, StartS), time_minutes(StartS, Start),
    field(D, end,   string, EndS),   time_minutes(EndS, End),
    (   Start < End -> true
    ;   format(string(M2), "start must precede end (got ~w >= ~w)",
               [StartS, EndS]),
        throw(bad_request(M2))
    ).

field(D, Key, Type, Value) :-
    (   is_dict(D), get_dict(Key, D, Value), of_type(Type, Value)
    ->  true
    ;   format(string(M), "missing or invalid field: ~w", [Key]),
        throw(bad_request(M))
    ).

of_type(string, V) :- string(V).
of_type(list, V)   :- is_list(V).

%!  time_minutes(+String, -Minutes) is det.
%
%   "HH:MM" -> minutes since midnight, validating ranges.

time_minutes(S, Minutes) :-
    (   split_string(S, ":", "", [Hs, Ms]),
        number_string(H, Hs), number_string(M, Ms),
        integer(H), integer(M),
        between(0, 23, H), between(0, 59, M)
    ->  Minutes is H * 60 + M
    ;   format(string(Msg), "bad time (expected HH:MM): ~w", [S]),
        throw(bad_request(Msg))
    ).

%--- response encoding -----------------------------------------------

schedule_json(Schedule, Json) :-
    maplist(class_json, Schedule, Json).

class_json(class(Name, section(Id, Slots)), 
           _{subject: Name, section: Id, slots: SlotsJson}) :-
    maplist(slot_json, Slots, SlotsJson).

slot_json(slot(Day, S, E), _{day: Day, start: Ss, end: Es}) :-
    minutes_time(S, Ss),
    minutes_time(E, Es).

minutes_time(Minutes, String) :-
    H is Minutes // 60,
    M is Minutes mod 60,
    format(string(String), "~`0t~d~2|:~`0t~d~5|", [H, M]).

%=====================================================================
% HTML fragment endpoint (hypermedia interface for the HTMX frontend)
%=====================================================================
%
%   POST /schedules/fragment    Content-Type: application/x-www-form-urlencoded
%
%   Accepts a plain HTML form. Field order encodes the tree:
%
%     name=algebra & id=A & day=mon & start=08:00 & end=10:00
%                  & id=B & day=tue & ...
%     name=prog    & ...
%
%   Each `name` opens a subject, each `id` opens a section, each
%   day/start/end triple is a slot. The flat pair list is parsed by a
%   DCG. Replies with an HTML fragment: one mini weekly timetable per
%   valid combination.

:- use_module(library(http/html_write)).
:- use_module(library(http/http_client)).

:- http_handler(root(schedules/fragment), handle_fragment, [method(post)]).

handle_fragment(Request) :-
    http_read_data(Request, Pairs, []),
    catch(
        ( parse_form(Pairs, Subjects),
          findall(S, valid_schedules(Subjects, S), Schedules),
          subject_names(Subjects, Names),
          reply_fragment(results(Names, Schedules))
        ),
        bad_request(Msg),
        reply_fragment(error(Msg))).

subject_names(Subjects, Names) :-
    findall(N, member(subject(N, _), Subjects), Names).

reply_fragment(Spec) :-
    phrase(fragment(Spec), Tokens),
    format('Content-type: text/html; charset=UTF-8~n~n'),
    print_html(Tokens).

%--- form parsing (DCG over the ordered Key=Value list) ---------------

parse_form(Pairs, Subjects) :-
    (   phrase(subjects_form(Subjects), Pairs),
        Subjects \== []
    ->  true
    ;   throw(bad_request("Add at least one subject with a section and a time slot."))
    ).

subjects_form([S|Ss]) --> subject_form(S), !, subjects_form(Ss).
subjects_form([])     --> [].

subject_form(subject(Name, Sections)) -->
    [name=V],
    { nonempty_atom(V, Name, "Every subject needs a name.") },
    sections_form(Sections),
    { Sections \== [] -> true
    ; throw(bad_request("Every subject needs at least one section."))
    }.

sections_form([S|Ss]) --> section_form(S), !, sections_form(Ss).
sections_form([])     --> [].

section_form(section(Id, Slots)) -->
    [id=V],
    { nonempty_atom(V, Id, "Every section needs an id.") },
    slots_form(Slots),
    { Slots \== [] -> true
    ; throw(bad_request("Every section needs at least one time slot."))
    }.

slots_form([S|Ss]) --> slot_form(S), !, slots_form(Ss).
slots_form([])     --> [].

slot_form(slot(Day, Start, End)) -->
    [day=DayV, start=Sv, end=Ev],
    { to_atom(DayV, Day),
      (   weekday(Day) -> true
      ;   format(string(M), "Unknown weekday: ~w", [Day]),
          throw(bad_request(M))
      ),
      atom_minutes(Sv, Start),
      atom_minutes(Ev, End),
      (   Start < End -> true
      ;   format(string(M2), "Start must precede end (got ~w >= ~w).", [Sv, Ev]),
          throw(bad_request(M2))
      )
    }.

nonempty_atom(V, Atom, Error) :-
    to_atom(V, Atom0),
    normalize_space(atom(Atom), Atom0),
    (   Atom == '' -> throw(bad_request(Error)) ; true ).

to_atom(V, A) :- ( atom(V) -> A = V ; term_to_atom(A, V) ).

atom_minutes(V, Minutes) :-
    atom_string(V, S),
    time_minutes(S, Minutes).

%--- fragment rendering -----------------------------------------------

fragment(error(Msg)) -->
    html(div(class(error), [span(class('error-mark'), '!'), Msg])).

fragment(results(_, [])) -->
    html(div(class(empty),
             [ h3('No valid combination'),
               p('Every way of picking one section per subject produces a time conflict.')
             ])).

fragment(results(Names, Schedules)) -->
    { length(Schedules, N),
      ( N =:= 1 -> Word = combination ; Word = combinations ) },
    html([ p(class('results-count'), [b(N), ' valid ', Word]),
           \combo_cards(Schedules, 1, Names)
         ]).

combo_cards([], _, _) --> [].
combo_cards([S|Ss], I, Names) -->
    combo_card(S, I, Names),
    { I1 is I + 1 },
    combo_cards(Ss, I1, Names).

combo_card(Schedule, I, Names) -->
    { legend_items(Schedule, Names, Legend),
      timetable_geometry(Schedule, Days, MinH, MaxH),
      NRows is (MaxH - MinH) * 2,
      length(Days, NDays),
      format(atom(GridStyle),
             'grid-template-columns: 2.6rem repeat(~w, 1fr); grid-template-rows: 1.6rem repeat(~w, 0.85rem);',
             [NDays, NRows])
    },
    html(article(class(combo),
                 [ header([span(class('combo-n'), ['#', I]), ul(class(legend), Legend)]),
                   div([class(timetable), style(GridStyle)],
                       [ \day_headers(Days, 2),
                         \hour_labels(MinH, MaxH),
                         \slot_blocks(Schedule, Names, Days, MinH)
                       ])
                 ])).

legend_items(Schedule, Names, Items) :-
    findall(li([span(class(Cls), ''), b(Name), ' / ', Id]),
            ( member(class(Name, section(Id, _)), Schedule),
              subject_class(Name, Names, Cls)
            ),
            Items).

subject_class(Name, Names, Cls) :-
    nth0(Ix, Names, Name), !,
    C is Ix mod 6,
    format(atom(Cls), 'c~w', [C]).

timetable_geometry(Schedule, Days, MinH, MaxH) :-
    findall(slot(D, S, E),
            ( member(class(_, section(_, Slots)), Schedule),
              member(slot(D, S, E), Slots) ),
            All),
    ( memberchk(slot(sun, _, _), All) -> Days = [mon, tue, wed, thu, fri, sat, sun]
    ; memberchk(slot(sat, _, _), All) -> Days = [mon, tue, wed, thu, fri, sat]
    ; Days = [mon, tue, wed, thu, fri]
    ),
    aggregate_all(min(S), member(slot(_, S, _), All), MinStart),
    aggregate_all(max(E), member(slot(_, _, E), All), MaxEnd),
    MinH is MinStart // 60,
    MaxH is (MaxEnd + 59) // 60.

day_headers([], _) --> [].
day_headers([D|Ds], Col) -->
    { format(atom(St), 'grid-column: ~w; grid-row: 1;', [Col]),
      Col1 is Col + 1 },
    html(div([class(dayhead), style(St)], D)),
    day_headers(Ds, Col1).

hour_labels(MinH, MaxH) --> hour_labels_(MinH, MinH, MaxH).

hour_labels_(_, H, MaxH) --> { H >= MaxH }, !, [].
hour_labels_(MinH, H, MaxH) -->
    { Row is (H - MinH) * 2 + 2,
      Row2 is Row + 2,
      format(atom(St), 'grid-column: 1; grid-row: ~w / ~w;', [Row, Row2]),
      format(atom(Label), '~`0t~d~2|', [H]),
      H1 is H + 1 },
    html(div([class(hour), style(St)], Label)),
    hour_labels_(MinH, H1, MaxH).

slot_blocks(Schedule, Names, Days, MinH) -->
    { findall(Block,
              ( member(class(Name, section(Id, Slots)), Schedule),
                subject_class(Name, Names, Cls),
                member(slot(D, S, E), Slots),
                nth0(DIx, Days, D),
                Col is DIx + 2,
                R1 is (S - MinH * 60) // 30 + 2,
                R2 is (E - MinH * 60 + 29) // 30 + 2,
                minutes_time(S, Ss), minutes_time(E, Es),
                format(atom(St), 'grid-column: ~w; grid-row: ~w / ~w;', [Col, R1, R2]),
                format(atom(Title), '~w ~w (~w-~w)', [Name, Id, Ss, Es]),
                Block = div([class(['slot', Cls]), style(St), title(Title)],
                            [b(Name), span([Id, ' ', Ss])])
              ),
              Blocks) },
    html(Blocks).
