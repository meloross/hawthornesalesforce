/**
 * LeadDistributionBatch — distributes Clear, unassigned leads from the HFS_Lead_Pool
 * to office queues per Office_Distribution_Setting__mdt allotments (priority order).
 * Idempotent: only ever touches TCPA Clear + Office__c = null leads owned by the pool.
 * Do Not Contact is excluded entirely (query is Clear-only).
 */
public with sharing class LeadDistributionBatch implements Database.Batchable<sObject>, Database.Stateful {

    public class OfficeAllot {
        public String code;
        public Id queueId;
        public Integer remaining;
    }

    public List<OfficeAllot> offices = new List<OfficeAllot>();
    public Integer currentIdx = 0;
    public Integer assignedCount = 0;
    private Id poolQueueId;

    public LeadDistributionBatch() {
        List<Office_Distribution_Setting__mdt> settings = [
            SELECT Office_Code__c, Daily_Allotment__c, Priority__c, Queue_DeveloperName__c
            FROM Office_Distribution_Setting__mdt
            WHERE Active__c = true
            ORDER BY Priority__c ASC NULLS LAST
        ];
        Set<String> devNames = new Set<String>{ 'HFS_Lead_Pool' };
        for (Office_Distribution_Setting__mdt s : settings) {
            if (String.isNotBlank(s.Queue_DeveloperName__c)) devNames.add(s.Queue_DeveloperName__c);
        }
        Map<String, Id> queueByDev = new Map<String, Id>();
        for (Group g : [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName IN :devNames]) {
            queueByDev.put(g.DeveloperName, g.Id);
        }
        poolQueueId = queueByDev.get('HFS_Lead_Pool');
        for (Office_Distribution_Setting__mdt s : settings) {
            Id qId = queueByDev.get(s.Queue_DeveloperName__c);
            Integer allot = (s.Daily_Allotment__c != null) ? Integer.valueOf(s.Daily_Allotment__c) : 0;
            if (qId != null && allot > 0 && String.isNotBlank(s.Office_Code__c)) {
                OfficeAllot oa = new OfficeAllot();
                oa.code = s.Office_Code__c;
                oa.queueId = qId;
                oa.remaining = allot;
                offices.add(oa);
            }
        }
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Office__c, OwnerId, Status, TCPA_Scrub_Status__c
            FROM Lead
            WHERE TCPA_Scrub_Status__c = 'Clear' AND Office__c = null AND OwnerId = :poolQueueId
            ORDER BY CreatedDate ASC
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Lead> scope) {
        List<Lead> toUpdate = new List<Lead>();
        for (Lead l : scope) {
            while (currentIdx < offices.size() && offices[currentIdx].remaining <= 0) {
                currentIdx++;
            }
            if (currentIdx >= offices.size()) {
                break; // all allotments filled — leave remaining leads in the pool
            }
            OfficeAllot oa = offices[currentIdx];
            l.Office__c = oa.code;
            l.OwnerId = oa.queueId;
            l.Status = 'Assigned';
            oa.remaining--;
            assignedCount++;
            toUpdate.add(l);
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('LeadDistributionBatch: assigned ' + assignedCount + ' leads across ' + offices.size() + ' offices.');
    }
}
