-- ============================================================
-- DIJO
-- Migration 027: Delivery Status History
-- ============================================================
--
-- PURPOSE
-- -------
-- Create an immutable operational audit trail for delivery
-- lifecycle changes.
--
-- Examples:
--
--   NULL -> waiting
--   waiting -> assigned
--   assigned -> accepted
--   accepted -> arrived_at_pickup
--   arrived_at_pickup -> picked_up
--   picked_up -> on_the_way
--   on_the_way -> completed
--
-- Release/reassignment:
--
--   assigned -> waiting
--   accepted -> waiting
--   arrived_at_pickup -> waiting
--
-- The audit event is generated automatically by a database
-- trigger whenever deliveries.status changes.
--
-- ============================================================


-- ============================================================
-- 1. DELIVERY STATUS HISTORY TABLE
-- ============================================================

create table if not exists public.delivery_status_history (
    id uuid primary key default gen_random_uuid(),

    delivery_id uuid not null
        references public.deliveries(id)
        on delete cascade,

    order_id uuid not null
        references public.orders(id)
        on delete cascade,

    business_id uuid not null
        references public.businesses(id)
        on delete cascade,

    from_status public.delivery_status null,

    to_status public.delivery_status not null,

    changed_by uuid null
        references public.profiles(id)
        on delete set null,

    driver_profile_id uuid null
        references public.profiles(id)
        on delete set null,

    created_at timestamptz not null default now()
);


-- ============================================================
-- 2. INDEXES
-- ============================================================

create index if not exists
delivery_status_history_delivery_id_idx
on public.delivery_status_history(delivery_id);


create index if not exists
delivery_status_history_order_id_idx
on public.delivery_status_history(order_id);


create index if not exists
delivery_status_history_business_id_idx
on public.delivery_status_history(business_id);


create index if not exists
delivery_status_history_driver_profile_id_idx
on public.delivery_status_history(driver_profile_id);


create index if not exists
delivery_status_history_created_at_idx
on public.delivery_status_history(created_at);


create index if not exists
delivery_status_history_delivery_created_idx
on public.delivery_status_history(
    delivery_id,
    created_at
);


-- ============================================================
-- 3. ENABLE RLS
-- ============================================================

alter table public.delivery_status_history
enable row level security;


-- ============================================================
-- 4. CUSTOMER READ POLICY
-- ============================================================
--
-- Customer may view delivery history belonging to their order.
-- ============================================================

drop policy if exists
"Customers can view own delivery history"
on public.delivery_status_history;

create policy
"Customers can view own delivery history"
on public.delivery_status_history
for select
to authenticated
using (
    exists (
        select 1
        from public.orders o
        where o.id = delivery_status_history.order_id
          and o.customer_id = auth.uid()
    )
);


-- ============================================================
-- 5. BUSINESS MEMBER READ POLICY
-- ============================================================

drop policy if exists
"Business members can view own delivery history"
on public.delivery_status_history;

create policy
"Business members can view own delivery history"
on public.delivery_status_history
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id =
            delivery_status_history.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active is true
    )
);


-- ============================================================
-- 6. DRIVER READ POLICY
-- ============================================================
--
-- Unlike deliveries.driver_profile_id, which becomes NULL when
-- an assignment is released, this history table preserves the
-- driver involved in each event.
--
-- A driver therefore retains access to their own historical
-- delivery events even after reassignment.
-- ============================================================

drop policy if exists
"Drivers can view own delivery history"
on public.delivery_status_history;

create policy
"Drivers can view own delivery history"
on public.delivery_status_history
for select
to authenticated
using (
    driver_profile_id = auth.uid()
);


-- ============================================================
-- 7. ADMIN READ POLICY
-- ============================================================

drop policy if exists
"Admins can view delivery history"
on public.delivery_status_history;

create policy
"Admins can view delivery history"
on public.delivery_status_history
for select
to authenticated
using (
    exists (
        select 1
        from public.profiles p
        where p.id = auth.uid()
          and p.role = 'admin'::public.user_role
          and p.is_active is true
    )
);


-- ============================================================
-- 8. HISTORY WRITER TRIGGER FUNCTION
-- ============================================================
--
-- SECURITY DEFINER is required because authenticated clients
-- are deliberately denied direct INSERT permission on the
-- history table.
--
-- auth.uid() still represents the original authenticated actor
-- who initiated the delivery transition.
--
-- On release:
--
-- NEW.driver_profile_id becomes NULL.
--
-- Therefore COALESCE preserves OLD.driver_profile_id so the
-- audit trail still records which driver was released.
-- ============================================================

create or replace function public.record_delivery_status_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_driver_profile_id uuid;
begin
    v_actor_id := auth.uid();


    -- ========================================================
    -- NEW DELIVERY
    -- ========================================================

    if tg_op = 'INSERT' then

        insert into public.delivery_status_history (
            delivery_id,
            order_id,
            business_id,
            from_status,
            to_status,
            changed_by,
            driver_profile_id
        )
        values (
            new.id,
            new.order_id,
            new.business_id,
            null,
            new.status,
            v_actor_id,
            new.driver_profile_id
        );

        return new;

    end if;


    -- ========================================================
    -- STATUS TRANSITION
    -- ========================================================

    if tg_op = 'UPDATE'
       and old.status is distinct from new.status then

        v_driver_profile_id :=
            coalesce(
                new.driver_profile_id,
                old.driver_profile_id
            );

        insert into public.delivery_status_history (
            delivery_id,
            order_id,
            business_id,
            from_status,
            to_status,
            changed_by,
            driver_profile_id
        )
        values (
            new.id,
            new.order_id,
            new.business_id,
            old.status,
            new.status,
            v_actor_id,
            v_driver_profile_id
        );

    end if;


    return new;
end;
$function$;


-- ============================================================
-- 9. TRIGGER
-- ============================================================

drop trigger if exists
deliveries_record_status_history
on public.deliveries;

create trigger deliveries_record_status_history
after insert or update of status
on public.deliveries
for each row
execute function public.record_delivery_status_history();


-- ============================================================
-- 10. BACKFILL EXISTING DELIVERIES
-- ============================================================
--
-- Existing rows predate Migration 027.
--
-- We cannot reconstruct their historical transitions reliably,
-- so create one baseline event representing their current
-- state.
--
-- changed_by = NULL indicates a migration-generated baseline.
-- ============================================================

insert into public.delivery_status_history (
    delivery_id,
    order_id,
    business_id,
    from_status,
    to_status,
    changed_by,
    driver_profile_id
)
select
    d.id,
    d.order_id,
    d.business_id,
    null,
    d.status,
    null,
    d.driver_profile_id
from public.deliveries d
where not exists (
    select 1
    from public.delivery_status_history h
    where h.delivery_id = d.id
);


-- ============================================================
-- 11. TABLE PRIVILEGES
-- ============================================================
--
-- History is read-only to application users.
-- The trigger is the only normal writer.
-- ============================================================

revoke all
on public.delivery_status_history
from anon;

revoke insert, update, delete
on public.delivery_status_history
from authenticated;

grant select
on public.delivery_status_history
to authenticated;


-- ============================================================
-- 12. TRIGGER FUNCTION PRIVILEGES
-- ============================================================
--
-- Application users must never call the trigger function
-- directly.
-- ============================================================

revoke all
on function public.record_delivery_status_history()
from public;

revoke all
on function public.record_delivery_status_history()
from anon;

revoke all
on function public.record_delivery_status_history()
from authenticated;


-- ============================================================
-- END MIGRATION 027
-- ============================================================
