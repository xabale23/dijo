-- ============================================
-- DIJO Migration 009
-- E.164 Phone Number Validation
-- ============================================

-- Generic international E.164 format:
-- + followed by 8 to 15 digits total.
--
-- Examples:
-- +27821234567
-- +26650123456
-- +441234567890

alter table public.profiles
drop constraint if exists profiles_phone_number_e164_check;

alter table public.profiles
add constraint profiles_phone_number_e164_check
check (
    phone_number is null
    or phone_number ~ '^\+[1-9][0-9]{7,14}$'
);


alter table public.profiles
drop constraint if exists profiles_whatsapp_number_e164_check;

alter table public.profiles
add constraint profiles_whatsapp_number_e164_check
check (
    whatsapp_number is null
    or whatsapp_number ~ '^\+[1-9][0-9]{7,14}$'
);


alter table public.businesses
drop constraint if exists businesses_phone_e164_check;

alter table public.businesses
add constraint businesses_phone_e164_check
check (
    phone is null
    or phone ~ '^\+[1-9][0-9]{7,14}$'
);
