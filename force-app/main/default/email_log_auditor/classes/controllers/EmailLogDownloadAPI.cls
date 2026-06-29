/**
 * EmailLogDownloadAPI — REST shell for on-demand acquisition.
 * Standard Salesforce OAuth session validation only (per task spec); no business logic here.
 * Delegates to EmailLogScheduler.run() so the same path is exercised whether triggered
 * by schedule or HTTP POST.
 */
@RestResource(urlMapping='/email-log-download/*')
global without sharing class EmailLogDownloadAPI {

    global class DownloadResponse {
        public Boolean success;
        public Integer downloaded;
        public Integer skipped;
        public Integer errors;
        public List<String> errorMessages;
    }

    @HttpPost
    global static DownloadResponse runDownload() {
        DownloadResponse out = new DownloadResponse();
        try {
            EmailLogAcquisitionService.AcquisitionResult r = new EmailLogScheduler().run();
            out.success = (r.errorCount == 0);
            out.downloaded = r.downloadedCount;
            out.skipped = r.skippedCount;
            out.errors = r.errorCount;
            out.errorMessages = r.errors;
        } catch (Exception ex) {
            out.success = false;
            out.errors = 1;
            out.errorMessages = new List<String>{ ex.getTypeName() + ': ' + ex.getMessage() };
        }
        return out;
    }
}
