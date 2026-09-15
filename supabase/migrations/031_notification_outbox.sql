-- ============================================================
-- DIJO
-- Migration 031: Notification Outbox
-- ============================================================
--
-- PURPOSE
-- -------
-- Create DIJO's durable notification queue.
--
-- Database transactions create notification jobs.
-- A trusted backend worker later:
--
--   1. claims pending jobs
--   2. sends WhatsApp messages through Meta
--   3. marks jobs sent or failed
--   4. retries transient failures
--
-- PostgreSQL does NOT call Meta directly.
--
-- FIRST PRODUCER
-- --------------
-- Pending delivery offers automatically create a WhatsApp
-- notification job for the offered driver.
--
-- SECURITY
-- --------
-- The outbox is backend-only.
--
-- anon/authenticated clients receive no direct table access
-- and cannot execute worker RPCs.
--
-- Worker RPCs are service_role only.
--
-- HARDENING
-- ---------
-- 1. Drivers without usable WhatsApp numbers cannot be claimed.
-- 2. Closed/expired delivery offers cannot be claimed.
-- 3. A notification already claimed by a worker is not
--    cancelled underneath that worker.
-- 4. Abandoned processing jobs are recovered safely.
-- 5. Multiple workers may claim jobs concurrently through
--    FOR UPDATE SKIP LOCKED.
--
-- ============================================================


-- ============================================================
-- 1. ENUMS
-- ============================================================

do $$
begin

    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
          on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname = 'notification_channel'
    ) then

        create type public.notification_channel
        as enum (
            'whatsapp'
        );

    end if;


    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
          on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname = 'notification_outbox_status'
    ) then

        create type public.notification_outbox_status
        as enum (
            'pending',
            'processing',
            'sent',
            'failed',
            'cancelled'
        );

    end if;

end
$$;


-- ============================================================
-- 2. NOTIFICATION OUTBOX TABLE
-- ============================================================

create table if not exists public.notification_outbox (
    id uuid primary key default gen_random_uuid(),

    recipient_profile_id uuid not null,

    channel public.notification_channel
        not null
        default 'whatsapp'::public.notification_channel,

    event_type text not null,

    payload jsonb not null default '{}'::jsonb,

    source_type text null,
    source_id uuid null,

    idempotency_key text not null,

    status public.notification_outbox_status
        not null
        default 'pending'::public.notification_outbox_status,

    attempt_count integer not null default 0,
    max_attempts integer not null default 5,

    available_at timestamptz not null default now(),

    locked_at timestamptz null,
    locked_by text null,

    last_attempt_at timestamptz null,

    sent_at timestamptz null,
    failed_at timestamptz null,

    last_error text null,

    provider_message_id text null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint notification_outbox_recipient_fkey
        foreign key (recipient_profile_id)
        references public.profiles (id)
        on delete cascade,

    constraint notification_outbox_idempotency_unique
        unique (idempotency_key),

    constraint notification_outbox_event_type_nonblank
        check (
            btrim(event_type) <> ''
            and length(event_type) <= 120
        ),

    constraint notification_outbox_source_type_valid
        check (
            source_type is null
            or (
                btrim(source_type) <> ''
                and length(source_type) <= 100
            )
        ),

    constraint notification_outbox_idempotency_nonblank
        check (
            btrim(idempotency_key) <> ''
            and length(idempotency_key) <= 250
        ),

    constraint notification_outbox_payload_object
        check (
            jsonb_typeof(payload) = 'object'
        ),

    constraint notification_outbox_attempt_count_valid
        check (
            attempt_count >= 0
        ),

    constraint notification_outbox_max_attempts_valid
        check (
            max_attempts >= 1
            and max_attempts <= 20
        ),

    constraint notification_outbox_locked_by_valid
        check (
            locked_by is null
            or (
                btrim(locked_by) <> ''
                and length(locked_by) <= 150
            )
        )
);


-- ============================================================
-- 3. INDEXES
-- ============================================================

create index if not exists
notification_outbox_claim_idx
on public.notification_outbox (
    status,
    available_at,
    created_at
);


create index if not exists
notification_outbox_recipient_idx
on public.notification_outbox (
    recipient_profile_id,
    created_at desc
);


create index if not exists
notification_outbox_source_idx
on public.notification_outbox (
    source_type,
    source_id
)
where source_id is not null;


create index if not exists
notification_outbox_processing_lock_idx
on public.notification_outbox (
    locked_at
)
where status =
    'processing'::public.notification_outbox_status;


create unique index if not exists
notification_outbox_provider_message_unique_idx
on public.notification_outbox (
    provider_message_id
)
where provider_message_id is not null;


-- ============================================================
-- 4. RLS + TABLE PRIVILEGES
-- ============================================================

alter table public.notification_outbox
enable row level security;


-- No client-facing RLS policies are intentionally created.
-- The outbox is backend infrastructure.

revoke all
on public.notification_outbox
from anon, authenticated;


-- Even service_role should use controlled worker RPCs rather
-- than directly mutating the outbox table.

revoke all
on public.notification_outbox
from service_role;


-- ============================================================
-- 5. INTERNAL / BACKEND ENQUEUE RPC
-- ============================================================

create or replace function public.enqueue_notification(
    p_recipient_profile_id uuid,
    p_event_type text,
    p_payload jsonb default '{}'::jsonb,
    p_idempotency_key text default null,
    p_source_type text default null,
    p_source_id uuid default null,
    p_available_at timestamptz default now(),
    p_max_attempts integer default 5
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_notification_id uuid;
    v_idempotency_key text;
begin

    -- ========================================================
    -- INPUT VALIDATION
    -- ========================================================

    if p_recipient_profile_id is null then
        raise exception
            'recipient_profile_id is required';
    end if;


    if p_event_type is null
       or btrim(p_event_type) = '' then
        raise exception
            'event_type is required';
    end if;


    if length(p_event_type) > 120 then
        raise exception
            'event_type cannot exceed 120 characters';
    end if;


    if p_payload is null
       or jsonb_typeof(p_payload) <> 'object' then
        raise exception
            'payload must be a JSON object';
    end if;


    if p_max_attempts is null
       or p_max_attempts < 1
       or p_max_attempts > 20 then
        raise exception
            'max_attempts must be between 1 and 20';
    end if;


    if p_available_at is null then
        raise exception
            'available_at is required';
    end if;


    if p_source_type is not null
       and (
           btrim(p_source_type) = ''
           or length(p_source_type) > 100
       ) then
        raise exception
            'source_type is invalid';
    end if;


    if not exists (
        select 1
        from public.profiles p
        where p.id = p_recipient_profile_id
          and p.is_active is true
    ) then
        raise exception
            'Active recipient profile required';
    end if;


    -- ========================================================
    -- IDEMPOTENCY KEY
    -- ========================================================

    v_idempotency_key := coalesce(
        nullif(
            btrim(p_idempotency_key),
            ''
        ),
        p_event_type
            || ':'
            || p_recipient_profile_id::text
            || ':'
            || gen_random_uuid()::text
    );


    if length(v_idempotency_key) > 250 then
        raise exception
            'idempotency_key cannot exceed 250 characters';
    end if;


    -- ========================================================
    -- INSERT JOB
    -- ========================================================

    insert into public.notification_outbox (
        recipient_profile_id,
        channel,
        event_type,
        payload,
        source_type,
        source_id,
        idempotency_key,
        status,
        attempt_count,
        max_attempts,
        available_at,
        created_at,
        updated_at
    )
    values (
        p_recipient_profile_id,
        'whatsapp'::public.notification_channel,
        p_event_type,
        p_payload,
        p_source_type,
        p_source_id,
        v_idempotency_key,
        'pending'::public.notification_outbox_status,
        0,
        p_max_attempts,
        p_available_at,
        now(),
        now()
    )

    on conflict (idempotency_key)
    do nothing

    returning id
    into v_notification_id;


    -- ========================================================
    -- IDEMPOTENT REPLAY
    -- ========================================================

    if v_notification_id is null then

        select n.id
        into v_notification_id
        from public.notification_outbox n
        where n.idempotency_key =
              v_idempotency_key;

    end if;


    return v_notification_id;

end;
$function$;


alter function public.enqueue_notification(
    uuid,
    text,
    jsonb,
    text,
    text,
    uuid,
    timestamptz,
    integer
)
owner to postgres;


-- ============================================================
-- 6. DRIVER OFFER -> OUTBOX PRODUCER
-- ============================================================

create or replace function
public.enqueue_delivery_offer_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin

    if new.status <>
       'pending'::public.delivery_offer_status then
        return new;
    end if;


    perform public.enqueue_notification(
        new.driver_profile_id,

        'driver.delivery_offer.available',

        jsonb_build_object(
            'offer_id',
            new.id,

            'order_id',
            new.order_id,

            'business_id',
            new.business_id,

            'pickup_location_id',
            new.pickup_location_id,

            'distance_metres',
            round(
                new.distance_metres::numeric,
                2
            ),

            'expires_at',
            new.expires_at
        ),

        'delivery_offer:'
            || new.id::text
            || ':available',

        'delivery_offer',

        new.id,

        now(),

        5
    );


    return new;

end;
$function$;


alter function
public.enqueue_delivery_offer_notification()
owner to postgres;


revoke all
on function
public.enqueue_delivery_offer_notification()
from public, anon, authenticated, service_role;


drop trigger if exists
delivery_offers_enqueue_notification
on public.delivery_offers;


create trigger
delivery_offers_enqueue_notification
after insert
on public.delivery_offers
for each row
execute function
public.enqueue_delivery_offer_notification();


-- ============================================================
-- 7. CANCEL UNSENT OFFER NOTIFICATION WHEN OFFER CLOSES
-- ============================================================
--
-- Only PENDING notifications are cancelled here.
--
-- A PROCESSING notification is already owned by a worker.
-- Changing its status underneath that worker could result in
-- Meta successfully sending the message while the worker can
-- no longer acknowledge the job.
--
-- ============================================================

create or replace function
public.cancel_delivery_offer_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin

    if old.status =
       'pending'::public.delivery_offer_status

       and new.status <>
           'pending'::public.delivery_offer_status then

        update public.notification_outbox n
        set
            status =
                'cancelled'::public.notification_outbox_status,

            locked_at = null,
            locked_by = null,

            updated_at = now()

        where n.source_type = 'delivery_offer'
          and n.source_id = new.id
          and n.status =
              'pending'::public.notification_outbox_status;

    end if;


    return new;

end;
$function$;


alter function
public.cancel_delivery_offer_notification()
owner to postgres;


revoke all
on function
public.cancel_delivery_offer_notification()
from public, anon, authenticated, service_role;


drop trigger if exists
delivery_offers_cancel_notification
on public.delivery_offers;


create trigger
delivery_offers_cancel_notification
after update of status
on public.delivery_offers
for each row
when (old.status is distinct from new.status)
execute function
public.cancel_delivery_offer_notification();


-- ============================================================
-- 8. WORKER: CLAIM NOTIFICATION JOBS
-- ============================================================
--
-- Uses FOR UPDATE SKIP LOCKED so multiple backend workers can
-- safely claim separate jobs concurrently.
--
-- Processing jobs use a lease. If a worker crashes, the job
-- can later be recovered and retried.
--
-- ============================================================

create or replace function
public.claim_notification_outbox(
    p_worker_id text,
    p_limit integer default 20,
    p_lease_seconds integer default 120
)
returns table (
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
    -- TERMINATE ABANDONED PROCESSING JOBS THAT HAVE EXHAUSTED
    -- ALL RETRIES
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
    -- RECOVER ABANDONED PROCESSING JOBS THAT STILL HAVE RETRIES
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
    -- FAIL JOBS THAT HAVE NO DELIVERABLE WHATSAPP RECIPIENT
    --
    -- This runs AFTER lease recovery so recovered jobs are
    -- also revalidated before they can be claimed again.
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
    -- CANCEL DELIVERY-OFFER NOTIFICATIONS WHOSE OFFER IS
    -- ALREADY CLOSED OR EXPIRED
    --
    -- This protects against:
    --
    --   accepted offers
    --   rejected offers
    --   cancelled offers
    --   expired-status offers
    --   pending offers whose expires_at has passed but whose
    --   status has not yet been updated by the expiry worker
    --
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
    -- PENDING JOBS THAT HAVE EXHAUSTED ATTEMPTS BECOME FAILED
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

        where n.status =
              'pending'::public.notification_outbox_status

          and n.available_at <= now()

          and n.attempt_count < n.max_attempts

          and p.is_active is true

          and p.whatsapp_number is not null

          and btrim(p.whatsapp_number) <> ''

          -- --------------------------------------------------
          -- Defense-in-depth:
          -- delivery-offer jobs are claimable only while the
          -- source offer remains live.
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


alter function public.claim_notification_outbox(
    text,
    integer,
    integer
)
owner to postgres;


-- ============================================================
-- 9. WORKER: MARK SENT
-- ============================================================

create or replace function
public.mark_notification_sent(
    p_notification_id uuid,
    p_worker_id text,
    p_provider_message_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_updated integer;
begin

    if p_notification_id is null then
        raise exception
            'notification_id is required';
    end if;


    if p_worker_id is null
       or btrim(p_worker_id) = '' then
        raise exception
            'worker_id is required';
    end if;


    if p_provider_message_id is not null
       and btrim(p_provider_message_id) = '' then
        p_provider_message_id := null;
    end if;


    update public.notification_outbox n
    set
        status =
            'sent'::public.notification_outbox_status,

        sent_at = now(),
        failed_at = null,

        provider_message_id =
            p_provider_message_id,

        last_error = null,

        locked_at = null,
        locked_by = null,

        updated_at = now()

    where n.id = p_notification_id

      and n.status =
          'processing'::public.notification_outbox_status

      and n.locked_by = p_worker_id;


    get diagnostics
        v_updated = row_count;


    if v_updated <> 1 then
        raise exception
            'Notification job is not owned by this worker';
    end if;


    return true;

end;
$function$;


alter function public.mark_notification_sent(
    uuid,
    text,
    text
)
owner to postgres;


-- ============================================================
-- 10. WORKER: MARK FAILED / RETRY
-- ============================================================

create or replace function
public.mark_notification_failed(
    p_notification_id uuid,
    p_worker_id text,
    p_error text,
    p_retry_after_seconds integer default null,
    p_terminal boolean default false
)
returns public.notification_outbox_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_attempt_count integer;
    v_max_attempts integer;

    v_retry_seconds integer;

    v_result_status
        public.notification_outbox_status;
begin

    if p_notification_id is null then
        raise exception
            'notification_id is required';
    end if;


    if p_worker_id is null
       or btrim(p_worker_id) = '' then
        raise exception
            'worker_id is required';
    end if;


    if p_error is null
       or btrim(p_error) = '' then
        raise exception
            'error message is required';
    end if;


    if p_retry_after_seconds is not null
       and (
           p_retry_after_seconds < 1
           or p_retry_after_seconds > 86400
       ) then
        raise exception
            'retry_after_seconds must be between 1 and 86400';
    end if;


    -- ========================================================
    -- LOCK JOB OWNED BY THIS WORKER
    -- ========================================================

    select
        n.attempt_count,
        n.max_attempts
    into
        v_attempt_count,
        v_max_attempts
    from public.notification_outbox n
    where n.id = p_notification_id

      and n.status =
          'processing'::public.notification_outbox_status

      and n.locked_by = p_worker_id

    for update;


    if not found then
        raise exception
            'Notification job is not owned by this worker';
    end if;


    -- ========================================================
    -- TERMINAL FAILURE
    -- ========================================================

    if p_terminal is true
       or v_attempt_count >= v_max_attempts then

        update public.notification_outbox n
        set
            status =
                'failed'::public.notification_outbox_status,

            failed_at = now(),

            last_error =
                left(p_error, 2000),

            locked_at = null,
            locked_by = null,

            updated_at = now()

        where n.id = p_notification_id;


        v_result_status :=
            'failed'::public.notification_outbox_status;


    -- ========================================================
    -- RETRY
    -- ========================================================

    else

        v_retry_seconds := coalesce(
            p_retry_after_seconds,

            least(
                1800,

                (
                    30
                    * power(
                        2,
                        greatest(
                            v_attempt_count - 1,
                            0
                        )
                    )
                )::integer
            )
        );


        update public.notification_outbox n
        set
            status =
                'pending'::public.notification_outbox_status,

            available_at =
                now()
                + (
                    v_retry_seconds
                    * interval '1 second'
                ),

            failed_at = null,

            last_error =
                left(p_error, 2000),

            locked_at = null,
            locked_by = null,

            updated_at = now()

        where n.id = p_notification_id;


        v_result_status :=
            'pending'::public.notification_outbox_status;

    end if;


    return v_result_status;

end;
$function$;


alter function public.mark_notification_failed(
    uuid,
    text,
    text,
    integer,
    boolean
)
owner to postgres;


-- ============================================================
-- 11. FUNCTION EXECUTION PRIVILEGES
-- ============================================================


-- ============================================================
-- ENQUEUE
-- ============================================================

revoke all
on function public.enqueue_notification(
    uuid,
    text,
    jsonb,
    text,
    text,
    uuid,
    timestamptz,
    integer
)
from public, anon, authenticated, service_role;


grant execute
on function public.enqueue_notification(
    uuid,
    text,
    jsonb,
    text,
    text,
    uuid,
    timestamptz,
    integer
)
to service_role;


-- ============================================================
-- CLAIM
-- ============================================================

revoke all
on function public.claim_notification_outbox(
    text,
    integer,
    integer
)
from public, anon, authenticated, service_role;


grant execute
on function public.claim_notification_outbox(
    text,
    integer,
    integer
)
to service_role;


-- ============================================================
-- MARK SENT
-- ============================================================

revoke all
on function public.mark_notification_sent(
    uuid,
    text,
    text
)
from public, anon, authenticated, service_role;


grant execute
on function public.mark_notification_sent(
    uuid,
    text,
    text
)
to service_role;


-- ============================================================
-- MARK FAILED / RETRY
-- ============================================================

revoke all
on function public.mark_notification_failed(
    uuid,
    text,
    text,
    integer,
    boolean
)
from public, anon, authenticated, service_role;


grant execute
on function public.mark_notification_failed(
    uuid,
    text,
    text,
    integer,
    boolean
)
to service_role;


-- ============================================================
-- 12. REASSERT CLIENT SECURITY BOUNDARY
-- ============================================================

revoke all
on public.notification_outbox
from anon, authenticated;


-- ============================================================
-- END MIGRATION 031
-- ============================================================
