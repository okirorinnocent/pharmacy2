-- MedSupply Uganda: run once in Supabase > SQL Editor
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  business_name text, phone text, address text,
  role text not null default 'customer' check (role in ('customer','admin')),
  credit_limit numeric not null default 0,
  created_at timestamptz default now());
create table products (
  id text primary key, name text not null, category text,
  price numeric not null check (price >= 0),
  stock int not null default 0 check (stock >= 0),
  reorder_level int default 10, batch text, expiry date);
create table orders (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users,
  recipient_name text, phone text, address text,
  items jsonb not null, total numeric not null,
  payment_method text, payment_status text default 'Pending Payment',
  status text default 'Processing', notes text,
  created_at timestamptz default now());

create function is_admin() returns boolean language sql security definer stable
set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin') $$;

create function handle_new_user() returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into profiles(id, business_name, phone)
  values (new.id, new.raw_user_meta_data->>'business_name', new.raw_user_meta_data->>'phone');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

alter table profiles enable row level security;
alter table products enable row level security;
alter table orders   enable row level security;

create policy "own or admin profile" on profiles for select using (id = auth.uid() or is_admin());
create policy "update own profile"   on profiles for update using (id = auth.uid());
revoke update on profiles from authenticated;
grant update (business_name, phone, address) on profiles to authenticated;  -- users can never change role/credit

create policy "read products"  on products for select to authenticated using (true);
create policy "admin products" on products for all using (is_admin()) with check (is_admin());

create policy "own or admin orders" on orders for select using (user_id = auth.uid() or is_admin());
create policy "admin update orders" on orders for update using (is_admin());
-- no insert policy on orders: customers can only order through place_order() below

-- Server-side checkout: prices and stock are checked in the database, never trusted from the browser
create function place_order(p_items jsonb, p_name text, p_phone text, p_address text, p_method text, p_notes text)
returns bigint language plpgsql security definer set search_path = public as $$
declare it jsonb; p products%rowtype; q int; total numeric := 0; lines jsonb := '[]'; oid bigint;
        credit numeric; pay text;
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Cart is empty'; end if;
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
    if total > coalesce(credit, 0) then raise exception 'Order exceeds your credit limit'; end if;
  end if;
  insert into orders(user_id, recipient_name, phone, address, items, total, payment_method, payment_status, notes)
  values (auth.uid(), p_name, p_phone, p_address, lines, total, p_method, pay, p_notes) returning id into oid;
  return oid;
end $$;
grant execute on function place_order to authenticated;

insert into products(id, name, category, price, stock, reorder_level, batch, expiry) values
 ('INV-001','Coartem 20/120mg (box)','Antimalarial',18000,120,30,'B2401','2027-08-01'),
 ('INV-002','Amoxicillin 500mg (box)','Antibiotic',22000,90,25,'B2402','2027-05-01'),
 ('INV-003','ORS Sachets (box)','Rehydration',9000,200,40,'B2403','2027-11-01'),
 ('INV-004','Paracetamol 500mg (box)','Analgesic',7000,300,50,'B2404','2028-01-01');

-- After you sign up in the app, make yourself admin (change the email):
-- update profiles set role='admin' where id = (select id from auth.users where email='you@example.com');
