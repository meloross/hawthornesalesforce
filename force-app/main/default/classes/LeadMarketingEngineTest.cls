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
                   SMS_Opt_Out__c, Global_DNC__c, Current_Drip__c, Phone, State,
                   Reply_Received__c, Last_Engagement_Type__c, Local_Timezone__c
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
        // Win-back = TRUE on any SOFT disqualification; FALSE only for the hard-suppress dispositions.
        List<Lead> ls = makeClearLeads(6);
        insert ls;
        Map<Id, Lead> old = priorMap(ls);
        // SOFT -> win-back eligible
        ls[0].Status = 'Disqualified'; ls[0].Call_Disposition__c = 'Not Interested';
        ls[1].Status = 'Disqualified'; ls[1].Call_Disposition__c = 'Already Enrolled Elsewhere';
        ls[2].Status = 'Disqualified'; // no disposition at all -> still soft
        // HARD-suppress -> NOT eligible
        ls[3].Status = 'Disqualified'; ls[3].Call_Disposition__c = 'Duplicate';
        ls[4].Status = 'Disqualified'; ls[4].Call_Disposition__c = 'Bad/Wrong Number';
        ls[5].Status = 'Disqualified'; ls[5].Call_Disposition__c = 'Do Not Call';

        LeadTriggerHandler.handleBefore(ls, old);

        System.assertEquals(true,  ls[0].Win_Back_Eligible__c, 'Not Interested is soft DQ');
        System.assertEquals(true,  ls[1].Win_Back_Eligible__c, 'Already Enrolled Elsewhere is soft DQ');
        System.assertEquals(true,  ls[2].Win_Back_Eligible__c, 'blank disposition is soft DQ');
        System.assertEquals(false, ls[3].Win_Back_Eligible__c, 'Duplicate is hard-suppress');
        System.assertEquals(false, ls[4].Win_Back_Eligible__c, 'Bad/Wrong Number is hard-suppress');
        System.assertEquals(false, ls[5].Win_Back_Eligible__c, 'Do Not Call is hard-suppress');
        for (Lead l : ls) System.assertEquals('None', l.Current_Drip__c, 'Disqualified exits any drip');
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
        Lead check = [SELECT SMS_Opt_Out__c, Current_Drip__c, SMS_Opt_Out_Date__c, SMS_Opt_Out_Source__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, check.SMS_Opt_Out__c);
        System.assertEquals('None', check.Current_Drip__c);
        System.assertNotEquals(null, check.SMS_Opt_Out_Date__c, 'opt-out date stamped by the trigger');
        System.assertEquals('Inbound STOP', check.SMS_Opt_Out_Source__c, 'setOptOut labels the source');
    }

    // Opt-out stamped when SMS_Opt_Out__c is flipped true directly (e.g. Marketing Cloud sync); source defaults to System.
    @isTest
    static void optOutStampViaTrigger() {
        Lead l = makeClearLeads(1)[0];
        insert l;
        Test.startTest();
        l.SMS_Opt_Out__c = true;
        update l;
        Test.stopTest();
        Lead check = [SELECT SMS_Opt_Out_Date__c, SMS_Opt_Out_Source__c FROM Lead WHERE Id = :l.Id];
        System.assertNotEquals(null, check.SMS_Opt_Out_Date__c);
        System.assertEquals('System', check.SMS_Opt_Out_Source__c);
    }

    // Timezone derived on insert: an 813 (Tampa) number resolves to Eastern; office fallback also Eastern.
    @isTest
    static void timezoneDerivedOnInsert() {
        Lead byPhone = new Lead(LastName='TZ', Company='TZ Co', Status='New', Office__c='HFS_TPA',
                                TCPA_Scrub_Status__c='Clear', Phone='(415) 555-0100');  // 415 = Pacific
        insert byPhone;
        System.assertEquals('America/Los_Angeles',
            [SELECT Local_Timezone__c FROM Lead WHERE Id = :byPhone.Id].Local_Timezone__c,
            'area code 415 -> Pacific');

        Lead byOffice = new Lead(LastName='TZ2', Company='TZ Co2', Status='New', Office__c='HFS_TPA',
                                 TCPA_Scrub_Status__c='Clear');  // no phone/state -> office default ET
        insert byOffice;
        System.assertEquals('America/New_York',
            [SELECT Local_Timezone__c FROM Lead WHERE Id = :byOffice.Id].Local_Timezone__c,
            'no phone/state -> office (Tampa) default Eastern');
    }

    // Engagement hand-off fires exactly once on a warm reply, with the LEAD_REPLIED Slack note + task.
    @isTest
    static void engagementHandOffFires() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = makeClearLeads(1)[0];
        insert l;
        Test.startTest();
        l.Reply_Received__c = true;
        l.Last_Engagement_Type__c = 'SMS Reply';
        update l;
        Test.stopTest();
        System.assertEquals(1,
            [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = 'Lead replied — respond'],
            'one hand-off task');
        List<SlackNotifier.Notification> notes = LeadTriggerHandler.lastNotes;
        Integer replied = 0;
        for (SlackNotifier.Notification n : notes) if (n.kind == 'LEAD_REPLIED') replied++;
        System.assertEquals(1, replied, 'one LEAD_REPLIED Slack note');
    }

    // A non-warm engagement type (Email Open) with no reply flip does NOT raise the hand-off.
    @isTest
    static void nonWarmEngagementNoHandOff() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = makeClearLeads(1)[0];
        insert l;
        Test.startTest();
        l.Last_Engagement_Type__c = 'Email Open';   // not warm, and Reply_Received__c stays false
        update l;
        Test.stopTest();
        System.assertEquals(0,
            [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = 'Lead replied — respond'],
            'Email Open alone is not a warm hand-off');
    }

    // The composed LEAD_REPLIED message reads "🔥 {Lead} replied — {type} · owner {Owner}".
    @isTest
    static void repliedMessageComposes() {
        SlackNotifier.Notification n = new SlackNotifier.Notification();
        n.kind = 'LEAD_REPLIED'; n.recordName = 'Jane Doe'; n.detail = 'SMS Reply';
        String msg = new SlackNotifier(new List<SlackNotifier.Notification>{ n }).compose(n, 'Garrett Wright');
        System.assert(msg.contains('Jane Doe replied'), 'text: ' + msg);
        System.assert(msg.contains('SMS Reply'), 'type in text: ' + msg);
        System.assert(msg.contains('Garrett Wright'), 'owner in text: ' + msg);
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
        // recordEngagement now writes fields only; the trigger raises the single "Lead replied — respond" hand-off.
        List<Task> tasks = [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject = 'Lead replied — respond'];
        System.assertEquals(1, tasks.size(), 'exactly one hand-off task, no double-fire');
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

    // Bulk distribution to one office -> ONE per-office summary Slack post; a single assignment to another
    // office in the same transaction -> a per-lead post. Every lead ALWAYS gets its own "call now" Task.
    @isTest
    static void bulkAssignSummaryVsSingle() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        List<Lead> ls = new List<Lead>();
        for (Integer i = 0; i < 3; i++) {   // 3 to Tampa (bulk)
            ls.add(new Lead(LastName='TPA'+i, Company='Co'+i, Status='New',
                            Office__c='HFS_TPA', TCPA_Scrub_Status__c='Clear', SMS_Consent__c=true));
        }
        ls.add(new Lead(LastName='MIA0', Company='CoM', Status='New',   // 1 to Miami (single)
                        Office__c='HFS_MIA', TCPA_Scrub_Status__c='Clear', SMS_Consent__c=true));
        insert ls;
        for (Lead l : ls) l.Status = 'Assigned';

        Test.startTest();
        update ls;   // one DML, mixed offices
        Test.stopTest();

        // Every assigned lead still gets its own call-now Task.
        System.assertEquals(4, [SELECT COUNT() FROM Task WHERE Subject = 'Call now — new clear lead'],
            'one call task per assigned lead, both paths');

        // Slack decision: Tampa summarized (1 bulk note, count 3), Miami per-lead (1 single note).
        List<SlackNotifier.Notification> notes = LeadTriggerHandler.lastNotes;
        System.assertNotEquals(null, notes);
        Integer bulkNotes = 0, singleNotes = 0, reported = 0;
        for (SlackNotifier.Notification n : notes) {
            if (n.kind == 'LEAD_ASSIGNED_BULK') { bulkNotes++; reported = n.leadCount; }
            else if (n.kind == 'LEAD_ASSIGNED') { singleNotes++; }
        }
        System.assertEquals(1, bulkNotes, 'one per-office summary for the 3 Tampa leads');
        System.assertEquals(3, reported, 'summary reports the office count');
        System.assertEquals(1, singleNotes, 'one per-lead post for the single Miami assignment');
    }

    // The composed bulk summary reads "N new clear leads assigned to <Office> — top of queue".
    @isTest
    static void bulkSummaryMessageComposes() {
        SlackNotifier.Notification n = new SlackNotifier.Notification();
        n.kind = 'LEAD_ASSIGNED_BULK'; n.officeCode = 'HFS_TPA'; n.leadCount = 7;
        String msg = new SlackNotifier(new List<SlackNotifier.Notification>{ n }).compose(n, 'Unassigned');
        System.assert(msg.contains('7 new clear leads assigned to Tampa'), 'summary text: ' + msg);
        System.assert(msg.contains('top of queue'), 'summary text: ' + msg);
    }
}
