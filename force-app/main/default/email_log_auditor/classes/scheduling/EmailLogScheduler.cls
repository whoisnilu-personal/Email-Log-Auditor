/**
 * EmailLogScheduler — Schedulable runner that triggers acquisition on the configured cadence.
 * Reads `LogScheduleConfig__mdt.Default` for IsEnabled / BatchSize, runs acquisition,
 * dispatches batch processing per downloaded EmailLogFile__c, then updates run timestamps.
 */
public without sharing class EmailLogScheduler implements Schedulable {

    @TestVisible
    private static IHttpCalloutService HTTP_OVERRIDE;
    @TestVisible
    private static IDmlService DML_OVERRIDE;
    @TestVisible
    private static EmailLogAcquisitionService SERVICE_OVERRIDE;
    @TestVisible
    private static LogScheduleConfig__mdt CONFIG_OVERRIDE;

    public void execute(SchedulableContext sc) {
        System.enqueueJob(new ScheduledRunQueueable());
    }

    public class ScheduledRunQueueable implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext ctx) {
            new EmailLogScheduler().run();
        }
    }

    /**
     * Direct entry point for "Download Now" + tests. Returns the AcquisitionResult.
     */
    public EmailLogAcquisitionService.AcquisitionResult run() {
        return run(false);
    }

    /**
     * forceRun = true bypasses the IsEnabled__c guard (used by "Download Now").
     *
     * ⚠️ Callout-ordering constraint (plan.md Critical Design Constraint):
     *   Step 1 — submitRequestCallouts()  → callouts only (GET ViewState + POST per sub-window)
     *   Step 2 — downloadNewLogs()        → callouts (list + download) then DML
     *   Step 3 — persistRequestOutcomes() → DML only (after all callouts complete)
     *   Step 4 — resolveTimedOutRequests() → DML only
     * All callouts in steps 1 and 2 complete before any DML. This satisfies Salesforce's
     * callout-before-DML rule in Schedulable context.
     */
    public EmailLogAcquisitionService.AcquisitionResult run(Boolean forceRun) {
        LogScheduleConfig__mdt cfg = loadConfig();
        if (!forceRun && cfg != null && cfg.IsEnabled__c == false && !Test.isRunningTest()) {
            return new EmailLogAcquisitionService.AcquisitionResult();
        }
        EmailLogAcquisitionService svc = buildService();
        List<EmailLogAcquisitionService.SubmittedRequest> requestOutcomes = null;

        // Step 1 — Request callouts (only when RequestMode is not Off/null — FR-010 backward compat)
        if (cfg != null && !String.isBlank(cfg.RequestMode__c) && cfg.RequestMode__c != 'Off') {
            try {
                EmailLogAcquisitionService.RequestParams params = buildRequestParams(cfg);
                requestOutcomes = svc.submitRequestCallouts(params);
            } catch (Exception ex) {
                // Request step failure must never halt the download sweep (US1 AC5 / FR-009)
                // Persist failure as a RequestFailed row via a synthetic SubmittedRequest
                EmailLogAcquisitionService.SubmittedRequest failRow =
                    new EmailLogAcquisitionService.SubmittedRequest();
                failRow.success       = false;
                failRow.failureMessage = 'Request step failed: ' + ex.getMessage();
                failRow.direction     = cfg.RequestDirection__c != null ? cfg.RequestDirection__c : 'Outbound';
                requestOutcomes = new List<EmailLogAcquisitionService.SubmittedRequest>{ failRow };
            }
        }

        // Step 2 — Existing download sweep (callouts + DML internally)
        EmailLogAcquisitionService.AcquisitionResult result = svc.downloadNewLogs();

        // Step 3 — Persist request tracking rows (DML only, after all callouts complete)
        if (requestOutcomes != null) {
            svc.persistRequestOutcomes(requestOutcomes);
        }

        // Step 4 — Resolve timed-out requests (DML only)
        svc.resolveTimedOutRequests();

        return result;
    }

    @TestVisible
    private EmailLogAcquisitionService buildService() {
        if (SERVICE_OVERRIDE != null) return SERVICE_OVERRIDE;
        IHttpCalloutService http = HTTP_OVERRIDE != null ? HTTP_OVERRIDE : new HttpCalloutService();
        IDmlService dml = DML_OVERRIDE != null ? DML_OVERRIDE : new DmlService();
        return new EmailLogAcquisitionService(http, dml);
    }

    /**
     * T030 — Build request params from schedule config.
     * PreviousDay = past 24 hours ending at job-start time.
     * CustomWindow = past RequestWindowHours__c hours ending at job-start time.
     */
    @TestVisible
    private EmailLogAcquisitionService.RequestParams buildRequestParams(LogScheduleConfig__mdt cfg) {
        Datetime now  = Datetime.now();
        
        EmailLogAcquisitionService.RequestParams p = new EmailLogAcquisitionService.RequestParams();
        p.endDatetime   = now;

        if (cfg.Frequency__c == 'Minutes') {
            Integer windowMinutes = 15;
            try { windowMinutes = Integer.valueOf(cfg.RunTime__c); } catch (Exception e) {}
            p.startDatetime = now.addMinutes(-windowMinutes);
        } else if (cfg.Frequency__c == 'Hourly') {
            p.startDatetime = now.addHours(-1);
        } else {
            Integer windowHours = ('PreviousDay'.equals(cfg.RequestMode__c)) ? 24
                : (cfg.RequestWindowHours__c != null ? cfg.RequestWindowHours__c.intValue() : 24);
            p.startDatetime = now.addHours(-windowHours);
        }

        p.direction     = String.isNotBlank(cfg.RequestDirection__c) ? cfg.RequestDirection__c : 'Outbound';
        p.emailFilter   = String.isNotBlank(cfg.RequestEmailFilter__c) ? cfg.RequestEmailFilter__c : null;
        return p;
    }

    @TestVisible
    private LogScheduleConfig__mdt loadConfig() {
        if (CONFIG_OVERRIDE != null) return CONFIG_OVERRIDE;
        List<LogScheduleConfig__mdt> rows = [
            SELECT IsEnabled__c, BatchSize__c, Frequency__c, RunTime__c, DayOfWeek__c,
                   RequestMode__c, RequestWindowHours__c, RequestDirection__c,
                   RequestEmailFilter__c, RequestTimeoutHours__c
            FROM LogScheduleConfig__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }
}
