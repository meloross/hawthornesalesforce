/**
 * WebsiteLeadIntakeTest — website → Salesforce intake (Base44 connector writes LeadSource='Website').
 * Covers the LeadTriggerHandler additions: round-robin to active reps, New/Pending + consent-source
 * defaulting, and the office-routed "🌐 New website lead" Slack alert + call task.
 */
@isTest
private class WebsiteLeadIntakeTest {

    @TestSetup static void seed() {
        insert new App_Secret__c(Name = 'Slack_Bot_Token', Secret_Value__c = 'xoxb-test-token');
    }

    static Lead websiteLead(String suffix) {
        return new Lead(FirstName = 'Web', LastName = 'Lead' + suffix, Company = 'Web Co ' + suffix,
                        LeadSource = 'Website');
    }

    // Round-robin cycles OwnerId deterministically across the eligible rep set (keyed on cumulative count = 0 here).
    @isTest static void roundRobinCyclesAcrossReps() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        List<Id> reps = new List<Id>();
        for (User u : [SELECT Id FROM User WHERE IsActive = true AND UserType = 'Standard' ORDER BY Id LIMIT 3]) {
            reps.add(u.Id);
        }
        System.assert(reps.size() >= 2, 'test org needs >= 2 active standard users for a round-robin');
        LeadTriggerHandler.repsOverride = reps;

        Integer n = reps.size() * 2;   // two full cycles proves rotation + wrap-around
        List<Lead> ls = new List<Lead>();
        for (Integer i = 0; i < n; i++) ls.add(websiteLead(String.valueOf(i)));

        Test.startTest();
        insert ls;
        Test.stopTest();

        // Requery: a before-insert owner assignment is not written back to the in-memory list.
        Map<Id, Id> ownerByLead = new Map<Id, Id>();
        for (Lead q : [SELECT Id, OwnerId FROM Lead WHERE Id IN :ls]) ownerByLead.put(q.Id, q.OwnerId);
        for (Integer i = 0; i < n; i++) {
            System.assertEquals(reps[Math.mod(i, reps.size())], ownerByLead.get(ls[i].Id),
                'round-robin owner at position ' + i);
        }
    }

    // Website lead gets Status=New, TCPA=Pending, and consent source stamped 'Web Form' when consent is given.
    @isTest static void defaultsAndConsentStamped() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        LeadTriggerHandler.repsOverride = new List<Id>{ UserInfo.getUserId() };
        Lead l = websiteLead('C');
        l.SMS_Consent__c = true;   // consented, no source set -> trigger stamps 'Web Form'

        Test.startTest();
        insert l;
        Test.stopTest();

        Lead check = [SELECT Status, TCPA_Scrub_Status__c, SMS_Consent_Source__c, OwnerId
                      FROM Lead WHERE Id = :l.Id];
        System.assertEquals('New', check.Status);
        System.assertEquals('Pending', check.TCPA_Scrub_Status__c);
        System.assertEquals('Web Form', check.SMS_Consent_Source__c, 'consent source stamped for website consent');
        System.assertEquals(UserInfo.getUserId(), check.OwnerId, 'round-robin assigned the (only) eligible rep');
    }

    // Insert raises exactly one "New website lead — call" task and one LEAD_WEBSITE Slack note.
    @isTest static void alertAndTaskRaised() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        LeadTriggerHandler.repsOverride = new List<Id>{ UserInfo.getUserId() };
        Lead l = websiteLead('A');

        Test.startTest();
        insert l;
        Test.stopTest();

        System.assertEquals(1,
            [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = 'New website lead — call'],
            'one call task for the website lead');
        Integer websiteNotes = 0;
        for (SlackNotifier.Notification n : LeadTriggerHandler.lastNotes) {
            if (n.kind == 'LEAD_WEBSITE') websiteNotes++;
        }
        System.assertEquals(1, websiteNotes, 'one LEAD_WEBSITE Slack note');
    }

    // A non-website lead is neither round-robined nor given a website task/note.
    @isTest static void nonWebsiteLeadUntouched() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        LeadTriggerHandler.repsOverride = new List<Id>{ UserInfo.getUserId() };
        Lead l = new Lead(LastName = 'Vend', Company = 'Vend Co', LeadSource = 'Purchased List');

        Test.startTest();
        insert l;
        Test.stopTest();

        System.assertEquals(UserInfo.getUserId(), [SELECT OwnerId FROM Lead WHERE Id = :l.Id].OwnerId,
            'non-website lead keeps the inserting owner (no round-robin)');
        System.assertEquals(0,
            [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = 'New website lead — call'],
            'no website task for a non-website lead');
    }

    // The composed message reads "🌐 New website lead — {Name} · {business} · owner {Owner}".
    @isTest static void websiteMessageComposes() {
        SlackNotifier.Notification n = new SlackNotifier.Notification();
        n.kind = 'LEAD_WEBSITE'; n.recordName = 'Jane Prospect'; n.company = 'Prospect LLC';
        String msg = new SlackNotifier(new List<SlackNotifier.Notification>{ n }).compose(n, 'Garrett Wright');
        System.assert(msg.contains('New website lead'), 'text: ' + msg);
        System.assert(msg.contains('Jane Prospect'), 'name in text: ' + msg);
        System.assert(msg.contains('Prospect LLC'), 'business in text: ' + msg);
        System.assert(msg.contains('Garrett Wright'), 'owner in text: ' + msg);
    }
}
