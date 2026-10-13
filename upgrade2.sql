-- MedSupply upgrade 2: run in Supabase > SQL Editor (safe to run more than once)
alter table products add column if not exists nda_number text;
alter table products add column if not exists batch_no text;
alter table orders   add column if not exists payment_ref text;

-- let guests browse the marketplace
drop policy if exists "public read products" on products;
create policy "public read products" on products for select using (true);

-- customers submit a Mobile Money / bank reference; admin then marks the order Paid
create or replace function submit_payment(p_order bigint, p_ref text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  update orders set payment_ref = p_ref, payment_status = 'Payment Submitted'
   where id = p_order and user_id = auth.uid()
     and payment_status in ('Pending Payment','Pay on Delivery','On Credit');
  if not found then raise exception 'Order not found or already paid'; end if;
end $$;
grant execute on function submit_payment(bigint,text) to authenticated;
notify pgrst, 'reload schema';
