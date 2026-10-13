-- MedSupply upgrade 3: buyers, sellers (admin-approved) and admin. Run AFTER upgrade2.sql. Safe to re-run.

-- 1) columns
alter table profiles add column if not exists account_type text not null default 'buyer';   -- 'buyer' | 'seller'
alter table profiles add column if not exists seller_status text;                           -- 'pending' | 'approved' | 'rejected'
alter table products add column if not exists seller_id uuid references auth.users(id);    -- null = MedSupply HQ stock
alter table products add column if not exists seller_name text;
alter table orders   add column if not exists seller_id uuid references auth.users(id);    -- one order per seller

-- 2) helpers
create or replace function is_admin() returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and role = 'admin') $$;

create or replace function is_approved_seller() returns boolean language sql security definer stable set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and account_type = 'seller' and seller_status = 'approved') $$;

-- 3) stop users editing their own role / credit limit / seller status
create or replace function protect_profile() returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('app.bypass', true), '') <> '1' and auth.uid() is not null and not is_admin() then
    new.role := old.role; new.credit_limit := old.credit_limit;
    new.seller_status := old.seller_status; new.account_type := old.account_type;
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_profile on profiles;
create trigger trg_protect_profile before update on profiles for each row execute function protect_profile();

-- 4) seller application + admin approval
create or replace function request_seller() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  perform set_config('app.bypass', '1', true);
  insert into profiles(id, account_type, seller_status) values (auth.uid(), 'seller', 'pending')
  on conflict (id) do update set account_type = 'seller', seller_status = coalesce(profiles.seller_status, 'pending')
  where profiles.role is distinct from 'admin';
end $$;
grant execute on function request_seller() to authenticated;

create or replace function admin_set_seller(p_user uuid, p_status text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_status not in ('approved','rejected','pending') then raise exception 'Bad status'; end if;
  perform set_config('app.bypass', '1', true);
  update profiles set seller_status = p_status where id = p_user and account_type = 'seller';
end $$;
grant execute on function admin_set_seller(uuid, text) to authenticated;

-- 5) sellers update status / confirm payment on THEIR orders only
create or replace function seller_update_order(p_order bigint, p_status text default null, p_paid boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_approved_seller() then raise exception 'Approved sellers only'; end if;
  if p_status is not null and p_status not in ('Processing','Dispatched','Delivered','Cancelled') then raise exception 'Bad status'; end if;
  update orders set status = coalesce(p_status, status), payment_status = case when p_paid then 'Paid' else payment_status end
   where id = p_order and seller_id = auth.uid();
  if not found then raise exception 'Order not found'; end if;
end $$;
grant execute on function seller_update_order(bigint, text, boolean) to authenticated;

-- 6) policies
drop policy if exists "admin read all profiles" on profiles;
create policy "admin read all profiles" on profiles for select using (is_admin());

drop policy if exists "sellers insert own products" on products;
create policy "sellers insert own products" on products for insert with check (seller_id = auth.uid() and is_approved_seller());
drop policy if exists "sellers update own products" on products;
create policy "sellers update own products" on products for update using (seller_id = auth.uid() and is_approved_seller()) with check (seller_id = auth.uid());
drop policy if exists "sellers delete own products" on products;
create policy "sellers delete own products" on products for delete using (seller_id = auth.uid() and is_approved_seller());
drop policy if exists "sellers read own orders" on orders;
create policy "sellers read own orders" on orders for select using (seller_id = auth.uid());

-- stamp the seller's business name on their products
create or replace function set_seller_name() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.seller_id is not null then select business_name into new.seller_name from profiles where id = new.seller_id; end if;
  return new;
end $$;
drop trigger if exists trg_seller_name on products;
create trigger trg_seller_name before insert on products for each row execute function set_seller_name();

-- 7) checkout: ONE ORDER PER SELLER (returns a JSON array of order ids)
drop function if exists place_order(jsonb, text, text, text, text, text);
create or replace function place_order(p_items jsonb, p_name text, p_phone text, p_address text, p_method text, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; p products%rowtype; q int; grand numeric := 0; groups jsonb := '{}'; ids jsonb := '[]'; k text;
        credit numeric; pay text; oid bigint;
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  if exists(select 1 from profiles where id = auth.uid() and account_type = 'seller') then raise exception 'Seller accounts cannot place orders'; end if;
  if p_method not in ('Mobile Money','Cash on Delivery','Trade Credit') then raise exception 'Choose a payment method'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Cart is empty'; end if;
  insert into profiles(id) values (auth.uid()) on conflict (id) do nothing;
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::int;
    if q <= 0 then raise exception 'Invalid quantity'; end if;
    select * into p from products where id = it->>'id' for update;
    if not found then raise exception 'Unknown product'; end if;
    if p.stock < q then raise exception 'Not enough stock for %', p.name; end if;
    update products set stock = stock - q where id = p.id;
    grand := grand + q * p.price;
    k := coalesce(p.seller_id::text, 'hq');
    groups := jsonb_set(groups, array[k], coalesce(groups->k, '[]'::jsonb) || jsonb_build_object('id', p.id, 'name', p.name, 'qty', q, 'price', p.price), true);
  end loop;
  pay := case p_method when 'Trade Credit' then 'On Credit' when 'Cash on Delivery' then 'Pay on Delivery' else 'Pending Payment' end;
  if p_method = 'Trade Credit' then
    select credit_limit into credit from profiles where id = auth.uid();
    if grand > coalesce(credit, 0) then raise exception 'Order exceeds your credit limit (limit: %)', coalesce(credit, 0); end if;
  end if;
  for k in select jsonb_object_keys(groups) loop
    insert into orders(user_id, seller_id, recipient_name, phone, address, items, total, payment_method, payment_status, notes)
    values (auth.uid(), case when k = 'hq' then null else k::uuid end, p_name, p_phone, p_address, groups->k,
            (select sum((x->>'qty')::int * (x->>'price')::numeric) from jsonb_array_elements(groups->k) x), p_method, pay, p_notes)
    returning id into oid;
    ids := ids || to_jsonb(oid);
  end loop;
  return ids;
end $$;
grant execute on function place_order(jsonb, text, text, text, text, text) to authenticated;
notify pgrst, 'reload schema';
