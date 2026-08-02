/**
 * Tests for LeadDistributionManager — the on-demand "Distribute Leads" admin tool.
 * The pool is empty in the real org today, so all coverage is built on Apex test data:
 * Clear leads owned by the HFS_Lead_Pool queue with Office__c = null.
 *
 * Setting a lead's Status to 'Assigned' re-fires LeadTriggerHandler -> Speed-to-Lead drip + call-now
 * Task + SlackNotifier (Queueable callout). We seed the Slack token and set a Slack HTTP mock exactly
 * like LeadMarketingEngineTest, so the enqueued job succeeds after Test.stopTest().
 */
@isTest
private class LeadDistributionManagerTest {

    @TestSetup
    static void seed() {
        insert new App_Secret__c(Name = 'Slack_Bot_Token', Secret_Value__c = 'xoxb-test-token');
    }

    /** Id of the HFS_Lead_Pool queue (deployed metadata, visible in tests). */
    static Id poolQueueId() {
        return [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'HFS_Lead_Pool' LIMIT 1].Id;
    }

    /** n Clear, un-allocated leads owned by the pool queue (Office__c = null). */
    static List<Lead> makePoolLeads(Integer n) {
        Id poolId = poolQueueId();
        List<Lead> ls = new List<Lead>();
        for (Integer i = 0; i < n; i++) {
            ls.add(new Lead(
                LastName = 'Pool' + i, Company = 'Co ' + i, Status = 'New',
                Office__c = null, TCPA_Scrub_Status__c = 'Clear', OwnerId = poolId));
        }
        insert ls;
        return ls;
    }

    static LeadDistributionManager.AllocationInput alloc(String code, Decimal v) {
        LeadDistributionManager.AllocationInput a = new LeadDistributionManager.AllocationInput();
        a.officeCode = code;
        a.value = v;
        return a;
    }

    static Integer countIn(String officeCode) {
        return [SELECT COUNT() FROM Lead WHERE Office__c = :officeCode AND Status = 'Assigned'];
    }

    static Integer poolRemaining() {
        Id poolId = poolQueueId();
        return [SELECT COUNT() FROM Lead
                WHERE TCPA_Scrub_Status__c = 'Clear' AND Office__c = null AND OwnerId = :poolId];
    }

    // ---- scan on an empty pool: total 0, all 4 offices returned with resolvable queues ----
    @isTest
    static void scanEmptyPool() {
        Test.startTest();
        LeadDistributionManager.PoolScan s = LeadDistributionManager.scanPool();
        Test.stopTest();
        System.assertEquals(0, s.total, 'no leads in the pool today');
        System.assertEquals(4, s.offices.size(), 'the 4 active offices');
        for (LeadDistributionManager.OfficeInfo oi : s.offices) {
            System.assertEquals(true, oi.queueResolved, 'each office queue resolves: ' + oi.code);
        }
        System.assert(s.maxPerRun > 0, 'a per-run cap is surfaced');
    }

    // ---- 60% NJ / 40% Tampa on a 6-lead pool -> NJ 3, Tampa 2, 1 leftover pooled; oldest-first ----
    @isTest
    static void splitByPercent() {
        List<Lead> ls = makePoolLeads(6);
        // Stagger CreatedDate so oldest-first is deterministic (oldest = ls[0]).
        for (Integer i = 0; i < ls.size(); i++) {
            Test.setCreatedDate(ls[i].Id, Datetime.now().addMinutes(-100 + i));
        }
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));

        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'PERCENT', new List<LeadDistributionManager.AllocationInput>{
                alloc('HFS_NJ', 60), alloc('HFS_TPA', 40)
            });
        Test.stopTest();

        System.assertEquals(true, r.success, r.message);
        System.assertEquals(6, r.poolBefore);
        System.assertEquals(5, r.totalAssigned, '3 (NJ) + 2 (Tampa)');
        System.assertEquals(1, r.remaining, 'one leftover stays pooled');
        System.assertEquals(3, countIn('HFS_NJ'));
        System.assertEquals(2, countIn('HFS_TPA'));
        System.assertEquals(1, poolRemaining());

        // Queue-owned assignment must still create the per-lead call-now Task (owned by running user,
        // since a queue can't own a Task) — this is the regression guard for the newTask() fix.
        System.assertEquals(5, [SELECT COUNT() FROM Task WHERE Subject = 'Call now — new clear lead'],
            'one call-now task per assigned lead, no queue-owner crash');

        // Oldest-first: the 3 oldest -> NJ, the next 2 -> Tampa, newest -> pool.
        Map<Id, Lead> byId = new Map<Id, Lead>([SELECT Id, Office__c FROM Lead WHERE Id IN :ls]);
        System.assertEquals('HFS_NJ', byId.get(ls[0].Id).Office__c, 'oldest -> NJ');
        System.assertEquals('HFS_NJ', byId.get(ls[2].Id).Office__c);
        System.assertEquals('HFS_TPA', byId.get(ls[3].Id).Office__c);
        System.assertEquals('HFS_TPA', byId.get(ls[4].Id).Office__c);
        System.assertEquals(null, byId.get(ls[5].Id).Office__c, 'newest -> still pooled');
    }

    // ---- by-number split with leftovers pooled ----
    @isTest
    static void splitByNumber() {
        makePoolLeads(10);
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));

        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'NUMBER', new List<LeadDistributionManager.AllocationInput>{
                alloc('HFS_NJ', 4), alloc('HFS_MIA', 3)
            });
        Test.stopTest();

        System.assertEquals(true, r.success, r.message);
        System.assertEquals(7, r.totalAssigned);
        System.assertEquals(3, r.remaining);
        System.assertEquals(4, countIn('HFS_NJ'));
        System.assertEquals(3, countIn('HFS_MIA'));
        System.assertEquals(3, poolRemaining());
    }

    // ---- all to one office (100%) ----
    @isTest
    static void allToOneOffice() {
        makePoolLeads(5);
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true}'));

        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'PERCENT', new List<LeadDistributionManager.AllocationInput>{ alloc('HFS_NJ', 100) });
        Test.stopTest();

        System.assertEquals(true, r.success, r.message);
        System.assertEquals(5, r.totalAssigned, 'all 5 to NJ');
        System.assertEquals(0, r.remaining);
        System.assertEquals(5, countIn('HFS_NJ'));
        System.assertEquals(0, poolRemaining());
    }

    // ---- validation: percentages over 100 ----
    @isTest
    static void rejectPercentOver100() {
        makePoolLeads(4);
        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'PERCENT', new List<LeadDistributionManager.AllocationInput>{
                alloc('HFS_NJ', 70), alloc('HFS_TPA', 50)
            });
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assertEquals(0, r.totalAssigned, 'nothing assigned on a rejected run');
        System.assertEquals(4, poolRemaining(), 'pool untouched');
        System.assert(r.message.contains('100%'), r.message);
    }

    // ---- validation: numbers exceed the pool ----
    @isTest
    static void rejectNumberOverPool() {
        makePoolLeads(3);
        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'NUMBER', new List<LeadDistributionManager.AllocationInput>{ alloc('HFS_NJ', 10) });
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assertEquals(3, poolRemaining(), 'pool untouched');
        System.assert(r.message.contains('only 3'), r.message);
    }

    // ---- empty pool: distribute returns a graceful message, assigns nothing ----
    @isTest
    static void distributeEmptyPool() {
        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'PERCENT', new List<LeadDistributionManager.AllocationInput>{ alloc('HFS_NJ', 100) });
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.message.toLowerCase().contains('empty'), r.message);
    }

    // ---- per-run guard (MAX_PER_RUN lowered so we don't need 5,000 rows) ----
    @isTest
    static void rejectOverMaxPerRun() {
        makePoolLeads(5);
        LeadDistributionManager.MAX_PER_RUN = 2;
        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'NUMBER', new List<LeadDistributionManager.AllocationInput>{ alloc('HFS_NJ', 5) });
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assertEquals(5, poolRemaining(), 'pool untouched');
        System.assert(r.message.contains('maximum per run'), r.message);
    }

    // ---- bad mode is rejected ----
    @isTest
    static void rejectBadMode() {
        makePoolLeads(2);
        Test.startTest();
        LeadDistributionManager.DistributeResult r = LeadDistributionManager.distribute(
            'WEIGHTED', new List<LeadDistributionManager.AllocationInput>{ alloc('HFS_NJ', 1) });
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Invalid mode'), r.message);
    }
}
