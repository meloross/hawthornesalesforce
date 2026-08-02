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
            toUpdate.add(new Lead(Id = l.Id, SMS_Opt_Out__c = true, Current_Drip__c = 'None'));
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }

    /** Single-lead convenience (per the spec signature); delegates to the bulk path. */
    public static void recordEngagement(Id leadId, String engagementType) {
        recordEngagement(new List<EngagementInput>{ new EngagementInput(leadId, engagementType) });
    }

    /** Bulk write-back: stamp engagement fields, set Reply_Received__c, alert the rep (Slack + Task). */
    public static void recordEngagement(List<EngagementInput> inputs) {
        if (inputs == null || inputs.isEmpty()) return;
        Map<Id, String> typeById = new Map<Id, String>();
        for (EngagementInput e : inputs) {
            if (e != null && e.leadId != null) typeById.put(e.leadId, e.engagementType);
        }
        if (typeById.isEmpty()) return;

        Map<Id, Lead> leads = new Map<Id, Lead>(
            [SELECT Id, Name, Company, Office__c, OwnerId FROM Lead WHERE Id IN :typeById.keySet()]);
        List<Lead> updates = new List<Lead>();
        List<Task> tasks = new List<Task>();
        List<SlackNotifier.Notification> notes = new List<SlackNotifier.Notification>();
        Datetime nowTs = System.now();

        for (Id lid : typeById.keySet()) {
            if (!leads.containsKey(lid)) continue;
            Lead l = leads.get(lid);
            String t = typeById.get(lid);
            Lead upd = new Lead(Id = lid, Last_Engagement_At__c = nowTs, Reply_Received__c = true);
            if (String.isNotBlank(t)) upd.Last_Engagement_Type__c = t;
            updates.add(upd);
            tasks.add(new Task(WhoId = lid, OwnerId = l.OwnerId, Subject = 'Lead engaged — follow up',
                               ActivityDate = Date.today(), Priority = 'High', Status = 'Not Started'));
            SlackNotifier.Notification n = new SlackNotifier.Notification();
            n.kind = 'LEAD_ENGAGED';
            n.officeCode = l.Office__c;
            n.recordName = l.Name;
            n.company = l.Company;
            n.ownerId = l.OwnerId;
            n.detail = t;
            notes.add(n);
        }

        if (!updates.isEmpty()) update updates;
        if (!tasks.isEmpty()) insert tasks;
        if (!notes.isEmpty()) System.enqueueJob(new SlackNotifier(notes));
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
