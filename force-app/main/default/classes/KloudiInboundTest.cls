/**
 * KloudiInboundTest — inbound webhook routing: STOP opt-out, matched-lead routing (keep active rep /
 * re-round-robin), no-match lead creation, task logging, LEAD_REPLIED Slack note, and the REST wrapper.
 * The enqueued Slack callout is mocked; no real messages leave.
 */
@isTest
private class KloudiInboundTest {

    @TestSetup static void seed() {
        insert new App_Secret__c(Name = 'Slack_Bot_Token', Secret_Value__c = 'xoxb-test-token');
    }

    static List<Id> reps() {
        List<Id> r = new List<Id>();
        for (User u : [SELECT Id FROM User WHERE IsActive = true AND UserType = 'Standard' ORDER BY Id LIMIT 2]) {
            r.add(u.Id);
        }
        return r;
    }

    @isTest static void stopOptsOutNoRouting() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = new Lead(LastName = 'KLstop', Company = 'KLstopCo', Phone = '4155559001', SMS_Opt_Out__c = false);
        insert l;
        Test.startTest();
        KloudiInboundService.process('{"source":"+14155559001","message":"STOP","conversation_id":"c1"}');
        Test.stopTest();
        Lead c = [SELECT SMS_Opt_Out__c, SMS_Opt_Out_Source__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, c.SMS_Opt_Out__c);
        System.assertEquals('Kloudi', c.SMS_Opt_Out_Source__c);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject LIKE 'Inbound STOP%']);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = 'Inbound SMS reply (Kloudi)'],
            'STOP does not route to a rep');
    }

    @isTest static void matchedActiveRepKept() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = new Lead(LastName = 'KLmatch', Company = 'KLmatchCo', Phone = '4155559002', OwnerId = UserInfo.getUserId());
        insert l;
        Test.startTest();
        KloudiInboundService.process('{"source":"4155559002","message":"yes interested","conversation_id":"c2","timestamp":"t"}');
        Test.stopTest();
        System.assertEquals(UserInfo.getUserId(), [SELECT OwnerId FROM Lead WHERE Id = :l.Id].OwnerId,
            'active-rep owner is kept');
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = 'Inbound SMS reply (Kloudi)']);
        System.assertEquals('LEAD_REPLIED', KloudiInboundService.lastNote.kind);
    }

    @isTest static void queueOwnedReRoundRobined() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        List<Id> rr = reps();
        System.assert(rr.size() >= 1, 'need an active standard user');
        LeadTriggerHandler.repsOverride = rr;
        Group q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Tampa_Leads' LIMIT 1];
        Lead l = new Lead(LastName = 'KLqueue', Company = 'KLqueueCo', Phone = '4155559003', OwnerId = q.Id);
        insert l;
        Test.startTest();
        KloudiInboundService.process('{"source":"4155559003","message":"call me"}');
        Test.stopTest();
        System.assertEquals(rr[0], [SELECT OwnerId FROM Lead WHERE Id = :l.Id].OwnerId,
            'queue-owned lead re-round-robined to a rep');
    }

    @isTest static void noMatchCreatesKloudiLead() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        List<Id> rr = reps();
        LeadTriggerHandler.repsOverride = rr;
        Test.startTest();
        KloudiInboundService.process('{"source":"+13125550199","message":"hi there","first_name":"Sam","last_name":"Klsmith","state":"IL","city":"Chicago","conversation_id":"c4"}');
        Test.stopTest();
        List<Lead> created = [SELECT Id, LeadSource, OwnerId, LastName, Phone, State FROM Lead WHERE Phone = '+13125550199'];
        System.assertEquals(1, created.size(), 'new Kloudi lead created');
        System.assertEquals('Kloudi SMS', created[0].LeadSource);
        System.assertEquals(rr[0], created[0].OwnerId, 'round-robin owner');
        System.assertEquals('Klsmith', created[0].LastName);
        System.assertEquals('IL', created[0].State);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhoId = :created[0].Id AND Subject = 'Inbound SMS reply (Kloudi)']);
    }

    @isTest static void restWrapperReturns200() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        LeadTriggerHandler.repsOverride = reps();
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/kloudi/inbound/6e2f5daf749068dca0e8b29ce7a33df246d7df27';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"source":"+13125550188","message":"hello"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();
        Test.startTest();
        KloudiInboundResource.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest static void badInputIsSafe() {
        KloudiInboundService.process('not json');
        KloudiInboundService.process(null);
        KloudiInboundService.process('{"message":"hi"}');   // no source
        System.assert(true, 'bad/empty input never throws');
    }
}
