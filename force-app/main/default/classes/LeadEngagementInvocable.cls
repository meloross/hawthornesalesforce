/**
 * LeadEngagementInvocable — Flow/Marketing-Cloud entry point for inbound engagement write-back.
 * Wraps LeadMarketingService.recordEngagement (bulk-safe). Also callable from Apex.
 */
public with sharing class LeadEngagementInvocable {

    public class Request {
        @InvocableVariable(required=true label='Lead Id')
        public Id leadId;
        @InvocableVariable(required=true label='Engagement Type')
        public String engagementType;   // SMS Reply | Email Click | Email Open | Inbound Call
    }

    @InvocableMethod(label='Record Lead Engagement' description='Stamp engagement fields, set Reply_Received__c, alert the rep (Slack + Task).')
    public static void record(List<Request> reqs) {
        if (reqs == null || reqs.isEmpty()) return;
        List<LeadMarketingService.EngagementInput> inputs = new List<LeadMarketingService.EngagementInput>();
        for (Request r : reqs) {
            inputs.add(new LeadMarketingService.EngagementInput(r.leadId, r.engagementType));
        }
        LeadMarketingService.recordEngagement(inputs);
    }
}
