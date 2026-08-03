@isTest
private class LeadTimezoneUtilTest {

    @isTest static void resolvesByAreaCode() {
        System.assertEquals('America/New_York',    LeadTimezoneUtil.resolve('(212) 555-0100', null, null)); // NY
        System.assertEquals('America/Chicago',     LeadTimezoneUtil.resolve('312-555-0100', null, null));   // Chicago
        System.assertEquals('America/Denver',      LeadTimezoneUtil.resolve('3035550100', null, null));     // Denver
        System.assertEquals('America/Phoenix',     LeadTimezoneUtil.resolve('602-555-0100', null, null));   // AZ no DST
        System.assertEquals('America/Los_Angeles', LeadTimezoneUtil.resolve('415-555-0100', null, null));   // SF
        System.assertEquals('America/Anchorage',   LeadTimezoneUtil.resolve('907-555-0100', null, null));   // AK
        System.assertEquals('Pacific/Honolulu',    LeadTimezoneUtil.resolve('808-555-0100', null, null));   // HI
        // Leading country code 1 is stripped
        System.assertEquals('America/Chicago',     LeadTimezoneUtil.resolve('1-312-555-0100', null, null));
    }

    @isTest static void fallsBackToStateThenOfficeThenDefault() {
        // No/short phone -> state fallback (2-letter and full name)
        System.assertEquals('America/Los_Angeles', LeadTimezoneUtil.resolve(null, 'CA', null));
        System.assertEquals('America/Chicago',     LeadTimezoneUtil.resolve('', 'Texas', null));
        System.assertEquals('America/New_York',    LeadTimezoneUtil.resolve('123', 'FL', null)); // too-short phone -> state
        // No phone/state -> office default (all four HFS offices are Eastern)
        System.assertEquals('America/New_York',    LeadTimezoneUtil.resolve(null, null, 'HFS_MIA'));
        // Nothing resolves -> company default (Eastern)
        System.assertEquals('America/New_York',    LeadTimezoneUtil.resolve(null, 'ZZ', 'NOPE'));
        System.assertEquals('America/New_York',    LeadTimezoneUtil.resolve(null, null, null));
    }

    @isTest static void areaCodeAndStateHelpers() {
        System.assertEquals('305', LeadTimezoneUtil.areaCode('(305) 555-1212'));
        System.assertEquals('305', LeadTimezoneUtil.areaCode('13055551212'));
        System.assertEquals(null,  LeadTimezoneUtil.areaCode('555-1212'));  // < 10 digits
        System.assertEquals(null,  LeadTimezoneUtil.areaCode(''));
        System.assertEquals('NY',  LeadTimezoneUtil.normalizeState('ny'));
        System.assertEquals('NY',  LeadTimezoneUtil.normalizeState('New York'));
        System.assertEquals(null,  LeadTimezoneUtil.normalizeState('Nowhere'));
        System.assertEquals(null,  LeadTimezoneUtil.normalizeState(''));
    }
}
