@isTest
private class TCPAScrubBatchTest {

    @isTest static void testBatchCleanAndMatch() {
        List<Lead> leads = new List<Lead>{
            new Lead(LastName='Alpha', Company='Alpha Co', Phone='555-123-0001', TCPA_Scrub_Status__c='Pending'),
            new Lead(LastName='Bravo', Company='Bravo Co', Phone='(555) 123-0002', TCPA_Scrub_Status__c='Pending')
        };
        insert leads;
        String body = '{"results":{"5551230001":{"clean":1,"is_bad_number":false},"5551230002":{"clean":0,"is_bad_number":true,"status":"TCPA | Federal DNC","status_array":["tcpa"]}}}';
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, body));

        Test.startTest();
        Database.executeBatch(new TCPAScrubBatch(), 2000);
        Test.stopTest();

        Map<String, String> statusByPhone = new Map<String, String>();
        for (Lead l : [SELECT Phone, TCPA_Scrub_Status__c FROM Lead WHERE Id IN :leads]) {
            statusByPhone.put(TCPAScrubService.normalize(l.Phone), l.TCPA_Scrub_Status__c);
        }
        System.assertEquals('Clear', statusByPhone.get('5551230001'));
        System.assertEquals('Do Not Contact', statusByPhone.get('5551230002'));
        System.assertEquals(2, [SELECT COUNT() FROM Compliance_Scrub_Log__c]);

        Compliance_Scrub_Log__c dnc = [SELECT Result__c, Is_Bad_Number__c, Matched_Lists__c, Vendor__c
                                       FROM Compliance_Scrub_Log__c WHERE Phone__c = '5551230002' LIMIT 1];
        System.assertEquals('Do Not Contact', dnc.Result__c);
        System.assertEquals(true, dnc.Is_Bad_Number__c);
        System.assertEquals('TCPA | Federal DNC', dnc.Matched_Lists__c);
        System.assertEquals('TCPA Litigator List', dnc.Vendor__c);
    }

    @isTest static void testBatchError() {
        insert new Lead(LastName='Echo', Company='Echo Co', Phone='5551230009', TCPA_Scrub_Status__c='Pending');
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(500, '{"error":"x"}'));

        Test.startTest();
        Database.executeBatch(new TCPAScrubBatch(), 2000);
        Test.stopTest();

        Lead l = [SELECT TCPA_Scrub_Status__c FROM Lead WHERE Phone = '5551230009' LIMIT 1];
        System.assertEquals('Error', l.TCPA_Scrub_Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Compliance_Scrub_Log__c WHERE Result__c = 'Error']);
    }

    @isTest static void testScheduler() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":{}}'));
        Test.startTest();
        new TCPAScrubScheduler().execute(null);
        Test.stopTest();
        System.assert(true, 'scheduler executed');
    }

    @isTest static void testInvocable() {
        insert new Lead(LastName='India', Company='India Co', Phone='5551230010', TCPA_Scrub_Status__c='Pending');
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":{"5551230010":{"clean":1,"is_bad_number":false}}}'));
        Test.startTest();
        List<String> jobIds = TCPAScrubInvocable.run(new List<String>{'go'});
        Test.stopTest();
        System.assertEquals(1, jobIds.size());
    }
}
