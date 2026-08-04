/**
 * SmsSenderResolver — resolves the outbound marketing-SMS sender number for a lead, driven by one org
 * toggle (SMS_Sender_Config__c hierarchy custom setting):
 *   Mode = PerRep    -> send from the lead owner's assigned number (User.SMS_Sending_Number__c)
 *   Mode = Dedicated -> send all from the single Dedicated_Number__c
 * Fallback to Dedicated_Number__c when the owner is a queue / not a user / has no assigned number.
 *
 * The resolved number is stamped onto Lead.Outbound_SMS_Number__c by the Lead trigger, so Marketing
 * Cloud journeys and KloudiService can read a ready-to-use sender per lead. Read-only scaffolding —
 * resolves + stamps a number; it does NOT send anything.
 *
 * User rows are read WITHOUT sharing (the Kloudi guest-context lesson) so this resolves even from a
 * Site guest / restricted context. Object CRUD is system-mode in Apex.
 */
public with sharing class SmsSenderResolver {

    @TestVisible private static Map<Id, String> numberOverride;   // tests inject owner->number without User DML

    public class SenderConfig {
        public String mode;
        public String dedicated;
    }

    /** Read the org toggle once. Defaults to PerRep with no dedicated number when unset. */
    public static SenderConfig config() {
        SenderConfig c = new SenderConfig();
        SMS_Sender_Config__c cfg = SMS_Sender_Config__c.getOrgDefaults();
        // Mode__c is Text (custom settings don't allow picklists); normalize to Dedicated|PerRep (default PerRep).
        String raw = (cfg != null) ? cfg.Mode__c : null;
        c.mode = (String.isNotBlank(raw) && raw.equalsIgnoreCase('Dedicated')) ? 'Dedicated' : 'PerRep';
        c.dedicated = (cfg != null) ? cfg.Dedicated_Number__c : null;
        return c;
    }

    /** Resolve the sender number for a single lead owner. */
    public static String resolveSenderForOwner(Id ownerId) {
        SenderConfig c = config();
        if (c.mode == 'Dedicated') return c.dedicated;
        // PerRep
        if (ownerId != null && String.valueOf(ownerId).startsWith('005')) {
            String repNum = new Elevated().sendingNumber(ownerId);
            if (String.isNotBlank(repNum)) return repNum;
            System.debug('SmsSenderResolver: PerRep owner ' + ownerId + ' has no SMS_Sending_Number__c; using Dedicated fallback.');
            return c.dedicated;
        }
        System.debug('SmsSenderResolver: owner ' + ownerId + ' is not a user (queue/null); using Dedicated fallback.');
        return c.dedicated;
    }

    /** Bulk-stamp Lead.Outbound_SMS_Number__c on the given leads (called by the trigger; sets only that field). */
    public static void stampSenders(List<Lead> leads) {
        if (leads == null || leads.isEmpty()) return;
        SenderConfig c = config();

        Set<Id> userOwnerIds = new Set<Id>();
        if (c.mode != 'Dedicated') {
            for (Lead l : leads) {
                if (l.OwnerId != null && String.valueOf(l.OwnerId).startsWith('005')) userOwnerIds.add(l.OwnerId);
            }
        }
        Map<Id, String> ownerNum = (!userOwnerIds.isEmpty())
            ? new Elevated().sendingNumbers(userOwnerIds) : new Map<Id, String>();

        for (Lead l : leads) {
            String num;
            if (c.mode == 'Dedicated') {
                num = c.dedicated;
            } else if (l.OwnerId != null && String.valueOf(l.OwnerId).startsWith('005')
                       && String.isNotBlank(ownerNum.get(l.OwnerId))) {
                num = ownerNum.get(l.OwnerId);
            } else {
                num = c.dedicated;   // queue-owned / no number -> dedicated fallback
            }
            l.Outbound_SMS_Number__c = num;
        }
    }

    /** User reads run WITHOUT sharing so the resolver works in restricted contexts (Site guest, etc.). */
    private without sharing class Elevated {
        String sendingNumber(Id userId) {
            if (numberOverride != null) return numberOverride.get(userId);
            List<User> us = [SELECT SMS_Sending_Number__c FROM User WHERE Id = :userId LIMIT 1];
            return us.isEmpty() ? null : us[0].SMS_Sending_Number__c;
        }
        Map<Id, String> sendingNumbers(Set<Id> userIds) {
            Map<Id, String> out = new Map<Id, String>();
            if (numberOverride != null) {
                for (Id i : userIds) out.put(i, numberOverride.get(i));
                return out;
            }
            for (User u : [SELECT Id, SMS_Sending_Number__c FROM User WHERE Id IN :userIds]) {
                out.put(u.Id, u.SMS_Sending_Number__c);
            }
            return out;
        }
    }
}
