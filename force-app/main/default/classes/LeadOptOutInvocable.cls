/**
 * LeadOptOutInvocable — Flow/Marketing-Cloud entry point for inbound STOP.
 * Wraps LeadMarketingService.setOptOut. Also callable from Apex.
 */
public with sharing class LeadOptOutInvocable {
    @InvocableMethod(label='Set SMS Opt-Out (Lead)' description='Inbound STOP: set SMS_Opt_Out__c and drop the lead from SMS drips.')
    public static void setOptOut(List<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) return;
        LeadMarketingService.setOptOut(new Set<Id>(leadIds));
    }
}
