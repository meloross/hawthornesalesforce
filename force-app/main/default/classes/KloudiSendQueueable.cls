/**
 * KloudiSendQueueable — async, callout-safe worker for KloudiService.sendViaKloudi (Flows/journeys).
 * Runs each compliance-gated send, collecting skip reasons in memory, then persists the skip-log Tasks
 * AFTER all callouts complete (never DML before a callout in the same transaction).
 */
public class KloudiSendQueueable implements Queueable, Database.AllowsCallouts {
    private List<KloudiService.SmsRequest> reqs;
    public KloudiSendQueueable(List<KloudiService.SmsRequest> reqs) { this.reqs = reqs; }

    public void execute(QueueableContext ctx) {
        if (reqs == null) return;
        List<Task> skipLogs = new List<Task>();
        for (KloudiService.SmsRequest req : reqs) {
            if (Limits.getCallouts() >= Limits.getLimitCallouts()) break;   // stay within the per-transaction cap
            KloudiService.KloudiResult res = KloudiService.sendToLead(req.leadId, req.source, req.message);
            if (res != null && res.skipReason != null) {
                skipLogs.add(new Task(WhoId = req.leadId,
                    Subject = 'SMS skipped (Kloudi): ' + res.skipReason,
                    Status = 'Completed', Priority = 'Normal', ActivityDate = Date.today()));
            }
        }
        if (!skipLogs.isEmpty()) insert skipLogs;
    }
}
