-- Migration 019a
-- Complete Migration 019 by enforcing that every order item
-- belongs to the same business as its parent order.

-- Required parent key for the composite foreign key.
alter table public.orders
    drop constraint if exists orders_id_business_id_key;

alter table public.orders
    add constraint orders_id_business_id_key
        unique (id, business_id);

-- Ensure an order item's business matches its parent order.
alter table public.order_items
    drop constraint if exists order_items_order_business_fkey;

alter table public.order_items
    add constraint order_items_order_business_fkey
        foreign key (order_id, business_id)
        references public.orders(id, business_id)
        on delete cascade;
