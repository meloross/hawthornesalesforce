# HFS Rep Users — Roster & Provisioning Record

*Data operation (not metadata). Created 2026-08-01 in ability-fun-6734 (production). Users are records, not deployable source — this file is the audit/recovery record.*

## Provisioning standard
- **IsActive = false** for all (consume no license, send no email; activate at launch).
- Base **Profile:** Minimum Access - Salesforce (`00efn000004GqwaAAC`). Real access comes from the tier permission set.
- **Username** pattern: `<firstname>@hawthornefs.com.hfs` (`.hfs` suffix for global uniqueness).
- LocaleSidKey `en_US` · EmailEncodingKey `UTF-8` · LanguageLocaleKey `en_US` · TimeZone `America/New_York` (Garrett = `America/Phoenix`).
- Created with `triggerUserEmail=false`. **No activation/welcome/reset emails sent.**
- License at time of creation: Salesforce 30 total, 1 used → 29 available.

## Roster (12 users, all INACTIVE)

| Name | User Id | Username | Email | Role | Permission Set | TZ |
|---|---|---|---|---|---|---|
| James Longo | 005fn000006vfZFAAY | james@hawthornefs.com.hfs | james@hawthornefs.com | Closing Team | HFS Closer | ET |
| Alex Russo | 005fn000006vfZGAAY | alex@hawthornefs.com.hfs | alex@hawthornefs.com | Closing Team | HFS Closer | ET |
| Jay Young | 005fn000006vfZHAAY | jay@hawthornefs.com.hfs | todd@hawthornefs.com | Closing Team | HFS Closer | ET |
| Marcus Lanns | 005fn000006vfZIAAY | marcus@hawthornefs.com.hfs | marcus@hawthornefs.com | Tampa Rep | HFS Hybrid | ET |
| Garrett Wright | 005fn000006vfZJAAY | garrett@hawthornefs.com.hfs | garrett@hawthornefs.com | Tampa Rep | HFS Hybrid | **AZ (Phoenix)** |
| Stephanie Carrera | 005fn000006vfZKAAY | stephanie@hawthornefs.com.hfs | stef@hawthornefs.com | Tampa Rep | HFS Hybrid | ET |
| Raquel Melgares | 005fn000006vfZLAAY | raquel@hawthornefs.com.hfs | raquel@hawthornefs.com | Miami Rep | HFS Hybrid | ET |
| Lianet Salinas | 005fn000006vfZMAAY | lianet@hawthornefs.com.hfs | lianet@hawthornefs.com | Miami Rep | HFS Hybrid | ET |
| Miles Wilson | 005fn000006vfZNAAY | miles@hawthornefs.com.hfs | miles@hawthornefs.com | Miami Rep | HFS Hybrid | ET |
| Yessica Gonzalez | 005fn000006vfZOAAY | yessica@hawthornefs.com.hfs | yessica@hawthornefs.com | New Jersey Rep | HFS Hybrid | ET |
| Valicia McRoy | 005fn000006vfZPAAY | valicia@hawthornefs.com.hfs | valicia@hawthornefs.com | New Jersey Rep | HFS Hybrid | ET |
| Kalyna Demchuk | 005fn000006vfZQAAY | kalyna@hawthornefs.com.hfs | kalyna@hawthornefs.com | Corporate / RevOps | HFS_Manager | ET |

## Resolved gap — HFS Manager (2026-08-01)
- **`HFS_Manager` permission set BUILT, DEPLOYED & ASSIGNED.** Deploy ID 0Affn000004qdcTCAQ; PermissionSet Id `0PSfn000004uqPpGAI`. It is **READ-ONLY on records** (reporting manager), NOT edit: Lead + Opportunity Read + **View All**; Account/Contact/Task Read; read-only FLS on all custom Lead/Opp fields; Hawthorne Sales app + Lead/Opp/Reports/Dashboards tabs; no Create/Edit/Delete/Modify All. Hawthorne Operations **report + dashboard folders shared View** to the `Corporate_RevOps` role (reaches all holders in that role).
- **Reporting/authoring perms (upgraded 2026-08-01, Deploy ID 0Affn000004qfO9CAI):** RunReports, Create and Customize Reports, Report Builder, Create Report Folders, Create and Customize Dashboards, Create Dashboard Folders, Edit My Dashboards. → Holders can build their OWN reports/dashboards but still cannot edit records.
- **Assignees:** Kalyna Demchuk (`0Pafn00000DeF5rCAF`) · Isabel Banks (`0Pafn00000DeRbXCAV`). Both INACTIVE — access applies when activated.

## Manager user — Isabel Banks (DATA — 2026-08-01)
- **Created INACTIVE:** `Isabel Banks`, Id `005fn000006wL8fAAE`, username `isabel@hawthornefs.com.hfs`, email `isabel@hawthornefs.com`, base Profile **Minimum Access - Salesforce** (Salesforce license), **Role `Corporate_RevOps`** (so the folder shares reach her). No password. `HFS_Manager` permission set assigned. Same manager setup as Kalyna.

## Admin user — Mar Mirza (DATA — 2026-08-01)
- **New System Administrator user created INACTIVE:** `Mar Mirza`, Id `005fn000006wJjZAAU`, username `mar@hawthornefs.com.hfs`, email `mar@hawthornefs.com`, Profile **System Administrator** (Salesforce license). No password set (Rahul activates + Mar sets own password later).
- **Old account `mar@hawthornefs.com` DEACTIVATED:** `Umar Mirza`, Id `005fn000006vRT3AAM` — was an unused (never logged in, 0 login history) API-only account on the *Salesforce Integration* license. Could not be converted to System Administrator (cross-license), so it was deactivated and a fresh admin user created instead. Its username `mar@hawthornefs.com` stays reserved by the deactivated record; the new login is `.hfs`-suffixed per this org's convention. **To make the new login exactly `mar@hawthornefs.com`, the old record must be renamed first (may send a username-change email) — not done.**

## Activation (later, at launch — NOT done now)
- Set `IsActive = true` (consumes 1 Salesforce license each). Then the org's login/welcome flow applies.
- Add users to the office Lead **queues** (currently empty membership).
