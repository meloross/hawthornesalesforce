@isTest
public class TCPAScrubHttpMock implements HttpCalloutMock {
    public Integer code;
    public String body;
    public HttpRequest lastRequest;
    public TCPAScrubHttpMock(Integer code, String body) {
        this.code = code;
        this.body = body;
    }
    public HttpResponse respond(HttpRequest req) {
        this.lastRequest = req;
        HttpResponse res = new HttpResponse();
        res.setStatusCode(code);
        res.setHeader('Content-Type', 'application/json');
        if (body != null) res.setBody(body);
        return res;
    }
}
