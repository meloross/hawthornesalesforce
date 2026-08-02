/**
 * LeadSlackNotify — the single Lead trigger. Delegates to LeadTriggerHandler, which runs the
 * Phase 1 Marketing Workflow Engine (drip routing on status/disposition change) AND the existing
 * Slack pipeline notifications. (Name retained from the original Slack-only trigger to avoid a
 * destructive rename; scope is now the full Lead orchestration.)
 */
trigger LeadSlackNotify on Lead (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        LeadTriggerHandler.handleBefore(Trigger.new, (Map<Id, Lead>) Trigger.oldMap);
    } else {
        LeadTriggerHandler.handleAfter(Trigger.new, (Map<Id, Lead>) Trigger.oldMap);
    }
}
