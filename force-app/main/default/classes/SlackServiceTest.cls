@isTest
private class SlackServiceTest {

    @isTest static void postOk() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":true,"channel":"C1","ts":"1700000000.000100"}'));
        Test.startTest();
        SlackService.SlackResult r = SlackService.postMessage('C1', 'hello *world*');
        Test.stopTest();
        System.assertEquals(true, r.ok, 'expected ok');
        System.assertEquals('1700000000.000100', r.ts);
        System.assertEquals(200, r.statusCode);
    }

    @isTest static void postNotInChannel() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":false,"error":"not_in_channel"}'));
        Test.startTest();
        SlackService.SlackResult r = SlackService.postMessage('C1', 'hi');
        Test.stopTest();
        System.assertEquals(false, r.ok);
        System.assertEquals('not_in_channel', r.error);
    }

    @isTest static void postOkFalseNoError() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(200, '{"ok":false}'));
        Test.startTest();
        SlackService.SlackResult r = SlackService.postMessage('C1', 'hi');
        Test.stopTest();
        System.assertEquals('unknown_error', r.error);
    }

    @isTest static void postHttpError() {
        Test.setMock(HttpCalloutMock.class, new SlackHttpMock(500, 'oops'));
        Test.startTest();
        SlackService.SlackResult r = SlackService.postMessage('C1', 'hi');
        Test.stopTest();
        System.assertEquals(false, r.ok);
        System.assertEquals('http_500', r.error);
    }

    @isTest static void postBlankChannel() {
        SlackService.SlackResult r = SlackService.postMessage('', 'hi');
        System.assertEquals('no_channel_configured', r.error);
        System.assertEquals(false, r.ok);
    }

    @isTest static void channelLookup() {
        System.assertEquals('C0BMF3307AM', SlackService.channelForOffice('HFS_TPA'), 'Tampa channel from CMDT');
        System.assertEquals(null, SlackService.channelForOffice('HFS_ZZZ'), 'unknown office -> null');
        System.assertEquals(null, SlackService.channelForOffice(''), 'blank -> null');
    }
}
