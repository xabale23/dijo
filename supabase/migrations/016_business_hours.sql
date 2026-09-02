-- ============================================================
-- DIJO Migration 016
-- Business hours and weekly availability
-- ============================================================


-- ============================================================
-- 1. BUSINESS HOURS TABLE
--
-- day_of_week:
-- 0 = Sunday
-- 1 = Monday
-- 2 = Tuesday
-- 3 = Wednesday
-- 4 = Thursday
-- 5 = Friday
-- 6 = Saturday
-- ============================================================

create table if not exists public.business_hours (
    id uuid primary key default gen_random_uuid(),

    location_id uuid not null
        references public.business_locations(id)
        on delete cascade,

    day_of_week smallint not null,

    opens_at time without time zone,
    closes_at time without time zone,

    is_closed boolean not null default false,
    is_24_hours boolean not null default false,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint business_hours_day_of_week_check
        check (day_of_week between 0 and 6),

    constraint business_hours_status_check
        check (
            (
                is_closed = true
                and is_24_hours = false
                and opens_at is null
                and closes_at is null
            )
            or
            (
                is_closed = false
                and is_24_hours = true
                and opens_at is null
                and closes_at is null
            )
            or
            (
                is_closed = false
                and is_24_hours = false
                and opens_at is not null
                and closes_at is not null
                and opens_at <> closes_at
            )
        ),

    constraint business_hours_one_day_per_location
        unique (location_id, day_of_week)
);


-- ============================================================
-- 2. INDEXES
-- ============================================================

create index if not exists business_hours_location_id_idx
    on public.business_hours(location_id);

create index if not exists business_hours_day_of_week_idx
    on public.business_hours(day_of_week);


-- ============================================================
-- 3. UPDATED_AT TRIGGER
-- ============================================================

drop trigger if exists business_hours_set_updated_at
    on public.business_hours;

create trigger business_hours_set_updated_at
before update on public.business_hours
for each row
execute function public.set_updated_at();


-- ============================================================
-- 4. ENABLE ROW LEVEL SECURITY
-- ============================================================

alter table public.business_hours
enable row level security;


-- ============================================================
-- 5. DROP POLICIES IF MIGRATION IS REPLAYED
-- ============================================================

drop policy if exists
    "Authenticated users can view active business hours"
on public.business_hours;

drop policy if exists
    "Members can view own business hours"
on public.business_hours;

drop policy if exists
    "Owners and managers can create business hours"
on public.business_hours;

drop policy if exists
    "Owners and managers can update business hours"
on public.business_hours;

drop policy if exists
    "Owners and managers can delete business hours"
on public.business_hours;


-- ============================================================
-- 6. AUTHENTICATED USERS CAN VIEW HOURS FOR ACTIVE LOCATIONS
-- ============================================================

create policy
    "Authenticated users can view active business hours"
on public.business_hours
for select
to authenticated
using (
    exists (
        select 1
        from public.business_locations bl
        join public.businesses b
          on b.id = bl.business_id
        where bl.id = business_hours.location_id
          and bl.is_active = true
          and b.is_active = true
    )
);


-- ============================================================
-- 7. BUSINESS MEMBERS CAN VIEW THEIR OWN HOURS
-- ============================================================

create policy
    "Members can view own business hours"
on public.business_hours
for select
to authenticated
using (
    exists (
        select 1
        from public.business_locations bl
        join public.business_members bm
          on bm.business_id = bl.business_id
        where bl.id = business_hours.location_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);


-- ============================================================
-- 8. OWNERS / MANAGERS CAN CREATE BUSINESS HOURS
-- ============================================================

create policy
    "Owners and managers can create business hours"
on public.business_hours
for insert
to authenticated
with check (
    exists (
        select 1
        from public.business_locations bl
        join public.business_members bm
          on bm.business_id = bl.business_id
        where bl.id = business_hours.location_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 9. OWNERS / MANAGERS CAN UPDATE BUSINESS HOURS
-- ============================================================

create policy
    "Owners and managers can update business hours"
on public.business_hours
for update
to authenticated
using (
    exists (
        select 1
        from public.business_locations bl
        join public.business_members bm
          on bm.business_id = bl.business_id
        where bl.id = business_hours.location_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
)
with check (
    exists (
        select 1
        from public.business_locations bl
        join public.business_members bm
          on bm.business_id = bl.business_id
        where bl.id = business_hours.location_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 10. OWNERS / MANAGERS CAN DELETE BUSINESS HOURS
-- ============================================================

create policy
    "Owners and managers can delete business hours"
on public.business_hours
for delete
to authenticated
using (
    exists (
        select 1
        from public.business_locations bl
        join public.business_members bm
          on bm.business_id = bl.business_id
        where bl.id = business_hours.location_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 11. TABLE PRIVILEGES
-- ============================================================

revoke all on table public.business_hours from anon;

grant select on table public.business_hours
to authenticated;

grant insert (
    location_id,
    day_of_week,
    opens_at,
    closes_at,
    is_closed,
    is_24_hours
)
on public.business_hours
to authenticated;

grant update (
    day_of_week,
    opens_at,
    closes_at,
    is_closed,
    is_24_hours
)
on public.business_hours
to authenticated;

grant delete on table public.business_hours
to authenticated;
