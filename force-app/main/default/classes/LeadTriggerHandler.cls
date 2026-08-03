/**
 * LeadTriggerHandler — Phase 1 Marketing Workflow Engine (routing brain) + the existing Slack notify.
 * Invoked from the single Lead trigger (LeadSlackNotify).
 *
 * BEFORE insert/update: mutate drip fields on the triggering records (no extra DML).
 * AFTER  insert/update: create Tasks + enqueue Slack posts (needs record Id + committed context).
 *
 * Gate: never ENTER/ADVANCE a drip when the lead is not marketing-eligible — computed in Apex
 * (Marketing_Eligible__c is a formula and is not recalculated in before-trigger context):
 *   eligible = TCPA_Scrub_Status__c == 'Clear' AND NOT SMS_Opt_Out__c AND NOT Global_DNC__c.
 * Suppression actions (Do Not Call, Bad Number, exits to 'None') always run.
 * Only acts on ACTUAL field changes (old vs new). Bulk-safe.
 */
public with sharing class LeadTriggerHandler {

    private static final Set<String> PERSISTENCE_DISPOS = new Set<String>{'No Answer', 'Left Voicemail', 'Busy'};

    // Dispositions that HARD-suppress a disqualified lead from win-back. Everything else (incl. blank
    // and 'Already Enrolled Elsewhere') is a SOFT disqualification -> win-back eligible.
    private static final Set<String> HARD_SUPPRESS_DISPOS = new Set<String>{'Do Not Call', 'Bad/Wrong Number', 'Duplicate'};

    // Warm inbound engagement types that trigger the office hand-off (Slack + "respond" task).
    private static final Set<String> WARM_ENGAGEMENT = new Set<String>{'SMS Reply', 'Email Click', 'Inbound Call'};

    // ---------- BEFORE: field mutations ----------
    public static void handleBefore(List<Lead> news, Map<Id, Lead> oldMap) {
        Datetime nowTs = System.now();
        for (Lead l : news) {
            Lead prior = (oldMap != null) ? oldMap.get(l.Id) : null;
            String oldStatus = (prior != null) ? prior.Status : null;
            String oldDispo = (prior != null) ? prior.Call_Disposition__c : null;

            // ----- Call disposition transition (the routing switch; runs FIRST) -----
            if (l.Call_Disposition__c != oldDispo && l.Call_Disposition__c != null) {
                Boolean elig = isMarketingEligible(l);
                String d = l.Call_Disposition__c;
                if (PERSISTENCE_DISPOS.contains(d)) {
                    if (elig) enterDrip(l, 'Persistence', nowTs);
                } else if (d == 'Contacted - Interested') {
                    if (elig) enterDrip(l, 'Warm-Support', nowTs);
                } else if (d == 'Not Interested') {
                    if (elig) enterDrip(l, 'Nurture', nowTs);
                } else if (d == 'Do Not Call') {
                    l.SMS_Opt_Out__c = true;
                    l.Global_DNC__c = true;
                    l.Current_Drip__c = 'None';
                    if (l.Status != 'Converted' && l.Status != 'Disqualified') l.Status = 'Disqualified';
                } else if (d == 'Bad/Wrong Number') {
                    l.Bad_Number__c = true;   // SMS suppressed via SMS_Eligible__c formula
                } else if (d == 'Already Enrolled Elsewhere' || d == 'Duplicate') {
                    l.Current_Drip__c = 'None';
                } else if (d == 'Language Barrier') {
                    l.Needs_Language_Reassignment__c = true;
                }
                // 'Callback Requested' -> AFTER task, drip paused (no field change here).
                // 'Qualified' disposition -> no drip change here (rep moves Status to Qualified).
            }

            // ----- Status transition (lifecycle state; runs AFTER disposition and wins on conflict) -----
            if (l.Status != oldStatus && l.Status != null) {
                Boolean elig = isMarketingEligible(l);
                if (l.Status == 'Assigned') {
                    if (elig) { enterDrip(l, 'Speed-to-Lead', nowTs); l.Speed_to_Lead_At__c = nowTs; }
                } else if (l.Status == 'Qualified') {
                    if (elig) enterDrip(l, 'Drive-to-Appointment', nowTs);
                } else if (l.Status == 'Appointment Set') {
                    if (elig) enterDrip(l, 'Confirm-Remind', nowTs);
                } else if (l.Status == 'No Show') {
                    if (elig) enterDrip(l, 'Reschedule', nowTs);
                } else if (l.Status == 'Nurture') {
                    if (elig) enterDrip(l, 'Nurture', nowTs);
                } else if (l.Status == 'Disqualified') {
                    l.Current_Drip__c = 'None';   // exit — terminal, overrides any disposition-set drip
                    // Win-back on any SOFT disqualification — every Disqualified EXCEPT the hard-suppress
                    // dispositions (Do Not Call, Bad/Wrong Number, Duplicate). 'Already Enrolled Elsewhere' counts as soft.
                    l.Win_Back_Eligible__c = !HARD_SUPPRESS_DISPOS.contains(l.Call_Disposition__c);
                } else if (l.Status == 'Converted') {
                    if (elig) enterDrip(l, 'Onboarding', nowTs);
                }
            }

            // ----- Quiet-hours timezone: derive when blank or when the phone/state source changed -----
            Boolean phoneChanged = (prior == null) ? (l.Phone != null) : (l.Phone != prior.Phone);
            Boolean stateChanged = (prior == null) ? (l.State != null) : (l.State != prior.State);
            if (String.isBlank(l.Local_Timezone__c) || phoneChanged || stateChanged) {
                String tz = LeadTimezoneUtil.resolve(l.Phone, l.State, l.Office__c);
                if (String.isNotBlank(tz)) l.Local_Timezone__c = tz;
            }

            // ----- Opt-out stamp: when SMS_Opt_Out__c flips true by any means, stamp date + source -----
            if (l.SMS_Opt_Out__c == true && (prior == null || prior.SMS_Opt_Out__c != true)) {
                if (l.SMS_Opt_Out_Date__c == null) l.SMS_Opt_Out_Date__c = nowTs;
                if (String.isBlank(l.SMS_Opt_Out_Source__c)) l.SMS_Opt_Out_Source__c = 'System';
            }
        }
    }

    // ---------- AFTER: tasks + Slack ----------
    @TestVisible private static List<SlackNotifier.Notification> lastNotes;

    public static void handleAfter(List<Lead> news, Map<Id, Lead> oldMap) {
        List<Task> tasks = new List<Task>();
        List<SlackNotifier.Notification> notes = new List<SlackNotifier.Notification>();

        // Newly-Assigned eligible leads grouped by office — drives the bulk-vs-single Slack decision below.
        Map<String, List<Lead>> assignedByOffice = new Map<String, List<Lead>>();

        for (Lead l : news) {
            Lead prior = (oldMap != null) ? oldMap.get(l.Id) : null;
            String oldStatus = (prior != null) ? prior.Status : null;
            String oldDispo = (prior != null) ? prior.Call_Disposition__c : null;
            Boolean elig = isMarketingEligible(l);

            // -> Assigned : ALWAYS create the per-lead call-now Task (never drop a rep's work item).
            // The Slack post is decided per-office after the loop: one summary for a bulk distribution run,
            // a per-lead "call now" post for a single real-time assignment.
            if (l.Status == 'Assigned' && oldStatus != 'Assigned' && elig
                    && !SlackTriggerState.assignedActioned.contains(l.Id)) {
                SlackTriggerState.assignedActioned.add(l.Id);
                tasks.add(newTask(l, 'Call now — new clear lead'));
                String officeKey = (l.Office__c == null) ? '' : l.Office__c;
                if (!assignedByOffice.containsKey(officeKey)) assignedByOffice.put(officeKey, new List<Lead>());
                assignedByOffice.get(officeKey).add(l);
            }

            // Callback Requested : rep callback task (drip paused)
            if (l.Call_Disposition__c == 'Callback Requested' && oldDispo != 'Callback Requested'
                    && !SlackTriggerState.callbackActioned.contains(l.Id)) {
                SlackTriggerState.callbackActioned.add(l.Id);
                tasks.add(newTask(l, 'Callback requested — follow up'));
            }

            // Existing Slack notify: -> Qualified / Appointment Set (TCPA Clear)
            if (l.Status != oldStatus && (l.Status == 'Qualified' || l.Status == 'Appointment Set')
                    && l.TCPA_Scrub_Status__c == 'Clear'
                    && !SlackTriggerState.leadsNotified.contains(l.Id)) {
                SlackTriggerState.leadsNotified.add(l.Id);
                notes.add(leadNote(l.Status == 'Appointment Set' ? 'LEAD_APPT' : 'LEAD_QUALIFIED', l, null));
            }

            // Engagement hand-off: Lead replied (Reply_Received__c false->true) OR a warm engagement type
            // (SMS Reply / Email Click / Inbound Call). Fires off Marketing Cloud's direct field writes AND
            // the recordEngagement API path — one hand-off, no double post/task. Routes by Office__c.
            Boolean replyFlipped = (l.Reply_Received__c == true) && (prior == null || prior.Reply_Received__c != true);
            Boolean warmType = (l.Last_Engagement_Type__c != null)
                    && (prior == null || l.Last_Engagement_Type__c != prior.Last_Engagement_Type__c)
                    && WARM_ENGAGEMENT.contains(l.Last_Engagement_Type__c);
            if ((replyFlipped || warmType) && !SlackTriggerState.engagementActioned.contains(l.Id)) {
                SlackTriggerState.engagementActioned.add(l.Id);
                tasks.add(newTask(l, 'Lead replied — respond'));
                notes.add(leadNote('LEAD_REPLIED', l, l.Last_Engagement_Type__c));
            }
        }

        // Speed-to-Lead Slack: >1 lead to the same office in one transaction (bulk distribution) -> ONE
        // per-office summary; a single assignment -> the per-lead "call now" post. Keeps the channel from
        // being spammed and stays within the per-transaction callout cap. Task already created for each.
        for (String officeKey : assignedByOffice.keySet()) {
            List<Lead> officeGroup = assignedByOffice.get(officeKey);
            if (officeGroup.size() == 1) {
                notes.add(leadNote('LEAD_ASSIGNED', officeGroup[0], null));
            } else {
                notes.add(assignedSummaryNote(officeKey, officeGroup.size()));
            }
        }

        if (!tasks.isEmpty()) insert tasks;
        lastNotes = notes;   // @TestVisible: lets tests assert the bulk-vs-single decision
        if (!notes.isEmpty()) System.enqueueJob(new SlackNotifier(notes));
    }

    // ---------- helpers ----------
    @TestVisible
    private static Boolean isMarketingEligible(Lead l) {
        return l.TCPA_Scrub_Status__c == 'Clear' && l.SMS_Opt_Out__c != true && l.Global_DNC__c != true;
    }

    private static void enterDrip(Lead l, String drip, Datetime nowTs) {
        l.Current_Drip__c = drip;
        l.Drip_Entered_At__c = nowTs;
    }

    private static Task newTask(Lead l, String subject) {
        Task t = new Task(
            WhoId = l.Id,
            Subject = subject,
            ActivityDate = Date.today(),
            Priority = 'High',
            Status = 'Not Started'
        );
        // A Task cannot be owned by a queue. When a lead sits in an office queue after distribution
        // (owner Id prefix 00G), leave OwnerId to default (the running user); only pin the task to the
        // lead owner when that owner is an individual User (005) — e.g. a single real-time assignment.
        if (l.OwnerId != null && String.valueOf(l.OwnerId).startsWith('005')) {
            t.OwnerId = l.OwnerId;
        }
        return t;
    }

    private static SlackNotifier.Notification assignedSummaryNote(String officeCode, Integer cnt) {
        SlackNotifier.Notification n = new SlackNotifier.Notification();
        n.kind = 'LEAD_ASSIGNED_BULK';
        n.officeCode = officeCode;
        n.leadCount = cnt;
        return n;
    }

    private static SlackNotifier.Notification leadNote(String kind, Lead l, String detail) {
        SlackNotifier.Notification n = new SlackNotifier.Notification();
        n.kind = kind;
        n.officeCode = l.Office__c;
        n.recordName = l.Name;
        n.company = l.Company;
        n.ownerId = l.OwnerId;
        n.detail = detail;
        return n;
    }
}
