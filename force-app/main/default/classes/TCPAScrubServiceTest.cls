@isTest
private class TCPAScrubServiceTest {

    @isTest static void testNormalize() {
        System.assertEquals('4077494791', TCPAScrubService.normalize('(407) 749-4791'));
        System.assertEquals(null, TCPAScrubService.normalize(''));
        System.assertEquals(null, TCPAScrubService.normalize('abc'));
        System.assertEquals(null, TCPAScrubService.normalize(null));
    }

    @isTest static void testScrubOneSendsPhoneNumberFormEncoded() {
        TCPAScrubHttpMock mock = new TCPAScrubHttpMock(200, '{"results":{"clean":1,"is_bad_number":false}}');
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        TCPAScrubService.ScrubResult r = TCPAScrubService.scrubOne('(407) 749-4791');
        Test.stopTest();
        System.assertEquals(true, r.clean);
        String sentBody = mock.lastRequest.getBody();
        System.assert(sentBody.contains('phone_number=4077494791'), 'body must carry phone_number: ' + sentBody);
        System.assert(sentBody.contains('type=all'), 'type=all preserved: ' + sentBody);
        System.assert(!sentBody.contains('"phone"'), 'must not send JSON "phone" key: ' + sentBody);
        System.assertEquals('application/x-www-form-urlencoded', mock.lastRequest.getHeader('Content-Type'));
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

    // Real mass shape: top-level "clean" map (good) + "match" array (DNC); response keys carry a leading 1.
    @isTest static void testMassCleanAndMatch() {
        String body = '{"meta":{"scrub_price":2,"coins_price":0},"match_statistics":[],'
            + '"match":[{"phone_number":"15551230002","status":"TCPA | Federal DNC","status_array":["tcpa","federal_dnc"],"is_bad_number":true,"phone_type":"mobile"}],'
            + '"clean":{"15551230001":{"phone_number":"15551230001"}}}';
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, body));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'555-123-0001','(555) 123-0002'});
        Test.stopTest();
        // Sent 10-digit; response 11-digit -> matched on last 10 digits.
        TCPAScrubService.ScrubResult cleanRes = res.get('5551230001');
        System.assertEquals(true, cleanRes.clean, 'phone under "clean" => Clear');
        System.assertEquals(false, cleanRes.isError);
        TCPAScrubService.ScrubResult dnc = res.get('5551230002');
        System.assertEquals(false, dnc.clean, 'phone in "match" => not clean');
        System.assertEquals(false, dnc.isError);
        System.assertEquals(true, dnc.isBadNumber);
        System.assertEquals('TCPA | Federal DNC', dnc.status);
        System.assertEquals(2, dnc.statusArray.size());
        System.assertEquals('mobile', dnc.phoneType);
    }

    // A single clean phone; sent digits match a clean key of equal length.
    @isTest static void testMassCleanSingle() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"clean":{"5551230099":{"phone_number":"5551230099"}},"match":[]}'));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'5551230099'});
        Test.stopTest();
        System.assertEquals(true, res.get('5551230099').clean);
        System.assertEquals(false, res.get('5551230099').isError);
    }

    // Leading-1 normalization: sent 11-digit maps to a 10-digit clean key (last-10 match).
    @isTest static void testMassLeadingOneMatch() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"clean":{"5551230077":{"phone_number":"5551230077"}},"match":[]}'));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'15551230077'});
        Test.stopTest();
        System.assertEquals(true, res.get('15551230077').clean, 'leading-1 sent digit maps to a 10-digit clean key');
    }

    // Sent phone absent from both clean and match -> Error (never default to Clear).
    @isTest static void testMassPhoneAbsentIsError() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"clean":{"5550000000":{"phone_number":"5550000000"}},"match":[]}'));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'5551230003'});
        Test.stopTest();
        System.assertEquals(true, res.get('5551230003').isError);
        System.assertEquals(false, res.get('5551230003').clean);
    }

    // Defensive: a match element without phone_number (uses 'phone') and without status still classifies DNC, no crash.
    @isTest static void testMassMatchDefensive() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"clean":{},"match":[{"phone":"5551230044"}]}'));
        Test.startTest();
        Map<String, TCPAScrubService.ScrubResult> res = TCPAScrubService.scrubPhones(new List<String>{'5551230044'});
        Test.stopTest();
        System.assertEquals(false, res.get('5551230044').isError, 'match element must classify, not error');
        System.assertEquals(false, res.get('5551230044').clean, 'in "match" => not clean => DNC');
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

    // HTTP 200 but vendor error body -> Error (never Clear/DNC), message captured + raw logged.
    @isTest static void testNotEnoughCreditsBody() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"error":"You do not have enough credits"}'));
        Test.startTest();
        TCPAScrubService.ScrubResult one = TCPAScrubService.scrubOne('5551230003');
        Map<String, TCPAScrubService.ScrubResult> mass = TCPAScrubService.scrubPhones(new List<String>{'5551230004'});
        Test.stopTest();
        System.assertEquals(true, one.isError, 'error-key body must be Error');
        System.assertEquals(false, one.clean, 'must not be clean');
        System.assert(one.errorMessage.contains('credits'), 'message captured: ' + one.errorMessage);
        System.assertEquals(true, mass.get('5551230004').isError);
        System.assert(mass.get('5551230004').rawResponse.contains('credits'), 'raw body carried for logging');
    }

    // HTTP 401 forbidden -> Error, no backup escalation (not a 5xx).
    @isTest static void test401Forbidden() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(401, '{"code":"rest_forbidden"}'));
        Test.startTest();
        TCPAScrubService.ScrubResult one = TCPAScrubService.scrubOne('5551230005');
        Map<String, TCPAScrubService.ScrubResult> mass = TCPAScrubService.scrubPhones(new List<String>{'5551230006'});
        Test.stopTest();
        System.assertEquals(true, one.isError, '401 must be Error');
        System.assertEquals(false, one.clean);
        System.assertEquals(true, mass.get('5551230006').isError);
        System.assertEquals(false, mass.get('5551230006').clean);
    }

    // 200 with results but NO clean field -> Error (ambiguous never becomes Clear or DNC).
    @isTest static void testMissingCleanField() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":{"is_bad_number":false}}'));
        Test.startTest();
        TCPAScrubService.ScrubResult one = TCPAScrubService.scrubOne('5551230007');
        Map<String, TCPAScrubService.ScrubResult> mass = TCPAScrubService.scrubPhones(new List<String>{'5551230008'});
        Test.stopTest();
        System.assertEquals(true, one.isError, 'missing clean must be Error');
        System.assertEquals(false, one.clean);
        System.assertEquals(true, mass.get('5551230008').isError);
    }

    // Unparseable clean value -> Error.
    @isTest static void testUnparseableClean() {
        Test.setMock(HttpCalloutMock.class, new TCPAScrubHttpMock(200, '{"results":{"clean":"maybe"}}'));
        Test.startTest();
        TCPAScrubService.ScrubResult one = TCPAScrubService.scrubOne('5551230012');
        Test.stopTest();
        System.assertEquals(true, one.isError, 'unparseable clean must be Error');
        System.assertEquals(false, one.clean);
    }
}
