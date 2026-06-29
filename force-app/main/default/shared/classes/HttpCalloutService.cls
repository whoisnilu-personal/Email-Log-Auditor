/**
 * SECURITY: without sharing — wraps the platform Http() callout. Inherits
 * authentication via session header set by the caller; no credentials stored
 * in this class.
 *
 * Production implementation of IHttpCalloutService.
 * Tests inject Test.createStub() against IHttpCalloutService instead of this class.
 */
public without sharing class HttpCalloutService implements IHttpCalloutService {
    public HttpResponse send(HttpRequest req) {
        return new Http().send(req);
    }
}
