/**
 * SlackNotifier — Queueable that composes high-end mrkdwn and posts pipeline events to the
 * office Slack channel. Enqueued from the Lead/Opportunity triggers (event-driven, no per-lead spam).
 * Offices with no Slack_Channel_Id__c configured are skipped.
 */
public with sharing class SlackNotifier implements Queueable, Database.AllowsCallouts {

    public class Notification {
        public String kind;          // LEAD_WEBSITE | LEAD_ASSIGNED | LEAD_ASSIGNED_BULK | LEAD_ENGAGED | LEAD_REPLIED | LEAD_QUALIFIED | LEAD_APPT | OPP_NEW | OPP_STAGE | OPP_WON
        public String officeCode;
        public String recordName;
        public String company;       // Lead
        public String stageName;     // Opp
        public Decimal totalDebt;    // Opp
        public Decimal hfsRevenue;   // Opp
        public Id ownerId;
        public String detail;        // e.g. engagement type for LEAD_ENGAGED
        public Integer leadCount;    // LEAD_ASSIGNED_BULK: # leads assigned to the office this transaction
    }

    private List<Notification> items;
    public SlackNotifier(List<Notification> items) { this.items = items; }

    public void execute(QueueableContext ctx) {
        if (items == null || items.isEmpty()) return;

        Set<Id> ownerIds = new Set<Id>();
        for (Notification n : items) if (n.ownerId != null) ownerIds.add(n.ownerId);
        Map<Id, String> ownerNames = new Map<Id, String>();
        if (!ownerIds.isEmpty()) {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :ownerIds]) ownerNames.put(u.Id, u.Name);
        }

        for (Notification n : items) {
            String channel = SlackService.channelForOffice(n.officeCode);
            if (String.isBlank(channel)) continue;   // skip offices with no channel configured
            if (Limits.getCallouts() >= Limits.getLimitCallouts()) break;  // stay within per-transaction callout cap (bulk-safe)
            String owner = (n.ownerId != null && ownerNames.containsKey(n.ownerId))
                ? ownerNames.get(n.ownerId) : 'Unassigned';
            SlackService.postMessage(channel, compose(n, owner));
        }
    }

    @TestVisible
    private String compose(Notification n, String owner) {
        if (n.kind == 'LEAD_WEBSITE') {
            return ':globe_with_meridians: *New website lead* — ' + safe(n.recordName)
                + ' · ' + safe(n.company) + ' · owner ' + owner;
        }
        if (n.kind == 'LEAD_ASSIGNED') {
            return ':rotating_light: *New clear lead — call now* — ' + safe(n.company)
                + ' · ' + safe(n.recordName) + ' · owner ' + owner;
        }
        if (n.kind == 'LEAD_ASSIGNED_BULK') {
            return ':rotating_light: *' + n.leadCount + ' new clear leads assigned to '
                + SlackService.officeLabel(n.officeCode) + ' — top of queue*';
        }
        if (n.kind == 'LEAD_ENGAGED') {
            String t = String.isBlank(n.detail) ? '' : ' (' + n.detail + ')';
            return ':wave: *Lead engaged' + t + '* — ' + safe(n.company)
                + ' · ' + safe(n.recordName) + ' · owner ' + owner;
        }
        if (n.kind == 'LEAD_REPLIED') {
            return ':fire: *' + safe(n.recordName) + ' replied* — ' + safe(n.detail)
                + ' · owner ' + owner;
        }
        if (n.kind == 'LEAD_QUALIFIED' || n.kind == 'LEAD_APPT') {
            String label = (n.kind == 'LEAD_APPT') ? 'Appointment Set' : 'Qualified';
            return ':telephone_receiver: *' + label + '* — ' + safe(n.company)
                + ' · ' + safe(n.recordName) + ' · owner ' + owner;
        }
        // Opportunity event
        String prefix = (n.kind == 'OPP_WON') ? ':tada: ' : '';
        return prefix + ':moneybag: *' + safe(n.stageName) + '* — ' + safe(n.recordName)
            + ' · debt ' + money(n.totalDebt) + ' · HFS rev ' + money(n.hfsRevenue)
            + ' · ' + owner;
    }

    private String safe(String s) { return String.isBlank(s) ? '—' : s; }

    private String money(Decimal d) {
        if (d == null) return '$0';
        return '$' + d.setScale(0, System.RoundingMode.HALF_UP).format();
    }
}
