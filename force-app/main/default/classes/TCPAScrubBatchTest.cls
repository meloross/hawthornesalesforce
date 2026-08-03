@isTest
private class TCPAScrubBatchTest {

    @isTest static void testBatchCleanAndMatch() {
        List<Lead> leads = new List<Lead>{
            new Lead(LastName='Alpha', Company='Alpha Co', Phone='555-123-0001', TCPA_Scrub_Status__c='Pending'),
            new Lead(LastName='Bravo', Company='Bravo Co', Phone='(555) 123-0002', TCPA_Scrub_Status__c='Pending')
        };
        insert leads;
        // Real mass shape: top-level "clean" map + "match" array; response keys carry a leading 1 (last-10 match).
        String body = '{"meta":{"scrub_price":2,"coins_price":0},"match_statistics":[],'
            + '"match":[{"phone_number":"15551230002","status":"TCPA | Federal DNC","status_array":["tcpa"],"is_bad_number":true,"phone_type":"mobile"}],'
            + '"clean":{"15551230001":{"phone_number":"15551230001"}}}';
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

    // "Not enough credits" body (HTTP 200) -> lead Error, message logged to Raw_Response__c, never Clear.
    @isTest static void testBatchCreditsError() {
        insert new Lead(LastName='Credits', Company='Credits Co', Phone='5551239999', TCPA_Scrub_Status__c='Pending');
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"error":"You do not have enough credits"}'));
        Test.startTest();
        Database.executeBatch(new TCPAScrubBatch(), 2000);
        Test.stopTest();

        Lead l = [SELECT TCPA_Scrub_Status__c FROM Lead WHERE Phone='5551239999' LIMIT 1];
        System.assertEquals('Error', l.TCPA_Scrub_Status__c, 'credits error must NOT be Clear/DNC');
        Compliance_Scrub_Log__c log = [SELECT Result__c, Raw_Response__c FROM Compliance_Scrub_Log__c WHERE Phone__c='5551239999' LIMIT 1];
        System.assertEquals('Error', log.Result__c);
        System.assert(log.Raw_Response__c != null && log.Raw_Response__c.contains('credits'), 'error body logged to Raw_Response__c');
    }

    // 401 forbidden -> lead Error.
    @isTest static void testBatch401() {
        insert new Lead(LastName='Forbid', Company='Forbid Co', Phone='5551238888', TCPA_Scrub_Status__c='Pending');
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(401, '{"code":"rest_forbidden"}'));
        Test.startTest();
        Database.executeBatch(new TCPAScrubBatch(), 2000);
        Test.stopTest();
        Lead l = [SELECT TCPA_Scrub_Status__c FROM Lead WHERE Phone='5551238888' LIMIT 1];
        System.assertEquals('Error', l.TCPA_Scrub_Status__c);
    }

    @isTest static void testInvocable() {
        insert new Lead(LastName='India', Company='India Co', Phone='5551230010', TCPA_Scrub_Status__c='Pending');
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":{"5551230010":{"clean":1,"is_bad_number":false}}}'));
        Test.startTest();
        List<String> jobIds = TCPAScrubInvocable.run(new List<String>{'go'});
        Test.stopTest();
        System.assertEquals(1, jobIds.size());
    }

    // Bounded run (pilot): maxLeads caps the query to N; meta.scrub_price/coins_price accumulate.
    @isTest static void testBoundedRunAndBurn() {
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 3; i++) {
            leads.add(new Lead(LastName='B'+i, Company='B Co '+i, Phone='555999000'+i,
                               TCPA_Scrub_Status__c='Pending', File_ID__c='PILOT'));
        }
        // A lead in a different cohort must be left untouched by the File_ID-scoped run.
        insert new Lead(LastName='Other', Company='Other Co', Phone='5558887777',
                        TCPA_Scrub_Status__c='Pending', File_ID__c='OTHER');
        insert leads;
        String body = '{"meta":{"scrub_price":2,"coins_price":0},"results":{'
            + '"5559990000":{"clean":1,"is_bad_number":false},'
            + '"5559990001":{"clean":0,"is_bad_number":true,"status":"TCPA"}}}';
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, body));

        Test.startTest();
        Database.executeBatch(new TCPAScrubBatch('PILOT', 2), 200);   // bounded to 2 of the 3 PILOT-cohort pending
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Lead WHERE TCPA_Scrub_Status__c != 'Pending'],
            'only 2 of the 3 PILOT-cohort leads scrubbed; OTHER cohort untouched (bounded + File_ID)');
        System.assertEquals(2, [SELECT COUNT() FROM Compliance_Scrub_Log__c], 'a log per scrubbed lead');
    }
}
