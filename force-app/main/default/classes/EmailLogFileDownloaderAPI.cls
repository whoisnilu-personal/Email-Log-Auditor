/*------------------------------------------------------------------------------------
Developer:    GitHub Copilot
Class:        EmailLogFileDownloaderAPI
Description:  REST endpoint to trigger programmatic Email Log File downloads.

              Endpoint:   POST  /services/apexrest/api/v1/email-logs/download
              Auth:       OAuth bearer token or session ID (standard Salesforce REST auth)

              Request body (JSON):
              {
                "listOnly":        true,         // list files without downloading
                "direction":       "Inbound",    // optional: Inbound | Outbound | null (all)
                "parentRecordId":  "001xx...",   // optional: attach files to this record
                "saveAsFile":      true          // save CSV as ContentDocument?
              }

              Response body (JSON):
              {
                "success": true,
                "enqueuedJobId": "7XXXX...",      // async job ID (when listOnly=false)
                "files": [                         // populated when listOnly=true
                  {
                    "fileId":      "0BRC2000000096X",
                    "label":       "Inbound Email Log 16 Apr 2026",
                    "servletPath": "/servlet/servlet.FileDownload?file=0BRC2000000096X&isdtp=p1"
                  }
                ],
                "message": "3 log file(s) enqueued for download."
              }

Test Class:   EmailLogFileServiceTest
History
Date           Author             Comments
--------------------------------------------------------------------------------------
25-04-2026    GitHub Copilot     Initial Release
------------------------------------------------------------------------------------*/
@RestResource(urlMapping='/api/v1/email-logs/download')
global without sharing class EmailLogFileDownloaderAPI {

    // ─────────────────────────────────────────────────────────────────────────
    // Request / Response inner classes
    // ─────────────────────────────────────────────────────────────────────────

    global class ApiRequest {
        /** When true, list available files without downloading. */
        public Boolean listOnly;
        /** Filter by direction label: 'Inbound', 'Outbound', or null for all. */
        public String  direction;
        /** SObject record to attach downloaded files to (ContentDocumentLink). */
        public String  parentRecordId;
        /** When true, save downloaded CSV as a ContentDocument File. */
        public Boolean saveAsFile;
    }

    global class LogFileInfo {
        public String fileId;
        public String label;
        public String servletPath;
    }

    global class ApiResponse {
        public Boolean         success;
        public String          enqueuedJobId;
        public List<LogFileInfo> files;
        public String          message;
        public String          errorMessage;

        public ApiResponse() {
            this.files = new List<LogFileInfo>();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // POST handler
    // ─────────────────────────────────────────────────────────────────────────

    @HttpPost
    global static ApiResponse handlePost() {
        ApiResponse response = new ApiResponse();

        try {
            // Parse request body
            ApiRequest req = parseRequest();

            if (req.listOnly == true) {
                // List only — no async job needed, callouts allowed in REST context
                List<EmailLogFileService.EmailLogEntry> entries =
                    EmailLogFileService.listAvailableLogs();

                for (EmailLogFileService.EmailLogEntry e : entries) {
                    Boolean include = String.isBlank(req.direction)
                        || e.label.containsIgnoreCase(req.direction);
                    if (!include) continue;

                    LogFileInfo info = new LogFileInfo();
                    info.fileId      = e.fileId;
                    info.label       = e.label;
                    info.servletPath = e.servletPath;
                    response.files.add(info);
                }

                response.success = true;
                response.message = response.files.size() + ' email log file(s) found.';

            } else {
                // Enqueue async download
                Id parentId = String.isNotBlank(req.parentRecordId)
                    ? (Id) req.parentRecordId
                    : null;

                String jobId = System.enqueueJob(
                    new EmailLogFileDownloaderQueueable(
                        req.direction,
                        parentId,
                        req.saveAsFile
                    )
                );

                response.success       = true;
                response.enqueuedJobId = jobId;
                response.message       = 'Email log download enqueued. '
                    + 'Check AsyncApexJob Id ' + jobId + ' for status.';
            }

        } catch (Exception ex) {
            response.success      = false;
            response.errorMessage = ex.getTypeName() + ': ' + ex.getMessage();
            RestContext.response.statusCode = 500;
        }

        return response;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static ApiRequest parseRequest() {
        RestRequest restReq = RestContext.request;

        // Prefer deserialized body; fall back to URL params for GET-style testing
        if (restReq.requestBody != null && restReq.requestBody.size() > 0) {
            String body = restReq.requestBody.toString();
            if (String.isNotBlank(body)) {
                return (ApiRequest) JSON.deserialize(body, ApiRequest.class);
            }
        }

        // Fallback: build from URL params (useful for quick testing via browser/Workbench)
        ApiRequest req = new ApiRequest();
        req.listOnly       = restReq.params.get('listOnly') == 'true';
        req.direction      = restReq.params.get('direction');
        req.parentRecordId = restReq.params.get('parentRecordId');
        req.saveAsFile     = restReq.params.get('saveAsFile') == 'true';
        return req;
    }
}