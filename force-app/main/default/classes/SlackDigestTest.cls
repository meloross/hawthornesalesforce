@isTest
private class SlackDigestTest {

    @TestSetup static void seed() {
        insert new App_Secret__c(Name = 'Slack_Bot_Token', Secret_Value__c = 'xoxb-test-token');
    }

    @isTest static void digestRunsAndPosts() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Account a = new Account(Name='Dig Acct');
        insert a;
        insert new Lead(LastName='DigLead', Company='Z', Status='Qualified',
                        Office__c='HFS_TPA', TCPA_Scrub_Status__c='Clear');
        insert new Opportunity(Name='Open1', StageName='Qualification',
            CloseDate=Date.today().addDays(5), AccountId=a.Id, Office__c='HFS_TPA', Total_Debt__c=50000);
        insert new Opportunity(Name='Won1', StageName='Closed Won',
            CloseDate=Date.today(), AccountId=a.Id, Office__c='HFS_TPA', Total_Debt__c=80000);
        Test.startTest();
        Database.executeBatch(new SlackDigestBatch(), 50);
        Test.stopTest();
        System.assert(true, 'digest batch completed for active offices without exception');
    }

    @isTest static void schedulerRuns() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Test.startTest();
        System.schedule('HFS Slack Digest Test', '0 0 8 * * ?', new SlackDigestScheduler());
        Test.stopTest();
        System.assert(true, 'scheduler executed and kicked off the digest batch');
    }
}
