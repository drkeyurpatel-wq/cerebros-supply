-- Cerebros supply portal v4: approval-only access, documents, credit period first, no controlled drugs

-- 1. Controlled drugs (NDPS / Schedule X / sedatives) are never sold on the portal
create table if not exists cerebros.blocked_molecules(word text primary key);
alter table cerebros.blocked_molecules enable row level security;
insert into cerebros.blocked_molecules(word) values
 ('midazolam'),('diazepam'),('lorazepam'),('alprazolam'),('clonazepam'),('clobazam'),('nitrazepam'),('chlordiazepoxide'),('flurazepam'),
 ('phenobarb'),('pentobarb'),('thiopent'),('barbit'),('ketamine'),('propofol'),('dexmedetomidine'),
 ('morphine'),('fentanyl'),('sufentanil'),('remifentanil'),('alfentanil'),('pethidine'),('meperidine'),('tramadol'),('tapentadol'),
 ('buprenorphine'),('butorphanol'),('nalbuphine'),('pentazocine'),('codeine'),('methadone'),('oxycodone'),('hydromorphone'),('hydrocodone'),
 ('dextropropoxyphene'),('zolpidem'),('zopiclone'),('meprobamate'),('methylphenidate'),('amphetamine'),('modafinil'),('cocaine')
on conflict do nothing;

create or replace function cerebros.controlled(t text) returns text language sql stable
set search_path to 'cerebros','pg_temp' as $$
  select word from cerebros.blocked_molecules where lower(coalesce(t,'')) like '%'||word||'%' limit 1
$$;

delete from cerebros.items i where cerebros.controlled(i.name||' '||coalesce(i.composition,'')) is not null
  and not exists(select 1 from cerebros.order_lines l where l.item_id=i.id);
update cerebros.items i set active=false where cerebros.controlled(i.name||' '||coalesce(i.composition,'')) is not null;

-- 2. Approval status for hospitals and logins
alter table cerebros.hospitals
  add column if not exists status text not null default 'approved',
  add column if not exists city text,
  add column if not exists contact_name text,
  add column if not exists contact_mobile text,
  add column if not exists grace_days int not null default 15,
  add column if not exists applied_at timestamptz,
  add column if not exists decided_at timestamptz,
  add column if not exists decided_by bigint,
  add column if not exists decision_note text;
alter table cerebros.hospitals drop constraint if exists hospitals_status_chk;
alter table cerebros.hospitals add constraint hospitals_status_chk check (status in ('applied','approved','rejected','suspended'));
alter table cerebros.hospitals alter column credit_limit drop not null;
alter table cerebros.hospitals alter column credit_limit drop default;
update cerebros.hospitals set credit_limit = null where credit_limit = 0;

alter table cerebros.users
  add column if not exists status text not null default 'approved',
  add column if not exists requested_by bigint,
  add column if not exists decided_by bigint,
  add column if not exists decided_at timestamptz;
alter table cerebros.users drop constraint if exists users_status_chk;
alter table cerebros.users add constraint users_status_chk check (status in ('pending','approved','rejected'));

-- 3. Documents
create table if not exists cerebros.doc_types(code text primary key, label text not null, required boolean not null, has_expiry boolean not null, has_no boolean not null, sort int not null, hint text);
alter table cerebros.doc_types enable row level security;
insert into cerebros.doc_types values
 ('dl20','Drug licence — Form 20 / 20B',true,true,true,1,'Licence to buy and stock Schedule H and other drugs'),
 ('dl21','Drug licence — Form 21 / 21B',true,true,true,2,'Licence for Schedule C and C1 drugs'),
 ('gst','GST registration certificate',true,false,true,3,'GSTIN must match the billing name'),
 ('pan','PAN card of the hospital or firm',true,false,true,4,null),
 ('reg','Hospital registration',true,true,true,5,'Clinical Establishment or Nursing Home registration'),
 ('chq','Cancelled cheque',true,false,false,6,'Of the account the hospital will pay from'),
 ('auth','Letter authorising staff to order',false,false,false,7,'On letterhead, signed by the owner or director'),
 ('fire','Fire NOC',false,true,true,8,null),
 ('bmw','Bio-medical waste authorisation',false,true,true,9,null),
 ('other','Other document',false,false,false,10,null)
on conflict (code) do update set label=excluded.label, required=excluded.required, has_expiry=excluded.has_expiry, has_no=excluded.has_no, sort=excluded.sort, hint=excluded.hint;

create table if not exists cerebros.documents(
  id bigserial primary key,
  hospital_id bigint not null references cerebros.hospitals(id),
  doc_type text not null references cerebros.doc_types(code),
  doc_no text, valid_till date,
  file_name text not null, mime text not null, size int not null, data bytea not null,
  status text not null default 'submitted' check (status in ('submitted','verified','rejected')),
  note text,
  uploaded_by bigint references cerebros.users(id), uploaded_at timestamptz not null default now(),
  checked_by bigint references cerebros.users(id), checked_at timestamptz);
alter table cerebros.documents enable row level security;
create index if not exists documents_h on cerebros.documents(hospital_id, doc_type);

create or replace function cerebros.docs_state(p_h bigint) returns jsonb language sql stable
set search_path to 'cerebros','pg_temp' as $$
  with t as (
    select dt.code, dt.label, dt.required,
      exists(select 1 from cerebros.documents x where x.hospital_id=p_h and x.doc_type=dt.code and x.status='verified' and (x.valid_till is null or x.valid_till >= cerebros.today())) ok,
      exists(select 1 from cerebros.documents x where x.hospital_id=p_h and x.doc_type=dt.code and x.status='submitted') waiting,
      (select max(x.valid_till) from cerebros.documents x where x.hospital_id=p_h and x.doc_type=dt.code and x.status='verified') till
    from cerebros.doc_types dt)
  select jsonb_build_object(
    'ok', not exists(select 1 from t where required and not ok),
    'missing', coalesce((select jsonb_agg(label order by label) from t where required and not ok and not waiting),'[]'),
    'waiting', coalesce((select jsonb_agg(label order by label) from t where waiting),'[]'),
    'expiring', coalesce((select jsonb_agg(jsonb_build_object('label',label,'till',till)) from t where ok and till is not null and till < cerebros.today()+30),'[]'))
$$;

-- 4. Who may use the portal
create or replace function cerebros.access_of(u cerebros.users) returns text language sql stable
set search_path to 'cerebros','pg_temp' as $$
  select case
    when u.id is null or not u.active or u.status='rejected' then null
    when u.role in ('desk','manager') then case when u.status='approved' then 'full' end
    else (select case when h.active and h.status='approved' and u.status='approved' then 'full'
                      when h.status='applied' and u.role='owner' then 'applicant' end
          from cerebros.hospitals h where h.id=u.hospital_id) end
$$;

create or replace function cerebros.auth_any(p_token text) returns cerebros.users language plpgsql
set search_path to 'cerebros','extensions','pg_temp' as $$
declare u cerebros.users;
begin
  select usr.* into u from cerebros.sessions s join cerebros.users usr on usr.id=s.user_id
   where s.token_hash = encode(digest(coalesce(p_token,''),'sha256'),'hex') and s.expires_at > now();
  if not found or cerebros.access_of(u) is null then raise exception 'Please log in again'; end if;
  return u;
end $$;

create or replace function cerebros.auth(p_token text) returns cerebros.users language plpgsql
set search_path to 'cerebros','extensions','pg_temp' as $$
declare u cerebros.users;
begin
  u := cerebros.auth_any(p_token);
  if cerebros.access_of(u) <> 'full' then raise exception 'Your hospital is waiting for approval by Cerebros'; end if;
  return u;
end $$;

create or replace function cerebros.new_session(p_user bigint) returns jsonb language plpgsql
set search_path to 'cerebros','extensions','pg_temp' as $$
declare t text := encode(gen_random_bytes(24),'hex'); u cerebros.users; h cerebros.hospitals;
begin
  delete from cerebros.sessions where expires_at < now();
  insert into cerebros.sessions values (encode(digest(t,'sha256'),'hex'), p_user, now() + interval '7 days');
  select * into u from cerebros.users where id=p_user;
  select * into h from cerebros.hospitals where id=u.hospital_id;
  return jsonb_build_object('token',t,'user',jsonb_build_object('id',u.id,'name',u.name,'role',u.role,'hospital_id',u.hospital_id,'hospital',h.name,
    'access',cerebros.access_of(u),'hospital_status',h.status));
end $$;

create or replace function cerebros.hid_for(u cerebros.users, d jsonb) returns bigint language plpgsql stable
set search_path to 'cerebros','pg_temp' as $$
declare v bigint;
begin
  if u.role in ('staff','owner') then return u.hospital_id; end if;
  v := nullif(d->>'hospital_id','')::bigint;
  if v is null or not exists(select 1 from cerebros.hospitals where id=v and status='approved' and active) then raise exception 'Choose an approved hospital to order for'; end if;
  return v;
end $$;

-- 5. Credit: the credit period is the rule; a limit is optional
create or replace function cerebros.credit(p_h bigint, p_extra numeric default 0) returns jsonb language plpgsql stable
set search_path to 'cerebros','pg_temp' as $$
declare h cerebros.hospitals; v_unpaid numeric; v_open numeric; v_od int; v_used numeric; ds jsonb;
  v_state text := 'ok'; v_reason text := ''; v_why text := ''; d date := cerebros.today();
  v_next date; v_next_amt numeric; v_due7 numeric; v_late numeric;
begin
  select * into h from cerebros.hospitals where id = p_h;
  if not found then raise exception 'Hospital not found'; end if;
  select coalesce(sum(total-paid),0), coalesce(max(d - due_date) filter (where total-paid > 0.5),0),
         min(due_date) filter (where total-paid > 0.5 and due_date >= d),
         coalesce(sum(total-paid) filter (where total-paid>0.5 and due_date between d and d+7),0),
         coalesce(sum(total-paid) filter (where total-paid>0.5 and due_date < d),0)
    into v_unpaid, v_od, v_next, v_due7, v_late from cerebros.bills where hospital_id = p_h;
  select coalesce(sum(total-paid),0) into v_next_amt from cerebros.bills where hospital_id=p_h and due_date=v_next and total-paid>0.5;
  v_od := greatest(v_od,0);
  select coalesce(sum(round(l.qty*l.rate*(1+l.gst_rate/100),2)),0) into v_open
    from cerebros.order_lines l join cerebros.orders o on o.id=l.order_id where o.hospital_id=p_h and o.status in (0,1,2);
  v_used := v_unpaid + v_open + p_extra;
  ds := cerebros.docs_state(p_h);
  if not h.active or h.status in ('rejected','suspended') then v_state:='block'; v_reason:='inactive'; v_why:='Access for this hospital is paused. Call the Cerebros desk.';
  elsif h.status = 'applied' then v_state:='block'; v_reason:='inactive'; v_why:='This hospital is waiting for approval.';
  elsif h.on_hold then v_state:='block'; v_reason:='hold'; v_why:='Cerebros has put this account on hold. Call the Cerebros desk.';
  elsif not (ds->>'ok')::boolean then v_state:='block'; v_reason:='docs';
    v_why:='Documents missing, expired or not yet checked: '||(select string_agg(x,', ') from jsonb_array_elements_text(ds->'missing') x)||
      case when jsonb_array_length(ds->'waiting')>0 then case when jsonb_array_length(ds->'missing')>0 then '. Being checked: ' else 'Being checked by Cerebros: ' end||(select string_agg(x,', ') from jsonb_array_elements_text(ds->'waiting') x) else '' end||'.';
  elsif v_od > h.grace_days then v_state:='block'; v_reason:='overdue'; v_why:='A bill is '||v_od||' days past its pay-by date. Pay it to order again.';
  elsif h.credit_limit is not null and v_used > h.credit_limit then v_state:='block'; v_reason:='limit';
    v_why := 'This order is more than the account can carry right now. Pay a bill or reduce the order.';
  elsif v_od > 0 then v_state:='warn'; v_why:='A bill is '||v_od||' days past its pay-by date. Ordering stops after '||h.grace_days||' days.';
  elsif jsonb_array_length(ds->'expiring')>0 then v_state:='warn'; v_why:='A licence expires soon. Upload the renewed copy under Documents.';
  end if;
  return jsonb_build_object('terms',h.terms_days,'grace',h.grace_days,'limit',h.credit_limit,'unpaid',v_unpaid,'open_orders',v_open,'used',v_used,
    'left',case when h.credit_limit is null then null else greatest(h.credit_limit-v_used,0) end,
    'overdue_days',v_od,'late_amount',v_late,'next_due',v_next,'next_due_amount',v_next_amt,'due_7',v_due7,
    'docs',ds,'state',v_state,'reason',v_reason,'why',v_why);
end $$;

-- 6. API
create or replace function cerebros.api_v2(p_action text, p_token text, d jsonb) returns jsonb language plpgsql
set search_path to 'cerebros','extensions','pg_temp' as $$
declare u cerebros.users; x cerebros.users; h cerebros.hospitals; r jsonb; o cerebros.orders; it cerebros.items; ln jsonb; c jsonb; doc cerebros.documents; dt cerebros.doc_types;
  v_img text; v_hid bigint; v_val numeric := 0; v_acc text; v_mob text; v_pin text; v_id bigint; v_bytes bytea; v_mime text; v_bad text; v_old text; v_till date;
  is_c boolean; is_m boolean;
begin
  if p_action in ('status','setup') then return cerebros.api(p_action, p_token, d); end if;

  if p_action = 'login' then
    v_mob := right(regexp_replace(coalesce(d->>'mobile',''),'\D','','g'),10); v_pin := coalesce(d->>'pin','');
    select * into u from cerebros.users where mobile = v_mob and active;
    if not found then perform pg_sleep(0.3); return jsonb_build_object('error','Wrong mobile number or PIN'); end if;
    if u.locked_until is not null and u.locked_until > now() then return jsonb_build_object('error','Too many wrong tries. Try again after 15 minutes.'); end if;
    if u.pin_hash <> crypt(v_pin, u.pin_hash) then
      update cerebros.users set failed = case when failed>=4 then 0 else failed+1 end, locked_until = case when failed>=4 then now()+interval '15 minutes' else locked_until end where id=u.id;
      return jsonb_build_object('error','Wrong mobile number or PIN');
    end if;
    update cerebros.users set failed=0, locked_until=null where id=u.id;
    select * into h from cerebros.hospitals where id=u.hospital_id;
    if cerebros.access_of(u) is null then
      if u.status='rejected' or h.status='rejected' then return jsonb_build_object('error','Your access request was not approved. Call the Cerebros desk.');
      elsif h.status='suspended' or not h.active then return jsonb_build_object('error','Access for your hospital is paused. Call the Cerebros desk.');
      else return jsonb_build_object('error','Your login is waiting for approval by Cerebros. You can log in once it is approved.'); end if;
    end if;
    insert into cerebros.audit(user_id,action,detail) values (u.id,'login','{}');
    return cerebros.new_session(u.id);
  end if;

  if p_action = 'apply' then
    if (select count(*) from cerebros.hospitals where applied_at > now()-interval '1 hour') >= 20 then raise exception 'Too many applications right now. Try again in an hour.'; end if;
    v_mob := right(regexp_replace(coalesce(d->>'mobile',''),'\D','','g'),10);
    if length(trim(coalesce(d->>'hospital','')))<3 then raise exception 'Enter the hospital name'; end if;
    if length(trim(coalesce(d->>'city','')))<2 then raise exception 'Enter the city'; end if;
    if length(trim(coalesce(d->>'name','')))<2 then raise exception 'Enter your name'; end if;
    if v_mob !~ '^[6-9]\d{9}$' then raise exception 'Enter a 10-digit mobile number'; end if;
    if coalesce(d->>'pin','') !~ '^\d{4,6}$' then raise exception 'PIN must be 4 to 6 digits'; end if;
    if coalesce(d->>'gstin','')<>'' and upper(d->>'gstin') !~ '^[0-9]{2}[A-Z0-9]{13}$' then raise exception 'GSTIN must be 15 characters'; end if;
    if exists(select 1 from cerebros.users where mobile=v_mob) then raise exception 'This mobile number already has a login. Log in instead.'; end if;
    insert into cerebros.hospitals(name,city,address,gstin,beds,credit_limit,terms_days,on_hold,is_group,active,status,contact_name,contact_mobile,applied_at)
      values (trim(d->>'hospital'), trim(d->>'city'), nullif(trim(coalesce(d->>'address','')),''), nullif(upper(trim(coalesce(d->>'gstin',''))),''), nullif(d->>'beds','')::int,
        null, 30, false, false, true, 'applied', trim(d->>'name'), v_mob, now()) returning id into v_hid;
    insert into cerebros.users(name,mobile,pin_hash,role,hospital_id,status) values (trim(d->>'name'), v_mob, crypt(d->>'pin',gen_salt('bf',8)), 'owner', v_hid, 'pending') returning id into v_id;
    insert into cerebros.audit(user_id,action,detail) values (v_id,'apply',jsonb_build_object('hospital',v_hid));
    return cerebros.new_session(v_id);
  end if;

  u := cerebros.auth_any(p_token);
  v_acc := cerebros.access_of(u);
  is_c := u.role in ('desk','manager'); is_m := u.role='manager';
  if v_acc = 'applicant' and p_action not in ('me','logout','change_pin','application','doc_types','doc_list','doc_upload','doc_get','doc_delete') then
    raise exception 'Your hospital is waiting for approval by Cerebros';
  end if;

  if p_action = 'me' then
    select * into h from cerebros.hospitals where id=u.hospital_id;
    return jsonb_build_object('id',u.id,'name',u.name,'role',u.role,'hospital_id',u.hospital_id,'hospital',h.name,'access',v_acc,'hospital_status',h.status);
  elsif p_action = 'logout' then
    delete from cerebros.sessions where token_hash = encode(digest(p_token,'sha256'),'hex'); return '{"ok":true}';
  elsif p_action = 'change_pin' then
    if u.pin_hash <> crypt(coalesce(d->>'old',''), u.pin_hash) then raise exception 'Old PIN is wrong'; end if;
    if coalesce(d->>'new','') !~ '^\d{4,6}$' then raise exception 'PIN must be 4 to 6 digits'; end if;
    update cerebros.users set pin_hash = crypt(d->>'new', gen_salt('bf',8)) where id=u.id;
    delete from cerebros.sessions where user_id=u.id and token_hash <> encode(digest(p_token,'sha256'),'hex');
    return '{"ok":true}';

  elsif p_action = 'application' then
    v_hid := cerebros.hid_for_docs(u, d);
    select * into h from cerebros.hospitals where id=v_hid;
    return jsonb_build_object('hospital',jsonb_build_object('id',h.id,'name',h.name,'city',h.city,'status',h.status,'applied_at',h.applied_at,'note',h.decision_note,'terms',h.terms_days),'docs',cerebros.docs_state(v_hid));
  elsif p_action = 'doc_types' then
    return (select jsonb_agg(to_jsonb(t) order by sort) from cerebros.doc_types t);
  elsif p_action = 'doc_list' then
    v_hid := cerebros.hid_for_docs(u, d);
    return jsonb_build_object('state',cerebros.docs_state(v_hid),'docs',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'type',x.doc_type,'label',t.label,'doc_no',x.doc_no,'valid_till',x.valid_till,
      'file_name',x.file_name,'size',x.size,'mime',x.mime,'status',x.status,'note',x.note,'uploaded_at',x.uploaded_at,'by',uu.name,'expired',x.valid_till < cerebros.today()) order by t.sort, x.id desc),'[]'::jsonb)
      from cerebros.documents x join cerebros.doc_types t on t.code=x.doc_type left join cerebros.users uu on uu.id=x.uploaded_by where x.hospital_id=v_hid));
  elsif p_action = 'doc_upload' then
    if u.role = 'staff' then raise exception 'Only the hospital owner can upload documents'; end if;
    v_hid := cerebros.hid_for_docs(u, d);
    select * into dt from cerebros.doc_types where code=d->>'type';
    if not found then raise exception 'Choose the document type'; end if;
    begin v_bytes := decode(coalesce(d->>'data',''),'base64'); exception when others then raise exception 'The file could not be read'; end;
    if length(v_bytes) = 0 then raise exception 'The file is empty'; end if;
    if length(v_bytes) > 5*1024*1024 then raise exception 'The file is larger than 5 MB. Scan it at a lower size.'; end if;
    v_mime := case when substring(v_bytes from 1 for 4) = '\x25504446'::bytea then 'application/pdf'
                   when substring(v_bytes from 1 for 3) = '\xffd8ff'::bytea then 'image/jpeg'
                   when substring(v_bytes from 1 for 8) = '\x89504e470d0a1a0a'::bytea then 'image/png' end;
    if v_mime is null then raise exception 'Upload a PDF, JPG or PNG file'; end if;
    v_till := nullif(d->>'valid_till','')::date;
    if dt.has_expiry and v_till is null then raise exception 'Enter the valid-till date of the %', lower(dt.label); end if;
    if v_till is not null and v_till < cerebros.today() then raise exception 'This document has already expired. Upload the renewed one.'; end if;
    if dt.has_no and length(trim(coalesce(d->>'doc_no','')))<3 then raise exception 'Enter the number printed on the %', lower(dt.label); end if;
    insert into cerebros.documents(hospital_id,doc_type,doc_no,valid_till,file_name,mime,size,data,uploaded_by)
      values (v_hid, dt.code, left(nullif(trim(coalesce(d->>'doc_no','')),''),60), v_till, left(regexp_replace(coalesce(d->>'file_name','document'),'[^A-Za-z0-9._ -]','_','g'),120), v_mime, length(v_bytes), v_bytes, u.id)
      returning id into v_id;
    insert into cerebros.audit(user_id,action,detail) values (u.id,'doc_upload',jsonb_build_object('hospital',v_hid,'doc',v_id,'type',dt.code));
    return jsonb_build_object('id',v_id);
  elsif p_action in ('doc_get','doc_delete') then
    select * into doc from cerebros.documents where id=(d->>'id')::bigint;
    if not found or (not is_c and doc.hospital_id <> u.hospital_id) then raise exception 'Document not found'; end if;
    if p_action = 'doc_get' then
      return jsonb_build_object('file_name',doc.file_name,'mime',doc.mime,'data',translate(encode(doc.data,'base64'),E'\n',''));
    end if;
    if u.role='staff' then raise exception 'Only the hospital owner can remove documents'; end if;
    if doc.status = 'verified' and not is_m then raise exception 'A checked document cannot be removed. Upload the new one instead.'; end if;
    delete from cerebros.documents where id=doc.id;
    insert into cerebros.audit(user_id,action,detail) values (u.id,'doc_delete',jsonb_build_object('hospital',doc.hospital_id,'doc',doc.id));
    return '{"ok":true}';

  elsif p_action = 'catalog' then
    return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'category',category,'subcategory',coalesce(subcategory,'Other'),'brand',brand,'manufacturer',manufacturer,
      'composition',composition,'image_url',image_url,'cold_chain',cold_chain,'in_stock',in_stock,'min_qty',min_qty,'pack',pack,'mrp',mrp,'rate',rate,'gst_rate',gst_rate,'hsn',hsn,'is_sample',is_sample)
      order by category desc, subcategory, name),'[]'::jsonb) from cerebros.items where active and cerebros.controlled(name||' '||coalesce(composition,'')) is null);

  elsif p_action in ('home','credit','my_orders','my_bills') then
    v_hid := cerebros.hid_for(u, d);
    if p_action = 'credit' then return cerebros.credit(v_hid,0); end if;
    if p_action = 'my_orders' then
      return (select coalesce(jsonb_agg(cerebros.order_json(q.id) order by q.id desc),'[]'::jsonb) from (select id from cerebros.orders where hospital_id=v_hid order by id desc limit 100) q);
    end if;
    if p_action = 'my_bills' then
      return jsonb_build_object('credit',cerebros.credit(v_hid,0),'bills',(select coalesce(jsonb_agg(cerebros.bill_json(b) order by b.bill_date desc, b.id desc),'[]'::jsonb) from cerebros.bills b where hospital_id=v_hid));
    end if;
    return jsonb_build_object('credit', cerebros.credit(v_hid,0),
      'hospital', (select jsonb_build_object('id',id,'name',name,'address',address) from cerebros.hospitals where id=v_hid),
      'open_orders', (select count(*) from cerebros.orders where hospital_id=v_hid and status in (0,1,2)),
      'reorder', (select coalesce(jsonb_agg(item_id order by n desc),'[]'::jsonb) from (select l.item_id, count(*) n from cerebros.order_lines l join cerebros.orders o2 on o2.id=l.order_id join cerebros.items i on i.id=l.item_id
          where o2.hospital_id=v_hid and o2.status<>9 and i.active group by l.item_id order by n desc limit 12) q),
      'trending', (select coalesce(jsonb_agg(item_id order by v desc),'[]'::jsonb) from (select l.item_id, sum(l.qty*l.rate) v from cerebros.order_lines l join cerebros.orders o2 on o2.id=l.order_id join cerebros.items i on i.id=l.item_id
          where o2.status<>9 and i.active and o2.created_at > now()-interval '30 days' group by l.item_id order by v desc limit 12) q));

  elsif p_action = 'place_order' then
    v_hid := cerebros.hid_for(u, d);
    if jsonb_typeof(d->'lines') is distinct from 'array' or jsonb_array_length(d->'lines') = 0 then raise exception 'Cart is empty'; end if;
    if jsonb_array_length(d->'lines') > 200 then raise exception 'Too many items in one order'; end if;
    for ln in select * from jsonb_array_elements(d->'lines') loop
      select * into it from cerebros.items where id = (ln->>'item_id')::bigint and active;
      if not found or cerebros.controlled(it.name||' '||coalesce(it.composition,'')) is not null then raise exception 'An item in the cart is no longer available. Remove it and try again.'; end if;
      if not it.in_stock then raise exception '% is out of stock. Remove it and try again.', it.name; end if;
      if coalesce((ln->>'qty')::numeric,0) < it.min_qty or (ln->>'qty')::numeric > 100000 then raise exception 'Check the quantity of % (minimum %)', it.name, it.min_qty; end if;
      if it.category = 'Implants and stents' and (coalesce(ln->>'case_date','')='' or length(trim(coalesce(ln->>'surgeon','')))<2) then raise exception 'Fill surgery date and surgeon for %', it.name; end if;
      v_val := v_val + round((ln->>'qty')::numeric * it.rate * (1+it.gst_rate/100),2);
    end loop;
    c := cerebros.credit(v_hid, v_val);
    if c->>'state' = 'block' then raise exception '%', c->>'why'; end if;
    insert into cerebros.orders(order_no,hospital_id,user_id,po_no,notes,delivery_slot,deliver_to)
      values ('ORD-'||nextval('cerebros.order_seq'), v_hid, u.id, nullif(trim(coalesce(d->>'po_no','')),''), nullif(trim(coalesce(d->>'notes','')),''),
        nullif(trim(coalesce(d->>'delivery_slot','')),''), nullif(trim(coalesce(d->>'deliver_to','')),'')) returning * into o;
    insert into cerebros.order_lines(order_id,item_id,qty,rate,gst_rate,case_date,surgeon)
      select o.id, i.id, (q->>'qty')::numeric, i.rate, i.gst_rate, nullif(q->>'case_date','')::date, nullif(trim(q->>'surgeon'),'')
      from jsonb_array_elements(d->'lines') q join cerebros.items i on i.id=(q->>'item_id')::bigint;
    if is_c then insert into cerebros.audit(user_id,action,detail) values (u.id,'order_on_behalf',jsonb_build_object('order',o.order_no,'hospital',v_hid)); end if;
    return jsonb_build_object('order_no',o.order_no,'order_id',o.id,'value',v_val);

  elsif p_action = 'order_detail' then
    select * into o from cerebros.orders where id=(d->>'order_id')::bigint;
    if not found or (not is_c and o.hospital_id<>u.hospital_id) then raise exception 'Order not found'; end if;
    return cerebros.order_json(o.id) || jsonb_build_object('credit', cerebros.credit(o.hospital_id,0));

  elsif p_action = 'users' then
    if not (is_c or u.role='owner') then raise exception 'Not allowed'; end if;
    return (select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'mobile',q.mobile,'role',q.role,'hospital_id',q.hospital_id,'hospital',hh.name,'active',q.active,'status',q.status,
      'requested_by',rb.name,'created_at',q.created_at) order by q.status desc, q.role, q.name),'[]'::jsonb)
      from cerebros.users q left join cerebros.hospitals hh on hh.id=q.hospital_id left join cerebros.users rb on rb.id=q.requested_by
      where (is_m or (u.role='desk' and q.role in ('staff','owner'))) or q.hospital_id=u.hospital_id);
  elsif p_action = 'user_save' then
    if not (is_m or u.role='owner') then raise exception 'Not allowed'; end if;
    v_id := nullif(d->>'id','')::bigint;
    if v_id is not null then select mobile into v_old from cerebros.users where id=v_id; end if;
    r := cerebros.api('user_save', p_token, d);
    if u.role = 'owner' and (v_id is null or v_old is distinct from d->>'mobile') then
      update cerebros.users set status='pending', requested_by=u.id, decided_by=null, decided_at=null where id=(r->>'id')::bigint;
      delete from cerebros.sessions where user_id=(r->>'id')::bigint;
      return r || '{"pending":true}';
    elsif v_id is null then
      update cerebros.users set status='approved', requested_by=u.id, decided_by=u.id, decided_at=now() where id=(r->>'id')::bigint;
    end if;
    return r;

  elsif p_action = 'item_save' then
    v_bad := cerebros.controlled(coalesce(d->>'name','')||' '||coalesce(d->>'composition',''));
    if v_bad is not null then raise exception '% is a controlled drug (NDPS / Schedule X / sedative). Cerebros does not sell these on the portal.', initcap(v_bad); end if;
    r := cerebros.api('item_save', p_token, d);
    v_img := nullif(trim(coalesce(d->>'image_url','')),'');
    if v_img is not null and v_img !~ '^https://' then raise exception 'Picture link must start with https://'; end if;
    update cerebros.items set subcategory=nullif(trim(coalesce(d->>'subcategory','')),''), brand=nullif(trim(coalesce(d->>'brand','')),''),
      manufacturer=nullif(trim(coalesce(d->>'manufacturer','')),''), composition=nullif(trim(coalesce(d->>'composition','')),''), image_url=v_img,
      cold_chain=coalesce((d->>'cold_chain')::boolean,false), in_stock=coalesce((d->>'in_stock')::boolean,true), min_qty=greatest(coalesce(nullif(d->>'min_qty','')::int,1),1)
      where id=(r->>'id')::bigint;
    return r;
  elsif p_action = 'items_bulk' then
    select string_agg(distinct trim(q->>'name'),', ') into v_bad from jsonb_array_elements(d->'rows') q
      where cerebros.controlled(coalesce(q->>'name','')||' '||coalesce(q->>'composition','')) is not null;
    if v_bad is not null then raise exception 'Remove controlled drugs (NDPS / Schedule X / sedatives) from the list: %', v_bad; end if;
    r := cerebros.api('items_bulk', p_token, d);
    update cerebros.items i set subcategory=coalesce(nullif(trim(q->>'subcategory'),''),i.subcategory), brand=coalesce(nullif(trim(q->>'brand'),''),i.brand),
      manufacturer=coalesce(nullif(trim(q->>'manufacturer'),''),i.manufacturer)
      from jsonb_array_elements(d->'rows') q where i.name=trim(q->>'name') and i.pack=coalesce(nullif(trim(q->>'pack'),''),'piece');
    return r;
  end if;

  -- Cerebros only from here
  if not is_c then return cerebros.api(p_action, p_token, d); end if;

  if p_action = 'dashboard' then
    return jsonb_build_object(
      'new_orders',(select count(*) from cerebros.orders where status=0),
      'in_process',(select coalesce(sum(round(l.qty*l.rate*(1+l.gst_rate/100),2)),0) from cerebros.order_lines l join cerebros.orders o2 on o2.id=l.order_id where o2.status in (0,1,2)),
      'to_collect',(select coalesce(sum(total-paid),0) from cerebros.bills),
      'overdue',(select coalesce(sum(total-paid),0) from cerebros.bills where total-paid>0.5 and due_date < cerebros.today()),
      'sales_30d',(select coalesce(sum(total),0) from cerebros.bills where bill_date > cerebros.today()-30),
      'sales_by_day',(select coalesce(jsonb_agg(jsonb_build_object('d',dd,'v',coalesce(v,0)) order by dd),'[]'::jsonb) from (select g::date dd from generate_series(cerebros.today()-29, cerebros.today(), interval '1 day') g) days
          left join (select bill_date, sum(total) v from cerebros.bills group by bill_date) b on b.bill_date=days.dd),
      'by_category',(select coalesce(jsonb_agg(jsonb_build_object('c',category,'v',v)),'[]'::jsonb) from (select i.category, sum(round(l.qty*l.rate,2)) v from cerebros.order_lines l join cerebros.orders o2 on o2.id=l.order_id join cerebros.items i on i.id=l.item_id where o2.status<>9 and o2.created_at > now()-interval '30 days' group by i.category) q),
      'top_hospitals',(select coalesce(jsonb_agg(jsonb_build_object('h',name,'v',v) order by v desc),'[]'::jsonb) from (select hh.name, sum(round(l.qty*l.rate,2)) v from cerebros.order_lines l join cerebros.orders o2 on o2.id=l.order_id join cerebros.hospitals hh on hh.id=o2.hospital_id where o2.status<>9 and o2.created_at > now()-interval '30 days' group by hh.name order by v desc limit 6) q),
      'items',(select count(*) from cerebros.items where active),'hospitals',(select count(*) from cerebros.hospitals where active and status='approved'),
      'access_waiting',(select count(*) from cerebros.hospitals where status='applied')+(select count(*) from cerebros.users q join cerebros.hospitals hh on hh.id=q.hospital_id where q.status='pending' and hh.status='approved' and q.active),
      'docs_waiting',(select count(*) from cerebros.documents where status='submitted'));
  elsif p_action = 'hospitals' then
    return (select coalesce(jsonb_agg(to_jsonb(q) || jsonb_build_object('credit',cerebros.credit(q.id,0),
      'staff',(select count(*) from cerebros.users z where z.hospital_id=q.id and z.status='approved' and z.active)) order by (q.status='approved') desc, q.name),'[]'::jsonb) from cerebros.hospitals q);
  elsif p_action = 'access_queue' then
    return jsonb_build_object(
      'hospitals',(select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'city',q.city,'address',q.address,'gstin',q.gstin,'beds',q.beds,'contact_name',q.contact_name,'contact_mobile',q.contact_mobile,
        'applied_at',q.applied_at,'docs',cerebros.docs_state(q.id),'files',(select count(*) from cerebros.documents z where z.hospital_id=q.id)) order by q.applied_at),'[]'::jsonb) from cerebros.hospitals q where q.status='applied'),
      'staff',(select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'mobile',q.mobile,'role',q.role,'hospital',hh.name,'requested_by',rb.name,'created_at',q.created_at) order by q.created_at),'[]'::jsonb)
        from cerebros.users q join cerebros.hospitals hh on hh.id=q.hospital_id left join cerebros.users rb on rb.id=q.requested_by where q.status='pending' and q.active and hh.status='approved'),
      'docs',(select coalesce(jsonb_agg(jsonb_build_object('id',z.id,'hospital_id',z.hospital_id,'hospital',hh.name,'hospital_status',hh.status,'type',z.doc_type,'label',t.label,'doc_no',z.doc_no,'valid_till',z.valid_till,'file_name',z.file_name,'size',z.size,'uploaded_at',z.uploaded_at) order by z.uploaded_at),'[]'::jsonb)
        from cerebros.documents z join cerebros.hospitals hh on hh.id=z.hospital_id join cerebros.doc_types t on t.code=z.doc_type where z.status='submitted'));
  elsif p_action = 'doc_check' then
    select * into doc from cerebros.documents where id=(d->>'id')::bigint for update;
    if not found then raise exception 'Document not found'; end if;
    if d->>'decision' not in ('verify','reject') then raise exception 'Choose verify or reject'; end if;
    if d->>'decision'='reject' and length(trim(coalesce(d->>'note','')))<3 then raise exception 'Write why it is rejected, so the hospital can fix it'; end if;
    update cerebros.documents set status=case when d->>'decision'='verify' then 'verified' else 'rejected' end, note=nullif(trim(coalesce(d->>'note','')),''),
      doc_no=coalesce(nullif(trim(coalesce(d->>'doc_no','')),''),doc_no), valid_till=coalesce(nullif(d->>'valid_till','')::date,valid_till), checked_by=u.id, checked_at=now() where id=doc.id
      returning * into doc;
    if doc.status='verified' then
      if doc.doc_type='gst' and doc.doc_no ~* '^[0-9]{2}[A-Z0-9]{13}$' then update cerebros.hospitals set gstin=upper(doc.doc_no) where id=doc.hospital_id; end if;
      if doc.doc_type in ('dl20','dl21') then
        update cerebros.hospitals set dl_no=(select string_agg(z.doc_no,' / ' order by z.doc_type) from (select distinct on (doc_type) doc_type, doc_no from cerebros.documents where hospital_id=doc.hospital_id and doc_type in ('dl20','dl21') and status='verified' order by doc_type, valid_till desc nulls last) z),
          dl_expiry=(select min(m) from (select max(valid_till) m from cerebros.documents where hospital_id=doc.hospital_id and doc_type in ('dl20','dl21') and status='verified' group by doc_type) z)
        where id=doc.hospital_id;
      end if;
    end if;
    insert into cerebros.audit(user_id,action,detail) values (u.id,'doc_check',jsonb_build_object('doc',doc.id,'decision',d->>'decision'));
    return '{"ok":true}';
  elsif p_action = 'user_decide' then
    select * into x from cerebros.users where id=(d->>'id')::bigint for update;
    if not found or x.role not in ('staff','owner') then raise exception 'Login not found'; end if;
    if d->>'decision' not in ('approve','reject') then raise exception 'Choose approve or reject'; end if;
    update cerebros.users set status=case when d->>'decision'='approve' then 'approved' else 'rejected' end, decided_by=u.id, decided_at=now() where id=x.id;
    if d->>'decision'='reject' then delete from cerebros.sessions where user_id=x.id; end if;
    insert into cerebros.audit(user_id,action,detail) values (u.id,'user_decide',jsonb_build_object('user',x.id,'decision',d->>'decision'));
    return '{"ok":true}';
  elsif p_action = 'hospital_docs' then
    return cerebros.api_v2('doc_list', p_token, d);
  end if;

  if not is_m then return cerebros.api(p_action, p_token, d); end if;

  if p_action = 'hospital_decide' then
    select * into h from cerebros.hospitals where id=(d->>'id')::bigint for update;
    if not found then raise exception 'Hospital not found'; end if;
    if d->>'decision' = 'approve' then
      if h.status not in ('applied','rejected') then raise exception 'This hospital is not waiting for approval'; end if;
      if not (cerebros.docs_state(h.id)->>'ok')::boolean then raise exception 'Check and verify all required documents first'; end if;
      update cerebros.hospitals set status='approved', terms_days=coalesce(nullif(d->>'terms_days','')::int,terms_days), decided_at=now(), decided_by=u.id, decision_note=null where id=h.id;
      update cerebros.users set status='approved', decided_by=u.id, decided_at=now() where hospital_id=h.id and role='owner' and status<>'approved';
    elsif d->>'decision' = 'reject' then
      if length(trim(coalesce(d->>'note','')))<3 then raise exception 'Write the reason'; end if;
      update cerebros.hospitals set status='rejected', decided_at=now(), decided_by=u.id, decision_note=trim(d->>'note') where id=h.id;
      update cerebros.users set status='rejected', decided_by=u.id, decided_at=now() where hospital_id=h.id and status='pending';
      delete from cerebros.sessions where user_id in (select id from cerebros.users where hospital_id=h.id);
    elsif d->>'decision' = 'suspend' then
      update cerebros.hospitals set status='suspended', decided_at=now(), decided_by=u.id, decision_note=nullif(trim(coalesce(d->>'note','')),'') where id=h.id;
      delete from cerebros.sessions where user_id in (select id from cerebros.users where hospital_id=h.id);
    elsif d->>'decision' = 'reinstate' then
      if h.status <> 'suspended' then raise exception 'This hospital is not paused'; end if;
      update cerebros.hospitals set status='approved', decided_at=now(), decided_by=u.id, decision_note=null where id=h.id;
    else raise exception 'Unknown decision'; end if;
    insert into cerebros.audit(user_id,action,detail) values (u.id,'hospital_decide',jsonb_build_object('hospital',h.id,'decision',d->>'decision'));
    return '{"ok":true}';
  elsif p_action = 'hospital_save' then
    v_id := nullif(d->>'id','')::bigint;
    if length(trim(coalesce(d->>'name','')))<3 then raise exception 'Enter the hospital name'; end if;
    if coalesce(nullif(d->>'terms_days','')::int,0) not between 7 and 120 then raise exception 'Credit period must be 7 to 120 days'; end if;
    if coalesce(nullif(d->>'grace_days','')::int,-1) not between 0 and 60 then raise exception 'Grace days must be 0 to 60'; end if;
    if nullif(d->>'credit_limit','')::numeric < 0 then raise exception 'Limit cannot be negative'; end if;
    if coalesce(d->>'gstin','') <> '' and upper(d->>'gstin') !~ '^[0-9]{2}[A-Z0-9]{13}$' then raise exception 'GSTIN must be 15 characters'; end if;
    if v_id is null then
      insert into cerebros.hospitals(name,city,address,gstin,beds,credit_limit,terms_days,grace_days,on_hold,is_group,active,status,contact_name,contact_mobile,decided_at,decided_by)
      values (trim(d->>'name'), nullif(trim(coalesce(d->>'city','')),''), d->>'address', nullif(upper(d->>'gstin'),''), nullif(d->>'beds','')::int, nullif(d->>'credit_limit','')::numeric,
        (d->>'terms_days')::int, (d->>'grace_days')::int, coalesce((d->>'on_hold')::boolean,false), coalesce((d->>'is_group')::boolean,false), true, 'approved',
        nullif(trim(coalesce(d->>'contact_name','')),''), nullif(trim(coalesce(d->>'contact_mobile','')),''), now(), u.id) returning id into v_id;
    else
      update cerebros.hospitals set name=trim(d->>'name'), city=nullif(trim(coalesce(d->>'city','')),''), address=d->>'address', gstin=nullif(upper(d->>'gstin'),''),
        beds=nullif(d->>'beds','')::int, credit_limit=nullif(d->>'credit_limit','')::numeric, terms_days=(d->>'terms_days')::int, grace_days=(d->>'grace_days')::int,
        on_hold=coalesce((d->>'on_hold')::boolean,false), is_group=coalesce((d->>'is_group')::boolean,false), active=coalesce((d->>'active')::boolean,true),
        contact_name=nullif(trim(coalesce(d->>'contact_name','')),''), contact_mobile=nullif(trim(coalesce(d->>'contact_mobile','')),'') where id=v_id;
    end if;
    insert into cerebros.audit(user_id,action,detail) values (u.id,'hospital_save', d - 'address');
    return jsonb_build_object('id',v_id);
  end if;
  return cerebros.api(p_action, p_token, d);
end $$;

create or replace function cerebros.hid_for_docs(u cerebros.users, d jsonb) returns bigint language plpgsql stable
set search_path to 'cerebros','pg_temp' as $$
declare v bigint;
begin
  if u.role in ('staff','owner') then return u.hospital_id; end if;
  v := nullif(d->>'hospital_id','')::bigint;
  if v is null or not exists(select 1 from cerebros.hospitals where id=v) then raise exception 'Choose the hospital'; end if;
  return v;
end $$;

revoke all on function cerebros.api_v2(text,text,jsonb) from public, anon, authenticated;
