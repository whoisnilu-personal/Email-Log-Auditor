/*------------------------------------------------------------------------------------
Developer:    GitHub Copilot (reverse-engineered - previously undocumented)
Class:        EmailLogFileService
Description:  Programmatically downloads Email Log zip files from Salesforce Setup
              using the current running user's session, without any browser interaction.

              TECHNICAL BACKGROUND
              ---------------------
              Email Log Files (Setup > Email > Email Log Files) are served by a
              Classic (Aloha) Visualforce page. They are NOT exposed via SOQL, REST
              API, or Tooling API. The internal 0BRC-prefix file IDs are embedded
              server-side in the VF page HTML and must be scraped out.

              AUTHENTICATION — 2-STEP COOKIE FLOW
              ----------------------------------------
              Apex CAN set Cookie request headers (contrary to some older docs).
              The correct pattern for VF Classic page access is:

              Step 1: GET {instanceDomain}/secur/frontdoor.jsp?sid=SESSION_ID
                      Salesforce validates the session and returns HTTP 200 with
                      Set-Cookie headers containing a VF-scoped sid and oid cookie.

              Step 2: GET {instanceDomain}/_ui/core/email/logs/EmailLogSearchOverview
                          ?isdtp=p1
                      with Cookie: sid=VF_SID; oid=ORG_ID
                      → 200 HTML page containing srcUp(%27%2Fservlet...%27) links

              Step 3: GET {instanceDomain}/servlet/servlet.FileDownload
                          ?file={0BRC_ID}&isdtp=p1
                      with Cookie: sid=VF_SID; oid=ORG_ID
                      → 200 application/zip (direct, no hop chain needed)

              HOW IT WORKS IN APEX
              ----------------------
              1. Call frontdoor.jsp with the Apex session ID → capture Set-Cookie.
              2. Parse sid and oid from the Set-Cookie response header.
              3. Fetch the VF overview page on the instance domain with that cookie.
              4. Parse the returned HTML for srcUp(%27%2Fservlet... patterns.
              5. For each file, call the download servlet with the same cookie.
              6. Decompress the zip using Compression.ZipReader (API 61.0+).
              7. Store CSV content as ContentDocument (File) linked to the given
                 parentId (or the running user's profile if none provided).

              CALLOUT REQUIREMENTS
              ----------------------
              - Must be called from an async context (Queueable, Future, Batch).
              - The named credential / Remote Site Setting for the org's own
                domains must allow calls FROM Apex to itself (add both
                {orgDomain}.my.salesforce.com and
                {orgDomain}.my.salesforce-setup.com as Remote Site entries).
              - Permission: "Manage Email Log Files" is required to view the page.

Test Class:   EmailLogFileServiceTest
History
Date           Author             Comments
--------------------------------------------------------------------------------------
25-04-2026    GitHub Copilot     Initial Release (reverse-engineered undocumented API)
------------------------------------------------------------------------------------*/
public without sharing class EmailLogFileService {

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    private static final String VF_OVERVIEW_PATH =
        '/_ui/core/email/logs/EmailLogSearchOverview?isdtp=p1';

    private static final String REQUEST_FORM_PATH =
        '/email/logs/editEmailLogSearch.apexp?isdtp=p1';

    // Regex to parse each ViewState hidden-input from VF page HTML.
    // Handles both attribute orderings (name...value and value...name).
    private static final String VIEWSTATE_NAME_FIRST_PATTERN =
        'name="(com\\.salesforce\\.visualforce\\.[A-Za-z]+)"[^<>]*value="([^"]*)"';
    private static final String VIEWSTATE_VALUE_FIRST_PATTERN =
        'value="([^"]*)"[^<>]*name="(com\\.salesforce\\.visualforce\\.[A-Za-z]+)"';

    // Prefix of a log_search_id in the success-redirect URL
    private static final String LOG_SEARCH_ID_PARAM = 'log_search_id=';

    // Both quote-styles appear in wild: literal ' and URL-encoded %27
    // Pattern captures: group(1) = full encoded servlet path, group(2) = file ID segment
    // Both URL-encoded quote styles: %27 (literal string %27) or ' (char)
    // File ID is alphanumeric; trailing params like %26isdtp%3Dp1 are consumed
    // lazily by [^']* before the closing quote.
    private static final String FILE_ID_PATTERN =
        'srcUp\\((?:\'|%27)(%2Fservlet%2Fservlet\\.FileDownload%3Ffile%3D([A-Za-z0-9]+)[^\']*?)(?:\'|%27)\\)';

    private static final String TITLE_PATTERN   = 'title="([^"]+)"';
    private static final String FILENAME_PATTERN = 'filename="([^"]+)"';

    private static final Integer HTTP_TIMEOUT_MS = 30000;
    private static final Integer MAX_HOPS        = 8;

    // ─────────────────────────────────────────────────────────────────────────
    // Public result type
    // ─────────────────────────────────────────────────────────────────────────

    public class EmailLogEntry {
        /** Internal Salesforce 0BRC-prefix file ID (not queryable via SOQL). */
        public String  fileId;
        /** Human-readable label from the anchor title attribute on the VF page. */
        public String  label;
        /** Relative servlet URL: /servlet/servlet.FileDownload?file=0BRC...&isdtp=p1 */
        public String  servletPath;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Request-log types
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Options for programmatically requesting a new Email Log file.
     * Start/end must be within the past 30 days;
     * the window must be ≤ 7 days; endDatetime must be before now.
     */
    public class EmailLogRequestOptions {
        /** Start of the log window (inclusive). Required. */
        public Datetime startDatetime;
        /** End of the log window (exclusive). Required. Must be before now and ≤ 7 days after start. */
        public Datetime endDatetime;
        /** Optional: comma-delimited email addresses / domains to filter on. */
        public String   searchString;
        /**
         * Mail event types to include. Valid values: R (Reception), D (Delivery),
         * T (Transient Failure), P (Permanent Failure).
         * Pass null or empty list to include all four.
         */
        public List<String> mailEvents;
        /**
         * Direction filter. Valid values: Outbound, Inbound, Both.
         * Defaults to Both when null.
         */
        public String   emailDirection;
        /**
         * Email address to notify when the log is ready.
         * Defaults to UserInfo.getUserEmail() when null.
         */
        public String   notificationEmail;
    }

    /** Result returned by requestEmailLog(). */
    public class EmailLogRequestResult {
        /** True when the request was accepted by Salesforce. */
        public Boolean success;
        /**
         * The 0IVC-prefixed internal ID of the new pending email log request,
         * extracted from the success-redirect URL's log_search_id parameter.
         * Use this to correlate with the entry that eventually appears in listAvailableLogs().
         */
        public String  logSearchId;
        /** Error message when success = false. */
        public String  errorMessage;
    }

    public class DownloadResult {
        /** The EmailLogEntry this result corresponds to. */
        public EmailLogEntry   entry;
        /** Zip file name as returned by Content-Disposition. */
        public String          zipFilename;
        /** CSV file name inside the zip (same prefix, .csv extension). */
        public String          csvFilename;
        /** Full CSV text content. */
        public String          csvContent;
        /** ContentDocumentId of the saved File (null if saveAsFile = false). */
        public Id              contentDocumentId;
        /** True when the download + parse completed without error. */
        public Boolean         success;
        /** Error message if success = false. */
        public String          errorMessage;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Main public API
    // ─────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────
    // Request new email log
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Programmatically request a new Email Log file from Salesforce Setup.
     *
     * FLOW (reverse-engineered — not officially documented):
     *   1. GET /email/logs/editEmailLogSearch.apexp  → extract VF ViewState
     *   2. POST same URL with form fields + ViewState → Salesforce returns 302
     *   3. Parse log_search_id from the Location / redirect URL
     *
     * The returned logSearchId (0IVC...) identifies the pending request.
     * After processing (typically a few minutes), it appears in listAvailableLogs()
     * with a download link.
     *
     * @param opts  Request parameters. startDatetime and endDatetime are required.
     * @return EmailLogRequestResult with success=true and the logSearchId on success.
     */
    public static EmailLogRequestResult requestEmailLog(EmailLogRequestOptions opts) {
        EmailLogRequestResult result = new EmailLogRequestResult();
        result.success = false;

        try {
            if (opts == null || opts.startDatetime == null || opts.endDatetime == null) {
                result.errorMessage = 'startDatetime and endDatetime are required.';
                return result;
            }

            String instanceDomain = getInstanceDomain();
            String vfCookies      = getVFSessionCookie(instanceDomain, UserInfo.getSessionId());

            // ── Step 1: GET the form page to obtain a fresh ViewState ──
            String formUrl = instanceDomain + REQUEST_FORM_PATH;
            HttpRequest getReq = buildGetRequest(formUrl, vfCookies);
            HttpResponse getRes = new Http().send(getReq);
            if (getRes.getStatusCode() != 200) {
                result.errorMessage = 'Could not load Email Log Request form (HTTP '
                    + getRes.getStatusCode() + ')';
                return result;
            }

            Map<String, String> vsFields = extractViewStateFields(getRes.getBody());
            if (vsFields.isEmpty()) {
                result.errorMessage = 'No ViewState found on Email Log Request form. '
                    + 'Ensure the running user has "Manage Email Log Files" permission.';
                return result;
            }

            // ── Step 2: Build POST body ──
            // Date format comes from the form's SELECT options: dd/MM/yyyy
            String dateFormat = detectDateFormat(getRes.getBody());
            // Time: 12-hour h:mm am/pm (Apex 'h:mm a' gives uppercase, toLower fixes)
            String startDateStr = opts.startDatetime.format(dateFormat);
            String startTimeStr = opts.startDatetime.format('h:mm a').toLowerCase();
            String endDateStr   = opts.endDatetime.format(dateFormat);
            String endTimeStr   = opts.endDatetime.format('h:mm a').toLowerCase();

            Map<String, List<String>> params = new Map<String, List<String>>();

            // Hidden form ID field (static)
            params.put('thePage:theForm', new List<String>{'thePage:theForm'});

            // Dates & times
            params.put('thePage:theForm:pageBlock:logDataSectionid:startDate',
                       new List<String>{startDateStr});
            params.put('thePage:theForm:pageBlock:logDataSectionid:startTime',
                       new List<String>{startTimeStr});
            params.put('thePage:theForm:pageBlock:logDataSectionid:endDate',
                       new List<String>{endDateStr});
            params.put('thePage:theForm:pageBlock:logDataSectionid:endTime',
                       new List<String>{endTimeStr});

            // Optional email filter
            params.put('thePage:theForm:pageBlock:logDataSectionid:searchString',
                       new List<String>{opts.searchString != null ? opts.searchString : ''});

            // Mail events: default to all four when not specified
            List<String> mailEvents = (opts.mailEvents != null && !opts.mailEvents.isEmpty())
                ? opts.mailEvents
                : new List<String>{'R', 'D', 'T', 'P'};
            params.put('thePage:theForm:pageBlock:logDataSectionid:mailEventTypes', mailEvents);

            // Email direction: default Both
            String direction = String.isNotBlank(opts.emailDirection) ? opts.emailDirection : 'Both';
            params.put('thePage:theForm:pageBlock:logDataSectionid:emailDirectionTypes',
                       new List<String>{direction});

            // Notification email: default to running user
            String notifEmail = String.isNotBlank(opts.notificationEmail)
                ? opts.notificationEmail
                : UserInfo.getUserEmail();
            params.put('thePage:theForm:pageBlock:deliveryNotificationsSection:sendNotification',
                       new List<String>{notifEmail});

            // Submit button (required to identify which submit was clicked)
            params.put('thePage:theForm:pageBlock:buttonsSection:submitBtn',
                       new List<String>{'Submit Request'});

            // ViewState fields from Step 1
            for (String vsName : vsFields.keySet()) {
                params.put(vsName, new List<String>{vsFields.get(vsName)});
            }

            // ── Step 3: POST ──
            String postBody = buildUrlEncodedBody(params);
            HttpRequest postReq = new HttpRequest();
            postReq.setMethod('POST');
            postReq.setEndpoint(formUrl);
            postReq.setTimeout(HTTP_TIMEOUT_MS);
            postReq.setHeader('Cookie', vfCookies);
            postReq.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            postReq.setBody(postBody);

            HttpResponse postRes = new Http().send(postReq);
            Integer status = postRes.getStatusCode();

            // ── Step 4: Extract log_search_id from redirect URL ──
            // Salesforce returns 302 with Location containing log_search_id
            // OR 200 if the redirect was already followed to the listing page
            String redirectUrl = postRes.getHeader('Location');
            String responseBody = postRes.getBody();

            // Check Location header (302 redirect)
            String logSearchId = extractLogSearchId(redirectUrl);

            // Fallback: check if response body URL contains log_search_id
            // (some Apex HTTP configs auto-follow POST redirects)
            if (String.isBlank(logSearchId)) {
                logSearchId = extractLogSearchId(responseBody);
            }

            // Fallback: check body for JS redirect
            if (String.isBlank(logSearchId)) {
                String jsUrl = extractJsRedirectUrl(responseBody);
                logSearchId = extractLogSearchId(jsUrl);
            }

            if (String.isBlank(logSearchId) && status >= 300 && status < 400) {
                result.errorMessage = 'Request may have succeeded (HTTP ' + status
                    + ') but could not extract log_search_id from Location: ' + redirectUrl;
                return result;
            }

            if (String.isBlank(logSearchId) && (status < 200 || status >= 400)) {
                result.errorMessage = 'Email Log Request form POST failed (HTTP ' + status
                    + '). Body snippet: '
                    + (responseBody != null ? responseBody.abbreviate(400) : 'null');
                return result;
            }

            result.success     = true;
            result.logSearchId = logSearchId;

        } catch (Exception ex) {
            result.success      = false;
            result.errorMessage = ex.getTypeName() + ': ' + ex.getMessage();
        }
        return result;
    }

    /**
     * Fetch available email log file entries from Setup without downloading them.
     *
     * @return List of EmailLogEntry records describing each downloadable file.
     */
    public static List<EmailLogEntry> listAvailableLogs() {
        String instanceDomain = getInstanceDomain();
        String vfCookies      = getVFSessionCookie(instanceDomain, UserInfo.getSessionId());
        String pageHtml       = fetchVFOverviewPage(instanceDomain, vfCookies);
        return parseEmailLogEntries(pageHtml);
    }

    /**
     * Download all available email log files and return their CSV content.
     * Optionally save each as a ContentDocument File attached to parentId.
     *
     * @param parentId    SObject record to link files to (e.g., a Task Id).
     *                    Pass null to skip file attachment.
     * @param saveAsFile  When true, each CSV is stored as a ContentDocument.
     * @return List of DownloadResult — one per entry found on the VF page.
     */
    public static List<DownloadResult> downloadAllLogs(Id parentId, Boolean saveAsFile) {
        String instanceDomain = getInstanceDomain();
        String vfCookies      = getVFSessionCookie(instanceDomain, UserInfo.getSessionId());
        String pageHtml       = fetchVFOverviewPage(instanceDomain, vfCookies);
        List<EmailLogEntry> entries = parseEmailLogEntries(pageHtml);

        // Phase 1: ALL callouts first — no DML allowed between callouts in Apex.
        // Pass saveAsFile=false so downloadSingleLog never inserts during this phase.
        List<DownloadResult> results = new List<DownloadResult>();
        for (EmailLogEntry entry : entries) {
            DownloadResult res = downloadSingleLog(entry, instanceDomain, vfCookies, null, false);
            results.add(res);
        }

        // Phase 2: ALL DML after every callout is done.
        if (saveAsFile == true) {
            for (DownloadResult res : results) {
                if (res.success) {
                    try {
                        res.contentDocumentId = saveContentDocument(
                            res.csvFilename, res.csvContent, res.entry.label, parentId
                        );
                    } catch (Exception ex) {
                        res.success      = false;
                        res.errorMessage = ex.getTypeName() + ': ' + ex.getMessage();
                    }
                }
            }
        }
        return results;
    }

    /**
     * Download a single log file by its 0BRC file ID.
     * Use listAvailableLogs() first to obtain a valid fileId.
     *
     * @param fileId      The 0BRC-prefixed internal ID (e.g. '0BRC2000000096X').
     * @param label       Human-readable label (used as ContentDocument title).
     * @param parentId    SObject record to link the file to, or null.
     * @param saveAsFile  When true, CSV is stored as a ContentDocument.
     * @return DownloadResult
     */
    public static DownloadResult downloadById(String fileId, String label, Id parentId, Boolean saveAsFile) {
        String instanceDomain = getInstanceDomain();
        String vfCookies      = getVFSessionCookie(instanceDomain, UserInfo.getSessionId());

        EmailLogEntry entry = new EmailLogEntry();
        entry.fileId      = fileId;
        entry.label       = label != null ? label : fileId;
        entry.servletPath = '/servlet/servlet.FileDownload?file=' + fileId + '&isdtp=p1';

        return downloadSingleLog(entry, instanceDomain, vfCookies, parentId, saveAsFile);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Domain / URL helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Return the org's instance domain (my.salesforce.com), no trailing slash.
     */
    @TestVisible
    private static String getInstanceDomain() {
        String instanceUrl = URL.getOrgDomainUrl().toExternalForm();
        if (instanceUrl.endsWith('/')) {
            instanceUrl = instanceUrl.left(instanceUrl.length() - 1);
        }
        return instanceUrl;
    }

    /**
     * Derive the Setup (Aloha) domain from the running org's instance URL.
     * e.g. https://myorg.sandbox.my.salesforce.com
     *   →  https://myorg.sandbox.my.salesforce-setup.com
     * Kept for potential direct-servlet-on-setup-domain fallback scenarios.
     */
    @TestVisible
    private static String getSetupDomain() {
        String instanceUrl = getInstanceDomain();
        if (instanceUrl.contains('salesforce-setup.com')) {
            return instanceUrl;
        }
        return instanceUrl.replace('my.salesforce.com', 'my.salesforce-setup.com');
    }

    /**
     * Obtain a VF-scoped session cookie by calling frontdoor.jsp with the current
     * Apex session ID. frontdoor.jsp returns HTTP 200 with Set-Cookie headers
     * containing a VF-domain sid that the Classic email-log pages accept.
     *
     * @param instanceDomain  https://org.my.salesforce.com (no trailing slash)
     * @param sessionId       UserInfo.getSessionId()
     * @return                Cookie header value: "sid=VALUE; oid=VALUE"
     */
    @TestVisible
    private static String getVFSessionCookie(String instanceDomain, String sessionId) {
        String frontdoorUrl = instanceDomain + '/secur/frontdoor.jsp?sid='
            + EncodingUtil.urlEncode(sessionId, 'UTF-8')
            + '&retURL=' + EncodingUtil.urlEncode(VF_OVERVIEW_PATH, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(frontdoorUrl);
        req.setTimeout(HTTP_TIMEOUT_MS);
        HttpResponse res = new Http().send(req);

        String rawSetCookie = res.getHeader('Set-Cookie');
        if (String.isBlank(rawSetCookie)) {
            throw new EmailLogServiceException(
                'frontdoor.jsp returned no Set-Cookie header (HTTP ' + res.getStatusCode() + '). '
                + 'Ensure the running user has a valid session and "Manage Email Log Files" permission.');
        }

        String sidVal = '';
        String oidVal = '';
        for (String seg : rawSetCookie.split(';')) {
            String s = seg.trim();
            if (s.startsWith('sid=') && String.isBlank(sidVal)) {
                sidVal = s.substring(4);
            }
            if (s.startsWith('oid=') && String.isBlank(oidVal)) {
                oidVal = s.substring(4);
            }
        }

        if (String.isBlank(sidVal)) {
            throw new EmailLogServiceException(
                'Could not extract sid cookie from frontdoor.jsp Set-Cookie response.');
        }

        return 'sid=' + sidVal + (String.isNotBlank(oidVal) ? '; oid=' + oidVal : '');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 1 — Fetch VF overview page
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fetch the Classic VF email log listing page using a pre-obtained VF session
     * cookie. The cookie must have been retrieved via getVFSessionCookie().
     *
     * @param instanceDomain  https://org.my.salesforce.com (no trailing slash)
     * @param vfCookies       "sid=VALUE; oid=VALUE" from getVFSessionCookie()
     * @return                HTML body of the email log overview page
     */
    @TestVisible
    private static String fetchVFOverviewPage(String instanceDomain, String vfCookies) {
        String currentUrl = instanceDomain + VF_OVERVIEW_PATH;

        for (Integer hop = 0; hop < MAX_HOPS; hop++) {
            HttpRequest req = buildGetRequest(currentUrl, vfCookies);
            HttpResponse res = new Http().send(req);
            Integer status = res.getStatusCode();

            if (status == 200) {
                String body = res.getBody();
                if (body.contains('FileDownload') || body.contains('srcUp')) {
                    return body;
                }
                throw new EmailLogServiceException(
                    'VF page loaded (HTTP 200) but contains no Email Log download links. '
                    + 'Ensure the running user has "Manage Email Log Files" permission '
                    + 'and that email log files have been generated for this org.'
                );
            }

            if (status >= 300 && status < 400) {
                String location = res.getHeader('Location');
                if (String.isNotBlank(location)) {
                    currentUrl = location;
                    continue;
                }
                throw new EmailLogServiceException(
                    'HTTP ' + status + ' redirect with no Location header at: ' + currentUrl
                );
            }

            throw new EmailLogServiceException(
                'Unexpected HTTP ' + status + ' fetching VF overview page at: ' + currentUrl
            );
        }
        throw new EmailLogServiceException(
            'Could not load VF email log page after ' + MAX_HOPS + ' redirects.'
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 2 — Parse file entries from HTML
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Extract all EmailLogEntry records from the VF page HTML.
     *
     * The page uses double-URL-encoded srcUp() calls:
     *   srcUp(%27%2Fservlet%2Fservlet.FileDownload%3Ffile%3D0BRC...%26isdtp%3Dp1%27)
     */
    @TestVisible
    private static List<EmailLogEntry> parseEmailLogEntries(String pageHtml) {
        List<EmailLogEntry> entries = new List<EmailLogEntry>();

        // Find all srcUp() occurrences
        Pattern  filePattern = Pattern.compile(FILE_ID_PATTERN);
        Matcher  fileMatcher = filePattern.matcher(pageHtml);
        Pattern  titlePat    = Pattern.compile(TITLE_PATTERN);

        while (fileMatcher.find()) {
            String encodedServletPath = fileMatcher.group(1);
            String rawFileIdSegment   = fileMatcher.group(2);

            // Decode %2F -> / etc.
            String servletPath = EncodingUtil.urlDecode(encodedServletPath, 'UTF-8');
            String fileId      = rawFileIdSegment.split('&')[0].split('%')[0];

            // Extract label from the anchor's title attribute in surrounding context
            Integer contextStart = Math.max(0, fileMatcher.start() - 50);
            Integer contextEnd   = Math.min(pageHtml.length(), fileMatcher.end() + 800);
            String contextHtml   = pageHtml.substring(contextStart, contextEnd);

            String label = fileId;
            Matcher titleMatcher = titlePat.matcher(contextHtml);
            if (titleMatcher.find()) {
                label = htmlUnescape(titleMatcher.group(1));
            }

            EmailLogEntry entry = new EmailLogEntry();
            entry.fileId      = fileId;
            entry.label       = label;
            entry.servletPath = servletPath;
            entries.add(entry);
        }
        return entries;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 3 — Download a single zip, parse CSV
    // ─────────────────────────────────────────────────────────────────────────

    @TestVisible
    private static DownloadResult downloadSingleLog(
        EmailLogEntry entry,
        String        instanceDomain,
        String        vfCookies,
        Id            parentId,
        Boolean       saveAsFile
    ) {
        DownloadResult result = new DownloadResult();
        result.entry   = entry;
        result.success = false;

        try {
            String currentUrl = instanceDomain + entry.servletPath;
            Blob   zipBlob    = null;
            String filename   = 'EmailLog_' + entry.fileId + '.zip';

            for (Integer hop = 0; hop < MAX_HOPS; hop++) {
                HttpRequest  req  = buildGetRequest(currentUrl, vfCookies);
                HttpResponse resp = new Http().send(req);

                Integer status = resp.getStatusCode();

                if (status == 200) {
                    String ct = resp.getHeader('Content-Type');
                    if (ct != null && ct.containsIgnoreCase('zip')) {
                        zipBlob = resp.getBodyAsBlob();
                        String cd = resp.getHeader('Content-Disposition');
                        if (String.isNotBlank(cd)) {
                            Pattern fnPat = Pattern.compile(FILENAME_PATTERN);
                            Matcher fnMat = fnPat.matcher(cd);
                            if (fnMat.find()) {
                                filename = fnMat.group(1);
                            }
                        }
                        break;  // Download complete
                    }
                    throw new EmailLogServiceException(
                        'Servlet returned HTTP 200 but Content-Type was not application/zip: ' + ct
                        + ' (URL: ' + currentUrl + ')'
                    );
                }

                if (status >= 300 && status < 400) {
                    String location = resp.getHeader('Location');
                    if (String.isBlank(location)) {
                        throw new EmailLogServiceException(
                            'Redirect with no Location header at: ' + currentUrl
                        );
                    }
                    currentUrl = location;
                    continue;
                }

                throw new EmailLogServiceException(
                    'Unexpected HTTP ' + status + ' downloading file ' + entry.fileId
                    + ' at: ' + currentUrl
                );
            }

            if (zipBlob == null) {
                throw new EmailLogServiceException(
                    'Failed to download zip for ' + entry.fileId + ' after ' + MAX_HOPS + ' hops.'
                );
            }

            // Parse the zip using Compression.ZipReader (Apex API 61.0+)
            String csvFilename = null;
            String csvContent  = null;

            Compression.ZipReader reader = new Compression.ZipReader(zipBlob);
            List<String> entries2 = reader.getEntryNames();
            for (String fname : entries2) {
                if (fname.endsWithIgnoreCase('.csv')) {
                    csvFilename = fname;
                    Blob csvBlob = reader.extract(fname);
                    csvContent = csvBlob != null ? csvBlob.toString() : null;
                    break;
                }
            }

            if (String.isBlank(csvContent)) {
                throw new EmailLogServiceException(
                    'Zip for ' + entry.fileId + ' contained no CSV file. '
                    + 'Files found: ' + String.join(entries2, ', ')
                );
            }

            result.zipFilename = filename;
            result.csvFilename = csvFilename;
            result.csvContent  = csvContent;
            result.success     = true;

            // Optionally persist as ContentDocument (File)
            if (saveAsFile == true) {
                result.contentDocumentId = saveContentDocument(
                    csvFilename,
                    csvContent,
                    entry.label,
                    parentId
                );
            }

        } catch (Exception ex) {
            result.success      = false;
            result.errorMessage = ex.getTypeName() + ': ' + ex.getMessage();
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 4 — Save as ContentDocument (File)
    // ─────────────────────────────────────────────────────────────────────────

    private static Id saveContentDocument(
        String csvFilename,
        String csvContent,
        String title,
        Id     parentId
    ) {
        ContentVersion cv = new ContentVersion();
        cv.Title           = title != null ? title.abbreviate(255) : csvFilename;
        cv.PathOnClient    = csvFilename != null ? csvFilename : 'EmailLog.csv';
        cv.VersionData     = Blob.valueOf(csvContent);
        cv.IsMajorVersion  = true;
        insert cv;

        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1]
                   .ContentDocumentId;

        if (parentId != null) {
            ContentDocumentLink link = new ContentDocumentLink();
            link.ContentDocumentId = docId;
            link.LinkedEntityId    = parentId;
            link.ShareType         = 'V';
            link.Visibility        = 'AllUsers';
            insert link;
        }
        return docId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HTTP helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Extract a JavaScript redirect URL from HTML that uses:
     *   window.location.replace("URL")  or  window.location.href="URL"
     *
     * Salesforce enhanced domains (introduced ~API 62) have frontdoor.jsp and
     * contentDoor return HTTP 200 with a JS page instead of HTTP 302, so Apex
     * Http callouts (which don't execute JS) need this to follow the chain.
     */
    @TestVisible
    private static String extractJsRedirectUrl(String htmlBody) {
        if (String.isBlank(htmlBody)) return null;
        // Handle both double-quoted and single-quoted JS redirects:
        //   window.location.replace("URL")  or  window.location.replace('URL')
        //   window.location.href="URL"      or  window.location.href='URL'
        // Salesforce enhanced domains use double quotes in frontdoor.jsp / contentDoor,
        // but single quotes in the AuraAloha frame navigator wrapper pages.
        Pattern p = Pattern.compile(
            'window\\.location\\.(?:replace\\([\'"]([^\'"]+)[\'"]|href=[\'"]([^\'"]+)[\'"])'
        );
        Matcher m = p.matcher(htmlBody);
        if (m.find()) {
            String g1 = m.group(1);
            return String.isNotBlank(g1) ? g1 : m.group(2);
        }
        return null;
    }

    private static HttpRequest buildGetRequest(String url, String cookieHeader) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(url);
        req.setTimeout(HTTP_TIMEOUT_MS);
        if (String.isNotBlank(cookieHeader)) {
            req.setHeader('Cookie', cookieHeader);
        }
        return req;
    }

    /**
     * Parse a raw Set-Cookie header string into a "name=value; name=value" string
     * suitable for use as a Cookie header value.
     *
     * Handles both comma-separated multi-cookie and single cookie strings.
     * Strips path=, expires=, domain=, secure, httponly attributes.
     */
    @TestVisible
    private static String parseCookieValues(String setCookieHeader) {
        List<String> pairs = new List<String>();
        // Split on ", " only when followed by a cookie name= (not expires dates)
        // Simple approach: split on ";" and collect first token of each segment
        List<String> segments = setCookieHeader.split(';');
        for (String seg : segments) {
            String trimmed = seg.trim();
            // Skip attribute tokens
            if (trimmed.startsWithIgnoreCase('path=')
                || trimmed.startsWithIgnoreCase('expires=')
                || trimmed.startsWithIgnoreCase('domain=')
                || trimmed.startsWithIgnoreCase('max-age=')
                || trimmed.startsWithIgnoreCase('samesite=')
                || trimmed.equalsIgnoreCase('secure')
                || trimmed.equalsIgnoreCase('httponly')) {
                continue;
            }
            if (trimmed.contains('=')) {
                pairs.add(trimmed);
            }
        }
        return String.join(pairs, '; ');
    }

    /**
     * Merge additional Set-Cookie values into an existing cookie string.
     * Later values override earlier ones for the same cookie name.
     */
    @TestVisible
    private static String mergeCookies(String existing, String additional) {
        Map<String, String> cookieMap = new Map<String, String>();

        // Parse existing
        for (String pair : existing.split(';')) {
            String t = pair.trim();
            if (t.contains('=')) {
                Integer eq = t.indexOf('=');
                cookieMap.put(t.substring(0, eq).trim(), t.substring(eq + 1).trim());
            }
        }
        // Parse additional (may be a raw Set-Cookie header)
        String parsed = parseCookieValues(additional);
        for (String pair : parsed.split(';')) {
            String t = pair.trim();
            if (t.contains('=')) {
                Integer eq = t.indexOf('=');
                cookieMap.put(t.substring(0, eq).trim(), t.substring(eq + 1).trim());
            }
        }

        List<String> result = new List<String>();
        for (String name : cookieMap.keySet()) {
            result.add(name + '=' + cookieMap.get(name));
        }
        return String.join(result, '; ');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Request-log helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Extract all com.salesforce.visualforce.* hidden-input values from VF page HTML.
     * Returns a map of field name → value.
     */
    @TestVisible
    private static Map<String, String> extractViewStateFields(String html) {
        Map<String, String> fields = new Map<String, String>();
        if (String.isBlank(html)) return fields;

        // name before value
        Pattern p1 = Pattern.compile(VIEWSTATE_NAME_FIRST_PATTERN);
        Matcher m1 = p1.matcher(html);
        while (m1.find()) {
            fields.put(m1.group(1), m1.group(2));
        }
        // value before name (fallback)
        Pattern p2 = Pattern.compile(VIEWSTATE_VALUE_FIRST_PATTERN);
        Matcher m2 = p2.matcher(html);
        while (m2.find()) {
            if (!fields.containsKey(m2.group(2))) {
                fields.put(m2.group(2), m2.group(1));
            }
        }
        return fields;
    }

    /**
     * Detect the date format used in the startDate SELECT's option values.
     * Falls back to 'dd/MM/yyyy' (India / most non-US locales).
     * Salesforce renders options matching the running user's locale date format.
     */
    @TestVisible
    private static String detectDateFormat(String formHtml) {
        // Look for: <option value="DD/MM/YYYY"> or value="MM/DD/YYYY" or value="YYYY-MM-DD"
        // We peek at the first <option value="..."> in the startDate SELECT block
        Pattern p = Pattern.compile('<option[^>]*value="(\\d{2}/\\d{2}/\\d{4})"');
        Matcher m = p.matcher(formHtml);
        if (m.find()) {
            String sample = m.group(1);  // e.g. '26/03/2026' or '03/26/2026'
            // If the middle segment > 12 it must be a day (dd/MM/yyyy)
            // Otherwise default to dd/MM/yyyy — covers most Salesforce locales
            String[] parts = sample.split('/');
            if (parts.size() == 3 && Integer.valueOf(parts[1]) > 12) {
                return 'MM/dd/yyyy'; // US locale: month first, day middle > 12
            }
            return 'dd/MM/yyyy';
        }
        return 'dd/MM/yyyy';
    }

    /**
     * Extract log_search_id=0IVC... from a URL string or page body.
     * Returns null if not found.
     */
    private static String extractLogSearchId(String text) {
        if (String.isBlank(text)) return null;
        Integer idx = text.indexOf(LOG_SEARCH_ID_PARAM);
        if (idx == -1) return null;
        String rest = text.substring(idx + LOG_SEARCH_ID_PARAM.length());
        // Value ends at next '&', '"', ' ', or end of string
        Pattern p = Pattern.compile('^([A-Za-z0-9]+)');
        Matcher m = p.matcher(rest);
        return m.find() ? m.group(1) : null;
    }

    /**
     * Build an application/x-www-form-urlencoded body from a map of
     * param name → list of values (supports repeated params for checkboxes).
     */
    @TestVisible
    private static String buildUrlEncodedBody(Map<String, List<String>> params) {
        List<String> parts = new List<String>();
        for (String name : params.keySet()) {
            String encodedName = EncodingUtil.urlEncode(name, 'UTF-8');
            for (String val : params.get(name)) {
                parts.add(encodedName + '=' + EncodingUtil.urlEncode(val != null ? val : '', 'UTF-8'));
            }
        }
        return String.join(parts, '&');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // String helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Unescape HTML entities: &amp; &quot; &lt; &gt; &#39;
     * Apex has no built-in htmlDecode in all versions; handle common cases.
     */
    @TestVisible
    private static String htmlUnescape(String input) {
        if (String.isBlank(input)) return input;
        return input
            .replace('&amp;',  '&')
            .replace('&quot;', '"')
            .replace('&#39;',  '\'')
            .replace('&lt;',   '<')
            .replace('&gt;',   '>');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Custom exception
    // ─────────────────────────────────────────────────────────────────────────

    public class EmailLogServiceException extends Exception {}
}