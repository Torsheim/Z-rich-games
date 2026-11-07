-- Either participant can end their mutual friendship; unrelated rows are inaccessible.
create function public.remove_friend(friend_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  delete from public.friendships f
  where f.user_low = least(auth.uid(), friend_user_id)
    and f.user_high = greatest(auth.uid(), friend_user_id)
    and auth.uid() in (f.user_low, f.user_high);
end;
$$;
revoke all on function public.remove_friend(uuid) from public, anon;
grant execute on function public.remove_friend(uuid) to authenticated;
