-- ============================================
-- DIJO Migration 013
-- Business Membership Management
-- ============================================


-- ============================================
-- SECURITY HELPERS
-- ============================================

create or replace function public.is_business_owner(
    p_business_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.businesses b
        where b.id = p_business_id
          and b.owner_id = auth.uid()
    )
    or exists (
        select 1
        from public.business_members bm
        where bm.business_id = p_business_id
          and bm.profile_id = auth.uid()
          and bm.role = 'owner'::public.business_member_role
          and bm.is_active = true
    );
$$;


create or replace function public.can_view_business_team(
    p_business_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.businesses b
        where b.id = p_business_id
          and b.owner_id = auth.uid()
    )
    or exists (
        select 1
        from public.business_members bm
        where bm.business_id = p_business_id
          and bm.profile_id = auth.uid()
          and bm.role in (
              'owner'::public.business_member_role,
              'manager'::public.business_member_role
          )
          and bm.is_active = true
    );
$$;


revoke all
on function public.is_business_owner(uuid)
from public;

grant execute
on function public.is_business_owner(uuid)
to authenticated;


revoke all
on function public.can_view_business_team(uuid)
from public;

grant execute
on function public.can_view_business_team(uuid)
to authenticated;


-- ============================================
-- OWNER MEMBERSHIP AUTO-CREATION
-- ============================================

create or replace function public.handle_new_business_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin

    if new.owner_id is not null then

        insert into public.business_members (
            business_id,
            profile_id,
            role,
            is_active
        )
        values (
            new.id,
            new.owner_id,
            'owner'::public.business_member_role,
            true
        )
        on conflict (business_id, profile_id)
        do update
        set
            role = 'owner'::public.business_member_role,
            is_active = true,
            updated_at = now();

    end if;

    return new;

end;
$$;


drop trigger if exists on_business_created_add_owner
on public.businesses;

create trigger on_business_created_add_owner
after insert on public.businesses
for each row
execute function public.handle_new_business_owner();


-- ============================================
-- BUSINESS TEAM VISIBILITY
-- ============================================

drop policy if exists "Owners and managers can view business team"
on public.business_members;

create policy "Owners and managers can view business team"
on public.business_members
for select
to authenticated
using (
    public.can_view_business_team(business_id)
);


-- ============================================
-- ADD BUSINESS MEMBER
-- ============================================

create or replace function public.add_business_member(
    p_business_id uuid,
    p_profile_id uuid,
    p_role public.business_member_role default 'staff'
)
returns public.business_members
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_member public.business_members;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    if not public.is_business_owner(p_business_id) then
        raise exception 'Only a business owner can add team members';
    end if;

    if p_role = 'owner'::public.business_member_role then
        raise exception 'Owner role cannot be assigned through this function';
    end if;

    if p_profile_id = auth.uid() then
        raise exception 'Business owner membership is managed separately';
    end if;

    insert into public.business_members (
        business_id,
        profile_id,
        role,
        is_active
    )
    values (
        p_business_id,
        p_profile_id,
        p_role,
        true
    )
    on conflict (business_id, profile_id)
    do update
    set
        role = excluded.role,
        is_active = true,
        updated_at = now()
    returning * into v_member;

    return v_member;

end;
$$;


revoke all
on function public.add_business_member(
    uuid,
    uuid,
    public.business_member_role
)
from public;

grant execute
on function public.add_business_member(
    uuid,
    uuid,
    public.business_member_role
)
to authenticated;


-- ============================================
-- CHANGE MEMBER ROLE
-- ============================================

create or replace function public.set_business_member_role(
    p_business_id uuid,
    p_profile_id uuid,
    p_role public.business_member_role
)
returns public.business_members
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_member public.business_members;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    if not public.is_business_owner(p_business_id) then
        raise exception 'Only a business owner can change team roles';
    end if;

    if p_role = 'owner'::public.business_member_role then
        raise exception 'Owner role cannot be assigned through this function';
    end if;

    if p_profile_id = auth.uid() then
        raise exception 'Business owner role cannot be changed here';
    end if;

    update public.business_members
    set
        role = p_role,
        updated_at = now()
    where business_id = p_business_id
      and profile_id = p_profile_id
      and role <> 'owner'::public.business_member_role
    returning * into v_member;

    if v_member.id is null then
        raise exception 'Business member not found or protected';
    end if;

    return v_member;

end;
$$;


revoke all
on function public.set_business_member_role(
    uuid,
    uuid,
    public.business_member_role
)
from public;

grant execute
on function public.set_business_member_role(
    uuid,
    uuid,
    public.business_member_role
)
to authenticated;


-- ============================================
-- ACTIVATE / DEACTIVATE MEMBER
-- ============================================

create or replace function public.set_business_member_active(
    p_business_id uuid,
    p_profile_id uuid,
    p_is_active boolean
)
returns public.business_members
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_member public.business_members;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    if not public.is_business_owner(p_business_id) then
        raise exception 'Only a business owner can manage team access';
    end if;

    if p_profile_id = auth.uid() then
        raise exception 'Business owner access cannot be changed here';
    end if;

    update public.business_members
    set
        is_active = p_is_active,
        updated_at = now()
    where business_id = p_business_id
      and profile_id = p_profile_id
      and role <> 'owner'::public.business_member_role
    returning * into v_member;

    if v_member.id is null then
        raise exception 'Business member not found or protected';
    end if;

    return v_member;

end;
$$;


revoke all
on function public.set_business_member_active(
    uuid,
    uuid,
    boolean
)
from public;

grant execute
on function public.set_business_member_active(
    uuid,
    uuid,
    boolean
)
to authenticated;
