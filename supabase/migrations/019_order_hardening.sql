-- Migration 019
-- Order integrity, indexes, and merchant read access.

-- ============================================================
-- 1. HARDEN ORDERS
-- ============================================================

alter table public.orders
    alter column status set not null,
    alter column created_at set not null,
    alter column updated_at set not null;

alter table public.orders
    drop constraint if exists orders_subtotal_non_negative,
    drop constraint if exists orders_delivery_fee_non_negative,
    drop constraint if exists orders_service_fee_non_negative,
    drop constraint if exists orders_total_non_negative;

alter table public.orders
    add constraint orders_subtotal_non_negative
        check (subtotal >= 0),
    add constraint orders_delivery_fee_non_negative
        check (delivery_fee >= 0),
    add constraint orders_service_fee_non_negative
        check (service_fee >= 0),
    add constraint orders_total_non_negative
        check (total >= 0);

-- ============================================================
-- 2. HARDEN ORDER ITEMS
-- ============================================================

alter table public.order_items
    alter column created_at set not null;

alter table public.order_items
    drop constraint if exists order_items_unit_price_non_negative,
    drop constraint if exists order_items_total_price_non_negative;

alter table public.order_items
    add constraint order_items_unit_price_non_negative
        check (unit_price >= 0),
    add constraint order_items_total_price_non_negative
        check (total_price >= 0);

-- ============================================================
-- 3. PREVENT CROSS-BUSINESS PRODUCT ASSIGNMENT
-- ============================================================

alter table public.products
    drop constraint if exists products_id_business_id_key;

alter table public.products
    add constraint products_id_business_id_key
        unique (id, business_id);

alter table public.order_items
    add column if not exists business_id uuid;

update public.order_items oi
set business_id = o.business_id
from public.orders o
where o.id = oi.order_id
  and oi.business_id is null;

alter table public.order_items
    alter column business_id set not null;

alter table public.order_items
    drop constraint if exists order_items_business_id_fkey,
    drop constraint if exists order_items_product_business_fkey;

alter table public.order_items
    add constraint order_items_business_id_fkey
        foreign key (business_id)
        references public.businesses(id),
    add constraint order_items_product_business_fkey
        foreign key (product_id, business_id)
        references public.products(id, business_id);

-- ============================================================
-- 4. PERFORMANCE INDEXES
-- ============================================================

create index if not exists orders_customer_id_idx
    on public.orders(customer_id);

create index if not exists orders_business_id_idx
    on public.orders(business_id);

create index if not exists orders_business_status_created_idx
    on public.orders(business_id, status, created_at desc);

create index if not exists orders_customer_created_idx
    on public.orders(customer_id, created_at desc);

create index if not exists order_items_order_id_idx
    on public.order_items(order_id);

create index if not exists order_items_product_id_idx
    on public.order_items(product_id);

create index if not exists order_items_business_id_idx
    on public.order_items(business_id);

-- ============================================================
-- 5. RLS: MERCHANT READ ACCESS
-- ============================================================

alter table public.orders enable row level security;
alter table public.order_items enable row level security;

drop policy if exists "Members can view own business orders"
on public.orders;

create policy "Members can view own business orders"
on public.orders
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = orders.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);

drop policy if exists "Members can view own business order items"
on public.order_items;

create policy "Members can view own business order items"
on public.order_items
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = order_items.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);

-- ============================================================
-- 6. PRIVILEGE HARDENING
-- ============================================================

revoke all on table public.orders from anon;
revoke all on table public.order_items from anon;

grant select on table public.orders to authenticated;
grant select on table public.order_items to authenticated;

revoke insert, update, delete
on table public.orders
from authenticated;

revoke insert, update, delete
on table public.order_items
from authenticated;
