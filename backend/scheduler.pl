:- module(scheduler,
          [ valid_schedules/2,          % +Subjects, -Schedule
            slot_overlap/2,             % +Slot1, +Slot2
            section_conflict/2,         % +Section1, +Section2
            section_consistent/1,       % +Section
            weekday/1                   % ?Day
          ]).

/** <module> University class-schedule generator

Representation
--------------
  * Subject : subject(Name, Sections)      Name is an atom, Sections a non-empty list.
  * Section : section(Id, Slots)           Id is an atom, Slots a non-empty list.
  * Slot    : slot(Day, Start, End)        Day is a weekday atom; Start/End are
                                           integers, minutes since midnight,
                                           with Start < End (half-open interval).
  * Schedule: list of class(SubjectName, section(Id, Slots)).

Times are half-open intervals [Start, End): a class ending 10:00 does NOT
conflict with one starting 10:00.
*/

weekday(mon).
weekday(tue).
weekday(wed).
weekday(thu).
weekday(fri).
weekday(sat).
weekday(sun).

%!  slot_overlap(+A, +B) is semidet.
%
%   Two slots conflict iff they share a weekday and their half-open
%   time intervals intersect: S1 < E2 and S2 < E1.

slot_overlap(slot(Day, S1, E1), slot(Day, S2, E2)) :-
    S1 < E2,
    S2 < E1.

%!  section_conflict(+Sec1, +Sec2) is semidet.
%
%   True if any meeting period of Sec1 overlaps any meeting period of
%   Sec2. Constraint 4 falls out of this: a section joins a schedule
%   only if *every* one of its slots is conflict-free, because a single
%   overlapping slot makes this predicate succeed.

section_conflict(section(_, Slots1), section(_, Slots2)) :-
    member(A, Slots1),
    member(B, Slots2),
    slot_overlap(A, B),
    !.

%!  section_consistent(+Section) is semidet.
%
%   A section must not overlap with itself (malformed input guard).

section_consistent(section(_, Slots)) :-
    \+ ( select(A, Slots, Rest),
         member(B, Rest),
         slot_overlap(A, B)
       ).

%!  valid_schedules(+Subjects, -Schedule) is nondet.
%
%   Enumerates, on backtracking, every combination that picks exactly
%   one section per subject (constraint 1) with no overlapping slots
%   (constraints 2 and 4). Duplicate subject names in the input are
%   collapsed to their first occurrence, so the same subject can never
%   be selected twice (constraint 3).

valid_schedules(Subjects, Schedule) :-
    dedup_subjects(Subjects, Unique),
    choose(Unique, [], Schedule).

dedup_subjects([], []).
dedup_subjects([subject(Name, Secs)|Rest], [subject(Name, Secs)|Out]) :-
    exclude([subject(N, _)]>>(N == Name), Rest, Rest1),
    dedup_subjects(Rest1, Out).

choose([], Acc, Schedule) :-
    reverse(Acc, Schedule).
choose([subject(Name, Sections)|Rest], Acc, Schedule) :-
    member(Section, Sections),
    section_consistent(Section),
    compatible(Section, Acc),
    choose(Rest, [class(Name, Section)|Acc], Schedule).

compatible(Section, Chosen) :-
    \+ ( member(class(_, Other), Chosen),
         section_conflict(Section, Other)
       ).
