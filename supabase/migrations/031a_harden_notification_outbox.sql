-- ============================================================
-- DIJO
-- Migration 031a: Harden Notification Outbox
-- ============================================================
--
-- PURPOSE
-- -------
-- Harden the already-deployed Migration 031 notification
-- outbox without recreating its infrastructure.
--
-- FIXES
-- -----
-- 1. Delivery-offer closure cancels only PENDING notifications.
--    PROCESSING jobs remain owned by their worker.
--
-- 2. Jobs for inactive recipients or recipients without a
--    usable WhatsApp number are failed before claiming.
--
-- 3. Delivery-offer notifications can only be claimed while
--    the underlying offer is still pending and unexpired.
--
-- 4. Recovered worker jobs are revalidated before they can
--    be claimed again.
--
-- ============================================================


-- ============================================================
-- 1. HARDEN DELIVERY-OFFER NOTIFICATION CANCELLATION
-- ============================================================
--
-- IMPORTANT:
-- Only PENDING notification jobs are cancelled.
--
-- A PROCESSING job has already been claimed by a worker.
-- Cancelling it underneath that worker could result in Meta
-- successfully sending the message while the worker can no
-- longer acknowledge the job.
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


-- ============================================================
-- 2. HARDEN WORKER CLAIM RPC
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
    -- FAIL JOBS WITH NO DELIVERABLE WHATSAPP RECIPIENT
    --
    -- This runs after lease recovery so recovered jobs are
    -- revalidated before they can be claimed again.
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
    -- CANCEL DELIVERY-OFFER NOTIFICATIONS WHOSE SOURCE OFFER
    -- IS NO LONGER LIVE
    --
    -- This protects against:
    --
    --   accepted offers
    --   rejected offers
    --   cancelled offers
    --   expired-status offers
    --   pending offers whose expires_at has already passed
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
    --
    -- FOR UPDATE SKIP LOCKED allows multiple workers to run
    -- concurrently without claiming the same notification.
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
          -- DELIVERY-OFFER SOURCE VALIDATION
          --
          -- Delivery-offer notifications can only be claimed
          -- while their source offer is still pending and has
          -- not expired.
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
-- 3. REASSERT CLAIM RPC PRIVILEGES
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
-- 4. REASSERT OUTBOX SECURITY BOUNDARY
-- ============================================================

revoke all
on public.notification_outbox
from anon, authenticated;


-- ============================================================
-- END MIGRATION 031a
-- ============================================================
