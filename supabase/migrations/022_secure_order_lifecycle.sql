-- Migration 022
-- Secure order lifecycle + immutable status history.
--
-- V1 responsibilities:
--   Customer:
--     pending -> cancelled
--
--   Active business owner/manager/staff:
--     pending   -> accepted
--     pending   -> cancelled
--     accepted  -> preparing
--     accepted  -> cancelled
--     preparing -> ready
--     preparing -> cancelled
--     ready     -> cancelled
--
-- Driver-controlled states are intentionally reserved for
-- the future delivery subsystem.

-- ============================================================
-- 1. ORDER STATUS HISTORY
-- ============================================================

create table if not exists public.order_status_history (
    id uuid primary key default gen_random_uuid(),

    order_id uuid not null
        references public.orders(id)
        on delete cascade,

    from_status public.order_status,

    to_status public.order_status not null,

    changed_by uuid
        references public.profiles(id)
        on delete set null,

    created_at timestamptz not null default now(),

    constraint order_status_history_actual_change
        check (
            from_status is null
            or from_status <> to_status
        )
);

create index if not exists order_status_history_order_id_idx
    on public.order_status_history(order_id);

create index if not exists order_status_history_order_created_idx
    on public.order_status_history(order_id, created_at);

-- ============================================================
-- 2. HISTORY RLS
-- ============================================================

alter table public.order_status_history
    enable row level security;

drop policy if exists "Customers can view own order status history"
on public.order_status_history;

create policy "Customers can view own order status history"
on public.order_status_history
for select
to authenticated
using (
    exists (
        select 1
        from public.orders o
        where o.id = order_status_history.order_id
          and o.customer_id = auth.uid()
    )
);

drop policy if exists "Members can view own business order status history"
on public.order_status_history;

create policy "Members can view own business order status history"
on public.order_status_history
for select
to authenticated
using (
    exists (
        select 1
        from public.orders o
        join public.business_members bm
          on bm.business_id = o.business_id
        where o.id = order_status_history.order_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);

revoke all
on table public.order_status_history
from anon;

grant select
on table public.order_status_history
to authenticated;

revoke insert, update, delete
on table public.order_status_history
from authenticated;

-- ============================================================
-- 3. SECURE STATUS TRANSITION RPC
-- ============================================================

create or replace function public.transition_order_status(
    p_order_id uuid,
    p_new_status public.order_status
)
returns public.order_status
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_actor_id uuid;

    v_customer_id uuid;
    v_business_id uuid;
    v_current_status public.order_status;

    v_is_customer boolean := false;
    v_is_business_member boolean := false;
begin
    -- ========================================================
    -- AUTHENTICATION
    -- ========================================================

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_order_id is null then
        raise exception 'order_id is required';
    end if;

    if p_new_status is null then
        raise exception 'new status is required';
    end if;

    -- Lock the order while validating + changing its state.
    select
        o.customer_id,
        o.business_id,
        o.status
    into
        v_customer_id,
        v_business_id,
        v_current_status
    from public.orders o
    where o.id = p_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;

    if v_current_status = p_new_status then
        raise exception
            'Order is already in status %',
            p_new_status;
    end if;

    -- ========================================================
    -- ACTOR RESOLUTION
    -- ========================================================

    v_is_customer :=
        (v_customer_id = v_actor_id);

    select exists (
        select 1
        from public.business_members bm
        where bm.business_id = v_business_id
          and bm.profile_id = v_actor_id
          and bm.is_active = true
          and bm.role in (
              'owner'::public.business_member_role,
              'manager'::public.business_member_role,
              'staff'::public.business_member_role
          )
    )
    into v_is_business_member;

    -- ========================================================
    -- CUSTOMER TRANSITIONS
    -- ========================================================

    if v_is_customer
       and v_current_status = 'pending'::public.order_status
       and p_new_status = 'cancelled'::public.order_status then

        update public.orders
        set status = p_new_status
        where id = p_order_id;

        insert into public.order_status_history (
            order_id,
            from_status,
            to_status,
            changed_by
        )
        values (
            p_order_id,
            v_current_status,
            p_new_status,
            v_actor_id
        );

        return p_new_status;
    end if;

    -- ========================================================
    -- BUSINESS TRANSITIONS
    -- ========================================================

    if v_is_business_member then

        if (
            v_current_status = 'pending'::public.order_status
            and p_new_status in (
                'accepted'::public.order_status,
                'cancelled'::public.order_status
            )
        )
        or (
            v_current_status = 'accepted'::public.order_status
            and p_new_status in (
                'preparing'::public.order_status,
                'cancelled'::public.order_status
            )
        )
        or (
            v_current_status = 'preparing'::public.order_status
            and p_new_status in (
                'ready'::public.order_status,
                'cancelled'::public.order_status
            )
        )
        or (
            v_current_status = 'ready'::public.order_status
            and p_new_status = 'cancelled'::public.order_status
        )
        then

            update public.orders
            set status = p_new_status
            where id = p_order_id;

            insert into public.order_status_history (
                order_id,
                from_status,
                to_status,
                changed_by
            )
            values (
                p_order_id,
                v_current_status,
                p_new_status,
                v_actor_id
            );

            return p_new_status;
        end if;

    end if;

    -- ========================================================
    -- EVERYTHING ELSE IS DENIED
    -- ========================================================

    raise exception
        'Status transition from % to % is not permitted for this user',
        v_current_status,
        p_new_status;
end;
$$;

-- ============================================================
-- 4. FUNCTION SECURITY
-- ============================================================

alter function public.transition_order_status(
    uuid,
    public.order_status
)
owner to postgres;

revoke all
on function public.transition_order_status(
    uuid,
    public.order_status
)
from public;

revoke all
on function public.transition_order_status(
    uuid,
    public.order_status
)
from anon;

grant execute
on function public.transition_order_status(
    uuid,
    public.order_status
)
to authenticated;
