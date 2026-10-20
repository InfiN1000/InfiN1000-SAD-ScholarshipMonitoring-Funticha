# Scholarship Monitoring and Academic Compliance System (SAD Midterm, Section A)

Stack: HTML + JavaScript (single file) + Supabase (Postgres, Auth, Row Level Security).

## Files
- `index.html` - the web app
- `schema.sql` - tables, access policies, functions, seed records (A01 to A06)
- `Analysis_Report.html` - Part I (A1 to A6, UML, ERD, use cases, traceability)
- `TEST_RESULTS.md` - TC01 to TC10 results; `evidence/` - screenshots

## Configuration (names only; values are not committed)
In `index.html` set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (the publishable key). Never use the service-role key.

## Setup
1. Create a Supabase project; run `schema.sql` in the SQL Editor.
2. Authentication > Users: create one staff and one scholar user (auto-confirm).
3. Promote and link them:
   ```sql
   update profiles set role='staff' where full_name='<staff email>';
   update scholars set user_id=(select id from profiles where full_name='<scholar email>') where student_id='A02';
   ```
4. Run: `python -m http.server 8000` and open http://localhost:8000
5. Sign in as staff or scholar.

## Access enforcement
RLS limits scholars to their own rows. Submissions and history have no direct write policies; all changes go through `security definer` functions (`submit_grades`, `verify_submission`, `evaluate_submission`, `decide_renewal`) that check the caller's role. Thresholds are read from the `programs` table.

## Test accounts
Supplied privately to the instructor. No passwords or keys are in this repository.

## Known defects / limitations
(Update after running the tests.)
- Corrections reuse the submission form (no separate resubmit screen).
- Login accounts are created in the Supabase dashboard, not in the app.
- Search and filter run in the browser over rows the database already allows.