/**
 * KloudiServiceTest — outbound Kloudi (addContact, sendSms, compliance-gated sendToLead, invocable).
 * All callouts are mocked (SlackHttpMock is a generic HttpCalloutMock) — NO real messages are sent.
 */
@isTest
private class KloudiServiceTest {

    @TestSetup static void seed() {
        insert new App_Secret__c(Name = 'KLOUDI_API', Secret_Value__c = 'kloudi-test-token');
    }

    static Integer seq = 0;
    static Lead makeLead(String tcpa, Boolean consent, Boolean optout) {
        seq++;
        Lead l = new Lead(FirstName = 'KL', LastName = 'OutTest' + seq, Company = 'KLOutCo' + seq,
            Phone = '415555' + String.valueOf(1000 + seq),
            TCPA_Scrub_Status__c = tcpa, SMS_Consent__c = consent, SMS_Opt_Out__c = optout,
            Local_Timezone__c = 'America/New_York');
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.duplicateRuleHeader.allowSave = true;   // fuzzy matcher treats the numeric suffixes as dupes
        Database.insert(l, dml);
        return l;
    }

    @isTest static void addContactPosts() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Lead l = makeLead('Clear', true, false);
        Test.startTest();
        KloudiService.KloudiResult r = KloudiService.addContact('list123', l);
        Test.stopTest();
        System.assertEquals(true, r.ok, 'addContact should be 2xx');
    }

    @isTest static void sendSmsRawPosts() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        Test.startTest();
        KloudiService.KloudiResult r = KloudiService.sendSms('+15551110000', '+14155550100', 'hi');
        Test.stopTest();
        System.assertEquals(true, r.ok);
        System.assertEquals(true, r.sent);
    }

    @isTest static void compliantSendGoes() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        KloudiService.nowOverride = Datetime.newInstanceGmt(2026, 1, 15, 18, 0, 0);   // ~1–2pm ET -> inside
        Lead l = makeLead('Clear', true, false);
        Test.startTest();
        KloudiService.KloudiResult r = KloudiService.sendToLead(l.Id, '+15551110000', 'hello');
        Test.stopTest();
        System.assertEquals(null, r.skipReason, 'should not skip: ' + r.skipReason);
        System.assertEquals(true, r.sent);
    }

    @isTest static void gateBlocksConsentTcpaOptout() {
        KloudiService.nowOverride = Datetime.newInstanceGmt(2026, 1, 15, 18, 0, 0);   // inside quiet hours
        Lead pend = makeLead('Pending', true, false);
        Lead noConsent = makeLead('Clear', false, false);
        Lead optd = makeLead('Clear', true, true);
        Test.startTest();
        System.assertEquals('not_tcpa_clear', KloudiService.sendToLead(pend.Id, 's', 'm').skipReason);
        System.assertEquals('no_sms_consent', KloudiService.sendToLead(noConsent.Id, 's', 'm').skipReason);
        System.assertEquals('opted_out', KloudiService.sendToLead(optd.Id, 's', 'm').skipReason);
        Test.stopTest();
    }

    @isTest static void gateBlocksQuietHours() {
        // 06:00 UTC = 10pm PT / 1am ET — outside 8a–9p in every continental US zone (test phone derives Pacific).
        KloudiService.nowOverride = Datetime.newInstanceGmt(2026, 1, 15, 6, 0, 0);
        Lead l = makeLead('Clear', true, false);
        Test.startTest();
        System.assertEquals('outside_quiet_hours', KloudiService.sendToLead(l.Id, 's', 'm').skipReason);
        Test.stopTest();
    }

    @isTest static void invocableSendsWhenClear() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));
        KloudiService.nowOverride = Datetime.newInstanceGmt(2026, 1, 15, 18, 0, 0);
        Lead l = makeLead('Clear', true, false);
        KloudiService.SmsRequest req = new KloudiService.SmsRequest();
        req.leadId = l.Id; req.source = '+15551110000'; req.message = 'hey';
        Test.startTest();
        KloudiService.sendViaKloudi(new List<KloudiService.SmsRequest>{ req });
        Test.stopTest();   // queueable runs here
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject LIKE 'SMS skipped%'],
            'clear lead -> sent, no skip log');
    }

    @isTest static void invocableSkipLogsTask() {
        KloudiService.nowOverride = Datetime.newInstanceGmt(2026, 1, 15, 18, 0, 0);
        Lead l = makeLead('Pending', true, false);   // not clear -> skip
        KloudiService.SmsRequest req = new KloudiService.SmsRequest();
        req.leadId = l.Id; req.source = 's'; req.message = 'm';
        Test.startTest();
        KloudiService.sendViaKloudi(new List<KloudiService.SmsRequest>{ req });
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject LIKE 'SMS skipped (Kloudi)%'],
            'skip persisted as a Task');
    }

    @isTest static void noTokenNoSend() {
        delete [SELECT Id FROM App_Secret__c WHERE Name = 'KLOUDI_API'];
        Test.startTest();
        KloudiService.KloudiResult r = KloudiService.sendSms('s', 'd', 'm');
        Test.stopTest();
        System.assertEquals('no_token_configured', r.error);
        System.assertEquals(false, r.sent);
    }
}
