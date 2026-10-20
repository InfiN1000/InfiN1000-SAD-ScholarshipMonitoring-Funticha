# Scholarship Monitoring (SAD Midterm, Section A)

## Setup
1. Create a Supabase project. Run `schema.sql` in the SQL Editor.
2. Authentication > Users: add two users (staff and scholar) with passwords (share privately with the instructor).
3. Promote and link them in SQL:
   ```sql
   update profiles set role='staff' where full_name='<staff email>';
   update scholars set user_id=(select id from profiles where full_name='<scholar email>') where student_id='A02';
   ```
4. In `index.html` set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (anon key only, never service-role).
5. Run: `python -m http.server 8000`, open http://localhost:8000.

## How access is enforced
Row Level Security limits scholars to their own rows. Submissions and history have no insert/update policies. All writes use `security definer` functions (`submit_grades`, `verify_submission`, `evaluate_submission`, `decide_renewal`) that check the caller's role. Thresholds are read from the `programs` table.

## Known defects
(Fill in honestly after testing TC01 to TC10.)
