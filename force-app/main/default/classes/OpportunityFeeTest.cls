@isTest
private class OpportunityFeeTest {
    // Percent fields return their DECIMAL in formulas (12% => 0.12), so the fee-amount
    // formulas are Total_Debt * Percent (NO extra /100). Verify a 120k / 12 / 20 deal.
    @isTest static void testFeeFormulas() {
        Opportunity o = new Opportunity(
            Name = 'Fee Formula Test',
            StageName = 'Qualification',
            CloseDate = Date.newInstance(2026, 12, 31),
            Total_Debt__c = 120000,
            Retainer_Percent__c = 12,
            Service_Fee_Percent__c = 20
        );
        insert o;
        o = [SELECT Retainer_Amount__c, Service_Fee_Amount__c, Total_Fee_Amount__c,
                    HFS_Revenue__c, Total_Fee_Percent__c
             FROM Opportunity WHERE Id = :o.Id];
        System.assert(Math.abs(o.Retainer_Amount__c   - 14400) < 0.01, 'Retainer = 12% of 120k = 14400, got ' + o.Retainer_Amount__c);
        System.assert(Math.abs(o.Service_Fee_Amount__c - 24000) < 0.01, 'Service = 20% of 120k = 24000, got ' + o.Service_Fee_Amount__c);
        System.assert(Math.abs(o.Total_Fee_Amount__c   - 38400) < 0.01, 'Total fee = 38400, got ' + o.Total_Fee_Amount__c);
        System.assert(Math.abs(o.HFS_Revenue__c        - 28800) < 0.01, 'HFS revenue = 75% of 38400 = 28800, got ' + o.HFS_Revenue__c);
        System.assert(Math.abs(o.Total_Fee_Percent__c  - 32)    < 0.01, 'Total fee % = 32, got ' + o.Total_Fee_Percent__c);
    }
}
