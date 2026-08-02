@isTest
private class LeadMarketingEngineTest {

    @TestSetup
    static void seed() {
        insert new App_Secret__c(Name = 'Slack_Bot_Token', Secret_Value__c = 'xoxb-test-token');
    }

    // Clear + consented leads (Status='New'), ready to transition. Office HFS_TPA has a Slack channel.
    static List<Lead> makeClearLeads(Integer n) {
        List<Lead> ls = new List<Lead>();
        for (Integer i = 0; i < n; i++) {
            ls.add(new Lead(
                LastName = 'Drip' + i, Company = 'Co ' + i, Status = 'New',
                Office__c = 'HFS_TPA', TCPA_Scrub_Status__c = 'Clear',
                SMS_Consent__c = true));
        }
        return ls;
    }

    static Map<Id, Lead> priorMap(List<Lead> ls) {
        return new Map<Id, Lead>([
            SELECT Id, Status, Call_Disposition__c, TCPA_Scrub_Status__c,
                   SMS_Opt_Out__c, Global_DNC__c, Current_Drip__c
            FROM Lead WHERE Id IN :ls]);
    }

    @isTest
    static void statusTransitionsSetDrips() {
        List<Lead> ls = makeClearLeads(6);
        insert ls;
        Map<Id, Lead> old = priorMap(ls);
        ls[0].Status = 'Assigned';
        ls[1].Status = 'Qualified';
        ls[2].Status = 'Appointment Set';
        ls[3].Status = 'No Show';
        ls[4].Status = 'Nurture';
        ls[5].Status = 'Converted';

        Test.startTest();
        LeadTriggerHandler.handleBefore(ls, old);
        Test.stopTest();

        System.assertEquals('Speed-to-Lead', ls[0].Current_Drip__c);
        System.assertNotEquals(null, ls[0].Speed_to_Lead_At__c);
        System.assertNotEquals(null, ls[0].Drip_Entered_At__c);
        System.assertEquals('Drive-to-Appointment', ls[1].Current_Drip__c);
        System.assertEquals('Confirm-Remind', ls[2].Current_Drip__c);
        System.assertEquals('Reschedule', ls[3].Current_Drip__c);
        System.assertEquals('Nurture', ls[4].Current_Drip__c);
        System.assertEquals('Onboarding', ls[5].Current_Drip__c);
    }

    @isTest
    static void disqualifiedSoftSetsWinBack() {
        List<Lead> ls = makeClearLeads(2);
        insert ls;
        Map<Id, Lead> old = priorMap(ls);
        // soft DQ (Not Interested) -> win-back eligible; hard DQ (Duplicate) -> not
        ls[0].Status = 'Disqualified'; ls[0].Call_Disposition__c = 'Not Interested';
        ls[1].Status = 'Disqualified'; ls[1].Call_Disposition__c = 'Duplicate';
        LeadTriggerHandler.handleBefore(ls, old);
        System.assertEquals('None', ls[0].Current_Drip__c);
        System.assertEquals(true, ls[0].Win_Back_Eligible__c, 'Not Interested is soft DQ');
        System.assertEquals('None', ls[1].Current_Drip__c);
        System.assertEquals(false, ls[1].Win_Back_Eligible__c, 'Duplicate is hard DQ');
    }

    @isTest
    static void dispositionBranches() {
        List<Lead> ls = makeClearLeads(9);
        insert ls;
        Map<Id, Lead> old = priorMap(ls);
        ls[0].Call_Disposition__c = 'No Answer';
        ls[1].Call_Disposition__c = 'Left Voicemail';
        ls[2].Call_Disposition__c = 'Contacted - Interested';
        ls[3].Call_Disposition__c = 'Not Interested';
        ls[4].Call_Disposition__c = 'Do Not Call';
        ls[5].Call_Disposition__c = 'Bad/Wrong Number';
        ls[6].Call_Disposition__c = 'Already Enrolled Elsewhere';
        ls[7].Call_Disposition__c = 'Language Barrier';
        ls[8].Call_Disposition__c = 'Duplicate';

        LeadTriggerHandler.handleBefore(ls, old);

        System.assertEquals('Persistence', ls[0].Current_Drip__c);
        System.assertEquals('Persistence', ls[1].Current_Drip__c);
        System.assertEquals('Warm-Support', ls[2].Current_Drip__c);
        System.assertEquals('Nurture', ls[3].Current_Drip__c);
        // Do Not Call -> suppress all + disqualify
        System.assertEquals(true, ls[4].SMS_Opt_Out__c);
        System.assertEquals(true, ls[4].Global_DNC__c);
        System.assertEquals('None', ls[4].Current_Drip__c);
        System.assertEquals('Disqualified', ls[4].Status);
        // Bad number
        System.assertEquals(true, ls[5].Bad_Number__c);
        // Already Enrolled / Duplicate -> None
        System.assertEquals('None', ls[6].Current_Drip__c);
        System.assertEquals('None', ls[8].Current_Drip__c);
        // Language barrier
        System.assertEquals(true, ls[7].Needs_Language_Reassignment__c);
    }

    @isTest
    static void eligibilityGateBlocksDrip() {
        // Not TCPA-Clear -> no drip on status advance
        List<Lead> ls = new List<Lead>{
            new Lead(LastName='Pending', Company='PendCo', Status='New',
                     Office__c='HFS_TPA', TCPA_Scrub_Status__c='Pending', SMS_Consent__c=true)
        };
        insert ls;
        Map<Id, Lead> old = priorMap(ls);
        ls[0].Status = 'Qualified';
        LeadTriggerHandler.handleBefore(ls, old);
        System.assertNotEquals('Drive-to-Appointment', ls[0].Current_Drip__c, 'ineligible lead must not enter a drip');
        System.assert(String.isBlank(ls[0].Current_Drip__c), 'no drip entered for an ineligible lead (unchanged)');
    }

    @isTest
    static void assignedEndToEndViaTrigger() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = makeClearLeads(1)[0];
        insert l;
        Test.startTest();
        l.Status = 'Assigned';
        update l;   // fires trigger -> before(drip) + after(task + slack)
        Test.stopTest();

        Lead check = [SELECT Current_Drip__c, Speed_to_Lead_At__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Speed-to-Lead', check.Current_Drip__c);
        System.assertNotEquals(null, check.Speed_to_Lead_At__c);
        List<Task> tasks = [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject = 'Call now — new clear lead'];
        System.assertEquals(1, tasks.size(), 'one speed-to-lead call task');
    }

    @isTest
    static void callbackRequestedCreatesTask() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = makeClearLeads(1)[0];
        insert l;
        Test.startTest();
        l.Call_Disposition__c = 'Callback Requested';
        update l;
        Test.stopTest();
        List<Task> tasks = [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject = 'Callback requested — follow up'];
        System.assertEquals(1, tasks.size());
    }

    @isTest
    static void setOptOutExitsDrip() {
        Lead l = makeClearLeads(1)[0];
        l.Current_Drip__c = 'Nurture';
        insert l;
        Test.startTest();
        LeadMarketingService.setOptOut(new Set<Id>{ l.Id });
        Test.stopTest();
        Lead check = [SELECT SMS_Opt_Out__c, Current_Drip__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, check.SMS_Opt_Out__c);
        System.assertEquals('None', check.Current_Drip__c);
    }

    @isTest
    static void recordEngagementStampsAndAlerts() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = makeClearLeads(1)[0];
        insert l;
        Test.startTest();
        LeadMarketingService.recordEngagement(l.Id, 'SMS Reply');
        Test.stopTest();
        Lead check = [SELECT Last_Engagement_Type__c, Last_Engagement_At__c, Reply_Received__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('SMS Reply', check.Last_Engagement_Type__c);
        System.assertNotEquals(null, check.Last_Engagement_At__c);
        System.assertEquals(true, check.Reply_Received__c);
        List<Task> tasks = [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject = 'Lead engaged — follow up'];
        System.assertEquals(1, tasks.size());
    }

    @isTest
    static void invocablesWork() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l1 = makeClearLeads(1)[0]; insert l1;
        Lead l2 = makeClearLeads(1)[0]; insert l2;
        Test.startTest();
        LeadOptOutInvocable.setOptOut(new List<Id>{ l1.Id });
        LeadEngagementInvocable.Request r = new LeadEngagementInvocable.Request();
        r.leadId = l2.Id; r.engagementType = 'Email Click';
        LeadEngagementInvocable.record(new List<LeadEngagementInvocable.Request>{ r });
        Test.stopTest();
        System.assertEquals(true, [SELECT SMS_Opt_Out__c FROM Lead WHERE Id = :l1.Id].SMS_Opt_Out__c);
        System.assertEquals('Email Click', [SELECT Last_Engagement_Type__c FROM Lead WHERE Id = :l2.Id].Last_Engagement_Type__c);
    }

    @isTest
    static void bulkAssignedIsSafe() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        List<Lead> ls = makeClearLeads(200);
        insert ls;
        for (Lead l : ls) l.Status = 'Assigned';
        Test.startTest();
        update ls;   // one DML, 200 records
        Test.stopTest();
        Integer drips = [SELECT COUNT() FROM Lead WHERE Id IN :ls AND Current_Drip__c = 'Speed-to-Lead'];
        System.assertEquals(200, drips, 'all 200 entered Speed-to-Lead');
        Integer tasks = [SELECT COUNT() FROM Task WHERE Subject = 'Call now — new clear lead'];
        System.assertEquals(200, tasks, 'one call task per assigned lead');
    }
}
