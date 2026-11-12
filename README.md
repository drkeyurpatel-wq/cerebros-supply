# Cerebros Supply

Hospital ordering portal for Cerebros Neurosciences Pvt. Ltd.

- `index.html` — the whole front end (no build step).
- Backend — Supabase project "Vendor", schema `cerebros`. The only entry point is the function `public.cerebros_api(action, token, data)`.
  The SQL is stored in that project as migration `cerebros_supply_portal_v1`.
- Login — mobile number + PIN. Roles: staff, owner (hospital); desk, manager (Cerebros).
- Rules enforced in the database: credit limit, 15-day overdue block, hold flag, papers check, implant case details, batch and expiry on medicines.

Not built yet: Tally push, WhatsApp/SMS messages, e-invoice, online payment.
