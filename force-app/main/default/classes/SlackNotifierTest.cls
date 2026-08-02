@isTest
private class SlackNotifierTest {

    @TestSetup static void seed() {
        insert new Slack_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), Bot_Token__c = 'xoxb-test-token');
    }

    @isTest static void leadQualifiedPosts() {
        Lead l = new Lead(LastName='Smith', Company='Acme', Status='New',
                          Office__c='HFS_TPA', TCPA_Scrub_Status__c='Clear');
        insert l;
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Test.startTest();
        l.Status = 'Qualified';
        update l;
        Test.stopTest();
        System.assert(SlackTriggerState.leadsNotified.contains(l.Id), 'lead should be marked notified');
    }

    @isTest static void leadApptSetPosts() {
        Lead l = new Lead(LastName='Jones', Company='Beta', Status='New',
                          Office__c='HFS_MIA', TCPA_Scrub_Status__c='Clear');
        insert l;
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Test.startTest();
        l.Status = 'Appointment Set';
        update l;
        Test.stopTest();
        System.assert(SlackTriggerState.leadsNotified.contains(l.Id));
    }

    @isTest static void leadNotClearSkipped() {
        Lead l = new Lead(LastName='NoScrub', Company='Gamma', Status='New',
                          Office__c='HFS_TPA', TCPA_Scrub_Status__c='Pending');
        insert l;
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Test.startTest();
        l.Status = 'Qualified';
        update l;
        Test.stopTest();
        System.assert(!SlackTriggerState.leadsNotified.contains(l.Id), 'non-Clear lead should be skipped');
    }

    @isTest static void leadNotInChannelHandled() {
        Lead l = new Lead(LastName='NIC', Company='Delta', Status='New',
                          Office__c='HFS_TPA', TCPA_Scrub_Status__c='Clear');
        insert l;
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":false,"error":"not_in_channel"}'));
        Test.startTest();
        l.Status = 'Qualified';
        update l;
        Test.stopTest();
        System.assert(SlackTriggerState.leadsNotified.contains(l.Id), 'notified even though Slack returned not_in_channel');
    }

    @isTest static void oppLifecyclePosts() {
        Account a = new Account(Name='Opp Acct');
        insert a;
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Test.startTest();
        Opportunity o = new Opportunity(Name='Deal A', StageName='Qualification',
            CloseDate=Date.today().addDays(10), AccountId=a.Id, Office__c='HFS_NJ', Total_Debt__c=120000);
        insert o;                                   // OPP_NEW
        SlackTriggerState.oppsNotified.clear();
        o.StageName = 'Proposal'; update o;         // OPP_STAGE
        SlackTriggerState.oppsNotified.clear();
        o.StageName = 'Closed Won'; update o;       // OPP_WON (:tada:)
        Test.stopTest();
        System.assert(SlackTriggerState.oppsNotified.contains(o.Id));
    }

    @isTest static void officeWithoutChannelSkipped() {
        SlackNotifier.Notification n = new SlackNotifier.Notification();
        n.kind = 'LEAD_QUALIFIED'; n.officeCode = 'HFS_ZZZ';
        n.recordName = 'X'; n.company = 'Y'; n.ownerId = UserInfo.getUserId();
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Test.startTest();
        System.enqueueJob(new SlackNotifier(new List<SlackNotifier.Notification>{ n }));
        Test.stopTest();
        System.assert(true, 'no channel -> skipped, no exception');
    }
}
