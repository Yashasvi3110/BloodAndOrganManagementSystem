# Blood & Organ Donation Management System

A small Flask + Oracle application to record and manage blood and organ donations, usage, and inventory. The frontend is a single-page HTML (vanilla JS + Tailwind CDN) and the backend is a Flask API that talks to an Oracle database (via oracledb).

## Features
- Register donors and patients
- Record blood donations and usages (stock updated via DB triggers)
- Record organ donations and usages (stock updated via DB triggers)
- Generate monthly reports (stored procedure populates `Monthly_Report`)
- Frontend UI with forms, tables and a Reports tab

## Quick Start
Prerequisites:
- Python 3.8+
- Oracle Database (XE or other) accessible and the user has privileges to create schema objects and execute procedures
- (Optional) Oracle Instant Client if required by your platform for oracledb

1. Install Python dependencies

```powershell
python -m pip install -r requirements.txt
```

2. Configure DB connection
- Edit `app.py` and set `ORACLE_CONFIG` (user/password/dsn) for your Oracle database.

3. Prepare the database
- Run `oracle_schema.sql` in SQL Developer / SQL*Plus to create tables, triggers, procedures and seed data.

4. Run the app

```powershell
python app.py
```

5. Open the UI
- Visit `http://127.0.0.1:5000/` in a browser.

## Important Notes
- The schema has been normalized: `BloodDonationLog` and `BloodUsageLog` do NOT store `blood_group` directly; the procedures and triggers derive blood_group by joining `Donor` or `Patient`. This avoids redundancy and satisfies BCNF.
- `SP_GENERATE_MONTHLY_REPORT` fills the `Monthly_Report` table; the frontend calls an endpoint that invokes this procedure and returns rows.
- Deleting donors/patients will also remove related logs (the backend currently deletes dependent logs before removing a donor/patient). If you require an audit trail, consider archiving instead of hard deletes.

## Testing the API
- Donor list: `GET /api/donors`
- Register donor: `POST /api/donors/register` with JSON `{name, blood_group, contact_number, is_organ_donor}`
- Record donation: `POST /api/donors/donate` with JSON `{donor_id, component, units}`
- Generate monthly report: `POST /api/reports/generate` with JSON `{month, year}`

Use a tool like `curl`, `Invoke-RestMethod` (PowerShell) or Postman to exercise the endpoints.

## Troubleshooting
- If you get `PLS-00905` or `object ... is invalid` for the stored procedure, run the diagnostic endpoint:

```powershell
Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:5000/api/db/proc_errors?name=SP_GENERATE_MONTHLY_REPORT'
```

Then inspect and recompile the procedure in your DB client.