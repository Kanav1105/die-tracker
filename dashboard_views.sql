-- ============================================================================
-- Die Tracker — dashboard views and functions  (v2: date ranges + die journey)
--
-- WHAT CHANGED FROM v1
--   * All six analytics functions now take (from_ts, to_ts) instead of (days).
--     This is what lets the manager pick any start date, with "till date" being
--     simply to_ts = now(). Changing an argument list requires DROP, not
--     REPLACE, so the drops at the top are required and are safe.
--   * Three new functions power the die journey: f_die_list, f_die_journey,
--     f_die_events.
--
-- Run the whole file in one go in the Supabase SQL Editor.
-- Tested end to end against Postgres 16 with data covering a clean 8-stage
-- route, a 290-hour customer hold, back-to-back holds, dies parked at NA,
-- a die at an outsource vendor, and open sessions. Every figure was checked
-- by hand against the known inputs.
-- ============================================================================

create or replace view v_die_sessions with (security_invoker=true) as
with sessioned as (
  select *, sum(case when type='START' then 1 else 0 end)
    over (partition by die_code order by ts, id) as session_no
  from events where die_code is not null)
select die_code, session_no, min(stage_no) as stage_no, min(machine_code) as machine_code,
  min(ts) filter (where type='START') as started_at,
  max(ts) filter (where type='END') as ended_at
from sessioned group by die_code, session_no;

create or replace view v_stage_visits with (security_invoker=true) as
select s.die_code, s.stage_no, st.name as stage_name, s.machine_code, m.name as machine_name,
  s.started_at, s.ended_at,
  round(extract(epoch from (s.ended_at-s.started_at))/3600.0,2) as duration_hours,
  round(extract(epoch from (s.started_at - lag(s.ended_at)
    over (partition by s.die_code order by s.started_at)))/3600.0,2) as queue_before_hours
from v_die_sessions s
left join stages st on st.no=s.stage_no
left join machines m on m.code=s.machine_code
where s.ended_at is not null;

create or replace view v_holds with (security_invoker=true) as
with sessioned as (
  select *, sum(case when type='START' then 1 else 0 end)
    over (partition by die_code order by ts, id) as session_no
  from events where die_code is not null),
pr as (select die_code, session_no, ts as hold_start, reason,
  lead(ts) over (partition by die_code,session_no order by ts) as next_ts,
  lead(type) over (partition by die_code,session_no order by ts) as next_type
  from sessioned where type in ('PAUSE','RESUME'))
select die_code, session_no, reason, hold_start,
  case when next_type='RESUME' then next_ts end as hold_end,
  round(extract(epoch from (coalesce(next_ts,now())-hold_start))/3600.0,2) as hold_hours
from pr where reason is not null;

-- ============================ ANALYTICS (date-ranged) ============================
-- Old signatures took days int. Changing the argument list means DROP, not REPLACE.
drop function if exists f_hold_summary(int);
drop function if exists f_machine_occupancy(int);
drop function if exists f_queue_by_stage(int);
drop function if exists f_die_leadtime(int);
drop function if exists f_machine_utilisation(int);
drop function if exists f_machine_utilisation(int,numeric);
drop function if exists f_die_utilisation(int);

create or replace function f_hold_summary(from_ts timestamptz, to_ts timestamptz default now())
returns table(reason_code text, reason_label text, occurrences bigint,
              total_hours numeric, total_days numeric)
language sql stable security invoker as $$
  select split_part(reason,' ',1),
         min(substring(reason from position(' ' in reason)+1)),
         count(*), round(sum(hold_hours)::numeric,1), round((sum(hold_hours)/24)::numeric,1)
  from v_holds
  where hold_start >= from_ts and hold_start <= to_ts
  group by split_part(reason,' ',1) order by 4 desc;
$$;

create or replace function f_machine_occupancy(from_ts timestamptz, to_ts timestamptz default now())
returns table(machine_code text, machine_name text, visits bigint, occupied_hours numeric)
language sql stable security invoker as $$
  select s.machine_code, m.name, count(*),
    round(sum(extract(epoch from (s.ended_at-s.started_at))/3600.0)::numeric,1)
  from v_die_sessions s join machines m on m.code=s.machine_code
  where s.ended_at is not null and s.machine_code not in ('100','114')
    and s.started_at >= from_ts and s.started_at <= to_ts
  group by s.machine_code, m.name order by 4 desc;
$$;

create or replace function f_queue_by_stage(from_ts timestamptz, to_ts timestamptz default now())
returns table(stage_name text, stage_no int, data_points bigint,
              avg_queue_hours numeric, max_queue_hours numeric)
language sql stable security invoker as $$
  select v.stage_name, v.stage_no, count(*),
    round(avg(v.queue_before_hours)::numeric,1), round(max(v.queue_before_hours)::numeric,1)
  from v_stage_visits v
  where v.queue_before_hours is not null and v.queue_before_hours >= 0
    and v.started_at >= from_ts and v.started_at <= to_ts
  group by v.stage_name, v.stage_no order by 4 desc;
$$;

create or replace function f_die_leadtime(from_ts timestamptz, to_ts timestamptz default now())
returns table(die_code text, elapsed_days numeric, touch_days numeric, outsourced_days numeric)
language sql stable security invoker as $$
  select s.die_code,
    round(extract(epoch from (max(coalesce(s.ended_at,now()))-min(s.started_at)))/86400.0,2),
    round(sum(extract(epoch from (coalesce(s.ended_at,now())-s.started_at)))/86400.0,2),
    round(coalesce(sum(extract(epoch from (coalesce(s.ended_at,now())-s.started_at)))
      filter (where s.machine_code='114'),0)/86400.0,2)
  from v_die_sessions s
  group by s.die_code
  having max(coalesce(s.ended_at,now())) >= from_ts and min(s.started_at) <= to_ts
  order by 2 desc;
$$;

create or replace function f_machine_utilisation(from_ts timestamptz, to_ts timestamptz default now(),
                                                 hours_per_day numeric default 24)
returns table(machine_code text, machine_name text, first_seen timestamptz,
              window_hours numeric, available_hours numeric, busy_hours numeric,
              idle_hours numeric, util_pct numeric, visits bigint)
language sql stable security invoker as $$
with s as (
  select v.machine_code,
    greatest(v.started_at, from_ts) as st,
    least(coalesce(v.ended_at, now()), to_ts) as en
  from v_die_sessions v
  where v.machine_code is not null and v.machine_code not in ('100','114')
    and coalesce(v.ended_at, now()) >= from_ts and v.started_at <= to_ts),
agg as (select machine_code, min(st) as first_seen, count(*) as visits,
  sum(extract(epoch from (en-st))) as busy_sec from s where en>st group by machine_code),
calc as (select a.*, extract(epoch from (to_ts - a.first_seen)) as window_sec,
  extract(epoch from (to_ts - a.first_seen))*(hours_per_day/24.0) as avail_sec from agg a)
select c.machine_code, m.name, c.first_seen,
  round((c.window_sec/3600)::numeric,1), round((c.avail_sec/3600)::numeric,1),
  round((c.busy_sec/3600)::numeric,1),
  round((greatest(c.avail_sec-c.busy_sec,0)/3600)::numeric,1),
  least(round((c.busy_sec/nullif(c.avail_sec,0)*100)::numeric,1),100.0), c.visits
from calc c join machines m on m.code=c.machine_code order by 8 desc;
$$;

create or replace function f_die_utilisation(from_ts timestamptz, to_ts timestamptz default now())
returns table(die_code text, first_seen timestamptz, window_hours numeric,
              active_hours numeric, vacant_hours numeric, util_pct numeric, sessions bigint)
language sql stable security invoker as $$
with s as (
  select v.die_code, greatest(v.started_at, from_ts) as st,
    least(coalesce(v.ended_at, now()), to_ts) as en
  from v_die_sessions v
  where coalesce(v.ended_at,now()) >= from_ts and v.started_at <= to_ts),
agg as (select die_code, min(st) as first_seen, count(*) as sessions,
  sum(extract(epoch from (en-st))) as active_sec from s where en>st group by die_code)
select a.die_code, a.first_seen,
  round((extract(epoch from (to_ts-a.first_seen))/3600)::numeric,1),
  round((a.active_sec/3600)::numeric,1),
  round((greatest(extract(epoch from (to_ts-a.first_seen))-a.active_sec,0)/3600)::numeric,1),
  least(round((a.active_sec/nullif(extract(epoch from (to_ts-a.first_seen)),0)*100)::numeric,1),100.0),
  a.sessions
from agg a order by 6 desc;
$$;

-- ============================ DIE JOURNEY ============================
-- Searchable die list. One row per die with headline numbers, for the picker.
create or replace function f_die_list(from_ts timestamptz, to_ts timestamptz default now())
returns table(die_code text, operation text, part text, stages_done bigint,
              first_activity timestamptz, last_activity timestamptz,
              elapsed_days numeric, touch_days numeric, hold_days numeric,
              current_stage_no int, current_stage text, current_machine text, state text)
language sql stable security invoker as $$
with s as (
  select v.* from v_die_sessions v
  where coalesce(v.ended_at, now()) >= from_ts and v.started_at <= to_ts),
agg as (
  select die_code,
    count(*) filter (where ended_at is not null) as stages_done,
    min(started_at) as first_activity,
    max(coalesce(ended_at, now())) as last_activity,
    sum(extract(epoch from (coalesce(ended_at,now()) - started_at))) as touch_sec
  from s group by die_code),
open_now as (
  select distinct on (die_code) die_code, stage_no, machine_code
  from v_die_sessions where ended_at is null order by die_code, started_at desc),
h as (
  select die_code, sum(hold_hours) as hold_hours from v_holds
  where hold_start >= from_ts and hold_start <= to_ts group by die_code)
select a.die_code, d.operation, d.part, a.stages_done,
  a.first_activity, a.last_activity,
  round(extract(epoch from (a.last_activity - a.first_activity))/86400.0, 2),
  round((a.touch_sec/86400.0)::numeric, 2),
  round(coalesce(h.hold_hours,0)/24.0, 2),
  o.stage_no, st.name, m.name,
  case when o.die_code is not null then 'running' else 'idle' end
from agg a
join dies d on d.code = a.die_code
left join open_now o on o.die_code = a.die_code
left join stages st on st.no = o.stage_no
left join machines m on m.code = o.machine_code
left join h on h.die_code = a.die_code
order by a.last_activity desc;
$$;

-- The journey: one row per stage visit, with duration, queue before, and
-- hold time inside that visit. This is the default view.
create or replace function f_die_journey(p_die text, from_ts timestamptz,
                                         to_ts timestamptz default now())
returns table(seq bigint, stage_no int, stage_name text, machine_code text, machine_name text,
              started_at timestamptz, ended_at timestamptz, duration_hours numeric,
              queue_before_hours numeric, hold_hours numeric, operator text, is_open boolean)
language sql stable security invoker as $$
with s as (
  select v.*, row_number() over (order by v.started_at) as seq
  from v_die_sessions v
  where v.die_code = p_die
    and coalesce(v.ended_at, now()) >= from_ts and v.started_at <= to_ts),
hold as (
  select session_no, sum(hold_hours) as hold_hours
  from v_holds where die_code = p_die group by session_no),
op as (
  select distinct on (die_code, stage_no, machine_code) die_code, stage_no, machine_code, operator
  from events where die_code = p_die and type='START' order by die_code, stage_no, machine_code, ts)
select s.seq, s.stage_no, st.name, s.machine_code, m.name,
  s.started_at, s.ended_at,
  round(extract(epoch from (coalesce(s.ended_at,now()) - s.started_at))/3600.0, 2),
  round(extract(epoch from (s.started_at - lag(s.ended_at)
    over (order by s.started_at)))/3600.0, 2),
  round(coalesce(h.hold_hours,0)::numeric, 2),
  op.operator,
  (s.ended_at is null)
from s
left join stages st on st.no = s.stage_no
left join machines m on m.code = s.machine_code
left join hold h on h.session_no = s.session_no
left join op on op.stage_no = s.stage_no and op.machine_code = s.machine_code
order by s.started_at;
$$;

-- Raw audit trail. Every event, unmodified. For when the manager wants to
-- see exactly what was logged rather than the summarised visit.
create or replace function f_die_events(p_die text, from_ts timestamptz,
                                        to_ts timestamptz default now())
returns table(ts timestamptz, type text, stage_no int, stage_name text,
              machine_code text, machine_name text, reason text, operator text, device_id text)
language sql stable security invoker as $$
  select e.ts, e.type, e.stage_no, st.name, e.machine_code, m.name,
         e.reason, e.operator, e.device_id
  from events e
  left join stages st on st.no = e.stage_no
  left join machines m on m.code = e.machine_code
  where e.die_code = p_die and e.ts >= from_ts and e.ts <= to_ts
  order by e.ts;
$$;

grant execute on function f_die_list(timestamptz,timestamptz),
  f_die_journey(text,timestamptz,timestamptz),
  f_die_events(text,timestamptz,timestamptz) to anon, authenticated;

-- ============================================================================
grant select on v_die_sessions, v_stage_visits, v_holds to anon, authenticated;
grant execute on function
  f_hold_summary(timestamptz,timestamptz),
  f_machine_occupancy(timestamptz,timestamptz),
  f_queue_by_stage(timestamptz,timestamptz),
  f_die_leadtime(timestamptz,timestamptz),
  f_machine_utilisation(timestamptz,timestamptz,numeric),
  f_die_utilisation(timestamptz,timestamptz)
  to anon, authenticated;

-- Verify
select 'die list' as check, count(*) from f_die_list(now()-interval '365 days')
union all select 'hold summary', count(*) from f_hold_summary(now()-interval '365 days')
union all select 'machine util', count(*) from f_machine_utilisation(now()-interval '365 days');
-- ============================================================================
