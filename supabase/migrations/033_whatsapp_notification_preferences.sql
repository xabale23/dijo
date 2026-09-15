-- ============================================================
-- DIJO
-- Migration 033: WhatsApp Notification Preferences & Consent
-- ============================================================
--
-- PURPOSE
-- -------
-- Introduce explicit WhatsApp notification consent.
--
-- A profile having a WhatsApp number does NOT automatically
-- authorize DIJO to send WhatsApp notifications.
--
-- Eligibility requires:
--
--   1. active profile
--   2. non-empty WhatsApp number
--   3. explicit opted-in consent
--   4. transactional notifications enabled
--   5. current WhatsApp number matches the number consented
--
-- Existing profiles are migrated to UNKNOWN consent.
--
-- Pending notifications for recipients without current consent
-- cannot be claimed by the notification worker.
--
-- Processing notifications are deliberately NOT cancelled,
-- because the provider send may already be in flight.
--
-- ============================================================


-- ============================================================
-- 1. CONSENT STATUS ENUM
-- ============================================================

do $$
begin

    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
          on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname = 'whatsapp_consent_status'
    ) then

        create type public.whatsapp_consent_status
        as enum (
            'unknown',
            'opted_in',
            'opted_out'
        );

    end if;

end
$$;


-- ============================================================
-- 2. WHATSAPP NOTIFICATION PREFERENCES
-- ============================================================

create table public.whatsapp_notification_preferences (

    profile_id uuid primary key
        references public.profiles(id)
        on delete cascade,

    consent_status public.whatsapp_consent_status
        not null
        default 'unknown',

    transactional_enabled boolean
        not null
        default false,

    -- Source of the most recent explicit opt-in.
    --
    -- Examples:
    -- signup
    -- settings
    -- whatsapp_inbound
    -- checkout
    -- support
    consent_source text,

    -- Snapshot of the exact WhatsApp number for which
    -- consent was granted.
    --
    -- If profiles.whatsapp_number later changes,
    -- the previous consent is no longer valid.
    consented_whatsapp_number text,

    -- Most recent opt-in timestamp.
    consented_at timestamptz,

    -- Most recent opt-out information.
    opted_out_at timestamptz,
    opt_out_source text,

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now(),


    constraint whatsapp_preferences_consent_source_check
        check (
            consent_source is null
            or (
                btrim(consent_source) <> ''
                and length(consent_source) <= 100
            )
        ),


    constraint whatsapp_preferences_opt_out_source_check
        check (
            opt_out_source is null
            or (
                btrim(opt_out_source) <> ''
                and length(opt_out_source) <= 100
            )
        ),


    constraint whatsapp_preferences_consented_number_check
        check (
            consented_whatsapp_number is null
            or btrim(consented_whatsapp_number) <> ''
        ),


    -- Explicit opt-in must have auditable consent evidence.
    constraint whatsapp_preferences_opted_in_check
        check (
            consent_status <>
                'opted_in'::public.whatsapp_consent_status

            or (
                consented_at is not null
                and consent_source is not null
                and btrim(consent_source) <> ''
                and consented_whatsapp_number is not null
                and btrim(consented_whatsapp_number) <> ''
            )
        ),


    -- Opted-out users may never have transactional delivery
    -- enabled.
    constraint whatsapp_preferences_opted_out_check
        check (
            consent_status <>
                'opted_out'::public.whatsapp_consent_status

            or (
                transactional_enabled is false
                and opted_out_at is not null
            )
        ),


    -- UNKNOWN is always non-deliverable.
    constraint whatsapp_preferences_unknown_check
        check (
            consent_status <>
                'unknown'::public.whatsapp_consent_status

            or transactional_enabled is false
        )
);


create index
whatsapp_notification_preferences_status_idx
on public.whatsapp_notification_preferences (
    consent_status,
    transactional_enabled
);


-- ============================================================
-- 3. RLS + DIRECT ACCESS HARDENING
-- ============================================================

alter table
public.whatsapp_notification_preferences
enable row level security;


revoke all
on table public.whatsapp_notification_preferences
from public, anon, authenticated, service_role;


-- Authenticated users may inspect their own preference state.
-- All mutation happens through controlled RPCs.
grant select
on table public.whatsapp_notification_preferences
to authenticated;


-- Backend may inspect consent state if required.
grant select
on table public.whatsapp_notification_preferences
to service_role;


drop policy if exists
"Users can read own WhatsApp preferences"
on public.whatsapp_notification_preferences;


create policy
"Users can read own WhatsApp preferences"
on public.whatsapp_notification_preferences
for select
to authenticated
using (
    profile_id = auth.uid()
);


-- ============================================================
-- 4. UPDATED_AT TRIGGER
-- ============================================================

create or replace function
public.set_whatsapp_notification_preferences_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin

    new.updated_at := now();

    return new;

end;
$function$;


alter function
public.set_whatsapp_notification_preferences_updated_at()
owner to postgres;


revoke all
on function
public.set_whatsapp_notification_preferences_updated_at()
from public, anon, authenticated, service_role;


drop trigger if exists
whatsapp_notification_preferences_set_updated_at
on public.whatsapp_notification_preferences;


create trigger
whatsapp_notification_preferences_set_updated_at
before update
on public.whatsapp_notification_preferences
for each row
execute function
public.set_whatsapp_notification_preferences_updated_at();


-- ============================================================
-- 5. AUTOMATIC PREFERENCE ROW FOR NEW PROFILES
-- ============================================================

create or replace function
public.create_whatsapp_notification_preference_for_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin

    insert into public.whatsapp_notification_preferences (
        profile_id,
        consent_status,
        transactional_enabled
    )
    values (
        new.id,
        'unknown'::public.whatsapp_consent_status,
        false
    )
    on conflict (profile_id)
    do nothing;

    return new;

end;
$function$;


alter function
public.create_whatsapp_notification_preference_for_profile()
owner to postgres;


revoke all
on function
public.create_whatsapp_notification_preference_for_profile()
from public, anon, authenticated, service_role;


drop trigger if exists
profiles_create_whatsapp_notification_preference
on public.profiles;


create trigger
profiles_create_whatsapp_notification_preference
after insert
on public.profiles
for each row
execute function
public.create_whatsapp_notification_preference_for_profile();


-- ============================================================
-- 6. BACKFILL EXISTING PROFILES
-- ============================================================
--
-- CRITICAL:
-- Existing WhatsApp numbers are NOT treated as consent.
--
-- Every existing profile starts UNKNOWN unless explicitly
-- opted in later.
-- ============================================================

insert into public.whatsapp_notification_preferences (
    profile_id,
    consent_status,
    transactional_enabled
)
select
    p.id,
    'unknown'::public.whatsapp_consent_status,
    false
from public.profiles p
on conflict (profile_id)
do nothing;


-- ============================================================
-- 7. INVALIDATE CONSENT WHEN WHATSAPP NUMBER CHANGES
-- ============================================================
--
-- Consent belongs to the number that was explicitly consented.
--
-- Changing the number:
--
--   - makes consent UNKNOWN
--   - disables transactional notifications
--   - preserves historical consent timestamps/source
--   - cancels PENDING WhatsApp jobs
--   - leaves PROCESSING jobs untouched
--
-- ============================================================

create or replace function
public.invalidate_whatsapp_consent_on_number_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin

    if old.whatsapp_number is distinct from new.whatsapp_number then

        insert into public.whatsapp_notification_preferences (
            profile_id,
            consent_status,
            transactional_enabled
        )
        values (
            new.id,
            'unknown'::public.whatsapp_consent_status,
            false
        )

        on conflict (profile_id)
        do update set
            consent_status =
                'unknown'::public.whatsapp_consent_status,

            transactional_enabled = false,

            updated_at = now();


        update public.notification_outbox n
        set
            status =
                'cancelled'::public.notification_outbox_status,

            locked_at = null,
            locked_by = null,

            last_error =
                'WhatsApp number changed; new consent required',

            updated_at = now()

        where n.recipient_profile_id = new.id

          and n.channel =
              'whatsapp'::public.notification_channel

          and n.status =
              'pending'::public.notification_outbox_status;

    end if;


    return new;

end;
$function$;


alter function
public.invalidate_whatsapp_consent_on_number_change()
owner to postgres;


revoke all
on function
public.invalidate_whatsapp_consent_on_number_change()
from public, anon, authenticated, service_role;


drop trigger if exists
profiles_invalidate_whatsapp_consent_on_number_change
on public.profiles;


create trigger
profiles_invalidate_whatsapp_consent_on_number_change
after update of whatsapp_number
on public.profiles
for each row
execute function
public.invalidate_whatsapp_consent_on_number_change();


-- ============================================================
-- 8. CENTRAL WHATSAPP ELIGIBILITY FUNCTION
-- ============================================================
--
-- p_event_type is deliberately part of the API now so DIJO can
-- later introduce event-category-specific preferences without
-- changing this function signature.
--
-- Migration 033 treats all current notification events as
-- transactional.
--
-- ============================================================

create or replace function
public.can_receive_whatsapp_notification(
    p_profile_id uuid,
    p_event_type text
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
    v_allowed boolean;
begin

    if p_profile_id is null then
        return false;
    end if;


    if p_event_type is null
       or btrim(p_event_type) = '' then
        return false;
    end if;


    select exists (

        select 1

        from public.profiles p

        join public.whatsapp_notification_preferences w
          on w.profile_id = p.id

        where p.id = p_profile_id

          and p.is_active is true

          and p.whatsapp_number is not null

          and btrim(p.whatsapp_number) <> ''

          and w.consent_status =
              'opted_in'::public.whatsapp_consent_status

          and w.transactional_enabled is true

          and w.consented_whatsapp_number is not null

          and btrim(w.consented_whatsapp_number) =
              btrim(p.whatsapp_number)

    )
    into v_allowed;


    return coalesce(v_allowed, false);

end;
$function$;


alter function
public.can_receive_whatsapp_notification(uuid, text)
owner to postgres;


revoke all
on function
public.can_receive_whatsapp_notification(uuid, text)
from public, anon, authenticated;


grant execute
on function
public.can_receive_whatsapp_notification(uuid, text)
to service_role;


-- ============================================================
-- 9. SELF-SERVICE OPT-IN
-- ============================================================

create or replace function
public.opt_in_whatsapp_notifications(
    p_consent_source text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_profile_id uuid;
    v_whatsapp_number text;
begin

    v_profile_id := auth.uid();


    if v_profile_id is null then
        raise exception
            'Authentication required';
    end if;


    if p_consent_source is null
       or btrim(p_consent_source) = '' then
        raise exception
            'consent_source is required';
    end if;


    if length(p_consent_source) > 100 then
        raise exception
            'consent_source cannot exceed 100 characters';
    end if;


    select p.whatsapp_number
    into v_whatsapp_number
    from public.profiles p
    where p.id = v_profile_id
      and p.is_active is true;


    if not found then
        raise exception
            'Active profile not found';
    end if;


    if v_whatsapp_number is null
       or btrim(v_whatsapp_number) = '' then
        raise exception
            'WhatsApp number is required before opting in';
    end if;


    insert into public.whatsapp_notification_preferences (
        profile_id,
        consent_status,
        transactional_enabled,
        consent_source,
        consented_whatsapp_number,
        consented_at
    )
    values (
        v_profile_id,
        'opted_in'::public.whatsapp_consent_status,
        true,
        btrim(p_consent_source),
        btrim(v_whatsapp_number),
        now()
    )

    on conflict (profile_id)
    do update set
        consent_status =
            'opted_in'::public.whatsapp_consent_status,

        transactional_enabled = true,

        consent_source =
            excluded.consent_source,

        consented_whatsapp_number =
            excluded.consented_whatsapp_number,

        consented_at = now(),

        updated_at = now();


    return true;

end;
$function$;


alter function
public.opt_in_whatsapp_notifications(text)
owner to postgres;


revoke all
on function
public.opt_in_whatsapp_notifications(text)
from public, anon, service_role;


grant execute
on function
public.opt_in_whatsapp_notifications(text)
to authenticated;


-- ============================================================
-- 10. SELF-SERVICE OPT-OUT
-- ============================================================

create or replace function
public.opt_out_whatsapp_notifications()
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_profile_id uuid;
begin

    v_profile_id := auth.uid();


    if v_profile_id is null then
        raise exception
            'Authentication required';
    end if;


    if not exists (
        select 1
        from public.profiles p
        where p.id = v_profile_id
    ) then
        raise exception
            'Profile not found';
    end if;


    insert into public.whatsapp_notification_preferences (
        profile_id,
        consent_status,
        transactional_enabled,
        opted_out_at,
        opt_out_source
    )
    values (
        v_profile_id,
        'opted_out'::public.whatsapp_consent_status,
        false,
        now(),
        'self_service'
    )

    on conflict (profile_id)
    do update set
        consent_status =
            'opted_out'::public.whatsapp_consent_status,

        transactional_enabled = false,

        opted_out_at = now(),

        opt_out_source = 'self_service',

        updated_at = now();


    -- Cancel only PENDING work.
    --
    -- PROCESSING jobs may already have reached Meta and must
    -- remain acknowledgeable by the worker.
    update public.notification_outbox n
    set
        status =
            'cancelled'::public.notification_outbox_status,

        locked_at = null,
        locked_by = null,

        last_error =
            'Recipient opted out of WhatsApp notifications',

        updated_at = now()

    where n.recipient_profile_id = v_profile_id

      and n.channel =
          'whatsapp'::public.notification_channel

      and n.status =
          'pending'::public.notification_outbox_status;


    return true;

end;
$function$;


alter function
public.opt_out_whatsapp_notifications()
owner to postgres;


revoke all
on function
public.opt_out_whatsapp_notifications()
from public, anon, service_role;


grant execute
on function
public.opt_out_whatsapp_notifications()
to authenticated;


-- ============================================================
-- 11. TRUSTED BACKEND CONSENT RECORDING
-- ============================================================
--
-- This allows a trusted backend to record verified consent
-- obtained outside the authenticated web UI, for example:
--
--   WhatsApp onboarding
--   verified inbound WhatsApp interaction
--   assisted support onboarding
--
-- service_role ONLY.
--
-- ============================================================

create or replace function
public.record_whatsapp_notification_consent(
    p_profile_id uuid,
    p_opted_in boolean,
    p_consent_source text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_whatsapp_number text;
    v_is_active boolean;
begin

    if p_profile_id is null then
        raise exception
            'profile_id is required';
    end if;


    if p_opted_in is null then
        raise exception
            'opted_in is required';
    end if;


    if p_consent_source is null
       or btrim(p_consent_source) = '' then
        raise exception
            'consent_source is required';
    end if;


    if length(p_consent_source) > 100 then
        raise exception
            'consent_source cannot exceed 100 characters';
    end if;


    select
        p.whatsapp_number,
        p.is_active
    into
        v_whatsapp_number,
        v_is_active
    from public.profiles p
    where p.id = p_profile_id;


    if not found then
        raise exception
            'Profile not found';
    end if;


    -- --------------------------------------------------------
    -- OPT IN
    -- --------------------------------------------------------

    if p_opted_in is true then

        if v_is_active is not true then
            raise exception
                'Inactive profile cannot opt in';
        end if;


        if v_whatsapp_number is null
           or btrim(v_whatsapp_number) = '' then
            raise exception
                'WhatsApp number is required before opting in';
        end if;


        insert into public.whatsapp_notification_preferences (
            profile_id,
            consent_status,
            transactional_enabled,
            consent_source,
            consented_whatsapp_number,
            consented_at
        )
        values (
            p_profile_id,
            'opted_in'::public.whatsapp_consent_status,
            true,
            btrim(p_consent_source),
            btrim(v_whatsapp_number),
            now()
        )

        on conflict (profile_id)
        do update set
            consent_status =
                'opted_in'::public.whatsapp_consent_status,

            transactional_enabled = true,

            consent_source =
                excluded.consent_source,

            consented_whatsapp_number =
                excluded.consented_whatsapp_number,

            consented_at = now(),

            updated_at = now();


    -- --------------------------------------------------------
    -- OPT OUT
    -- --------------------------------------------------------

    else

        insert into public.whatsapp_notification_preferences (
            profile_id,
            consent_status,
            transactional_enabled,
            opted_out_at,
            opt_out_source
        )
        values (
            p_profile_id,
            'opted_out'::public.whatsapp_consent_status,
            false,
            now(),
            btrim(p_consent_source)
        )

        on conflict (profile_id)
        do update set
            consent_status =
                'opted_out'::public.whatsapp_consent_status,

            transactional_enabled = false,

            opted_out_at = now(),

            opt_out_source =
                excluded.opt_out_source,

            updated_at = now();


        update public.notification_outbox n
        set
            status =
                'cancelled'::public.notification_outbox_status,

            locked_at = null,
            locked_by = null,

            last_error =
                'Recipient opted out of WhatsApp notifications',

            updated_at = now()

        where n.recipient_profile_id = p_profile_id

          and n.channel =
              'whatsapp'::public.notification_channel

          and n.status =
              'pending'::public.notification_outbox_status;

    end if;


    return true;

end;
$function$;


alter function
public.record_whatsapp_notification_consent(
    uuid,
    boolean,
    text
)
owner to postgres;


revoke all
on function
public.record_whatsapp_notification_consent(
    uuid,
    boolean,
    text
)
from public, anon, authenticated;


grant execute
on function
public.record_whatsapp_notification_consent(
    uuid,
    boolean,
    text
)
to service_role;


-- ============================================================
-- 12. CONSENT-AWARE NOTIFICATION CLAIM WORKER
-- ============================================================
--
-- Preserves all Migration 031a protections:
--
--   - worker validation
--   - lease recovery
--   - abandoned job failure
--   - WhatsApp number validation
--   - live delivery-offer validation
--   - max-attempt protection
--   - FOR UPDATE SKIP LOCKED
--
-- Adds:
--
--   - explicit WhatsApp consent enforcement
--   - transactional preference enforcement
--   - consented-number matching
--
-- ============================================================

create or replace function
public.claim_notification_outbox(
    p_worker_id text,
    p_limit integer default 20,
    p_lease_seconds integer default 120
)
returns table(
    notification_id uuid,
    recipient_profile_id uuid,
    recipient_whatsapp_number text,
    channel public.notification_channel,
    event_type text,
    payload jsonb,
    source_type text,
    source_id uuid,
    attempt_count integer,
    max_attempts integer,
    available_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$

#variable_conflict use_column

begin

    -- ========================================================
    -- INPUT VALIDATION
    -- ========================================================

    if p_worker_id is null
       or btrim(p_worker_id) = '' then
        raise exception
            'worker_id is required';
    end if;


    if length(p_worker_id) > 150 then
        raise exception
            'worker_id cannot exceed 150 characters';
    end if;


    if p_limit is null
       or p_limit < 1
       or p_limit > 100 then
        raise exception
            'limit must be between 1 and 100';
    end if;


    if p_lease_seconds is null
       or p_lease_seconds < 30
       or p_lease_seconds > 600 then
        raise exception
            'lease_seconds must be between 30 and 600';
    end if;


    -- ========================================================
    -- TERMINATE ABANDONED PROCESSING JOBS AT MAX ATTEMPTS
    -- ========================================================

    update public.notification_outbox n
    set
        status =
            'failed'::public.notification_outbox_status,

        failed_at = coalesce(
            n.failed_at,
            now()
        ),

        locked_at = null,
        locked_by = null,

        last_error = coalesce(
            n.last_error,
            'Notification worker lease expired after maximum attempts'
        ),

        updated_at = now()

    where n.status =
          'processing'::public.notification_outbox_status

      and n.locked_at <=
          now() -
          (
              p_lease_seconds
              * interval '1 second'
          )

      and n.attempt_count >= n.max_attempts;


    -- ========================================================
    -- RECOVER ABANDONED PROCESSING JOBS WITH RETRIES LEFT
    -- ========================================================

    update public.notification_outbox n
    set
        status =
            'pending'::public.notification_outbox_status,

        locked_at = null,
        locked_by = null,

        available_at = now(),

        updated_at = now()

    where n.status =
          'processing'::public.notification_outbox_status

      and n.locked_at <=
          now() -
          (
              p_lease_seconds
              * interval '1 second'
          )

      and n.attempt_count < n.max_attempts;


    -- ========================================================
    -- FAIL UNDELIVERABLE RECIPIENTS
    -- ========================================================

    update public.notification_outbox n
    set
        status =
            'failed'::public.notification_outbox_status,

        failed_at = coalesce(
            n.failed_at,
            now()
        ),

        last_error =
            case
                when p.is_active is not true then
                    'Recipient profile is inactive'
                else
                    'Recipient has no WhatsApp number'
            end,

        locked_at = null,
        locked_by = null,

        updated_at = now()

    from public.profiles p

    where p.id = n.recipient_profile_id

      and n.status =
          'pending'::public.notification_outbox_status

      and (
          p.is_active is not true
          or p.whatsapp_number is null
          or btrim(p.whatsapp_number) = ''
      );


    -- ========================================================
    -- CANCEL PENDING WHATSAPP JOBS WITHOUT CURRENT CONSENT
    -- ========================================================
    --
    -- Absence of consent is a policy decision, not a provider
    -- delivery failure, therefore these jobs become CANCELLED.
    --
    -- PROCESSING jobs are intentionally untouched.
    -- ========================================================

    update public.notification_outbox n
    set
        status =
            'cancelled'::public.notification_outbox_status,

        locked_at = null,
        locked_by = null,

        last_error =
            case

                when w.profile_id is null then
                    'Recipient has no WhatsApp consent record'

                when w.consent_status =
                     'opted_out'::public.whatsapp_consent_status then
                    'Recipient opted out of WhatsApp notifications'

                when w.consented_whatsapp_number is not null
                     and btrim(w.consented_whatsapp_number)
                         is distinct from
                         btrim(p.whatsapp_number) then
                    'WhatsApp number changed since consent'

                when w.consent_status <>
                     'opted_in'::public.whatsapp_consent_status then
                    'Recipient has not opted in to WhatsApp notifications'

                when w.transactional_enabled is not true then
                    'Transactional WhatsApp notifications are disabled'

                else
                    'Recipient is not eligible for WhatsApp notifications'

            end,

        updated_at = now()

    from public.profiles p

    left join public.whatsapp_notification_preferences w
      on w.profile_id = p.id

    where p.id = n.recipient_profile_id

      and n.channel =
          'whatsapp'::public.notification_channel

      and n.status =
          'pending'::public.notification_outbox_status

      and not (
          w.consent_status =
              'opted_in'::public.whatsapp_consent_status

          and w.transactional_enabled is true

          and w.consented_whatsapp_number is not null

          and btrim(w.consented_whatsapp_number) =
              btrim(p.whatsapp_number)
      );


    -- ========================================================
    -- CANCEL DELIVERY-OFFER NOTIFICATIONS WHOSE SOURCE OFFER
    -- IS NO LONGER LIVE
    -- ========================================================

    update public.notification_outbox n
    set
        status =
            'cancelled'::public.notification_outbox_status,

        locked_at = null,
        locked_by = null,

        updated_at = now()

    where n.status =
          'pending'::public.notification_outbox_status

      and n.source_type = 'delivery_offer'

      and (
          n.source_id is null

          or not exists (
              select 1
              from public.delivery_offers o
              where o.id = n.source_id
                and o.status =
                    'pending'::public.delivery_offer_status
                and o.expires_at > now()
          )
      );


    -- ========================================================
    -- FAIL PENDING JOBS THAT EXHAUSTED ATTEMPTS
    -- ========================================================

    update public.notification_outbox n
    set
        status =
            'failed'::public.notification_outbox_status,

        failed_at = coalesce(
            n.failed_at,
            now()
        ),

        locked_at = null,
        locked_by = null,

        last_error = coalesce(
            n.last_error,
            'Maximum notification attempts reached'
        ),

        updated_at = now()

    where n.status =
          'pending'::public.notification_outbox_status

      and n.attempt_count >= n.max_attempts;


    -- ========================================================
    -- CLAIM AVAILABLE JOBS ATOMICALLY
    -- ========================================================

    return query

    with candidates as (

        select n.id

        from public.notification_outbox n

        join public.profiles p
          on p.id = n.recipient_profile_id

        join public.whatsapp_notification_preferences w
          on w.profile_id = p.id

        where n.status =
              'pending'::public.notification_outbox_status

          and n.available_at <= now()

          and n.attempt_count < n.max_attempts

          and p.is_active is true

          and p.whatsapp_number is not null

          and btrim(p.whatsapp_number) <> ''

          -- --------------------------------------------------
          -- EXPLICIT WHATSAPP CONSENT
          -- --------------------------------------------------

          and w.consent_status =
              'opted_in'::public.whatsapp_consent_status

          and w.transactional_enabled is true

          and w.consented_whatsapp_number is not null

          and btrim(w.consented_whatsapp_number) =
              btrim(p.whatsapp_number)


          -- --------------------------------------------------
          -- DELIVERY-OFFER SOURCE VALIDATION
          -- --------------------------------------------------

          and (
              n.source_type is distinct from 'delivery_offer'

              or (
                  n.source_id is not null

                  and exists (
                      select 1
                      from public.delivery_offers source_offer
                      where source_offer.id = n.source_id
                        and source_offer.status =
                            'pending'::public.delivery_offer_status
                        and source_offer.expires_at > now()
                  )
              )
          )

        order by
            n.available_at asc,
            n.created_at asc,
            n.id asc

        for update of n
        skip locked

        limit p_limit
    ),

    claimed as (

        update public.notification_outbox n
        set
            status =
                'processing'::public.notification_outbox_status,

            attempt_count =
                n.attempt_count + 1,

            locked_at = now(),
            locked_by = p_worker_id,

            last_attempt_at = now(),

            updated_at = now()

        from candidates c

        where n.id = c.id

        returning
            n.id,
            n.recipient_profile_id,
            n.channel,
            n.event_type,
            n.payload,
            n.source_type,
            n.source_id,
            n.attempt_count,
            n.max_attempts,
            n.available_at
    )

    select
        c.id,
        c.recipient_profile_id,
        p.whatsapp_number,
        c.channel,
        c.event_type,
        c.payload,
        c.source_type,
        c.source_id,
        c.attempt_count,
        c.max_attempts,
        c.available_at

    from claimed c

    join public.profiles p
      on p.id = c.recipient_profile_id

    order by
        c.available_at asc,
        c.id asc;

end;
$function$;


alter function
public.claim_notification_outbox(
    text,
    integer,
    integer
)
owner to postgres;


revoke all
on function
public.claim_notification_outbox(
    text,
    integer,
    integer
)
from public, anon, authenticated;


grant execute
on function
public.claim_notification_outbox(
    text,
    integer,
    integer
)
to service_role;


-- ============================================================
-- 13. FINAL PRIVILEGE REASSERTION
-- ============================================================

revoke all
on function
public.set_whatsapp_notification_preferences_updated_at()
from public, anon, authenticated, service_role;

revoke all
on function
public.create_whatsapp_notification_preference_for_profile()
from public, anon, authenticated, service_role;

revoke all
on function
public.invalidate_whatsapp_consent_on_number_change()
from public, anon, authenticated, service_role;


revoke all
on function
public.can_receive_whatsapp_notification(uuid, text)
from public, anon, authenticated;

grant execute
on function
public.can_receive_whatsapp_notification(uuid, text)
to service_role;


revoke all
on function
public.opt_in_whatsapp_notifications(text)
from public, anon, service_role;

grant execute
on function
public.opt_in_whatsapp_notifications(text)
to authenticated;


revoke all
on function
public.opt_out_whatsapp_notifications()
from public, anon, service_role;

grant execute
on function
public.opt_out_whatsapp_notifications()
to authenticated;


revoke all
on function
public.record_whatsapp_notification_consent(
    uuid,
    boolean,
    text
)
from public, anon, authenticated;

grant execute
on function
public.record_whatsapp_notification_consent(
    uuid,
    boolean,
    text
)
to service_role;


revoke all
on function
public.claim_notification_outbox(
    text,
    integer,
    integer
)
from public, anon, authenticated;

grant execute
on function
public.claim_notification_outbox(
    text,
    integer,
    integer
)
to service_role;


-- ============================================================
-- END MIGRATION 033
-- ============================================================
