/**
 * SlackTriggerState — per-transaction guards for the Lead/Opportunity triggers so re-entrant
 * updates (workflow field updates, downstream DML) don't double-post or double-create tasks.
 */
public class SlackTriggerState {
    public static Set<Id> leadsNotified = new Set<Id>();      // Qualified/Appt Slack notify
    public static Set<Id> oppsNotified = new Set<Id>();       // Opp Slack notify
    public static Set<Id> assignedActioned = new Set<Id>();   // Speed-to-Lead task + Slack
    public static Set<Id> callbackActioned = new Set<Id>();   // Callback-requested task
}
