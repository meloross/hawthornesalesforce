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
| Kalyna Demchuk | 005fn000006vfZQAAY | kalyna@hawthornefs.com.hfs | kalyna@hawthornefs.com | Corporate / RevOps | **none (see gap)** | ET |

## Open gap
- **"HFS Manager" permission set does not exist yet.** Kalyna Demchuk (Corporate / RevOps) has her user + role but **no rep permission set**. Build an `HFS Manager` permission set (broad cross-office Lead + Opportunity read, plus edit) and assign it to her.

## Activation (later, at launch — NOT done now)
- Set `IsActive = true` (consumes 1 Salesforce license each). Then the org's login/welcome flow applies.
- Add users to the office Lead **queues** (currently empty membership).
