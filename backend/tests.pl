:- use_module(scheduler).
:- use_module(library(plunit)).

:- begin_tests(scheduler).

% -- overlap detection ------------------------------------------------

test(overlap_same_day) :-
    slot_overlap(slot(mon, 480, 600), slot(mon, 540, 660)).

test(no_overlap_different_day, [fail]) :-
    slot_overlap(slot(mon, 480, 600), slot(tue, 480, 600)).

test(touching_intervals_do_not_overlap, [fail]) :-
    % half-open: 08:00-10:00 and 10:00-12:00 are compatible
    slot_overlap(slot(mon, 480, 600), slot(mon, 600, 720)).

test(containment_overlaps) :-
    slot_overlap(slot(fri, 480, 720), slot(fri, 540, 600)).

% -- overlapping sections are excluded --------------------------------

test(overlapping_sections_pruned, [set(Ids == [[a2, b1]])]) :-
    valid_schedules(
        [ subject(a, [ section(a1, [slot(mon, 480, 600)]),
                       section(a2, [slot(tue, 480, 600)]) ]),
          subject(b, [ section(b1, [slot(mon, 540, 660)]) ]) ],
        S),
    findall(I, member(class(_, section(I, _)), S), Ids).

% -- multi-day sections (constraint 4) ---------------------------------

test(multiday_all_slots_must_fit, [set(Ids == [[a2, b1]])]) :-
    % a1 is fine on mon but its wed slot collides with b1 -> a1 rejected whole
    valid_schedules(
        [ subject(a, [ section(a1, [slot(mon, 480, 600), slot(wed, 480, 600)]),
                       section(a2, [slot(mon, 480, 600), slot(thu, 480, 600)]) ]),
          subject(b, [ section(b1, [slot(wed, 500, 620)]) ]) ],
        S),
    findall(I, member(class(_, section(I, _)), S), Ids).

% -- duplicate subjects (constraint 3) ---------------------------------

test(duplicate_subject_selected_once, [set(Names == [[a]])]) :-
    valid_schedules(
        [ subject(a, [section(a1, [slot(mon, 480, 600)])]),
          subject(a, [section(a1, [slot(mon, 480, 600)])]) ],
        S),
    findall(N, member(class(N, _), S), Names).

% -- no valid combination ----------------------------------------------

test(no_valid_combination, [fail]) :-
    valid_schedules(
        [ subject(a, [section(a1, [slot(mon, 480, 600)])]),
          subject(b, [section(b1, [slot(mon, 500, 620)])]) ],
        _).

% -- internally inconsistent section is never selected ------------------

test(self_overlapping_section_rejected, [fail]) :-
    valid_schedules(
        [ subject(a, [section(bad, [slot(mon, 480, 600),
                                    slot(mon, 540, 660)])]) ],
        _).

% -- exhaustiveness: cartesian product when nothing conflicts -----------

test(all_combinations_enumerated, [true(N == 4)]) :-
    findall(S,
            valid_schedules(
                [ subject(a, [ section(a1, [slot(mon, 480, 600)]),
                               section(a2, [slot(tue, 480, 600)]) ]),
                  subject(b, [ section(b1, [slot(wed, 480, 600)]),
                               section(b2, [slot(thu, 480, 600)]) ]) ],
                S),
            All),
    length(All, N).

test(empty_input_yields_empty_schedule, [true(S == [])]) :-
    valid_schedules([], S).

:- end_tests(scheduler).
