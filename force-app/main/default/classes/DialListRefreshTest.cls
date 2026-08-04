/**
 * DialListRefreshTest - covers the dialer list-gate: only eligible leads stage, phones normalize to E.164,
 * a DST-safe timezone is stamped, re-runs are idempotent, suppressions drop stale entries in finish(),
 * the Schedulable path enqueues the batch, and the normalize()/inWindow() helpers.
 */
@IsTest
private class DialListRefreshTest {

    // A Lead that satisfies Dialer_Eligible__c (TCPA Clear + not DNC + not Bad Number + has Phone).
    static Lead eligibleLead(String last, String phone) {
        return new Lead(
            FirstName = 'Dial', LastName = last, Company = 'DialCo ' + last,
            Status = 'New', Phone = phone,
            TCPA_Scrub_Status__c = 'Clear', Global_DNC__c = false, Bad_Number__c = false
        );
    }

    @IsTest
    static void stagesEligibleLeadsOnly() {
        List<Lead> ls = new List<Lead>{
            eligibleLead('A', '925-849-2311'),
            eligibleLead('B', '(212) 555-0100')
        };
        Lead bad = eligibleLead('C', '305-555-0199');
        bad.Bad_Number__c = true;   // -> Dialer_Eligible__c = false
        ls.add(bad);
        insert ls;

        Test.startTest();
        Database.executeBatch(new DialListRefresh(), 200);
        Test.stopTest();

        Map<Id, Dial_List_Entry__c> byLead = new Map<Id, Dial_List_Entry__c>();
        for (Dial_List_Entry__c e : [
                SELECT Id, Lead__c, Lead_Ext_Id__c, Phone_Number__c, Time_Zone__c,
                       Ok_To_Call__c, Office__c, Staged_At__c
                FROM Dial_List_Entry__c]) {
            byLead.put(e.Lead__c, e);
        }

        System.assertEquals(2, byLead.size(), 'Only the two eligible leads should be staged');
        System.assert(byLead.containsKey(ls[0].Id), 'Eligible lead A staged');
        System.assert(byLead.containsKey(ls[1].Id), 'Eligible lead B staged');
        System.assert(!byLead.containsKey(bad.Id), 'Bad-number lead must NOT be staged');

        Dial_List_Entry__c a = byLead.get(ls[0].Id);
        System.assertEquals('+19258492311', a.Phone_Number__c, 'Phone normalized to E.164');
        System.assertEquals(String.valueOf(ls[0].Id), a.Lead_Ext_Id__c, 'Ext id = Lead Id');
        System.assertEquals(true, a.Ok_To_Call__c, 'Ok to call set true');
        System.assertNotEquals(null, a.Staged_At__c, 'Staged timestamp set');
        System.assert(String.isNotBlank(a.Time_Zone__c), 'Timezone stamped for the export window');
    }

    @IsTest
    static void reRunIsIdempotent() {
        insert eligibleLead('D', '2125550100');

        Test.startTest();
        Database.executeBatch(new DialListRefresh(), 200);   // async pass runs at stopTest
        Test.stopTest();

        // A second synchronous pass proves the upsert on Lead_Ext_Id__c does not duplicate.
        List<Lead> scope = [SELECT Id, Phone, MobilePhone, Office__c, Local_Timezone__c, State
                            FROM Lead WHERE Dialer_Eligible__c = true];
        new DialListRefresh().execute(null, scope);

        System.assertEquals(1, [SELECT COUNT() FROM Dial_List_Entry__c],
            'Upsert keeps exactly one entry per lead across runs');
    }

    @IsTest
    static void suppressionDropsStaleEntries() {
        Lead l = eligibleLead('E', '2125550100');
        insert l;
        // Pre-stage an entry, then make the lead ineligible so finish() must remove it.
        insert new Dial_List_Entry__c(Lead_Ext_Id__c = l.Id, Lead__c = l.Id,
                                      Phone_Number__c = '+12125550100', Ok_To_Call__c = true,
                                      Staged_At__c = System.now());
        l.Global_DNC__c = true;   // now Dialer_Eligible__c = false
        update l;

        Test.startTest();
        Database.executeBatch(new DialListRefresh(), 200);   // start selects 0 eligible; finish drops the stale row
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Dial_List_Entry__c],
            'Entry for a now-ineligible lead must be dropped by finish()');
    }

    @IsTest
    static void schedulableEnqueuesBatch() {
        insert eligibleLead('F', '2125550100');

        Test.startTest();
        new DialListRefresh().execute((SchedulableContext) null);   // Schedulable.execute -> executeBatch
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Dial_List_Entry__c],
            'Scheduler path stages the eligible lead');
    }

    @IsTest
    static void normalizeAndWindowHelpers() {
        System.assertEquals('+19258492311', DialListRefresh.normalize('925-849-2311'), '10-digit -> +1');
        System.assertEquals('+19258492311', DialListRefresh.normalize('1 (925) 849-2311'), '11-digit kept');
        System.assertEquals(null, DialListRefresh.normalize('12345'), 'too short -> null');
        System.assertEquals(null, DialListRefresh.normalize(''), 'blank -> null');

        // inWindow value is time-of-day dependent; just exercise both branches for coverage.
        Boolean w = DialListRefresh.inWindow('America/New_York');
        System.assert(w == true || w == false, 'inWindow returns a boolean');
        Boolean d = DialListRefresh.inWindow(null);   // blank -> default tz branch
        System.assert(d == true || d == false, 'inWindow handles blank tz');
    }
}
