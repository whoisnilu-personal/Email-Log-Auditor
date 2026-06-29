/**
 * Single-callout abstraction for AWAF dependency injection at the HTTP boundary.
 * Production: HttpCalloutService.
 * Tests: Test.createStub() against this interface.
 */
public interface IHttpCalloutService {
    HttpResponse send(HttpRequest req);
}
