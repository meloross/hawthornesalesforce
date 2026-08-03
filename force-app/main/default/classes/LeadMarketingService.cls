/**
 * LeadMarketingService — Apex entry points the send channel (Marketing Cloud / integration) calls
 * later. Bulk-safe. No SMS/email is sent here; this is the write-back + hand-off layer.
 */
public with sharing class LeadMarketingService {

    /** Inbound STOP: opt out of SMS and drop the lead from its (SMS) drip. */
    public static void setOptOut(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) return;
        List<Lead> toUpdate = new List<Lead>();
        for (Lead l : [SELECT Id, SMS_Opt_Out__c, Current_Drip__c FROM Lead WHERE Id IN :leadIds]) {
            toUpdate.add(new Lead(Id = l.Id, SMS_Opt_Out__c = true, Current_Drip__c = 'None',
                                  SMS_Opt_Out_Source__c = 'Inbound STOP'));
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }

    /** Single-lead convenience (per the spec signature); delegates to the bulk path. */
    public static void recordEngagement(Id leadId, String engagementType) {
        recordEngagement(new List<EngagementInput>{ new EngagementInput(leadId, engagementType) });
    }

    /**
     * Bulk write-back: stamp the engagement fields + set Reply_Received__c.
     * The office Slack alert + "Lead replied — respond" task are raised by the Lead trigger
     * (LeadTriggerHandler) off this field write — so this API path and Marketing Cloud's direct
     * field writes both route through ONE hand-off (no double post/task).
     */
    public static void recordEngagement(List<EngagementInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return;
        Map<Id, String> typeById = new Map<Id, String>();
        for (EngagementInput e : inputs) {
            if (e != null && e.leadId != null) typeById.put(e.leadId, e.engagementType);
        }
        if (typeById.isEmpty()) return;

        Datetime nowTs = System.now();
        List<Lead> updates = new List<Lead>();
        // Only touch leads that actually exist (avoids errors on stale ids).
        for (Id lid : new Map<Id, Lead>([SELECT Id FROM Lead WHERE Id IN :typeById.keySet()]).keySet()) {
            Lead upd = new Lead(Id = lid, Last_Engagement_At__c = nowTs, Reply_Received__c = true);
            String t = typeById.get(lid);
            if (String.isNotBlank(t)) upd.Last_Engagement_Type__c = t;
            updates.add(upd);
        }
        if (!updates.isEmpty()) update updates;   // trigger raises Slack + task
    }

    public class EngagementInput {
        public Id leadId;
        public String engagementType;
        public EngagementInput(Id leadId, String engagementType) {
            this.leadId = leadId;
            this.engagementType = engagementType;
        }
    }
}
