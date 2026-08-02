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
                    if (l.Call_Disposition__c == 'Not Interested') l.Win_Back_Eligible__c = true;
                } else if (l.Status == 'Converted') {
                    if (elig) enterDrip(l, 'Onboarding', nowTs);
                }
            }
        }
    }

    // ---------- AFTER: tasks + Slack ----------
    public static void handleAfter(List<Lead> news, Map<Id, Lead> oldMap) {
        List<Task> tasks = new List<Task>();
        List<SlackNotifier.Notification> notes = new List<SlackNotifier.Notification>();

        for (Lead l : news) {
            Lead prior = (oldMap != null) ? oldMap.get(l.Id) : null;
            String oldStatus = (prior != null) ? prior.Status : null;
            String oldDispo = (prior != null) ? prior.Call_Disposition__c : null;
            Boolean elig = isMarketingEligible(l);

            // -> Assigned : Speed-to-Lead rep alert (call-now task + Slack)
            if (l.Status == 'Assigned' && oldStatus != 'Assigned' && elig
                    && !SlackTriggerState.assignedActioned.contains(l.Id)) {
                SlackTriggerState.assignedActioned.add(l.Id);
                tasks.add(newTask(l, 'Call now — new clear lead'));
                notes.add(leadNote('LEAD_ASSIGNED', l, null));
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
        }

        if (!tasks.isEmpty()) insert tasks;
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
        return new Task(
            WhoId = l.Id,
            OwnerId = l.OwnerId,
            Subject = subject,
            ActivityDate = Date.today(),
            Priority = 'High',
            Status = 'Not Started'
        );
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
