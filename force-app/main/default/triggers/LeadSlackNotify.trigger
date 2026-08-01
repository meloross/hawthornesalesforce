/**
 * LeadSlackNotify — posts to the office Slack channel when a Lead moves to
 * Qualified or Appointment Set AND its TCPA scrub status is Clear.
 * Bulk-safe (processes all chunks), recursion-guarded (per-record, per-transaction).
 */
trigger LeadSlackNotify on Lead (after update) {
    List<SlackNotifier.Notification> notes = new List<SlackNotifier.Notification>();
    for (Lead l : Trigger.new) {
        if (SlackTriggerState.leadsNotified.contains(l.Id)) continue;
        Lead prior = Trigger.oldMap.get(l.Id);
        Boolean statusChanged = (l.Status != prior.Status);
        Boolean qualified = (l.Status == 'Qualified');
        Boolean apptSet = (l.Status == 'Appointment Set');
        if (statusChanged && (qualified || apptSet) && l.TCPA_Scrub_Status__c == 'Clear') {
            SlackTriggerState.leadsNotified.add(l.Id);
            SlackNotifier.Notification n = new SlackNotifier.Notification();
            n.kind = apptSet ? 'LEAD_APPT' : 'LEAD_QUALIFIED';
            n.officeCode = l.Office__c;
            n.recordName = l.Name;
            n.company = l.Company;
            n.ownerId = l.OwnerId;
            notes.add(n);
        }
    }
    if (!notes.isEmpty()) {
        System.enqueueJob(new SlackNotifier(notes));
    }
}
