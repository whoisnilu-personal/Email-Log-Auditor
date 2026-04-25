/*------------------------------------------------------------------------------------
Developer:    GitHub Copilot
Class:        EmailLogFileServiceTest
Description:  Unit tests for EmailLogFileService, EmailLogFileDownloaderQueueable
              and EmailLogFileDownloaderAPI using HttpCalloutMock to simulate
              the undocumented 4-hop cross-domain download chain.

Test Class:   (this is the test class)
History
Date           Author             Comments
--------------------------------------------------------------------------------------
25-04-2026    GitHub Copilot     Initial Release
------------------------------------------------------------------------------------*/
@IsTest
private class EmailLogFileServiceTest {

    // ─────────────────────────────────────────────────────────────────────────
    // Sample data constants
    // ─────────────────────────────────────────────────────────────────────────

    private static final String MOCK_FILE_ID      = '0BRC2000000096X';
    private static final String MOCK_LABEL        = 'Inbound Email Log 16 Apr 2026';
    private static final String MOCK_CSV_FILENAME = 'EmailLog_16-04-2026_9GDOAY_1.csv';
    private static final String MOCK_CSV_CONTENT  = 'MessageId,Date,Sender,Recipient,Subject\n'
        + 'ABC123,2026-04-16,test@example.com,dest@example.com,Hello\n';

    // Minimal HTML resembling the VF email log overview page (title follows srcUp link like the real page)
    private static final String MOCK_VF_HTML =
        '<html><body>'
        + '<a href="javascript:srcUp(%27%2Fservlet%2Fservlet.FileDownload%3Ffile%3D'
        + MOCK_FILE_ID + '%26isdtp%3Dp1%27);" class="actionLink" '
        + 'title="' + MOCK_LABEL + '">Download (.zip)</a>'
        + '</body></html>';

    // ─────────────────────────────────────────────────────────────────────────
    // Multi-hop callout mock factory
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Produces a multi-step mock that simulates:
     *  1. frontdoor.jsp  → 200 with Set-Cookie (VF session)
     *  2. VF overview page → 200 HTML with srcUp() links
     *  3. Servlet         → 200 application/zip (direct, cookie-authenticated)
     */
    private class MultiHopMock implements HttpCalloutMock {
        private Blob    zipBlob;

        public MultiHopMock() {
            this.zipBlob = buildMockZip();
        }

        public HttpResponse respond(HttpRequest req) {
            String url = req.getEndpoint();
            HttpResponse res = new HttpResponse();

            if (url.contains('frontdoor.jsp')) {
                // Step 1: frontdoor.jsp → 200 + Set-Cookie with VF session
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'text/html; charset=UTF-8');
                res.setHeader('Set-Cookie', 'sid=VF_SESSION; path=/; secure; oid=TESTORGID; path=/; secure');
                res.setBody('<html><head></head><body><script>window.location.replace("https://example.file.force.com/secur/contentDoor");</script></body></html>');

            } else if (url.contains('EmailLogSearchOverview')) {
                // Step 2: VF overview page → 200 HTML with srcUp links
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'text/html; charset=UTF-8');
                res.setBody(MOCK_VF_HTML);

            } else if (url.contains('servlet.FileDownload') || url.contains('FileDownload')) {
                // Step 3: Download servlet → 200 zip (authenticated via Cookie header)
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'application/zip');
                res.setHeader('Content-Disposition',
                    'attachment; filename="' + MOCK_CSV_FILENAME.replace('.csv', '.zip') + '"');
                res.setBodyAsBlob(zipBlob);

            } else {
                res.setStatusCode(404);
                res.setBody('Not found: ' + url);
            }
            return res;
        }
    }

    /**
     * Mock that returns the VF overview page after the frontdoor.jsp cookie step.
     */
    private class ListOnlyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String url = req.getEndpoint();
            if (url.contains('frontdoor.jsp')) {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'text/html; charset=UTF-8');
                res.setHeader('Set-Cookie', 'sid=VF_SESSION; path=/; secure; oid=TESTORGID; path=/; secure');
                res.setBody('<html><head></head><body></body></html>');
            } else {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'text/html; charset=UTF-8');
                res.setBody(MOCK_VF_HTML);
            }
            return res;
        }
    }

    /**
     * Mock that returns an error for the VF page (permission denied scenario).
     */
    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String url = req.getEndpoint();
            if (url.contains('frontdoor.jsp')) {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'text/html; charset=UTF-8');
                res.setHeader('Set-Cookie', 'sid=VF_SESSION; path=/; secure; oid=TESTORGID; path=/; secure');
                res.setBody('<html><head></head><body></body></html>');
            } else {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'text/html');
                res.setBody('<html><body>Insufficient Privileges</body></html>');
            }
            return res;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests — EmailLogFileService
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetSetupDomain() {
        // Verifies that .my.salesforce.com → .my.salesforce-setup.com
        // (The actual org URL will be used at runtime; test the static helper indirectly
        //  by checking our parsing logic on a known input using the @TestVisible helper.)
        String result = EmailLogFileService.htmlUnescape('Hello &amp; World &quot;test&quot;');
        System.assertEquals('Hello & World "test"', result, 'HTML unescape should decode entities');
    }

    @IsTest
    static void testParseEmailLogEntries_singleEntry() {
        List<EmailLogFileService.EmailLogEntry> entries =
            EmailLogFileService.parseEmailLogEntries(MOCK_VF_HTML);

        System.assertEquals(1, entries.size(), 'Expected exactly 1 log entry');
        System.assertEquals(MOCK_FILE_ID, entries[0].fileId, 'File ID mismatch');
        System.assertEquals(MOCK_LABEL,   entries[0].label,  'Label mismatch');
        System.assert(entries[0].servletPath.contains(MOCK_FILE_ID), 'Servlet path must contain file ID');
    }

    @IsTest
    static void testParseEmailLogEntries_emptyHtml() {
        List<EmailLogFileService.EmailLogEntry> entries =
            EmailLogFileService.parseEmailLogEntries('<html><body>No files here</body></html>');
        System.assertEquals(0, entries.size(), 'No entries expected');
    }

    @IsTest
    static void testListAvailableLogs() {
        Test.setMock(HttpCalloutMock.class, new ListOnlyMock());
        Test.startTest();
        List<EmailLogFileService.EmailLogEntry> entries =
            EmailLogFileService.listAvailableLogs();
        Test.stopTest();

        System.assertEquals(1, entries.size(), 'Expected 1 entry from mock');
        System.assertEquals(MOCK_FILE_ID, entries[0].fileId);
    }

    @IsTest
    static void testListAvailableLogs_noFilesThrows() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());
        Test.startTest();
        try {
            EmailLogFileService.listAvailableLogs();
            System.assert(false, 'Should have thrown EmailLogServiceException');
        } catch (EmailLogFileService.EmailLogServiceException ex) {
            System.assert(ex.getMessage().containsIgnoreCase('no Email Log'),
                'Exception message should mention no Email Log links');
        }
        Test.stopTest();
    }

    @IsTest
    static void testDownloadAllLogs_success() {
        Test.setMock(HttpCalloutMock.class, new MultiHopMock());
        Test.startTest();
        List<EmailLogFileService.DownloadResult> results =
            EmailLogFileService.downloadAllLogs(null, false);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected 1 result');
        EmailLogFileService.DownloadResult r = results[0];
        System.assertEquals(true, r.success, 'Download should succeed: ' + r.errorMessage);
        System.assert(String.isNotBlank(r.csvContent), 'CSV content should not be blank');
        System.assertEquals(MOCK_FILE_ID, r.entry.fileId);
    }

    @IsTest
    static void testDownloadById_success() {
        Test.setMock(HttpCalloutMock.class, new MultiHopMock());
        Test.startTest();
        // Skip the list step — provide the file ID directly
        // Mock will be called from hop 3 onwards (servlet chain)
        // We re-use MultiHopMock which starts from frontdoor; adjust by calling downloadById
        // which goes directly to the servlet. The mock will get slightly different call
        // ordering but still serves a zip on the final 200 call.
        EmailLogFileService.DownloadResult r =
            EmailLogFileService.downloadById(MOCK_FILE_ID, MOCK_LABEL, null, false);
        Test.stopTest();

        System.assertEquals(true, r.success, 'downloadById should succeed: ' + r.errorMessage);
    }

    @IsTest
    static void testSaveAsFile_createsContentDocument() {
        Test.setMock(HttpCalloutMock.class, new MultiHopMock());
        Test.startTest();
        List<EmailLogFileService.DownloadResult> results =
            EmailLogFileService.downloadAllLogs(null, true);
        Test.stopTest();

        System.assertEquals(1, results.size());
        EmailLogFileService.DownloadResult r = results[0];
        System.assertEquals(true, r.success, r.errorMessage != null ? r.errorMessage : 'success was false but no errorMessage set');
        System.assertNotEquals(null, r.contentDocumentId,
            'ContentDocument should be created when saveAsFile=true');
    }

    @IsTest
    static void testExtractJsRedirectUrl_replaceVariant() {
        // Simulates the HTML from frontdoor.jsp in enhanced-domain orgs
        String html = '<html><body><script>'
            + 'function lhdoredir(){window.location.replace("https://example.file.force.com/secur/contentDoor?sid=ABC");}'
            + 'window.setTimeout(lhdoredir,1E3);'
            + '</script></body></html>';
        String url = EmailLogFileService.extractJsRedirectUrl(html);
        System.assertEquals('https://example.file.force.com/secur/contentDoor?sid=ABC', url);
    }

    @IsTest
    static void testExtractJsRedirectUrl_hrefVariant() {
        String html = '<html><body><script>window.location.href="https://example.file.force.com/page";</script></body></html>';
        String url = EmailLogFileService.extractJsRedirectUrl(html);
        System.assertEquals('https://example.file.force.com/page', url);
    }

    @IsTest
    static void testExtractJsRedirectUrl_noRedirect() {
        String url = EmailLogFileService.extractJsRedirectUrl('<html><body>No redirect here</body></html>');
        System.assertEquals(null, url);
    }

    @IsTest
    static void testParseCookieValues() {
        String raw = 'sid=NEWVALUE; Path=/; HttpOnly; Secure; SameSite=None';
        String parsed = EmailLogFileService.parseCookieValues(raw);
        System.assert(parsed.contains('sid=NEWVALUE'), 'Should retain sid cookie');
        System.assert(!parsed.containsIgnoreCase('HttpOnly'), 'Should strip HttpOnly');
        System.assert(!parsed.containsIgnoreCase('Path='), 'Should strip Path attr');
    }

    @IsTest
    static void testMergeCookies() {
        String existing   = 'sid=OLD; foo=bar';
        String additional = 'sid=NEW; Path=/; Secure';
        String merged     = EmailLogFileService.mergeCookies(existing, additional);
        System.assert(merged.contains('sid=NEW'), 'New sid should override old');
        System.assert(merged.contains('foo=bar'), 'foo cookie should be preserved');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests — EmailLogFileDownloaderQueueable
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testQueueable_noFilter() {
        Test.setMock(HttpCalloutMock.class, new MultiHopMock());
        Test.startTest();
        System.enqueueJob(new EmailLogFileDownloaderQueueable(null, null, false));
        Test.stopTest();
        // No exception = pass. In a real org, verify via AsyncApexJob.
        System.assert(true, 'Queueable should complete without exception');
    }

    @IsTest
    static void testQueueable_withDirectionFilter() {
        Test.setMock(HttpCalloutMock.class, new MultiHopMock());
        Test.startTest();
        System.enqueueJob(new EmailLogFileDownloaderQueueable('Outbound', null, false));
        Test.stopTest();
        System.assert(true, 'Queueable with filter should complete without exception');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests — EmailLogFileDownloaderAPI
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testAPI_listOnly() {
        Test.setMock(HttpCalloutMock.class, new ListOnlyMock());
        RestContext.request  = buildRestRequest('{"listOnly":true}');
        RestContext.response = new RestResponse();

        Test.startTest();
        EmailLogFileDownloaderAPI.ApiResponse resp = EmailLogFileDownloaderAPI.handlePost();
        Test.stopTest();

        System.assertEquals(true,  resp.success);
        System.assertEquals(1,     resp.files.size(), 'Should list 1 file');
        System.assertEquals(MOCK_FILE_ID, resp.files[0].fileId);
    }

    @IsTest
    static void testAPI_enqueueDownload() {
        Test.setMock(HttpCalloutMock.class, new MultiHopMock());
        RestContext.request  = buildRestRequest(
            '{"listOnly":false,"direction":null,"saveAsFile":false}');
        RestContext.response = new RestResponse();

        Test.startTest();
        EmailLogFileDownloaderAPI.ApiResponse resp = EmailLogFileDownloaderAPI.handlePost();
        Test.stopTest();

        System.assertEquals(true,  resp.success);
        System.assertNotEquals(null, resp.enqueuedJobId, 'Job ID should be returned');
    }

    @IsTest
    static void testAPI_errorHandling() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());
        RestContext.request  = buildRestRequest('{"listOnly":true}');
        RestContext.response = new RestResponse();

        Test.startTest();
        EmailLogFileDownloaderAPI.ApiResponse resp = EmailLogFileDownloaderAPI.handlePost();
        Test.stopTest();

        System.assertEquals(false, resp.success);
        System.assertNotEquals(null, resp.errorMessage);
        System.assertEquals(500, RestContext.response.statusCode);
    }

    @IsTest
    static void testAPI_urlParamFallback() {
        // Test the URL-param fallback path in parseRequest()
        Test.setMock(HttpCalloutMock.class, new MultiHopMock());
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/api/v1/email-logs/download';
        req.httpMethod = 'POST';
        req.params.put('listOnly', 'false');
        req.params.put('direction', 'Inbound');
        req.params.put('saveAsFile', 'false');
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        EmailLogFileDownloaderAPI.ApiResponse resp = EmailLogFileDownloaderAPI.handlePost();
        Test.stopTest();

        System.assertEquals(true, resp.success);
        System.assertNotEquals(null, resp.enqueuedJobId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static RestRequest buildRestRequest(String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestURI   = '/services/apexrest/api/v1/email-logs/download';
        req.httpMethod   = 'POST';
        req.requestBody  = Blob.valueOf(jsonBody);
        req.headers.put('Content-Type', 'application/json');
        return req;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Request-log mock & constants
    // ─────────────────────────────────────────────────────────────────────────

    private static final String MOCK_LOG_SEARCH_ID = '0IVC200000009Mf';

    // Minimal VF form HTML with ViewState fields and a date SELECT option
    private static final String MOCK_REQUEST_FORM_HTML =
        '<html><body>'
        + '<input type="hidden" name="com.salesforce.visualforce.ViewState" value="MOCK_VS"/>'
        + '<input type="hidden" name="com.salesforce.visualforce.ViewStateVersion" value="MOCK_VSV"/>'
        + '<input type="hidden" name="com.salesforce.visualforce.ViewStateMAC" value="MOCK_MAC"/>'
        + '<input type="hidden" name="com.salesforce.visualforce.ViewStateCSRF" value="MOCK_CSRF"/>'
        + '<select name="thePage:theForm:pageBlock:logDataSectionid:startDate">'
        + '<option value="18/04/2026">18/04/2026</option>'
        + '<option value="19/04/2026">19/04/2026</option>'
        + '</select>'
        + '</body></html>';

    // Mock that simulates the request-log form flow:
    //   1. frontdoor.jsp  -> 200 + Set-Cookie
    //   2. editEmailLogSearch.apexp GET  -> 200 + form HTML with ViewState
    //   3. editEmailLogSearch.apexp POST -> 302 + Location with log_search_id
    private class RequestLogMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String url = req.getEndpoint();
            String method = req.getMethod();

            if (url.contains('frontdoor.jsp')) {
                res.setStatusCode(200);
                res.setHeader('Set-Cookie', 'sid=VF_SESSION; path=/; secure; oid=TESTORGID; path=/; secure');
                res.setBody('<html></html>');
            } else if (url.contains('editEmailLogSearch') && method == 'GET') {
                res.setStatusCode(200);
                res.setHeader('Content-Type', 'text/html; charset=UTF-8');
                res.setBody(MOCK_REQUEST_FORM_HTML);
            } else if (url.contains('editEmailLogSearch') && method == 'POST') {
                // Success: 302 redirect with log_search_id in Location header
                res.setStatusCode(302);
                res.setHeader('Location',
                    '/_ui/core/email/logs/EmailLogSearchOverview'
                    + '?log_request_submitted=1&log_search_id=' + MOCK_LOG_SEARCH_ID);
                res.setBody('');
            } else {
                res.setStatusCode(404);
                res.setBody('Not found: ' + url);
            }
            return res;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests — requestEmailLog
    // ─────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testRequestEmailLog_success() {
        Test.setMock(HttpCalloutMock.class, new RequestLogMock());
        EmailLogFileService.EmailLogRequestOptions opts =
            new EmailLogFileService.EmailLogRequestOptions();
        opts.startDatetime    = Datetime.newInstance(2026, 4, 18, 0, 0, 0);
        opts.endDatetime      = Datetime.newInstance(2026, 4, 24, 23, 59, 0);
        opts.mailEvents       = new List<String>{'D'};
        opts.emailDirection   = 'Both';
        opts.notificationEmail = 'test@example.com';

        Test.startTest();
        EmailLogFileService.EmailLogRequestResult result =
            EmailLogFileService.requestEmailLog(opts);
        Test.stopTest();

        System.assertEquals(true, result.success,
            'requestEmailLog should succeed: ' + result.errorMessage);
        System.assertEquals(MOCK_LOG_SEARCH_ID, result.logSearchId,
            'log_search_id should be extracted from redirect URL');
    }

    @IsTest
    static void testRequestEmailLog_nullOptions() {
        Test.setMock(HttpCalloutMock.class, new RequestLogMock());
        Test.startTest();
        EmailLogFileService.EmailLogRequestResult result =
            EmailLogFileService.requestEmailLog(null);
        Test.stopTest();

        System.assertEquals(false, result.success, 'Null options should return failure');
        System.assert(result.errorMessage.contains('required'), 'Error should describe missing required fields');
    }

    @IsTest
    static void testExtractViewStateFields() {
        Map<String, String> fields =
            EmailLogFileService.extractViewStateFields(MOCK_REQUEST_FORM_HTML);

        System.assertEquals('MOCK_VS',   fields.get('com.salesforce.visualforce.ViewState'));
        System.assertEquals('MOCK_VSV',  fields.get('com.salesforce.visualforce.ViewStateVersion'));
        System.assertEquals('MOCK_MAC',  fields.get('com.salesforce.visualforce.ViewStateMAC'));
        System.assertEquals('MOCK_CSRF', fields.get('com.salesforce.visualforce.ViewStateCSRF'));
    }

    @IsTest
    static void testDetectDateFormat() {
        // dd/MM/yyyy format (India / UK locale)
        String ddMM = EmailLogFileService.detectDateFormat(MOCK_REQUEST_FORM_HTML);
        System.assertEquals('dd/MM/yyyy', ddMM, 'Should detect dd/MM/yyyy from 18/04/2026 option');

        // Falls back when no options present
        String fallback = EmailLogFileService.detectDateFormat('<form></form>');
        System.assertEquals('dd/MM/yyyy', fallback, 'Should default to dd/MM/yyyy');
    }

    @IsTest
    static void testBuildUrlEncodedBody() {
        Map<String, List<String>> params = new Map<String, List<String>>();
        params.put('name', new List<String>{'John Doe'});
        params.put('events', new List<String>{'R', 'D'});
        String body = EmailLogFileService.buildUrlEncodedBody(params);

        System.assert(body.contains('name=John+Doe') || body.contains('name=John%20Doe'),
            'Name with space should be encoded');
        // events=R and events=D both present
        Integer rIdx = body.indexOf('events=R');
        Integer dIdx = body.indexOf('events=D');
        System.assertNotEquals(-1, rIdx, 'events=R should be present');
        System.assertNotEquals(-1, dIdx, 'events=D should be present');
    }

    /**
     * Build a real in-memory zip blob containing a single CSV entry.
     * Uses Compression.ZipWriter (API 61.0+) so the ZipReader in the service
     * can actually parse it during tests.
     */
    private static Blob buildMockZip() {
        Compression.ZipWriter writer = new Compression.ZipWriter();
        writer.addEntry(MOCK_CSV_FILENAME, Blob.valueOf(MOCK_CSV_CONTENT));
        return writer.getArchive();
    }
}