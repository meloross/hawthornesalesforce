/**
 * SmsSenderResolverTest — switchable-sender resolution + trigger stamping. Injects owner->number via
 * SmsSenderResolver.numberOverride (no User DML / MIXED_DML). Sends nothing.
 */
@isTest
private class SmsSenderResolverTest {

    static SMS_Sender_Config__c cfg(String mode, String dedicated) {
        SMS_Sender_Config__c c = new SMS_Sender_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(), Mode__c = mode, Dedicated_Number__c = dedicated);
        insert c;
        return c;
    }

    @isTest static void perRepReturnsOwnerNumber() {
        cfg('PerRep', '+13125550999');
        SmsSenderResolver.numberOverride = new Map<Id, String>{ UserInfo.getUserId() => '+13125550111' };
        Test.startTest();
        String n = SmsSenderResolver.resolveSenderForOwner(UserInfo.getUserId());
        Test.stopTest();
        System.assertEquals('+13125550111', n, 'PerRep -> owner number');
    }

    @isTest static void perRepFallsBackWhenOwnerHasNoNumber() {
        cfg('PerRep', '+13125550999');
        SmsSenderResolver.numberOverride = new Map<Id, String>{ UserInfo.getUserId() => null };
        Test.startTest();
        String n = SmsSenderResolver.resolveSenderForOwner(UserInfo.getUserId());
        Test.stopTest();
        System.assertEquals('+13125550999', n, 'no owner number -> Dedicated fallback');
    }

    @isTest static void queueOwnerFallsBackToDedicated() {
        cfg('PerRep', '+13125550999');
        Group q = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Tampa_Leads' LIMIT 1];
        Test.startTest();
        String n = SmsSenderResolver.resolveSenderForOwner(q.Id);
        Test.stopTest();
        System.assertEquals('+13125550999', n, 'queue owner -> Dedicated fallback');
    }

    @isTest static void dedicatedModeAlwaysDedicated() {
        cfg('Dedicated', '+13125550999');
        SmsSenderResolver.numberOverride = new Map<Id, String>{ UserInfo.getUserId() => '+13125550111' };
        Test.startTest();
        String n = SmsSenderResolver.resolveSenderForOwner(UserInfo.getUserId());
        Test.stopTest();
        System.assertEquals('+13125550999', n, 'Dedicated mode ignores rep number');
    }

    @isTest static void unsetConfigDefaultsToPerRep() {
        // No config inserted -> getOrgDefaults null -> PerRep, dedicated null.
        Test.startTest();
        String n = SmsSenderResolver.resolveSenderForOwner(UserInfo.getUserId());
        Test.stopTest();
        System.assertEquals(null, n, 'unset config: PerRep, no owner number, no dedicated -> null');
    }

    @isTest static void stampSendersBulk() {
        cfg('PerRep', '+13125550999');
        SmsSenderResolver.numberOverride = new Map<Id, String>{ UserInfo.getUserId() => '+13125550122' };
        List<Lead> ls = new List<Lead>();
        for (Integer i = 0; i < 3; i++) ls.add(new Lead(LastName = 'SND' + i, Company = 'SNDCo' + i, OwnerId = UserInfo.getUserId()));
        Test.startTest();
        SmsSenderResolver.stampSenders(ls);
        Test.stopTest();
        for (Lead l : ls) System.assertEquals('+13125550122', l.Outbound_SMS_Number__c);
    }

    @isTest static void triggerStampsOnInsert() {
        cfg('PerRep', '+13125550999');
        SmsSenderResolver.numberOverride = new Map<Id, String>{ UserInfo.getUserId() => '+13125550133' };
        Lead l = new Lead(FirstName = 'Snd', LastName = 'TrigStamp', Company = 'SndTrigCo');
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.duplicateRuleHeader.allowSave = true;
        Test.startTest();
        Database.insert(l, dml);   // owner defaults to running user; trigger stamps Outbound_SMS_Number__c
        Test.stopTest();
        System.assertEquals('+13125550133',
            [SELECT Outbound_SMS_Number__c FROM Lead WHERE Id = :l.Id].Outbound_SMS_Number__c,
            'trigger stamped the resolved sender on insert');
    }
}
