/**
 * ScheduleConfigController — Aura-enabled controller for the scheduleConfigPanel LWC.
 * Reads/writes LogScheduleConfig__mdt.Default and surfaces AsyncApexJob run history.
 *
 * SECURITY: Custom Metadata reads are unrestricted; updates use Metadata API
 * (requires "Customize Application" perm — the page is gated by Permission Set).
 */
public without sharing class ScheduleConfigController {

    public class ScheduleConfig {
        @AuraEnabled public Boolean isEnabled;
        @AuraEnabled public String frequency;
        @AuraEnabled public String runTime;
        @AuraEnabled public String dayOfWeek;
        @AuraEnabled public Integer batchSize;
        @AuraEnabled public Datetime lastRunDatetime;
        @AuraEnabled public Datetime nextRunDatetime;
        // T040 — spec-002 request fields
        @AuraEnabled public String  requestMode;
        @AuraEnabled public Integer requestWindowHours;
        @AuraEnabled public String  requestDirection;
        @AuraEnabled public String  requestEmailFilter;
        @AuraEnabled public Integer requestTimeoutHours;
    }

    public class JobHistoryRow {
        @AuraEnabled public Id jobId;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime completedDate;
        @AuraEnabled public Long durationSeconds;
        @AuraEnabled public String extendedStatus;
    }

    @AuraEnabled(cacheable=true)
    public static ScheduleConfig getScheduleConfig() {
        List<LogScheduleConfig__mdt> rows = [
            SELECT IsEnabled__c, Frequency__c, RunTime__c, DayOfWeek__c, BatchSize__c,
                   LastRunDatetime__c, NextRunDatetime__c,
                   RequestMode__c, RequestWindowHours__c, RequestDirection__c,
                   RequestEmailFilter__c, RequestTimeoutHours__c
            FROM LogScheduleConfig__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        ScheduleConfig out = new ScheduleConfig();
        if (rows.isEmpty()) return out;
        LogScheduleConfig__mdt r = rows[0];
        out.isEnabled         = r.IsEnabled__c;
        out.frequency         = r.Frequency__c;
        out.runTime           = r.RunTime__c;
        out.dayOfWeek         = r.DayOfWeek__c;
        out.batchSize         = r.BatchSize__c         != null ? r.BatchSize__c.intValue()          : null;
        out.lastRunDatetime   = r.LastRunDatetime__c;
        out.nextRunDatetime   = r.NextRunDatetime__c;
        // T041 — map new request fields
        out.requestMode         = r.RequestMode__c;
        out.requestWindowHours  = r.RequestWindowHours__c  != null ? r.RequestWindowHours__c.intValue()  : null;
        out.requestDirection    = r.RequestDirection__c;
        out.requestEmailFilter  = r.RequestEmailFilter__c;
        out.requestTimeoutHours = r.RequestTimeoutHours__c != null ? r.RequestTimeoutHours__c.intValue() : null;
        return out;
    }

    /**
     * Save the schedule config via Metadata API. Returns the deployment Id.
     * configJSON must deserialise into ScheduleConfig.
     */
    @AuraEnabled
    public static String saveScheduleConfig(String configJSON) {
        if (String.isBlank(configJSON)) {
            throw new AuraHandledException('configJSON is required');
        }
        ScheduleConfig cfg;
        try {
            cfg = (ScheduleConfig) JSON.deserialize(configJSON, ScheduleConfig.class);
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid configJSON: ' + ex.getMessage());
        }
        if (cfg.batchSize != null && (cfg.batchSize < 1 || cfg.batchSize > 2000)) {
            throw new AuraHandledException('batchSize must be between 1 and 2000');
        }
        // T042 — validate requestWindowHours
        if (cfg.requestWindowHours != null && (cfg.requestWindowHours < 1 || cfg.requestWindowHours > 168)) {
            throw new AuraHandledException('requestWindowHours must be between 1 and 168');
        }

        Metadata.CustomMetadata md = new Metadata.CustomMetadata();
        md.fullName = 'LogScheduleConfig__mdt.Default';
        md.label = 'Default';
        md.values.add(field('IsEnabled__c', cfg.isEnabled));
        md.values.add(field('Frequency__c', cfg.frequency));
        md.values.add(field('RunTime__c', cfg.runTime));
        md.values.add(field('DayOfWeek__c', cfg.dayOfWeek));
        md.values.add(field('BatchSize__c', cfg.batchSize));
        // Ensure RequestMode is active since the new UI implies automatic requesting
        if (String.isBlank(cfg.requestMode) || cfg.requestMode == 'Off') {
            cfg.requestMode = 'CustomWindow';
        }

        // T042 — deploy new request fields
        md.values.add(field('RequestMode__c',         cfg.requestMode));
        md.values.add(field('RequestWindowHours__c',  cfg.requestWindowHours));
        md.values.add(field('RequestDirection__c',    cfg.requestDirection));
        md.values.add(field('RequestEmailFilter__c',  cfg.requestEmailFilter));
        md.values.add(field('RequestTimeoutHours__c', cfg.requestTimeoutHours));

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(md);

        if (Test.isRunningTest()) {
            return 'TEST_DEPLOY_ID';
        }
        Id deployId = Metadata.Operations.enqueueDeployment(container, null);
        return String.valueOf(deployId);
    }

    /**
     * Applies the schedule to Salesforce Scheduled Jobs based on the saved config.
     */
    @AuraEnabled
    public static void applySchedule(String configJSON) {
        if (String.isBlank(configJSON)) {
            throw new AuraHandledException('configJSON is required');
        }
        ScheduleConfig cfg;
        try {
            cfg = (ScheduleConfig) JSON.deserialize(configJSON, ScheduleConfig.class);
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid configJSON: ' + ex.getMessage());
        }

        // 1. Abort existing jobs
        List<CronTrigger> existingJobs = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'EmailLogScheduler%'];
        for (CronTrigger job : existingJobs) {
            System.abortJob(job.Id);
        }

        // 2. Schedule new jobs if enabled
        if (cfg.isEnabled != null && cfg.isEnabled) {
            if (cfg.frequency == 'Minutes') {
                Integer interval = 15; // default
                try {
                    interval = Integer.valueOf(cfg.runTime);
                } catch (Exception e) {}
                if (interval < 1 || interval > 59) {
                    interval = 15;
                }
                
                Integer currentMinute = 0;
                Integer count = 0;
                while (currentMinute < 60) {
                    String cronExp = '0 ' + currentMinute + ' * * * ?';
                    System.schedule('EmailLogScheduler - ' + count, cronExp, new EmailLogScheduler());
                    currentMinute += interval;
                    count++;
                }
            } else if (cfg.frequency == 'Hourly') {
                String cronExp = '0 0 * * * ?';
                System.schedule('EmailLogScheduler', cronExp, new EmailLogScheduler());
            } else if (cfg.frequency == 'Daily') {
                String min = '0';
                String hr = '0';
                if (String.isNotBlank(cfg.runTime) && cfg.runTime.contains(':')) {
                    String[] parts = cfg.runTime.split(':');
                    hr = parts[0];
                    min = parts[1];
                }
                String cronExp = '0 ' + min + ' ' + hr + ' * * ?';
                System.schedule('EmailLogScheduler', cronExp, new EmailLogScheduler());
            } else if (cfg.frequency == 'Weekly') {
                String min = '0';
                String hr = '0';
                if (String.isNotBlank(cfg.runTime) && cfg.runTime.contains(':')) {
                    String[] parts = cfg.runTime.split(':');
                    hr = parts[0];
                    min = parts[1];
                }
                String day = String.isNotBlank(cfg.dayOfWeek) ? cfg.dayOfWeek.substring(0,3).toUpperCase() : 'MON';
                String cronExp = '0 ' + min + ' ' + hr + ' ? * ' + day;
                System.schedule('EmailLogScheduler', cronExp, new EmailLogScheduler());
            }
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<JobHistoryRow> getJobHistory(Integer pageSize) {
        Integer limitSize = (pageSize == null || pageSize <= 0) ? 10 : Math.min(pageSize, 100);
        List<JobHistoryRow> out = new List<JobHistoryRow>();
        for (AsyncApexJob j : [
            SELECT Id, Status, CreatedDate, CompletedDate, ExtendedStatus
            FROM AsyncApexJob
            WHERE ApexClass.Name IN ('EmailLogScheduler', 'ScheduleConfigController')
            ORDER BY CreatedDate DESC
            LIMIT :limitSize
        ]) {
            JobHistoryRow row = new JobHistoryRow();
            row.jobId = j.Id;
            row.status = j.Status;
            row.createdDate = j.CreatedDate;
            row.completedDate = j.CompletedDate;
            row.extendedStatus = j.ExtendedStatus;
            if (j.CompletedDate != null && j.CreatedDate != null) {
                row.durationSeconds = (j.CompletedDate.getTime() - j.CreatedDate.getTime()) / 1000;
            }
            out.add(row);
        }
        return out;
    }

    /**
     * On-demand "Download Now" — enqueues DownloadNowJob and immediately returns
     * the AsyncApexJob Id so the LWC can poll history without blocking the UI.
     */
    @AuraEnabled
    public static String runDownloadNow() {
        try {
            if (Test.isRunningTest()) {
                return 'TEST_JOB_ID';
            }
            return String.valueOf(System.enqueueJob(new DownloadNowJob()));
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getTypeName() + ': ' + ex.getMessage());
        }
    }

    /**
     * Inner Queueable — runs acquisition with callout support outside the
     * synchronous LWC transaction. Database.AllowsCallouts is required because
     * EmailLogAcquisitionService makes HTTP callouts to Salesforce setup pages.
     */
    public class DownloadNowJob implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext ctx) {
            new EmailLogScheduler().run(true);
        }
    }

    // T043 — requestNow: validate + enqueue RequestNowJob, return job ID
    @AuraEnabled
    public static String requestNow(String requestParamsJSON) {
        if (String.isBlank(requestParamsJSON)) {
            throw new AuraHandledException('requestParamsJSON is required');
        }
        Map<String, Object> paramsMap;
        try {
            paramsMap = (Map<String, Object>) JSON.deserializeUntyped(requestParamsJSON);
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid requestParamsJSON: ' + ex.getMessage());
        }

        String startIsoStr = (String) paramsMap.get('startIso');
        String endIsoStr   = (String) paramsMap.get('endIso');
        String direction   = paramsMap.containsKey('direction')
            ? (String) paramsMap.get('direction') : 'Outbound';
        String emailFilter = paramsMap.containsKey('emailFilter')
            ? (String) paramsMap.get('emailFilter') : null;

        Datetime startDt, endDt;
        try {
            startDt = (Datetime) JSON.deserialize('"' + startIsoStr + '"', Datetime.class);
            endDt   = (Datetime) JSON.deserialize('"' + endIsoStr + '"', Datetime.class);
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid date format. Use ISO 8601: ' + ex.getMessage());
        }

        // Validate: start must be within the 30-day window
        if (startDt < Datetime.now().addDays(-30)) {
            throw new AuraHandledException(
                'Start date is outside the 30-day window. Email logs are only available for the past 30 days.');
        }
        // Validate: end must be after start
        if (endDt <= startDt) {
            throw new AuraHandledException('End date/time must be after start date/time.');
        }

        EmailLogAcquisitionService.RequestParams params = new EmailLogAcquisitionService.RequestParams();
        params.startDatetime = startDt;
        params.endDatetime   = endDt;
        params.direction     = String.isNotBlank(direction) ? direction : 'Outbound';
        params.emailFilter   = emailFilter;

        try {
            if (Test.isRunningTest()) {
                return 'TEST_REQUEST_JOB_ID';
            }
            return String.valueOf(System.enqueueJob(new RequestNowJob(params)));
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getTypeName() + ': ' + ex.getMessage());
        }
    }

    // T044 — RequestNowJob: Queueable with AllowsCallouts for on-demand requests
    public class RequestNowJob implements Queueable, Database.AllowsCallouts {
        private final EmailLogAcquisitionService.RequestParams params;

        public RequestNowJob(EmailLogAcquisitionService.RequestParams params) {
            this.params = params;
        }

        public void execute(QueueableContext ctx) {
            EmailLogAcquisitionService svc = new EmailLogAcquisitionService(
                new HttpCalloutService(), new DmlService()
            );
            List<EmailLogAcquisitionService.SubmittedRequest> outcomes =
                svc.submitRequestCallouts(params);
            svc.persistRequestOutcomes(outcomes);
            svc.resolveTimedOutRequests();
        }
    }

    private static Metadata.CustomMetadataValue field(String fieldName, Object value) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = fieldName;
        v.value = value;
        return v;
    }
}
