/**
 * DialListRefresh - materializes the compliant callable universe for the Amazon Connect Outbound
 * Campaign into Dial_List_Entry__c. Batchable + Schedulable.
 *
 * Gate: Lead.Dialer_Eligible__c = true (TCPA Clear + not Global DNC + not Bad Number + a callable
 * Phone/MobilePhone). This is the STATIC eligibility gate only. The recipient-local 8am-9pm window is a
 * RUNTIME filter applied at export (see inWindow) - deliberately NOT applied here, so the staging table
 * always mirrors the full callable universe and the export decides who is dial-able right now.
 *
 * Idempotent: upsert on Lead_Ext_Id__c (the Lead Id) => one entry per eligible Lead, safe to re-run.
 * finish() drops entries whose Lead is no longer eligible (opt-out / DNC / scrub flip / bad number) or
 * whose Lead was deleted, so suppressions fall out on every cycle. Timezone reuses Lead.Local_Timezone__c
 * (populated by the marketing engine), falling back to LeadTimezoneUtil so every entry carries a DST-safe
 * IANA tz for the export window.
 *
 * NOTE (compliance): "call consent" is intentionally NOT gated here - no call-consent field exists on Lead,
 * and predictive-vs-preview for the cold list is a Legal/mode decision (see the dialer runbook). Add a
 * consent clause to Dialer_Eligible__c before predictive-dialing cold cell numbers if counsel requires it.
 */
public with sharing class DialListRefresh implements Database.Batchable<SObject>, Schedulable {

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Phone, MobilePhone, Office__c, Local_Timezone__c, State
            FROM Lead
            WHERE Dialer_Eligible__c = true
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Lead> scope) {
        List<Dial_List_Entry__c> ups = new List<Dial_List_Entry__c>();
        for (Lead l : scope) {
            String raw = String.isNotBlank(l.Phone) ? l.Phone : l.MobilePhone;
            String num = normalize(raw);
            if (num == null) continue;   // no valid callable number -> never stage an un-dialable row
            String tz = String.isNotBlank(l.Local_Timezone__c)
                ? l.Local_Timezone__c
                : LeadTimezoneUtil.resolve(raw, l.State, l.Office__c);
            ups.add(new Dial_List_Entry__c(
                Lead_Ext_Id__c  = l.Id,
                Lead__c         = l.Id,
                Phone_Number__c = num,
                Office__c       = l.Office__c,
                Time_Zone__c    = tz,
                Ok_To_Call__c   = true,
                Staged_At__c    = System.now()
            ));
        }
        if (!ups.isEmpty()) upsert ups Lead_Ext_Id__c;   // idempotent on the Lead Id
    }

    public void finish(Database.BatchableContext bc) {
        // Suppressions win: drop anyone no longer eligible (or whose Lead was deleted) since staging.
        List<Dial_List_Entry__c> stale = [
            SELECT Id FROM Dial_List_Entry__c
            WHERE Lead__c = null OR Lead__r.Dialer_Eligible__c = false
        ];
        if (!stale.isEmpty()) delete stale;
    }

    /** Schedulable entry point - e.g. every 30 min so new clears flow in and suppressions drop out. */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new DialListRefresh(), 200);
    }

    /** Reusable in-window check for the export job - DST-safe via IANA tz. 8am-9pm recipient-local. */
    public static Boolean inWindow(String tzId) {
        if (String.isBlank(tzId)) tzId = LeadTimezoneUtil.DEFAULT_TZ;
        Integer h = Integer.valueOf(Datetime.now().format('H', tzId));
        return h >= 8 && h < 21;
    }

    /** Digits-only -> +1XXXXXXXXXX E.164; null if not a valid 10/11-digit NANP number. */
    @TestVisible
    static String normalize(String p) {
        if (String.isBlank(p)) return null;
        String d = p.replaceAll('[^0-9]', '');
        if (d.length() == 10) d = '1' + d;
        if (d.length() != 11 || !d.startsWith('1')) return null;   // reject malformed
        return '+' + d;
    }
}
