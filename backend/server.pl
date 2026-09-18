:- module(server, [start/1, stop/1]).

/** <module> HTTP interface for the schedule generator

Serves the frontend and the hypermedia endpoints it talks to. Every
response is an HTML fragment; there is no JSON API and no client-side
JavaScript.

  GET  /                     the frontend (../frontend/public)
  GET  /subjects/fragment    the catalogue as <li> checkboxes
  POST /subjects/form        subject=Name&... -> form fieldsets
  GET  /blank/subject        one empty subject / section / slot, for the
  GET  /blank/section        "+ Add subject", "+ section" and "+ slot"
  GET  /blank/slot           buttons
  POST /schedules/fragment   the form -> one timetable per valid combination

Markup lives here only: the page carries no <template> copies of it.
Forms and fragments both speak the representation scheduler.pl uses --
subject(Name, Sections), section(Id, Slots), slot(Day, Start, End) with
times as minutes since midnight -- so JSON and "HH:MM" exist only at the
edges, in catalogue/1 and the two time predicates.
*/

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_files)).
:- use_module(library(http/http_client)).
:- use_module(library(http/html_write)).
:- use_module(library(http/json)).
:- use_module(scheduler).

start(Port) :- http_server(http_dispatch, [port(Port)]).
stop(Port)  :- http_stop_server(Port, []).

%   The frontend is served by this same server: no proxy, no second
%   container, no /api prefix. Longer paths below take precedence.
:- http_handler(root(.), serve_static, [prefix]).

serve_static(Request) :- http_reply_from_files('../frontend/public', [], Request).
serve_static(Request) :- http_404([], Request).   % the files handler fails, not 404s

:- http_handler(root(schedules/fragment), handle_fragment,    [method(post)]).
:- http_handler(root(subjects/fragment),  handle_subject_list, [method(get)]).
:- http_handler(root(subjects/form),      handle_subject_form, [method(post)]).
:- http_handler(root(blank/subject),      handle_blank(subject), [method(get)]).
:- http_handler(root(blank/section),      handle_blank(section), [method(get)]).
:- http_handler(root(blank/slot),         handle_blank(slot),    [method(get)]).

%!  reply_markup(:Body) is det.
%
%   Reply with the HTML that the html//1 DCG Body produces.

reply_markup(Body) :-
    phrase(Body, Tokens),
    format('Content-type: text/html; charset=UTF-8~n~n'),
    print_html(Tokens).

%=====================================================================
% The catalogue
%=====================================================================

%!  catalogue(-Subjects) is det.
%
%   2026.json as scheduler terms. Re-read per request: it is 165 kB and
%   a page load asks for it at most twice.

catalogue(Subjects) :-
    setup_call_cleanup(
        open('2026.json', read, In, [encoding(utf8)]),
        json_read_dict(In, Dict),
        close(In)),
    maplist(dict_subject, Dict.subjects, Subjects).

dict_subject(D, subject(Name, Sections)) :-
    atom_string(Name, D.name),
    maplist(dict_section, D.sections, Sections).

dict_section(D, section(Id, Slots)) :-
    atom_string(Id, D.id),
    maplist(dict_slot, D.slots, Slots0),
    list_to_set(Slots0, Slots).   % the catalogue repeats each slot per term

dict_slot(D, slot(Day, Start, End)) :-
    atom_string(Day, D.day),
    time_minutes(D.start, Start),
    time_minutes(D.end, End).

handle_subject_list(_Request) :-
    catch(( catalogue(Subjects),
            findall(Item, ( nth0(I, Subjects, S), checkbox_item(I, S, Item) ), Items),
            reply_markup(html(Items))
          ),
          E,
          ( message_to_string(E, M), reply_markup(fragment(error(M))) )).

%   --i carries the index so CSS can stagger the reveal animation.
checkbox_item(I, subject(Name, _), li(style(Style), label([input(Attrs), ' ', Name]))) :-
    format(atom(Style), '--i: ~w', [I]),
    Attrs = [type(checkbox), name(subject), value(Name)].

handle_subject_form(Request) :-
    http_read_data(Request, Pairs, []),
    findall(Name, member(subject=Name, Pairs), Names),
    (   Names == []
    ->  throw(http_reply(no_content))   % nothing ticked: htmx leaves the form alone
    ;   catalogue(Subjects),
        include(picked_subject(Names), Subjects, Picked),
        reply_markup(subject_fieldsets(Picked))
    ).

picked_subject(Names, subject(Name, _)) :- memberchk(Name, Names).

%=====================================================================
% Form markup
%=====================================================================

handle_blank(subject, _Request) :- blank_subject(S), reply_markup(subject_fieldsets([S])).
handle_blank(section, _Request) :- blank_section(S), reply_markup(section_divs([S])).
handle_blank(slot,    _Request) :- blank_slot(S),    reply_markup(slot_rows([S])).

blank_subject(subject('', [Section])) :- blank_section(Section).
blank_section(section('', [Slot]))    :- blank_slot(Slot).
blank_slot(slot(mon, 480, 600)).

subject_fieldsets([]) --> [].
subject_fieldsets([subject(Name, Sections)|Ss]) -->
    html(fieldset(class(subject),
                  [ div(class('subject-head'),
                        [ input([type(text), name(name), value(Name),
                                 placeholder('Subject name (e.g. algebra)'), required(required)]),
                          \remove_button('Remove subject', 'fieldset.subject')
                        ]),
                    div(class(sections), \section_divs(Sections)),
                    \add_button('/blank/section', 'previous .sections', '+ section')
                  ])),
    subject_fieldsets(Ss).

section_divs([]) --> [].
section_divs([section(Id, Slots)|Ss]) -->
    html(div(class(section),
             [ div(class('section-head'),
                   [ input([type(text), name(id), value(Id),
                            placeholder('Section id (e.g. A)'), required(required)]),
                     \remove_button('Remove section', 'div.section')
                   ]),
               div(class(slots), \slot_rows(Slots)),
               \add_button('/blank/slot', 'previous .slots', '+ slot')
             ])),
    section_divs(Ss).

slot_rows([]) --> [].
slot_rows([slot(Day, Start, End)|Ss]) -->
    { minutes_time(Start, Ss1), minutes_time(End, Es) },
    html(div(class('slot-row'),
             [ select(name(day), \day_options(Day)),
               input([type(time), name(start), value(Ss1), required(required)]),
               span(class(arrow), '→'),
               input([type(time), name(end), value(Es), required(required)]),
               \remove_button('Remove slot', 'div.slot-row')
             ])),
    slot_rows(Ss).

%   Removal is pure DOM work, so it stays in hyperscript; adding a row
%   fetches it from here. hx-target/hx-swap are always explicit: both are
%   inherited attributes, and these buttons sit inside a form that sets
%   them for the results pane.
remove_button(Title, Closest) -->
    { format(atom(Script), 'on click remove closest <~w/>', [Closest]) },
    html(button([type(button), class(x), title(Title), '_'(Script)], '×')).

add_button(Path, Target, Label) -->
    html(button([type(button), class([ghost, small]),
                 'hx-get'(Path), 'hx-target'(Target), 'hx-swap'(beforeend)],
                Label)).

day_options(Selected) -->
    day_options([mon-'Mon', tue-'Tue', wed-'Wed', thu-'Thu',
                 fri-'Fri', sat-'Sat', sun-'Sun'], Selected).

day_options([], _) --> [].
day_options([Day-Label|Ds], Selected) -->
    { Day == Selected -> Attrs = [value(Day), selected(selected)] ; Attrs = [value(Day)] },
    html(option(Attrs, Label)),
    day_options(Ds, Selected).

%=====================================================================
% Times
%=====================================================================

%!  time_minutes(+String, -Minutes) is det.
%!  minutes_time(+Minutes, -String) is det.
%
%   "HH:MM" <-> minutes since midnight, validating ranges.

time_minutes(S, Minutes) :-
    (   split_string(S, ":", "", [Hs, Ms]),
        number_string(H, Hs), number_string(M, Ms),
        integer(H), integer(M),
        between(0, 23, H), between(0, 59, M)
    ->  Minutes is H * 60 + M
    ;   format(string(Msg), "bad time (expected HH:MM): ~w", [S]),
        throw(bad_request(Msg))
    ).

minutes_time(Minutes, String) :-
    H is Minutes // 60,
    M is Minutes mod 60,
    format(string(String), "~`0t~d~2|:~`0t~d~5|", [H, M]).

%=====================================================================
% POST /schedules/fragment
%=====================================================================
%
%   Accepts the plain HTML form. Field order encodes the tree:
%
%     name=algebra & id=A & day=mon & start=08:00 & end=10:00
%                  & id=B & day=tue & ...
%     name=prog    & ...
%
%   Each `name` opens a subject, each `id` opens a section, each
%   day/start/end triple is a slot. The flat pair list is parsed by a
%   DCG. Replies with one mini weekly timetable per valid combination.

handle_fragment(Request) :-
    http_read_data(Request, Pairs, []),
    catch(
        ( parse_form(Pairs, Subjects),
          findall(S, valid_schedules(Subjects, S), Schedules),
          findall(N, member(subject(N, _), Subjects), Names),
          reply_markup(fragment(results(Names, Schedules)))
        ),
        bad_request(Msg),
        reply_markup(fragment(error(Msg)))).

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

%--- results rendering -------------------------------------------------

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
