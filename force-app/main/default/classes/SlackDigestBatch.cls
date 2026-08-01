/**
 * SlackDigestBatch — posts a daily pipeline digest to each active office's Slack channel.
 * One office per scope for callout isolation. AllowsCallouts.
 * Digest: new leads today, # Qualified, # Appointment Set, open pipeline $ + count, won $ this week.
 */
public with sharing class SlackDigestBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {

    public Iterable<SObject> start(Database.BatchableContext bc) {
        List<SObject> offices = new List<SObject>();
        for (Office_Distribution_Setting__mdt s : Office_Distribution_Setting__mdt.getAll().values()) {
            if (s.Active__c == true && String.isNotBlank(s.Slack_Channel_Id__c)) offices.add(s);
        }
        return offices;
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        for (SObject so : scope) {
            Office_Distribution_Setting__mdt s = (Office_Distribution_Setting__mdt) so;
            SlackService.postMessage(s.Slack_Channel_Id__c, buildDigest(s.Office_Code__c));
        }
    }

    public void finish(Database.BatchableContext bc) {}

    @TestVisible
    private String buildDigest(String office) {
        Integer newLeads  = [SELECT COUNT() FROM Lead WHERE Office__c = :office AND CreatedDate = TODAY];
        Integer qualified = [SELECT COUNT() FROM Lead WHERE Office__c = :office AND Status = 'Qualified'];
        Integer apptSet   = [SELECT COUNT() FROM Lead WHERE Office__c = :office AND Status = 'Appointment Set'];

        Integer openCount = 0; Decimal openDebt = 0;
        for (AggregateResult ar : [
                SELECT COUNT(Id) c, SUM(Total_Debt__c) d FROM Opportunity
                WHERE Office__c = :office AND StageName NOT IN ('Closed Won','Closed Lost')]) {
            openCount = (Integer) ar.get('c');
            openDebt  = (ar.get('d') != null) ? (Decimal) ar.get('d') : 0;
        }

        Integer wonCount = 0; Decimal wonDebt = 0; Decimal wonRev = 0;
        for (Opportunity o : [
                SELECT Total_Debt__c, HFS_Revenue__c FROM Opportunity
                WHERE Office__c = :office AND StageName = 'Closed Won' AND CloseDate = THIS_WEEK]) {
            wonCount++;
            if (o.Total_Debt__c != null)   wonDebt += o.Total_Debt__c;
            if (o.HFS_Revenue__c != null)  wonRev  += o.HFS_Revenue__c;
        }

        return ':bar_chart: *Daily Pipeline — ' + officeLabel(office) + '*  (' + Date.today().format() + ')\n'
            + '• New leads today: *' + newLeads + '*\n'
            + '• Qualified: *' + qualified + '*   •  Appointments set: *' + apptSet + '*\n'
            + '• Open pipeline: *' + openCount + '* deals · *' + money(openDebt) + '*\n'
            + '• Won this week: *' + wonCount + '* deals · *' + money(wonDebt) + '* debt · *' + money(wonRev) + '* HFS rev';
    }

    private String officeLabel(String code) {
        Map<String, String> m = new Map<String, String>{
            'HFS_TPA' => 'Tampa', 'HFS_MIA' => 'Miami', 'HFS_NJ' => 'New Jersey', 'HFS_NY' => 'New York'
        };
        if (String.isBlank(code)) return 'Office';
        return m.containsKey(code) ? m.get(code) : code;
    }

    private String money(Decimal d) {
        if (d == null) return '$0';
        return '$' + d.setScale(0, System.RoundingMode.HALF_UP).format();
    }
}
