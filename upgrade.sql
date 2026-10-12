-- MedSupply upgrade: run in Supabase > SQL Editor (safe to run more than once)
alter table products add column if not exists image_url text;
alter table products add column if not exists old_price numeric;

-- make sure every existing user has a profile row
insert into profiles(id, business_name)
select id, split_part(email,'@',1) from auth.users on conflict (id) do nothing;

create or replace function place_order(p_items jsonb, p_name text, p_phone text, p_address text, p_method text, p_notes text)
returns bigint language plpgsql security definer set search_path = public as $$
declare it jsonb; p products%rowtype; q int; total numeric := 0; lines jsonb := '[]'; oid bigint;
        credit numeric; pay text;
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
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
    total := total + q * p.price;
    lines := lines || jsonb_build_object('id', p.id, 'name', p.name, 'qty', q, 'price', p.price);
  end loop;
  pay := case p_method when 'Trade Credit' then 'On Credit' when 'Cash on Delivery' then 'Pay on Delivery' else 'Pending Payment' end;
  if p_method = 'Trade Credit' then
    select credit_limit into credit from profiles where id = auth.uid();
    if total > coalesce(credit, 0) then raise exception 'Order exceeds your credit limit (limit: %)', coalesce(credit,0); end if;
  end if;
  insert into orders(user_id, recipient_name, phone, address, items, total, payment_method, payment_status, notes)
  values (auth.uid(), p_name, p_phone, p_address, lines, total, p_method, pay, p_notes) returning id into oid;
  return oid;
end $$;
grant execute on function place_order(jsonb,text,text,text,text,text) to authenticated;
notify pgrst, 'reload schema';   -- refresh the API cache so the function is found

-- optional: show a discount badge on one product
-- update products set old_price = 25000 where id = 'INV-002';
