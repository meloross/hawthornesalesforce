@isTest
private class TCPAScrubServiceTest {

    @isTest static void testNormalize() {
        System.assertEquals('4077494791', TCPAScrubService.normalize('(407) 749-4791'));
        System.assertEquals(null, TCPAScrubService.normalize(''));
        System.assertEquals(null, TCPAScrubService.normalize('abc'));
        System.assertEquals(null, TCPAScrubService.normalize(null));
    }

    @isTest static void testCleanSingle() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":{"clean":1,"is_bad_number":false}}'));
        Test.startTest();
        TCPAScrubService.ScrubResult r = TCPAScrubService.scrubOne('407-749-4791');
        Test.stopTest();
        System.assertEquals(true, r.clean);
        System.assertEquals(false, r.isBadNumber);
        System.assertEquals(false, r.isError);
    }

    @isTest static void testMatchSingle() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200,
            '{"results":{"clean":0,"is_bad_number":true,"status":"TCPA | Federal DNC","status_array":["tcpa","federal_dnc"],"phone_type":"mobile"}}'));
        Test.startTest();
        TCPAScrubService.ScrubResult r = TCPAScrubService.scrubOne('4077494791');
        Test.stopTest();
        System.assertEquals(false, r.clean);
        System.assertEquals(true, r.isBadNumber);
        System.assertEquals('TCPA | Federal DNC', r.status);
        System.assertEquals(2, r.statusArray.size());
        System.assertEquals('mobile', r.phoneType);
    }

    @isTest static void testMassPhoneKeyed() {
        String body = '{"results":{"5551230001":{"clean":1,"is_bad_number":false},"5551230002":{"clean":0,"is_bad_number":true,"status":"TCPA"}}}';
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, body));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'555-123-0001','(555) 123-0002'});
        Test.stopTest();
        System.assertEquals(true, res.get('5551230001').clean);
        System.assertEquals(true, res.get('5551230002').isBadNumber);
    }

    @isTest static void testMassSingleShape() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":{"clean":1,"is_bad_number":false}}'));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'5551230099'});
        Test.stopTest();
        System.assertEquals(true, res.get('5551230099').clean);
    }

    @isTest static void testMassListShape() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":[{"phone":"5551230077","clean":1,"is_bad_number":false}]}'));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'5551230077'});
        Test.stopTest();
        System.assertEquals(true, res.get('5551230077').clean);
    }

    @isTest static void testErrorHttp() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(500, '{"error":"boom"}'));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'5551230003'});
        TCPAScrubService.ScrubResult one = TCPAScrubService.scrubOne('5551230003');
        Test.stopTest();
        System.assertEquals(true, res.get('5551230003').isError);
        System.assertEquals(true, one.isError);
    }

    @isTest static void testEmptyAndBlank() {
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'', 'xx'});
        TCPAScrubService.ScrubResult r = TCPAScrubService.scrubOne('');
        Test.stopTest();
        System.assertEquals(0, res.size());
        System.assertEquals(true, r.isError);
    }
}
