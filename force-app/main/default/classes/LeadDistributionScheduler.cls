/**
 * LeadDistributionScheduler — run lead distribution on a schedule, independent of the scrub chain.
 * e.g. System.schedule('HFS Lead Distribution', '0 30 * * * ?', new LeadDistributionScheduler());
 */
public with sharing class LeadDistributionScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new LeadDistributionBatch(), 200);
    }
}
