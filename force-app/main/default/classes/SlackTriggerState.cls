/**
 * SlackTriggerState — per-transaction recursion guards for the Slack notify triggers.
 * Tracks record ids already notified this transaction so re-entrant updates (e.g. from
 * workflow field updates) don't double-post, while still allowing all chunks of a bulk DML.
 */
public class SlackTriggerState {
    public static Set<Id> leadsNotified = new Set<Id>();
    public static Set<Id> oppsNotified = new Set<Id>();
}
