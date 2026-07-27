-- Die register. Run in Supabase SQL Editor.
insert into dies (code, customer, part) values
  ('2601U','Maruti Tier-1','Front Door Outer OP20 - Upper'),
  ('2601L','Maruti Tier-1','Front Door Outer OP20 - Lower'),
  ('2602','Maruti Tier-1','Front Door Outer OP30'),
  ('2603','Hero Moto','Fuel Tank Draw OP10'),
  ('2604','Ashok Leyland','Cross Member Trim')
on conflict (code) do nothing;

-- OPTIONAL: allow the app's Setup tab to add dies.
-- Skip this if you would rather add dies only in the Supabase table editor.
-- create policy insert_dies on dies for insert with check (true);
