-- W7-1: account deletion (ACC-10, CMP-2).
-- The client removes its media first, then calls this RPC. Deleting the
-- auth.users row cascades through profiles to every row the person owns.

set search_path = public, extensions;

create function public.delete_account()
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Sign in to delete your account' using errcode = 'insufficient_privilege';
  end if;
  delete from auth.users where id = v_me;
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated, service_role;
