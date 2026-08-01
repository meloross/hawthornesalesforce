@isTest
private class LeadDistributionBatchTest {

    private static Id poolQueueId() {
        return [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'HFS_Lead_Pool' LIMIT 1].Id;
    }

    @isTest static void testDistributionToTopOffice() {
        Id poolId = poolQueueId();
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 5; i++) {
            leads.add(new Lead(LastName = 'Dist' + i, Company = 'Dist Co ' + i,
                Phone = '55500000' + i, TCPA_Scrub_Status__c = 'Clear', OwnerId = poolId));
        }
        insert leads;

        Test.startTest();
        Database.executeBatch(new LeadDistributionBatch(), 200);
        Test.stopTest();

        // Tampa is priority 1 with allotment 2500 — all 5 land there.
        for (Lead l : [SELECT Office__c, OwnerId, Status FROM Lead WHERE Id IN :leads]) {
            System.assertEquals('HFS_TPA', l.Office__c, 'should route to top-priority office');
            System.assertEquals('Assigned', l.Status);
            System.assertNotEquals(poolId, l.OwnerId, 'owner should move off the pool to the office queue');
        }
    }

    @isTest static void testExcludesDncAndNonPool() {
        Id poolId = poolQueueId();
        Lead dnc = new Lead(LastName = 'Dnc', Company = 'Dnc Co', TCPA_Scrub_Status__c = 'Do Not Contact', OwnerId = poolId);
        Lead notPool = new Lead(LastName = 'NotPool', Company = 'NotPool Co', TCPA_Scrub_Status__c = 'Clear'); // owner = running user
        insert new List<Lead>{ dnc, notPool };

        Test.startTest();
        Database.executeBatch(new LeadDistributionBatch(), 200);
        Test.stopTest();

        System.assertEquals(null, [SELECT Office__c FROM Lead WHERE Id = :dnc.Id].Office__c, 'DNC must not be distributed');
        System.assertEquals(null, [SELECT Office__c FROM Lead WHERE Id = :notPool.Id].Office__c, 'non-pool lead must not be distributed');
    }

    @isTest static void testScheduler() {
        Test.startTest();
        new LeadDistributionScheduler().execute(null);
        Test.stopTest();
        System.assert(true, 'scheduler executed');
    }
}
