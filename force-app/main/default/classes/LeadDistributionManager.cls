/**
 * LeadDistributionManager — engine for the on-demand "Distribute Leads" admin tool.
 *
 * Rahul (admin) scans the cleared, un-allocated lead pool and allocates it across the 4 offices by
 * NUMBER or PERCENT, oldest-first. This replaces the old auto-waterfall: LeadDistributionBatch is
 * retained but no longer auto-fires (see TCPAScrubBatch.finish()). Cleared leads park in HFS_Lead_Pool
 * and wait for this tool.
 *
 * POOL = Lead WHERE TCPA_Scrub_Status__c = 'Clear' AND Office__c = null AND OwnerId = HFS_Lead_Pool queue.
 * Everything stays gated on 'Clear' — Pending/Flagged/Error/DNC leads are never queried or touched.
 *
 * Assignment is SYNCHRONOUS on purpose: (1) the tool shows an exact "what went where" confirmation,
 * and (2) the existing Assigned automation posts ONE per-office Slack summary per transaction — an
 * async batch (scope 200) would fragment that into many posts. Capped at MAX_PER_RUN leads/run to stay
 * within governor limits (each assigned lead => 1 Lead update + 1 Task insert via LeadTriggerHandler).
 * Run again to move more; unallocated leads stay pooled.
 */
public with sharing class LeadDistributionManager {

    // Non-final + @TestVisible so a test can lower it and exercise the per-run guard without 5,000 rows.
    @TestVisible private static Integer MAX_PER_RUN = 5000;
    private static final String POOL_DEV = 'HFS_Lead_Pool';

    // ---------- Scan ----------
    public class OfficeInfo {
        @AuraEnabled public String code;
        @AuraEnabled public String label;
        @AuraEnabled public String queueDeveloperName;
        @AuraEnabled public Boolean queueResolved;
    }
    public class PoolScan {
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer maxPerRun;
        @AuraEnabled public List<OfficeInfo> offices;
    }

    /** Current pool size + the 4 active offices (label/queue). Called on load and after each run. */
    @AuraEnabled
    public static PoolScan scanPool() {
        PoolScan s = new PoolScan();
        s.total = poolCount();
        s.maxPerRun = MAX_PER_RUN;
        s.offices = new List<OfficeInfo>();
        Map<String, Id> qByDev = queueIdsByDev();
        for (Office_Distribution_Setting__mdt m : settings()) {
            OfficeInfo oi = new OfficeInfo();
            oi.code = m.Office_Code__c;
            oi.label = officeLabel(m);
            oi.queueDeveloperName = m.Queue_DeveloperName__c;
            oi.queueResolved = String.isNotBlank(m.Queue_DeveloperName__c)
                && qByDev.containsKey(m.Queue_DeveloperName__c);
            s.offices.add(oi);
        }
        return s;
    }

    /** Count of Clear, un-allocated leads sitting in the HFS_Lead_Pool queue. */
    @AuraEnabled
    public static Integer poolCount() {
        Id poolId = poolQueueId();
        if (poolId == null) return 0;
        return [
            SELECT COUNT()
            FROM Lead
            WHERE TCPA_Scrub_Status__c = 'Clear' AND Office__c = null AND OwnerId = :poolId
        ];
    }

    // ---------- Distribute ----------
    public class AllocationInput {
        @AuraEnabled public String officeCode;
        @AuraEnabled public Decimal value;   // count (NUMBER mode) OR percent (PERCENT mode)
    }
    public class OfficeResult {
        @AuraEnabled public String code;
        @AuraEnabled public String label;
        @AuraEnabled public Integer target;
        @AuraEnabled public Integer assigned;
    }
    public class DistributeResult {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public String message;
        @AuraEnabled public Integer poolBefore = 0;
        @AuraEnabled public Integer totalAssigned = 0;
        @AuraEnabled public Integer remaining = 0;
        @AuraEnabled public List<OfficeResult> offices = new List<OfficeResult>();
    }

    /**
     * Validate the per-office allocation, then assign oldest-first up to each office's target.
     * mode = 'NUMBER' | 'PERCENT'. Never throws for a validation problem — returns success=false + message.
     */
    @AuraEnabled
    public static DistributeResult distribute(String mode, List<AllocationInput> allocations) {
        DistributeResult res = new DistributeResult();
        String m = (mode == null) ? '' : mode.toUpperCase();
        Integer total = poolCount();
        res.poolBefore = total;
        res.remaining = total;

        if (m != 'NUMBER' && m != 'PERCENT') return fail(res, 'Invalid mode — use By number or By percent.');

        Map<String, Office_Distribution_Setting__mdt> byCode = new Map<String, Office_Distribution_Setting__mdt>();
        for (Office_Distribution_Setting__mdt s : settings()) byCode.put(s.Office_Code__c, s);
        Map<String, Id> qByDev = queueIdsByDev();

        // ----- validate inputs + compute per-office targets (preserving request order) -----
        List<String> orderedCodes = new List<String>();
        Map<String, Integer> targetByCode = new Map<String, Integer>();
        Decimal sumPct = 0;
        Integer sumNum = 0;

        if (allocations != null) {
            for (AllocationInput a : allocations) {
                if (a == null || String.isBlank(a.officeCode) || a.value == null) continue;
                if (a.value < 0) return fail(res, 'Values cannot be negative.');
                if (!byCode.containsKey(a.officeCode)) return fail(res, 'Unknown office: ' + a.officeCode + '.');

                Integer tgt;
                if (m == 'PERCENT') {
                    sumPct += a.value;
                    tgt = ((a.value / 100) * total).intValue();   // floor for non-negative values
                } else {
                    tgt = a.value.intValue();                     // floor
                    sumNum += tgt;
                }
                if (tgt > 0) {
                    if (!targetByCode.containsKey(a.officeCode)) orderedCodes.add(a.officeCode);
                    targetByCode.put(a.officeCode,
                        (targetByCode.containsKey(a.officeCode) ? targetByCode.get(a.officeCode) : 0) + tgt);
                }
            }
        }

        if (m == 'PERCENT' && sumPct > 100) {
            return fail(res, 'Percentages add up to ' + sumPct.stripTrailingZeros() + '% — they must total 100% or less.');
        }
        if (m == 'NUMBER' && sumNum > total) {
            return fail(res, 'Numbers add up to ' + sumNum + ', but only ' + total + ' lead(s) are in the pool.');
        }

        Integer totalTarget = 0;
        for (String c : orderedCodes) totalTarget += targetByCode.get(c);

        if (totalTarget == 0) {
            return fail(res, total == 0
                ? 'The pool is empty — there is nothing to distribute.'
                : 'Nothing to distribute — every office target is 0.');
        }
        if (totalTarget > MAX_PER_RUN) {
            return fail(res, 'This run would assign ' + totalTarget + ' leads; the maximum per run is '
                + MAX_PER_RUN + '. Lower the amounts or run again after this batch (leftovers stay in the pool).');
        }

        // ----- resolve destination queues for the targeted offices -----
        Map<String, Id> queueForCode = new Map<String, Id>();
        for (String c : orderedCodes) {
            Office_Distribution_Setting__mdt s = byCode.get(c);
            Id qId = (s != null && String.isNotBlank(s.Queue_DeveloperName__c))
                ? qByDev.get(s.Queue_DeveloperName__c) : null;
            if (qId == null) {
                return fail(res, 'No queue found for office ' + c + ' ('
                    + (s != null ? s.Queue_DeveloperName__c : '') + ').');
            }
            queueForCode.put(c, qId);
        }

        // ----- pull exactly as many oldest pool leads as needed -----
        Id poolId = poolQueueId();
        List<Lead> pool = [
            SELECT Id
            FROM Lead
            WHERE TCPA_Scrub_Status__c = 'Clear' AND Office__c = null AND OwnerId = :poolId
            ORDER BY CreatedDate ASC
            LIMIT :totalTarget
        ];

        // ----- assign oldest-first, filling each office to its target in request order -----
        List<Lead> toUpdate = new List<Lead>();
        Map<String, Integer> assignedByCode = new Map<String, Integer>();
        Integer idx = 0;
        for (String c : orderedCodes) {
            Integer want = targetByCode.get(c);
            Id qId = queueForCode.get(c);
            Integer got = 0;
            while (got < want && idx < pool.size()) {
                Lead l = pool[idx];
                l.Office__c = c;
                l.OwnerId = qId;
                l.Status = 'Assigned';
                toUpdate.add(l);
                idx++;
                got++;
            }
            assignedByCode.put(c, got);
        }

        if (!toUpdate.isEmpty()) update toUpdate;   // re-fires LeadTriggerHandler: Speed-to-Lead drip, call-now Task, Slack

        // ----- build the "what went where" confirmation -----
        Integer totalAssigned = 0;
        for (String c : orderedCodes) {
            OfficeResult orr = new OfficeResult();
            orr.code = c;
            orr.label = officeLabel(byCode.get(c));
            orr.target = targetByCode.get(c);
            orr.assigned = assignedByCode.get(c);
            totalAssigned += orr.assigned;
            res.offices.add(orr);
        }
        res.success = true;
        res.totalAssigned = totalAssigned;
        res.remaining = total - totalAssigned;
        res.message = 'Assigned ' + totalAssigned + ' of ' + total + ' pooled lead(s). '
            + res.remaining + ' remain in the pool.';
        return res;
    }

    // ---------- helpers ----------
    private static DistributeResult fail(DistributeResult res, String msg) {
        res.success = false;
        res.message = msg;
        res.totalAssigned = 0;
        res.remaining = res.poolBefore;
        return res;
    }

    private static List<Office_Distribution_Setting__mdt> settingsCache;
    private static List<Office_Distribution_Setting__mdt> settings() {
        if (settingsCache == null) {
            settingsCache = [
                SELECT MasterLabel, Office_Code__c, Daily_Allotment__c, Priority__c, Queue_DeveloperName__c
                FROM Office_Distribution_Setting__mdt
                WHERE Active__c = true
                ORDER BY Priority__c ASC NULLS LAST
            ];
        }
        return settingsCache;
    }

    private static String officeLabel(Office_Distribution_Setting__mdt m) {
        return (m == null) ? null : m.MasterLabel;
    }

    private static Map<String, Id> queueCache;
    private static Map<String, Id> queueIdsByDev() {
        if (queueCache == null) {
            Set<String> devs = new Set<String>{ POOL_DEV };
            for (Office_Distribution_Setting__mdt m : settings()) {
                if (String.isNotBlank(m.Queue_DeveloperName__c)) devs.add(m.Queue_DeveloperName__c);
            }
            queueCache = new Map<String, Id>();
            for (Group g : [SELECT Id, DeveloperName FROM Group WHERE Type = 'Queue' AND DeveloperName IN :devs]) {
                queueCache.put(g.DeveloperName, g.Id);
            }
        }
        return queueCache;
    }

    private static Id poolQueueId() {
        return queueIdsByDev().get(POOL_DEV);
    }
}
