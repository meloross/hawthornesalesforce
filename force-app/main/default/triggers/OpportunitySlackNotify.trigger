/**
 * OpportunitySlackNotify — posts to the office Slack channel on Opportunity create,
 * StageName change, and transition to Closed Won (prefaced with :tada:).
 * Bulk-safe (processes all chunks), recursion-guarded (per-record, per-transaction).
 */
trigger OpportunitySlackNotify on Opportunity (after insert, after update) {
    List<SlackNotifier.Notification> notes = new List<SlackNotifier.Notification>();
    for (Opportunity o : Trigger.new) {
        if (SlackTriggerState.oppsNotified.contains(o.Id)) continue;
        Boolean isNew = Trigger.isInsert;
        Boolean stageChanged = false;
        Boolean becameWon = false;
        if (Trigger.isUpdate) {
            Opportunity prior = Trigger.oldMap.get(o.Id);
            stageChanged = (o.StageName != prior.StageName);
            becameWon = (o.StageName == 'Closed Won' && prior.StageName != 'Closed Won');
        }
        if (isNew || stageChanged) {
            SlackTriggerState.oppsNotified.add(o.Id);
            SlackNotifier.Notification n = new SlackNotifier.Notification();
            n.kind = becameWon ? 'OPP_WON' : (isNew ? 'OPP_NEW' : 'OPP_STAGE');
            n.officeCode = o.Office__c;
            n.recordName = o.Name;
            n.stageName = o.StageName;
            n.totalDebt = o.Total_Debt__c;
            n.hfsRevenue = o.HFS_Revenue__c;
            n.ownerId = o.OwnerId;
            notes.add(n);
        }
    }
    if (!notes.isEmpty()) {
        System.enqueueJob(new SlackNotifier(notes));
    }
}
