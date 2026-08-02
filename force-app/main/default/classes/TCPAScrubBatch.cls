/**
 * TCPAScrubBatch — scrubs Pending leads against TCPA Litigator List.
 * Updates Lead.TCPA_Scrub_Status__c and writes a Compliance_Scrub_Log__c per lead.
 * Run with scope 2000 (mass endpoint returns up to 3000 inline with small_list=true).
 */
public with sharing class TCPAScrubBatch implements Database.Batchable<sObject>, Database.AllowsCallouts, Database.Stateful {

    public Integer totalProcessed = 0;
    public Integer clearCount = 0;
    public Integer dncCount = 0;
    public Integer errorCount = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Phone, TCPA_Scrub_Status__c
            FROM Lead
            WHERE TCPA_Scrub_Status__c = 'Pending' AND Phone != null
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Lead> scope) {
        Map<Id, String> leadToDigits = new Map<Id, String>();
        List<String> phones = new List<String>();
        for (Lead l : scope) {
            String d = TCPAScrubService.normalize(l.Phone);
            leadToDigits.put(l.Id, d);
            if (d != null) phones.add(d);
        }

        Map<String, TCPAScrubService.ScrubResult> results;
        try {
            results = TCPAScrubService.scrubPhones(phones);
        } catch (Exception e) {
            results = new Map<String, TCPAScrubService.ScrubResult>();
        }

        List<Lead> toUpdate = new List<Lead>();
        List<Compliance_Scrub_Log__c> logs = new List<Compliance_Scrub_Log__c>();
        String jobKey = (bc != null && bc.getJobId() != null) ? String.valueOf(bc.getJobId()) : null;
        Datetime nowTs = Datetime.now();
        Id poolId = poolQueueId();

        for (Lead l : scope) {
            String d = leadToDigits.get(l.Id);
            TCPAScrubService.ScrubResult r = (d != null && results.containsKey(d)) ? results.get(d) : null;

            Compliance_Scrub_Log__c log = new Compliance_Scrub_Log__c();
            log.Lead__c = l.Id;
            log.Phone__c = d;
            log.Vendor__c = 'TCPA Litigator List';
            log.Job_Key__c = jobKey;
            log.Scrubbed_At__c = nowTs;

            String status;
            if (r == null || r.isError) {
                status = 'Error';
                log.Result__c = 'Error';
                log.Clean__c = false;
                log.Is_Bad_Number__c = (r != null) ? r.isBadNumber : false;
                if (r != null) {
                    log.Matched_Lists__c = truncate(r.errorMessage, 255);
                    log.Phone_Type__c = r.phoneType;
                    log.Raw_Response__c = r.rawResponse;
                }
                errorCount++;
            } else {
                Boolean isClean = (r.clean == true);
                Boolean isBad = (r.isBadNumber == true);
                if (isClean && !isBad) {
                    status = 'Clear';
                    log.Result__c = 'Clear';
                    clearCount++;
                } else {
                    status = 'Do Not Contact';
                    log.Result__c = 'Do Not Contact';
                    dncCount++;
                }
                log.Clean__c = isClean;
                log.Is_Bad_Number__c = isBad;
                log.Matched_Lists__c = truncate(r.status, 255);
                log.Phone_Type__c = r.phoneType;
                log.Raw_Response__c = r.rawResponse;
            }

            l.TCPA_Scrub_Status__c = status;
            // Clear leads flow into the pool so LeadDistributionBatch can allot them to offices.
            if (status == 'Clear' && poolId != null) {
                l.OwnerId = poolId;
            }
            toUpdate.add(l);
            logs.add(log);
            totalProcessed++;
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        if (!logs.isEmpty()) insert logs;
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('TCPAScrubBatch finished. processed=' + totalProcessed
            + ' clear=' + clearCount + ' dnc=' + dncCount + ' error=' + errorCount);
        // DECOUPLED 2026-08-02: distribution is now manual/admin-controlled via the "Distribute Leads"
        // tool (LeadDistributionManager). Cleared leads simply PARK in HFS_Lead_Pool (OwnerId set in
        // execute() above) and wait for the admin to allocate them. The old auto-waterfall
        // (LeadDistributionBatch) is retained but intentionally no longer auto-fires here.
    }

    private static Id poolQueueId() {
        List<Group> gs = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'HFS_Lead_Pool' LIMIT 1];
        return gs.isEmpty() ? null : gs[0].Id;
    }

    private static String truncate(String s, Integer len) {
        if (s == null) return null;
        return s.length() > len ? s.substring(0, len) : s;
    }
}
