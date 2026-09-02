-- ============================================
-- DIJO Migration 010
-- Automatic updated_at Timestamps
-- ============================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;


drop trigger if exists profiles_set_updated_at
on public.profiles;

create trigger profiles_set_updated_at
before update on public.profiles
for each row
execute function public.set_updated_at();


drop trigger if exists businesses_set_updated_at
on public.businesses;

create trigger businesses_set_updated_at
before update on public.businesses
for each row
execute function public.set_updated_at();


drop trigger if exists products_set_updated_at
on public.products;

create trigger products_set_updated_at
before update on public.products
for each row
execute function public.set_updated_at();


drop trigger if exists orders_set_updated_at
on public.orders;

create trigger orders_set_updated_at
before update on public.orders
for each row
execute function public.set_updated_at();
