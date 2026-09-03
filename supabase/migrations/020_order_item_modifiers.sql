-- Migration 020
-- Historical modifier snapshots for order items.

-- ============================================================
-- 1. ORDER ITEM OPTION SNAPSHOTS
-- ============================================================

create table if not exists public.order_item_options (
    id uuid primary key default gen_random_uuid(),

    order_item_id uuid not null
        references public.order_items(id)
        on delete cascade,

    option_group_id uuid
        references public.product_option_groups(id)
        on delete set null,

    option_id uuid
        references public.product_options(id)
        on delete set null,

    option_group_name text not null,
    option_name text not null,

    price_adjustment numeric not null default 0,

    quantity integer not null default 1,

    total_price numeric not null default 0,

    created_at timestamptz not null default now(),

    constraint order_item_options_group_name_not_blank
        check (length(trim(option_group_name)) > 0),

    constraint order_item_options_name_not_blank
        check (length(trim(option_name)) > 0),

    constraint order_item_options_price_adjustment_non_negative
        check (price_adjustment >= 0),

    constraint order_item_options_quantity_positive
        check (quantity > 0),

    constraint order_item_options_total_price_non_negative
        check (total_price >= 0)
);

-- ============================================================
-- 2. INDEXES
-- ============================================================

create index if not exists order_item_options_order_item_id_idx
    on public.order_item_options(order_item_id);

create index if not exists order_item_options_option_group_id_idx
    on public.order_item_options(option_group_id);

create index if not exists order_item_options_option_id_idx
    on public.order_item_options(option_id);

-- ============================================================
-- 3. ROW LEVEL SECURITY
-- ============================================================

alter table public.order_item_options
    enable row level security;

drop policy if exists "Customers can view own order item options"
on public.order_item_options;

create policy "Customers can view own order item options"
on public.order_item_options
for select
to authenticated
using (
    exists (
        select 1
        from public.order_items oi
        join public.orders o
          on o.id = oi.order_id
        where oi.id = order_item_options.order_item_id
          and o.customer_id = auth.uid()
    )
);

drop policy if exists "Members can view own business order item options"
on public.order_item_options;

create policy "Members can view own business order item options"
on public.order_item_options
for select
to authenticated
using (
    exists (
        select 1
        from public.order_items oi
        join public.business_members bm
          on bm.business_id = oi.business_id
        where oi.id = order_item_options.order_item_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);

-- ============================================================
-- 4. PRIVILEGES
-- ============================================================

revoke all on table public.order_item_options from anon;

grant select on table public.order_item_options
to authenticated;

revoke insert, update, delete
on table public.order_item_options
from authenticated;
