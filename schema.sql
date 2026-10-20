-- Scholarship Monitoring: run whole file in Supabase SQL Editor (synthetic data only)
create table profiles(id uuid primary key references auth.users on delete cascade,
  role text not null default 'scholar' check(role in('scholar','staff')), full_name text);

create table programs(id serial primary key, name text unique not null,
  max_gwa numeric(3,2) not null, min_units int not null, max_failed int not null,
  max_inc int not null, max_drop int not null, deadline timestamptz not null);

create table scholars(id uuid primary key default gen_random_uuid(),
  user_id uuid unique references profiles(id), student_id text unique not null,
  full_name text not null, program_id int not null references programs(id),
  award_status text not null default 'Active');

create table submissions(id uuid primary key default gen_random_uuid(),
  scholar_id uuid not null references scholars(id), academic_year text not null,
  semester int not null check(semester in(1,2,3)),
  gwa numeric(3,2) not null check(gwa between 1 and 5),
  units int not null check(units>=0), failed int not null check(failed>=0),
  inc int not null check(inc>=0), dropped int not null check(dropped>=0),
  evidence_ref text not null check(length(trim(evidence_ref))>0),
  submitted_at timestamptz not null default now(),
  verification_status text not null default 'Pending' check(verification_status in('Pending','Verified','Returned')),
  return_reason text,
  compliance text not null default 'Not Evaluated' check(compliance in('Not Evaluated','Compliant','With Deficiency')),
  compliance_reasons text[] not null default '{}',
  renewal_decision text not null default 'None' check(renewal_decision in('None','Approved','Held')),
  decision_note text,
  unique(scholar_id, academic_year, semester));

create table history(id bigserial primary key, submission_id uuid not null references submissions(id),
  action text not null, detail text, actor uuid, at timestamptz not null default now());

-- new signups become scholars; promote staff manually (see bottom)
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,full_name) values(new.id,new.email); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create function is_staff() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and role='staff') $$;

-- RLS: reads by policy; ALL writes to submissions/history go through RPCs only
alter table profiles enable row level security; alter table programs enable row level security;
alter table scholars enable row level security; alter table submissions enable row level security;
alter table history enable row level security;
create policy p_prof on profiles for select using(id=auth.uid() or is_staff());
create policy p_prog on programs for select to authenticated using(true);
create policy sc_sel on scholars for select using(is_staff() or user_id=auth.uid());
create policy sc_ins on scholars for insert with check(is_staff());
create policy sub_sel on submissions for select using(is_staff() or scholar_id in(select id from scholars where user_id=auth.uid()));
create policy h_sel on history for select using(is_staff() or submission_id in(
  select s.id from submissions s join scholars c on c.id=s.scholar_id where c.user_id=auth.uid()));

create function log_h(p_sub uuid,p_action text,p_detail text) returns void language sql security definer set search_path=public as
$$ insert into history(submission_id,action,detail,actor) values(p_sub,p_action,p_detail,auth.uid()) $$;

create function submit_grades(p_ay text,p_sem int,p_gwa numeric,p_units int,p_failed int,p_inc int,p_drop int,p_evidence text)
returns void language plpgsql security definer set search_path=public as $$
declare sc scholars; ex submissions; sid uuid;
begin
  select * into sc from scholars where user_id=auth.uid();
  if sc.id is null then raise exception 'No scholar record is linked to your account'; end if;
  if p_gwa is null or p_gwa<1 or p_gwa>5 then raise exception 'GWA must be between 1.00 and 5.00'; end if;
  if p_units<0 or p_failed<0 or p_inc<0 or p_drop<0 then raise exception 'Units and counts cannot be negative'; end if;
  if p_evidence is null or length(trim(p_evidence))=0 then raise exception 'Grade-document reference is required'; end if;
  select * into ex from submissions where scholar_id=sc.id and academic_year=p_ay and semester=p_sem;
  if ex.id is null then
    insert into submissions(scholar_id,academic_year,semester,gwa,units,failed,inc,dropped,evidence_ref)
    values(sc.id,p_ay,p_sem,p_gwa,p_units,p_failed,p_inc,p_drop,p_evidence) returning id into sid;
    perform log_h(sid,'Submitted','Initial submission');
  elsif ex.verification_status='Returned' then
    update submissions set gwa=p_gwa,units=p_units,failed=p_failed,inc=p_inc,dropped=p_drop,evidence_ref=p_evidence,
      submitted_at=now(),verification_status='Pending',return_reason=null,compliance='Not Evaluated',
      compliance_reasons='{}',renewal_decision='None',decision_note=null where id=ex.id;
    perform log_h(ex.id,'Resubmitted','Correction after return; back to Pending');
  else raise exception 'Duplicate: a submission for % semester % already exists', p_ay, p_sem;
  end if;
end $$;

create function verify_submission(p_id uuid,p_status text,p_reason text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_status not in('Verified','Returned') then raise exception 'Invalid status'; end if;
  if p_status='Returned' and coalesce(trim(p_reason),'')='' then raise exception 'A reason is required when returning evidence'; end if;
  update submissions set verification_status=p_status,return_reason=case when p_status='Returned' then p_reason end,
    compliance='Not Evaluated',compliance_reasons='{}',renewal_decision='None' where id=p_id;
  perform log_h(p_id,'Verification: '||p_status,p_reason);
end $$;

create function evaluate_submission(p_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare s submissions; pr programs; r text[]:='{}';
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  select * into s from submissions where id=p_id;
  if s.verification_status<>'Verified' then raise exception 'Cannot evaluate: evidence is not Verified'; end if;
  select p.* into pr from programs p join scholars c on c.program_id=p.id where c.id=s.scholar_id;
  if s.gwa>pr.max_gwa then r:=r||format('GWA %s exceeds maximum %s',s.gwa,pr.max_gwa); end if;
  if s.units<pr.min_units then r:=r||format('Enrolled units %s below minimum %s',s.units,pr.min_units); end if;
  if s.failed>pr.max_failed then r:=r||format('Failed subjects %s exceed allowed %s',s.failed,pr.max_failed); end if;
  if s.inc>pr.max_inc then r:=r||format('Incomplete grades %s exceed allowed %s',s.inc,pr.max_inc); end if;
  if s.dropped>pr.max_drop then r:=r||format('Dropped subjects %s exceed allowed %s',s.dropped,pr.max_drop); end if;
  if s.submitted_at>pr.deadline then r:=r||'Submitted late (after deadline)'; end if;
  update submissions set compliance=case when cardinality(r)=0 then 'Compliant' else 'With Deficiency' end,
    compliance_reasons=r,renewal_decision='None' where id=p_id;
  perform log_h(p_id,'Evaluated',case when cardinality(r)=0 then 'Compliant' else 'With Deficiency: '||array_to_string(r,'; ') end);
end $$;

create function decide_renewal(p_id uuid,p_decision text,p_note text) returns void
language plpgsql security definer set search_path=public as $$
declare s submissions;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  if p_decision not in('Approved','Held') then raise exception 'Invalid decision'; end if;
  select * into s from submissions where id=p_id;
  if s.verification_status<>'Verified' or s.compliance='Not Evaluated' then raise exception 'Verify and evaluate before deciding renewal'; end if;
  if p_decision='Approved' and s.compliance<>'Compliant' then raise exception 'Cannot approve a record with deficiency'; end if;
  update submissions set renewal_decision=p_decision,decision_note=p_note where id=p_id;
  perform log_h(p_id,'Renewal: '||p_decision,p_note);
end $$;

grant execute on function submit_grades,verify_submission,evaluate_submission,decide_renewal to authenticated;

-- Seed (policies + six scholars). Deadline is Asia/Manila.
insert into programs(name,max_gwa,min_units,max_failed,max_inc,max_drop,deadline) values
 ('Merit Scholar',1.75,18,0,0,0,'2026-10-30 17:00+08'),
 ('Community Scholar',2.25,15,0,0,1,'2026-10-30 17:00+08');
insert into scholars(student_id,full_name,program_id) values
 ('A01','Test Scholar 01',1),('A02','Test Scholar 02',1),('A03','Test Scholar 03',2),
 ('A04','Test Scholar 04',2),('A05','Test Scholar 05',1),('A06','Test Scholar 06',2);
insert into submissions(scholar_id,academic_year,semester,gwa,units,failed,inc,dropped,evidence_ref,submitted_at,verification_status)
select c.id,'2026-2027',1,v.g,v.u,v.f,v.i,v.d,'GRADES-'||v.sid,v.t::timestamptz,v.vs
from (values
 ('A01',1.75,18,0,0,0,'2026-10-30 17:00+08','Verified'),
 ('A02',1.76,18,0,0,0,'2026-10-29 17:00+08','Verified'),
 ('A03',2.25,15,0,0,1,'2026-10-29 17:00+08','Verified'),
 ('A04',2.25,14,0,1,0,'2026-10-29 17:00+08','Verified'),
 ('A05',1.50,18,1,0,0,'2026-10-30 17:01+08','Verified'),
 ('A06',2.00,15,0,0,0,'2026-10-29 17:00+08','Pending')
) as v(sid,g,u,f,i,d,t,vs) join scholars c on c.student_id=v.sid;

-- AFTER creating two users in Authentication > Users (e.g. staff@test.local, scholar@test.local):
-- update profiles set role='staff' where full_name='staff@test.local';
-- insert into profiles... (auto-created) then link a scholar account:
-- update scholars set user_id=(select id from profiles where full_name='scholar@test.local') where student_id='A02';
