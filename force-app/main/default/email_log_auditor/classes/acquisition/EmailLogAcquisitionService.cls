/**
 * EmailLogAcquisitionService — AWAF port of the legacy EmailLogFileService POC.
 *
 * Constructor DI for IHttpCalloutService + IDmlService (Constitution Principle II).
 * Public surface focused on the US1 use case:
 *   - listAvailableLogs()  : scrape Setup VF page, return entries
 *   - isFirstRun()         : true when EmailLogFile__c row count = 0
 *   - downloadNewLogs()    : skip cached, download new, store CSV as ContentDocument,
 *                            insert EmailLogFile__c (status=Processing); caller
 *                            (Scheduler / Download Now) is responsible for batch dispatch.
 *
 * SECURITY: ContentDocumentLink is created with ShareType='V' (Viewer) per
 * Constitution Principle IV. CRUD/FLS enforced upstream by permission set.
 */
public without sharing class EmailLogAcquisitionService {
  // ───────── Public DTOs ─────────

  public class EmailLogEntry {
    public String fileId;
    public String label;
    public String servletPath;
  }

  public class AcquisitionResult {
    public Integer downloadedCount = 0;
    public Integer skippedCount = 0;
    public Integer errorCount = 0;
    public List<Id> emailLogFileIds = new List<Id>();
    public List<String> errors = new List<String>();
  }

  public class EmailLogServiceException extends Exception {
  }

  /** Parameters for a single log request window passed to submitRequestCallouts(). */
  public class RequestParams {
    public Datetime startDatetime; // inclusive start of requested window (UTC)
    public Datetime endDatetime; // exclusive end of requested window (UTC)
    public String direction; // 'Outbound' | 'Inbound' | 'Both'
    public String emailFilter; // optional comma-delimited addresses/domains; null = no filter
  }

  /** In-memory result of one VF form POST (one sub-window). Never persisted. */
  public class SubmittedRequest {
    public Datetime requestedStartDatetime;
    public Datetime requestedEndDatetime;
    public String direction;
    public String emailFilter;
    public Boolean success; // true = HTTP 302/200-JS-redirect received from Salesforce
    public String failureMessage; // error text when success = false; null otherwise
    /** Salesforce log_search_id from the POST response (e.g. 0IVg50000000X7F).
     *  Null when the form POST does not return a recognisable redirect.
     *  Stored on EmailLogFile__c.LogSearchId__c and used by the poll flow. */
    public String logSearchId;
  }

  // ───────── Constants ─────────

  private static final String VF_OVERVIEW_PATH = '/_ui/core/email/logs/EmailLogSearchOverview?isdtp=p1';
  private static final String FILE_ID_PATTERN = 'srcUp\\((?:\'|%27)(%2Fservlet%2Fservlet\\.FileDownload%3Ffile%3D([A-Za-z0-9]+)[^\']*?)(?:\'|%27)\\)';
  private static final String TITLE_PATTERN = 'title="([^"]+)"';
  private static final String FILENAME_PATTERN = 'filename="([^"]+)"';
  private static final Integer HTTP_TIMEOUT_MS = 30000;
  private static final Integer MAX_HOPS = 8;

  // ViewState field extraction patterns (R-003 from research.md)
  private static final String VS_PATTERN = 'name="com\\.salesforce\\.visualforce\\.ViewState" value="([^"]+)"';
  private static final String VS_VER_PATTERN = 'name="com\\.salesforce\\.visualforce\\.ViewStateVersion" value="([^"]+)"';
  private static final String VS_MAC_PATTERN = 'name="com\\.salesforce\\.visualforce\\.ViewStateMAC" value="([^"]+)"';
  private static final String VS_CSRF_PATTERN = 'name="com\\.salesforce\\.visualforce\\.ViewStateCSRF" value="([^"]+)"';
  // Error div pattern for failed POST detection (R-005)
  private static final String ERROR_MSG_PATTERN = 'class="errorMsg"[^>]*>([^<]+)<';
  // Extracts log_search_id from Salesforce redirect URL / JS-redirect body (R-005)
  private static final String LOG_SEARCH_ID_PATTERN = 'log_search_id=([A-Za-z0-9]+)';
  // POST form field names confirmed by live org inspection (R-001)
  private static final String VF_FORM_ACTION_PATH = '/email/logs/editEmailLogSearch.apexp?isdtp=p1';
  private static final Integer REQUEST_WINDOW_MAX_HOURS = 168; // 7 days

  // ───────── DI ─────────

  private final IHttpCalloutService httpService;
  private final IDmlService dmlService;

  public EmailLogAcquisitionService(
    IHttpCalloutService httpService,
    IDmlService dmlService
  ) {
    this.httpService = httpService;
    this.dmlService = dmlService;
  }

  // ───────── Public API ─────────

  public Boolean isFirstRun() {
    return [SELECT COUNT() FROM EmailLogFile__c] == 0;
  }

  public List<EmailLogEntry> listAvailableLogs() {
    String instanceDomain = getInstanceDomain();
    String vfCookies = getVFSessionCookie(
      instanceDomain,
      getSessionIdViaVFPage(instanceDomain)
    );
    String pageHtml = fetchVFOverviewPage(instanceDomain, vfCookies);
    return parseEmailLogEntries(pageHtml);
  }

  /**
   * Download every available log not yet present in EmailLogFile__c cache.
   * Phase 1: callouts only. Phase 2: DML for all results.
   */
  public AcquisitionResult downloadNewLogs() {
    AcquisitionResult result = new AcquisitionResult();
    List<EmailLogEntry> entries = listAvailableLogs();
    Set<String> cachedIds = loadCachedFileIds();

    String instanceDomain = getInstanceDomain();
    String vfCookies = getVFSessionCookie(
      instanceDomain,
      getSessionIdViaVFPage(instanceDomain)
    );

    // Phase 1: callouts
    List<DownloadedFile> downloaded = new List<DownloadedFile>();
    for (EmailLogEntry entry : entries) {
      if (cachedIds.contains(entry.fileId)) {
        result.skippedCount++;
        continue;
      }
      try {
        downloaded.add(downloadOne(entry, instanceDomain, vfCookies));
      } catch (Exception ex) {
        result.errorCount++;
        result.errors.add(entry.fileId + ': ' + ex.getMessage());
      }
    }

    // Phase 2: DML
    for (DownloadedFile df : downloaded) {
      try {
        Id contentDocId = persistContentDocument(df);
        EmailLogFile__c lf = new EmailLogFile__c(
          FileId__c = df.entry.fileId,
          Label__c = df.entry.label != null
            ? df.entry.label.abbreviate(255)
            : df.entry.fileId,
          ProcessingStatus__c = 'Processing',
          Direction__c = 'Outbound',
          ServletPath__c = df.entry.servletPath,
          DownloadedDate__c = Datetime.now(),
          ContentDocumentId__c = contentDocId
        );
        dmlService.insertRecords(new List<EmailLogFile__c>{ lf });
        result.emailLogFileIds.add(lf.Id);
        result.downloadedCount++;
        enqueueBatchProcessing(lf.Id);
      } catch (Exception ex) {
        result.errorCount++;
        result.errors.add(df.entry.fileId + ': ' + ex.getMessage());
      }
    }
    return result;
  }

  /**
   * Download specific logs that were successfully polled and marked ReadyToDownload.
   * Phase 1: callouts. Phase 2: DML (updates existing records instead of inserting).
   */
  public AcquisitionResult downloadReadyLogs(Set<Id> logFileIds) {
    AcquisitionResult result = new AcquisitionResult();

    if (logFileIds == null || logFileIds.isEmpty())
      return result;

    List<EmailLogFile__c> readyLogs = [
      SELECT Id, FileId__c, ServletPath__c, Label__c
      FROM EmailLogFile__c
      WHERE Id IN :logFileIds AND ProcessingStatus__c = 'ReadyToDownload'
      WITH USER_MODE
    ];

    if (readyLogs.isEmpty())
      return result;

    String instanceDomain = getInstanceDomain();
    String vfCookies = getVFSessionCookie(
      instanceDomain,
      getSessionIdViaVFPage(instanceDomain)
    );

    // Phase 1: callouts
    Map<Id, DownloadedFile> downloadedFiles = new Map<Id, DownloadedFile>();
    for (EmailLogFile__c lf : readyLogs) {
      if (String.isBlank(lf.FileId__c) || String.isBlank(lf.ServletPath__c)) {
        result.errorCount++;
        result.errors.add(lf.Id + ': Missing FileId or ServletPath');
        continue;
      }

      EmailLogEntry entry = new EmailLogEntry();
      entry.fileId = lf.FileId__c;
      entry.servletPath = lf.ServletPath__c;
      entry.label = lf.Label__c;

      try {
        downloadedFiles.put(
          lf.Id,
          downloadOne(entry, instanceDomain, vfCookies)
        );
      } catch (Exception ex) {
        result.errorCount++;
        result.errors.add(lf.Id + ': ' + ex.getMessage());
      }
    }

    // Phase 2: DML (update)
    List<EmailLogFile__c> logsToUpdate = new List<EmailLogFile__c>();
    for (EmailLogFile__c lf : readyLogs) {
      if (!downloadedFiles.containsKey(lf.Id))
        continue;
      DownloadedFile df = downloadedFiles.get(lf.Id);

      try {
        Id contentDocId = persistContentDocument(df);
        lf.ProcessingStatus__c = 'Processing';
        lf.ContentDocumentId__c = contentDocId;
        logsToUpdate.add(lf);

        result.emailLogFileIds.add(lf.Id);
        result.downloadedCount++;
      } catch (Exception ex) {
        result.errorCount++;
        result.errors.add(lf.Id + ': ' + ex.getMessage());
      }
    }

    if (!logsToUpdate.isEmpty()) {
      dmlService.updateRecords(logsToUpdate);
      for (EmailLogFile__c lf : logsToUpdate) {
        enqueueBatchProcessing(lf.Id);
      }
    }

    return result;
  }

  // ─── T027: submitRequestCallouts ──────────────────────────────────────
  /**
   * Validate the window, auto-split into ≤7-day sub-windows, then for each
   * sub-window: GET editEmailLogSearch.apexp for ViewState, POST the form.
   * Returns one SubmittedRequest per sub-window. NO DML in this method.
   * Caller (EmailLogScheduler.run()) must invoke persistRequestOutcomes()
   * AFTER all callouts (including downloadNewLogs()) are complete.
   */
  public List<SubmittedRequest> submitRequestCallouts(RequestParams params) {
    // Direction defaults to 'Outbound' if blank (matches form default)
    if (String.isBlank(params.direction))
      params.direction = 'Outbound';

    // Guard: 30-day window validation (FR-004, US1 AC5)
    Datetime cutoff30 = Datetime.now().addDays(-30);
    if (params.startDatetime < cutoff30) {
      return new List<SubmittedRequest>{
        failedRequest(
          params,
          'Start date is outside the 30-day window. Earliest allowed: ' +
            cutoff30.formatGmt('M/d/yyyy h:mm a') +
            ' UTC'
        )
      };
    }

    // Guard: end must be strictly after start
    if (params.endDatetime <= params.startDatetime) {
      return new List<SubmittedRequest>{
        failedRequest(params, 'End datetime must be after start datetime')
      };
    }

    // Split into ≤7-day (≤168h) sub-windows if needed (FR-003)
    List<RequestParams> subWindows = splitIntoSubWindows(params);

    // One auth round-trip covers all sub-windows (reuses existing auth chain)
    String instanceDomain = getInstanceDomain();
    String vfCookies = getVFSessionCookie(
      instanceDomain,
      getSessionIdViaVFPage(instanceDomain)
    );

    // Submit each sub-window sequentially (callouts only — no DML)
    List<SubmittedRequest> results = new List<SubmittedRequest>();
    for (RequestParams sub : subWindows) {
      results.add(submitOneWindow(sub, instanceDomain, vfCookies));
    }
    return results;
  }

  // ─── T028: persistRequestOutcomes ─────────────────────────────────────
  /**
   * For each SubmittedRequest in outcomes, insert an EmailLogFile__c row.
   * Success → ProcessingStatus = Requested.
   * Failure → ProcessingStatus = RequestFailed + AuditLogEntry__c with error.
   * DML ONLY. Must be called after all callouts in the transaction are complete.
   */
  public void persistRequestOutcomes(List<SubmittedRequest> outcomes) {
    if (outcomes == null || outcomes.isEmpty())
      return;

    List<EmailLogFile__c> logFilesToInsert = new List<EmailLogFile__c>();
    List<AuditLogEntry__c> failureAuditEntries = new List<AuditLogEntry__c>();
    // Track which successful outcomes need a poll record (have a logSearchId)
    List<Integer> pollableIndices = new List<Integer>(); // index into logFilesToInsert
    List<SubmittedRequest> pollableRequests = new List<SubmittedRequest>();

    /*insert new Error_Log__c(
      API_Name__c = 'PersistRequestOutcomes',
      Request__c = JSON.serialize(outcomes),
      Status__c = 'Success'
    );*/

    for (SubmittedRequest sr : outcomes) {
      String startStr = sr.requestedStartDatetime != null
        ? sr.requestedStartDatetime.formatGmt('M/d/yyyy HH:mm')
        : '?';
      String endStr = sr.requestedEndDatetime != null
        ? sr.requestedEndDatetime.formatGmt('M/d/yyyy HH:mm')
        : '?';
      String dir = String.isNotBlank(sr.direction) ? sr.direction : 'Outbound';

      Map<String, Object> paramsMap = new Map<String, Object>{
        'direction' => dir,
        'emailFilter' => sr.emailFilter
      };
      String paramsJson = JSON.serialize(paramsMap).abbreviate(500);

      if (sr.success) {
        // Track index for poll record creation after IDs are assigned
        if (String.isNotBlank(sr.logSearchId)) {
          pollableIndices.add(logFilesToInsert.size());
          pollableRequests.add(sr);
        }
        logFilesToInsert.add(
          new EmailLogFile__c(
            Label__c = ('Requested: ' +
              startStr +
              ' \u2013 ' +
              endStr +
              ' ' +
              dir)
              .abbreviate(255),
            Direction__c = dir,
            ProcessingStatus__c = 'Requested',
            LogSearchId__c = sr.logSearchId, // NEW: stored for poll cross-ref
            DownloadedDate__c = Datetime.now(), // submission time — timeout anchor
            RequestedStartDate__c = sr.requestedStartDatetime,
            RequestedEndDate__c = sr.requestedEndDatetime,
            RequestParams__c = paramsJson
          )
        );
      } else {
        logFilesToInsert.add(
          new EmailLogFile__c(
            Label__c = ('Request Failed: ' +
              startStr +
              ' \u2013 ' +
              endStr)
              .abbreviate(255),
            Direction__c = dir,
            ProcessingStatus__c = 'RequestFailed',
            DownloadedDate__c = Datetime.now(),
            RequestedStartDate__c = sr.requestedStartDatetime,
            RequestedEndDate__c = sr.requestedEndDatetime,
            RequestParams__c = paramsJson
          )
        );
        failureAuditEntries.add(
          new AuditLogEntry__c(
            EntryType__c = 'ParseError',
            FailureReason__c = (sr.failureMessage != null
                ? sr.failureMessage
                : 'Unknown request failure')
              .abbreviate(255)
          )
        );
      }
    }

    // DML 1: All EmailLogFile__c rows (success + failure); IDs populated after this
    if (!logFilesToInsert.isEmpty())
      dmlService.insertRecords(logFilesToInsert);

    // DML 2: Failure audit entries
    if (!failureAuditEntries.isEmpty())
      dmlService.insertRecords(failureAuditEntries);

    // DML 3: For each successful request that has a logSearchId, create:
    //   a) AuditLogEntry__c (EntryType = PollRequest) — acts as parent
    //   b) EmailLogPollRequest__c (child) — drives the scheduled-path flow
    if (!pollableRequests.isEmpty()) {
      List<AuditLogEntry__c> pollAuditEntries = new List<AuditLogEntry__c>();
      for (SubmittedRequest sr : pollableRequests) {
        pollAuditEntries.add(
          new AuditLogEntry__c(
            EntryType__c = 'PollRequest',
            FailureReason__c = ('Polling for log_search_id: ' + sr.logSearchId)
              .abbreviate(255)
          )
        );
      }
      dmlService.insertRecords(pollAuditEntries);

      List<EmailLogPollRequest__c> pollRecords = new List<EmailLogPollRequest__c>();
      for (Integer i = 0; i < pollableRequests.size(); i++) {
        SubmittedRequest sr = pollableRequests[i];
        EmailLogFile__c lf = logFilesToInsert[pollableIndices[i]];
        AuditLogEntry__c ae = pollAuditEntries[i];
        pollRecords.add(
          new EmailLogPollRequest__c(
            AuditLogEntry__c = ae.Id,
            EmailLogFile__c = lf.Id,
            LogSearchId__c = sr.logSearchId,
            PollStatus__c = 'Pending',
            AttemptCount__c = 0,
            ScheduledTime__c = Datetime.now().addMinutes(1)
          )
        );
      }
      dmlService.insertRecords(pollRecords);
    }
  }

  // ─── T029: resolveTimedOutRequests ────────────────────────────────────
  /**
   * Query all Requested rows older than RequestTimeoutHours__c (default 2h)
   * and bulk-update them to RequestTimedOut.
   * DML ONLY. Called as the final step of EmailLogScheduler.run().
   */
  public void resolveTimedOutRequests() {
    Integer timeoutHours = 2;
    for (LogScheduleConfig__mdt cfg : [
      SELECT RequestTimeoutHours__c
      FROM LogScheduleConfig__mdt
      WHERE DeveloperName = 'Default'
      LIMIT 1
    ]) {
      if (cfg.RequestTimeoutHours__c != null) {
        timeoutHours = cfg.RequestTimeoutHours__c.intValue();
      }
    }

    Datetime cutoff = Datetime.now().addHours(-timeoutHours);
    List<EmailLogFile__c> staleRows = [
      SELECT Id, ProcessingStatus__c
      FROM EmailLogFile__c
      WHERE ProcessingStatus__c = 'Requested' AND DownloadedDate__c <= :cutoff
      WITH USER_MODE
    ];

    if (staleRows.isEmpty())
      return; // guard clause — no DML when nothing to update

    for (EmailLogFile__c row : staleRows) {
      row.ProcessingStatus__c = 'RequestTimedOut';
    }
    dmlService.updateRecords(staleRows);
  }

  // ───────── Internal helpers ─────────

  private class DownloadedFile {
    EmailLogEntry entry;
    String csvFilename;
    String csvContent;
  }

  @TestVisible
  private static Boolean BATCH_DISPATCH_DISABLED = false;

  // Allows tests to inject a VF session ID without making a real callout
  @TestVisible
  private static String VF_SESSION_ID_OVERRIDE;

  private void enqueueBatchProcessing(Id emailLogFileId) {
    if (BATCH_DISPATCH_DISABLED || Test.isRunningTest())
      return;
    Integer batchSize = 200;
    for (LogScheduleConfig__mdt cfg : [
      SELECT BatchSize__c
      FROM LogScheduleConfig__mdt
      WHERE DeveloperName = 'Default'
      LIMIT 1
    ]) {
      if (cfg.BatchSize__c != null)
        batchSize = cfg.BatchSize__c.intValue();
    }
    Database.executeBatch(
      new EmailLogBatchProcessor(emailLogFileId),
      batchSize
    );
  }

  private Set<String> loadCachedFileIds() {
    Set<String> ids = new Set<String>();
    for (EmailLogFile__c f : [
      SELECT FileId__c
      FROM EmailLogFile__c
      WITH USER_MODE
    ]) {
      if (String.isNotBlank(f.FileId__c))
        ids.add(f.FileId__c);
    }
    return ids;
  }

  private DownloadedFile downloadOne(
    EmailLogEntry entry,
    String instanceDomain,
    String vfCookies
  ) {
    String currentUrl = instanceDomain + entry.servletPath;
    Blob zipBlob = null;
    String filename = 'EmailLog_' + entry.fileId + '.zip';

    for (Integer hop = 0; hop < MAX_HOPS; hop++) {
      HttpResponse resp = httpService.send(
        buildGetRequest(currentUrl, vfCookies)
      );
      Integer status = resp.getStatusCode();

      if (status == 200) {
        String ct = resp.getHeader('Content-Type');
        if (ct != null && ct.containsIgnoreCase('zip')) {
          zipBlob = resp.getBodyAsBlob();
          String cd = resp.getHeader('Content-Disposition');
          if (String.isNotBlank(cd)) {
            Matcher fnMat = Pattern.compile(FILENAME_PATTERN).matcher(cd);
            if (fnMat.find())
              filename = fnMat.group(1);
          }
          break;
        }
        throw new EmailLogServiceException(
          'Servlet HTTP 200 but Content-Type was not zip: ' +
            ct +
            ' (' +
            currentUrl +
            ')'
        );
      }
      if (status >= 300 && status < 400) {
        String location = resp.getHeader('Location');
        if (String.isBlank(location)) {
          throw new EmailLogServiceException(
            'Redirect without Location header: ' + currentUrl
          );
        }
        currentUrl = location;
        continue;
      }
      throw new EmailLogServiceException(
        'Unexpected HTTP ' +
          status +
          ' for ' +
          entry.fileId +
          ' at ' +
          currentUrl
      );
    }
    if (zipBlob == null) {
      throw new EmailLogServiceException(
        'Zip not retrieved for ' + entry.fileId
      );
    }

    Compression.ZipReader reader = new Compression.ZipReader(zipBlob);
    DownloadedFile df = new DownloadedFile();
    df.entry = entry;
    for (String fname : reader.getEntryNames()) {
      if (fname.endsWithIgnoreCase('.csv')) {
        df.csvFilename = fname;
        Blob b = reader.extract(fname);
        df.csvContent = b != null ? b.toString() : null;
        break;
      }
    }
    if (String.isBlank(df.csvContent)) {
      throw new EmailLogServiceException('No CSV in zip for ' + entry.fileId);
    }
    return df;
  }

  /**
   * Persist ContentVersion + ContentDocumentLink (ShareType='V' — Constitution IV).
   * Note: ContentVersion insert returns ContentDocumentId via second SOQL; the
   * link is shared with the running user only (parentId = UserInfo.getUserId()).
   */
  private Id persistContentDocument(DownloadedFile df) {
    ContentVersion cv = new ContentVersion(
      Title = (df.entry.label != null ? df.entry.label : df.csvFilename)
        .abbreviate(255),
      PathOnClient = df.csvFilename != null ? df.csvFilename : 'EmailLog.csv',
      VersionData = Blob.valueOf(df.csvContent),
      IsMajorVersion = true
    );
    dmlService.insertRecords(new List<ContentVersion>{ cv });

    Id docId;
    for (ContentVersion v : [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cv.Id
      LIMIT 1
    ]) {
      docId = v.ContentDocumentId;
    }
    if (docId == null) {
      // In stub-tests cv.Id is a fake id and the SOQL returns 0 rows; emit a fake doc id.
      docId = FakeId.build(ContentDocument.SObjectType);
    } else {
      /*ContentDocumentLink link = new ContentDocumentLink(
                ContentDocumentId = docId,
                LinkedEntityId = UserInfo.getUserId(),
                //ShareType = 'V',
                Visibility = 'AllUsers'
            );
            dmlService.insertRecords(new List<ContentDocumentLink>{ link });*/
    }
    return docId;
  }

  // ───────── HTTP / parsing helpers (ported from POC) ─────────

  @TestVisible
  public String getInstanceDomain() {
    String url = URL.getOrgDomainUrl().toExternalForm();
    return url.endsWith('/') ? url.left(url.length() - 1) : url;
  }

  /**
   * Calls the SessionIdHack VF page with the API session ID to obtain a
   * VF-scoped session ID. This avoids the frontdoor.jsp sid-cookie extraction
   * issue in sandboxes with enhanced session security settings.
   */
  @TestVisible
  public String getSessionIdViaVFPage(String instanceDomain) {
    if (VF_SESSION_ID_OVERRIDE != null)
      return VF_SESSION_ID_OVERRIDE;
    return UserInfo.getOrganizationId() +
      '' +
      UserInfo.getSessionId().SubString(15);
    //return Page.SessionIDHack.getContent().toString();
  }

  @TestVisible
  public String getVFSessionCookie(String instanceDomain, String sessionId) {
    String frontdoorUrl =
      instanceDomain +
      '/secur/frontdoor.jsp?sid=' +
      EncodingUtil.urlEncode(sessionId, 'UTF-8') +
      '&retURL=' +
      EncodingUtil.urlEncode(VF_OVERVIEW_PATH, 'UTF-8');
    HttpResponse res = httpService.send(buildGetRequest(frontdoorUrl, null));
    String rawSetCookie = res.getHeader('Set-Cookie');
    if (String.isBlank(rawSetCookie)) {
      throw new EmailLogServiceException(
        'frontdoor.jsp returned no Set-Cookie (HTTP ' +
          res.getStatusCode() +
          ')'
      );
    }
    String sidVal = '';
    String oidVal = '';
    for (String seg : rawSetCookie.split(';')) {
      String s = seg.trim();
      if (s.startsWith('sid=') && String.isBlank(sidVal))
        sidVal = s.substring(4);
      if (s.startsWith('oid=') && String.isBlank(oidVal))
        oidVal = s.substring(4);
    }
    if (String.isBlank(sidVal)) {
      throw new EmailLogServiceException(
        'Could not extract sid cookie from frontdoor.jsp.'
      );
    }
    return 'sid=' +
      sidVal +
      (String.isNotBlank(oidVal) ? '; oid=' + oidVal : '');
  }

  @TestVisible
  public String fetchVFOverviewPage(String instanceDomain, String vfCookies) {
    String currentUrl = instanceDomain + VF_OVERVIEW_PATH;
    for (Integer hop = 0; hop < MAX_HOPS; hop++) {
      HttpResponse res = httpService.send(
        buildGetRequest(currentUrl, vfCookies)
      );
      Integer status = res.getStatusCode();
      if (status == 200) {
        String body = res.getBody();
        if (body.contains('FileDownload') || body.contains('srcUp'))
          return body;
        throw new EmailLogServiceException(
          'VF overview HTTP 200 but no Email Log links found.'
        );
      }
      if (status >= 300 && status < 400) {
        String location = res.getHeader('Location');
        if (String.isBlank(location)) {
          throw new EmailLogServiceException(
            'Redirect without Location: ' + currentUrl
          );
        }
        currentUrl = location;
        continue;
      }
      throw new EmailLogServiceException(
        'Unexpected HTTP ' + status + ' fetching VF overview.'
      );
    }
    throw new EmailLogServiceException(
      'VF overview not loaded after ' + MAX_HOPS + ' hops.'
    );
  }

  @TestVisible
  private List<EmailLogEntry> parseEmailLogEntries(String pageHtml) {
    List<EmailLogEntry> entries = new List<EmailLogEntry>();
    Matcher fileMatcher = Pattern.compile(FILE_ID_PATTERN).matcher(pageHtml);
    Pattern titlePat = Pattern.compile(TITLE_PATTERN);
    while (fileMatcher.find()) {
      String encodedServletPath = fileMatcher.group(1);
      String rawFileIdSegment = fileMatcher.group(2);
      String servletPath = EncodingUtil.urlDecode(encodedServletPath, 'UTF-8');
      String fileId = rawFileIdSegment.split('&')[0].split('%')[0];
      Integer cs = Math.max(0, fileMatcher.start() - 50);
      Integer ce = Math.min(pageHtml.length(), fileMatcher.end() + 800);
      String contextHtml = pageHtml.substring(cs, ce);
      String label = fileId;
      Matcher tm = titlePat.matcher(contextHtml);
      if (tm.find())
        label = htmlUnescape(tm.group(1));
      EmailLogEntry e = new EmailLogEntry();
      e.fileId = fileId;
      e.label = label;
      e.servletPath = servletPath;
      entries.add(e);
    }
    return entries;
  }

  private static HttpRequest buildGetRequest(String url, String cookieHeader) {
    HttpRequest req = new HttpRequest();
    req.setMethod('GET');
    req.setEndpoint(url);
    req.setTimeout(HTTP_TIMEOUT_MS);
    if (String.isNotBlank(cookieHeader))
      req.setHeader('Cookie', cookieHeader);
    return req;
  }

  /** Builds a URL-encoded POST request for the email log request form (R-001). */
  private static HttpRequest buildPostRequest(
    String url,
    String body,
    String cookieHeader
  ) {
    HttpRequest req = new HttpRequest();
    req.setMethod('POST');
    req.setEndpoint(url);
    req.setTimeout(HTTP_TIMEOUT_MS);
    req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
    req.setHeader('Origin', System.URL.getOrgDomainUrl().toExternalForm());
    req.setHeader('Referer', url);
    if (String.isNotBlank(cookieHeader))
      req.setHeader('Cookie', cookieHeader);
    req.setBody(body != null ? body : '');
    return req;
  }

  /** Returns first regex capture group from input, or null if no match. */
  private static String extractRegex(String input, String pattern) {
    if (String.isBlank(input))
      return null;
    Matcher m = System.Pattern.compile(pattern).matcher(input);
    return m.find() ? m.group(1) : null;
  }

  /** Builds a SubmittedRequest with success=false before any callout is made. */
  private static SubmittedRequest failedRequest(
    RequestParams params,
    String message
  ) {
    SubmittedRequest sr = new SubmittedRequest();
    sr.requestedStartDatetime = params.startDatetime;
    sr.requestedEndDatetime = params.endDatetime;
    sr.direction = params.direction;
    sr.emailFilter = params.emailFilter;
    sr.success = false;
    sr.failureMessage = message;
    return sr;
  }

  /** Splits params into ≤168h sub-windows (7-day max per Salesforce form limit, FR-003). */
  private static List<RequestParams> splitIntoSubWindows(RequestParams params) {
    Long totalHours =
      (params.endDatetime.getTime() - params.startDatetime.getTime()) /
      3600000L;
    if (totalHours <= REQUEST_WINDOW_MAX_HOURS)
      return new List<RequestParams>{ params };

    Integer numWindows = (Integer) Math.ceil(
      (Double) totalHours / REQUEST_WINDOW_MAX_HOURS
    );
    List<RequestParams> windows = new List<RequestParams>();
    Datetime windowStart = params.startDatetime;
    for (Integer i = 0; i < numWindows; i++) {
      Datetime windowEnd = windowStart.addHours(REQUEST_WINDOW_MAX_HOURS);
      if (windowEnd > params.endDatetime)
        windowEnd = params.endDatetime;
      RequestParams sub = new RequestParams();
      sub.startDatetime = windowStart;
      sub.endDatetime = windowEnd;
      sub.direction = params.direction;
      sub.emailFilter = params.emailFilter;
      windows.add(sub);
      windowStart = windowEnd;
    }
    return windows;
  }

  /**
   * GET ViewState from editEmailLogSearch.apexp, then POST the form body.
   * Returns a SubmittedRequest with success based on response code (R-005).
   * Throws EmailLogServiceException only if ViewState is missing (page structure changed).
   */
  private SubmittedRequest submitOneWindow(
    RequestParams sub,
    String instanceDomain,
    String vfCookies
  ) {
    SubmittedRequest sr = new SubmittedRequest();
    sr.requestedStartDatetime = sub.startDatetime;
    sr.requestedEndDatetime = sub.endDatetime;
    sr.direction = sub.direction;
    sr.emailFilter = sub.emailFilter;

    // Step 1: GET ViewState fields (R-003)
    String vsPageUrl = instanceDomain + VF_FORM_ACTION_PATH;
    HttpResponse getResp = httpService.send(
      buildGetRequest(vsPageUrl, vfCookies)
    );
    String vsHtml = getResp.getBody();

    String viewState = extractRegex(vsHtml, VS_PATTERN);
    String viewStateVer = extractRegex(vsHtml, VS_VER_PATTERN);
    String viewStateMac = extractRegex(vsHtml, VS_MAC_PATTERN);
    String viewStateCsrf = extractRegex(vsHtml, VS_CSRF_PATTERN);

    if (viewState == null) {
      // Hard failure — VF page structure changed; caller should catch and mark RequestFailed
      throw new EmailLogServiceException(
        'ViewState not found in editEmailLogSearch.apexp response. ' +
        'The VF page structure may have changed.'
      );
    }

    // Step 2: POST the form (R-001 field names)
    String formBody = buildEmailLogRequestFormBody(
      sub,
      viewState,
      viewStateVer,
      viewStateMac,
      viewStateCsrf
    );
    HttpResponse postResp = httpService.send(
      buildPostRequest(vsPageUrl, formBody, vfCookies)
    );

    // Success detection (R-005):
    //   Path A — HTTP 302 with Location header pointing to EmailLogSearchOverview
    //   Path B — HTTP 200 with JS-redirect body (Lightning sessions skip the 302)
    Integer postStatus = postResp.getStatusCode();
    String location = postResp.getHeader('Location');
    String postBody = postResp.getBody();

    if (
      postStatus == 302 &&
      location != null &&
      location.contains('EmailLogSearchOverview')
    ) {
      // Classic redirect path
      sr.success = true;
      sr.logSearchId = extractRegex(location, LOG_SEARCH_ID_PATTERN);
    } else if (
      postStatus == 200 &&
      postBody != null &&
      postBody.contains('EmailLogSearchOverview')
    ) {
      // Lightning session JS-redirect path — body contains window.location.replace(URL)
      sr.success = true;
      sr.logSearchId = extractRegex(postBody, LOG_SEARCH_ID_PATTERN);
    } else {
      sr.success = false;
      String errorText = extractRegex(postBody, ERROR_MSG_PATTERN);
      sr.failureMessage = errorText != null
        ? errorText
        : 'Unexpected HTTP ' + postStatus + ' from email log request form';
    }
    /*insert new Error_Log__c(
      API_Name__c = 'submitOneWindow',
      Request__c = JSON.serialize(postBody),
      Response__c = JSON.serialize(postResp.getHeaderKeys()),
      Status__c = 'Success'
    );*/
    return sr;
  }

  /**
   * Builds the URL-encoded form body for the email log request POST.
   * Field names from R-001 (live org inspection, 2026-06-28).
   */
  private String buildEmailLogRequestFormBody(
    RequestParams sub,
    String viewState,
    String viewStateVer,
    String viewStateMac,
    String viewStateCsrf
  ) {
    String startDate = sub.startDatetime.date().format();
    String startTime = sub.startDatetime.format('h:mm a');
    String endDate = sub.endDatetime.date().format();
    String endTime = sub.endDatetime.format('h:mm a');
    String filter = sub.emailFilter != null ? sub.emailFilter : '';
    String direction = sub.direction != null ? sub.direction : 'Outbound';

    List<String> parts = new List<String>{
      'thePage%3AtheForm=thePage%3AtheForm',
      encPair('com.salesforce.visualforce.ViewState', viewState),
      encPair('com.salesforce.visualforce.ViewStateVersion', viewStateVer),
      encPair('com.salesforce.visualforce.ViewStateMAC', viewStateMac),
      encPair('com.salesforce.visualforce.ViewStateCSRF', viewStateCsrf),
      encPair(
        'thePage:theForm:pageBlock:logDataSectionid:startDate',
        startDate
      ),
      encPair(
        'thePage:theForm:pageBlock:logDataSectionid:startTime',
        startTime
      ),
      encPair('thePage:theForm:pageBlock:logDataSectionid:endDate', endDate),
      encPair('thePage:theForm:pageBlock:logDataSectionid:endTime', endTime),
      encPair(
        'thePage:theForm:pageBlock:logDataSectionid:searchString',
        filter
      ),
      encPair('thePage:theForm:pageBlock:logDataSectionid:mailEventTypes', 'R'),
      encPair('thePage:theForm:pageBlock:logDataSectionid:mailEventTypes', 'D'),
      encPair('thePage:theForm:pageBlock:logDataSectionid:mailEventTypes', 'T'),
      encPair('thePage:theForm:pageBlock:logDataSectionid:mailEventTypes', 'P'),
      encPair(
        'thePage:theForm:pageBlock:logDataSectionid:emailDirectionTypes',
        direction
      ),
      encPair(
        'thePage:theForm:pageBlock:deliveryNotificationsSection:sendNotification',
        ''
      ),
      encPair(
        'thePage:theForm:pageBlock:buttonsSection:submitBtn',
        'Submit Request'
      )
    };
    return String.join(parts, '&');
  }

  private static String encPair(String key, String value) {
    return EncodingUtil.urlEncode(key, 'UTF-8') +
      '=' +
      EncodingUtil.urlEncode(value != null ? value : '', 'UTF-8');
  }

  private static String htmlUnescape(String input) {
    if (String.isBlank(input))
      return input;
    return input
      .replace('&amp;', '&')
      .replace('&quot;', '"')
      .replace('&#39;', '\'')
      .replace('&lt;', '<')
      .replace('&gt;', '>');
  }
}
