/**
 * KloudiInboundService — routes an inbound Kloudi SMS reply.
 *
 * Runs WITHOUT SHARING (system context): the Site guest user has no sharing grant to Leads, and the
 * endpoint is already gated by the unguessable URL token, so the processor operates system-wide. Owners
 * are always set to real reps (never the guest) so guest-user record-ownership limits don't apply.
 */
public without sharing class KloudiInboundService {

    @TestVisible private static final Set<String> STOP_WORDS =
        new Set<String>{'STOP', 'UNSUBSCRIBE', 'QUIT', 'END', 'CANCEL'};
    @TestVisible private static SlackNotifier.Notification lastNote;   // lets tests assert the Slack decision

    public static void process(String raw) {
        if (String.isBlank(raw)) return;
        Map<String, Object> m;
        try { m = (Map<String, Object>) JSON.deserializeUntyped(raw); }
        catch (Exception e) { return; }

        String source = str(m, 'source');
        String message = str(m, 'message');
        String last10 = last10(source);
        if (last10 == null) return;

        List<Lead> matches = matchByPhone(last10);
        String body = (message == null) ? '' : message.trim();

        // STOP/UNSUBSCRIBE/QUIT/END/CANCEL -> opt out every phone match; log; no rep routing.
        if (STOP_WORDS.contains(body.toUpperCase())) {
            handleOptOut(matches);
            return;
        }

        // Any other reply -> routable engagement.
        Lead lead = routeLead(matches, source, str(m, 'first_name'), str(m, 'last_name'),
                              str(m, 'state'), str(m, 'city'));
        if (lead == null) return;
        logInboundTask(lead, message, str(m, 'conversation_id'), str(m, 'timestamp'));
        enqueueSlack(lead, message);
    }

    private static void handleOptOut(List<Lead> matches) {
        if (matches.isEmpty()) return;
        Datetime nowTs = Datetime.now();
        List<Task> logs = new List<Task>();
        for (Lead l : matches) {
            l.SMS_Opt_Out__c = true;
            l.SMS_Opt_Out_Source__c = 'Kloudi';
            l.SMS_Opt_Out_Date__c = nowTs;
            logs.add(new Task(WhoId = l.Id, Subject = 'Inbound STOP — SMS opt-out (Kloudi)',
                Status = 'Completed', Priority = 'Normal', ActivityDate = Date.today(),
                OwnerId = ownerForTask(l.OwnerId)));
        }
        update matches;
        insert logs;
    }

    /** Matched active-rep owner kept; unowned/queue-owned/inactive -> round-robin; no match -> create. */
    private static Lead routeLead(List<Lead> matches, String source, String fn, String ln, String st, String city) {
        if (!matches.isEmpty()) {
            Lead l = matches[0];
            if (!isActiveRep(l.OwnerId)) {
                LeadTriggerHandler.assignRoundRobin(new List<Lead>{ l });
                update l;
            }
            return l;
        }
        String last = String.isNotBlank(ln) ? ln : 'SMS Reply';
        Lead nl = new Lead(
            FirstName = String.isNotBlank(fn) ? fn : null,
            LastName = last,
            Company = (String.isNotBlank(fn) || String.isNotBlank(ln)) ? (safe(fn) + ' ' + last).trim() : 'SMS Reply',
            Phone = source, State = st, City = city,
            LeadSource = 'Kloudi SMS', Status = 'New', TCPA_Scrub_Status__c = 'Pending');
        LeadTriggerHandler.assignRoundRobin(new List<Lead>{ nl });
        // Never drop an inbound reply: we already phone-matched (no hit), so bypass duplicate rules on create.
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.duplicateRuleHeader.allowSave = true;
        Database.insert(nl, dml);
        return [SELECT Id, Name, OwnerId, Office__c, Company FROM Lead WHERE Id = :nl.Id LIMIT 1];
    }

    private static void logInboundTask(Lead l, String message, String convId, String tstamp) {
        String taskDesc = 'Inbound SMS via Kloudi\n\nMessage: ' + (message == null ? '' : message)
            + '\nConversation: ' + (convId == null ? '' : convId)
            + '\nTimestamp: ' + (tstamp == null ? '' : tstamp);
        insert new Task(WhoId = l.Id, Subject = 'Inbound SMS reply (Kloudi)', Description = taskDesc,
            Status = 'Completed', Priority = 'High', ActivityDate = Date.today(),
            OwnerId = ownerForTask(l.OwnerId));
    }

    private static void enqueueSlack(Lead l, String message) {
        SlackNotifier.Notification n = new SlackNotifier.Notification();
        n.kind = 'LEAD_REPLIED';   // reuse the existing engagement kind -> no SlackNotifier change
        n.officeCode = (l.Office__c != null) ? l.Office__c : LeadTriggerHandler.officeForUser(l.OwnerId);
        n.recordName = l.Name;
        n.ownerId = l.OwnerId;
        n.detail = 'SMS: ' + truncate((message == null ? '' : message), 120);
        lastNote = n;
        System.enqueueJob(new SlackNotifier(new List<SlackNotifier.Notification>{ n }));
    }

    // ---- phone matching: exact IN over common stored formats (selective — uses the Phone index) ----
    @TestVisible
    private static List<Lead> matchByPhone(String last10) {
        String a = last10.substring(0, 3), b = last10.substring(3, 6), c = last10.substring(6);
        Set<String> v = new Set<String>{
            last10, '1' + last10, '+1' + last10,
            a + '-' + b + '-' + c, '(' + a + ') ' + b + '-' + c, a + '.' + b + '.' + c, a + ' ' + b + ' ' + c,
            '1 ' + a + '-' + b + '-' + c, '+1 ' + a + '-' + b + '-' + c, '+1 (' + a + ') ' + b + '-' + c
        };
        List<String> variants = new List<String>(v);
        return [SELECT Id, Name, OwnerId, Office__c, Company, Phone
                FROM Lead WHERE Phone IN :variants LIMIT 200];
    }

    @TestVisible
    private static String last10(String phone) {
        if (phone == null) return null;
        String d = phone.replaceAll('[^0-9]', '');
        if (String.isBlank(d)) return null;
        return d.length() > 10 ? d.substring(d.length() - 10) : d;
    }

    private static Boolean isActiveRep(Id ownerId) {
        if (ownerId == null || !String.valueOf(ownerId).startsWith('005')) return false;
        List<User> us = [SELECT IsActive FROM User WHERE Id = :ownerId LIMIT 1];
        return !us.isEmpty() && us[0].IsActive == true;
    }

    private static Id ownerForTask(Id ownerId) {
        return (ownerId != null && String.valueOf(ownerId).startsWith('005')) ? ownerId : null;
    }

    private static String str(Map<String, Object> m, String k) {
        Object v = (m == null) ? null : m.get(k);
        return (v == null) ? null : String.valueOf(v);
    }
    private static String safe(String s) { return s == null ? '' : s; }
    private static String truncate(String s, Integer n) {
        if (s == null) return '';
        return s.length() > n ? s.substring(0, n) : s;
    }
}
