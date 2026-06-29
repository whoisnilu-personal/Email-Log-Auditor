/**
 * ConfiguratorController — Apex controller for the emailLogConfigurator LWC.
 *
 * Provides org environment detection and Remote Site Setting verification.
 * Uses lightweight HTTP probes to determine whether each required RSS
 * is configured — an "Unauthorized endpoint" callout exception signals
 * a missing RSS without requiring Tooling API access.
 */
public without sharing class ConfiguratorController {

    // ─── DTOs ───────────────────────────────────────────────────────

    /** Org environment details returned to the configurator wizard. */
    public class OrgInfo {
        @AuraEnabled public String orgName;
        @AuraEnabled public String orgId;
        @AuraEnabled public String instanceUrl;
        @AuraEnabled public String contentUrl;
        @AuraEnabled public String setupUrl;
    }

    /** Verification result for a single Remote Site Setting. */
    public class SiteVerification {
        @AuraEnabled public String developerName;
        @AuraEnabled public String name;
        @AuraEnabled public String url;
        @AuraEnabled public String status;      // 'active' | 'missing'
        @AuraEnabled public String description;
    }

    // ─── Public Methods ─────────────────────────────────────────────

    /**
     * Returns org domain information. Cacheable — org URLs don't change
     * within a session.
     */
    @AuraEnabled(cacheable=true)
    public static OrgInfo getOrgInfo() {
        OrgInfo info   = new OrgInfo();
        String host    = URL.getOrgDomainUrl().getHost();
        String prefix  = extractOrgPrefix(host);

        info.orgName     = UserInfo.getOrganizationName();
        info.orgId       = UserInfo.getOrganizationId();
        info.instanceUrl = URL.getOrgDomainUrl().toExternalForm();
        info.contentUrl  = 'https://' + prefix + '.file.force.com';
        info.setupUrl    = 'https://' + prefix + '.my.salesforce-setup.com';
        return info;
    }

    /**
     * Verifies the three Remote Site Settings required by Email Log Auditor.
     * NOT cacheable — makes HTTP callouts and the result may change after
     * the admin adds missing RSS entries.
     */
    @AuraEnabled
    public static List<SiteVerification> verifyRemoteSites() {
        String host   = URL.getOrgDomainUrl().getHost();
        String prefix = extractOrgPrefix(host);
        String base   = URL.getOrgDomainUrl().toExternalForm();

        List<SiteVerification> results = new List<SiteVerification>();
        results.add(probeEndpoint(
            'ELA_Instance_Domain',
            'Instance Domain', base,
            'Org instance — required for email log API callouts and session management'
        ));
        results.add(probeEndpoint(
            'ELA_Content_CDN',
            'Content CDN',
            'https://' + prefix + '.file.force.com',
            'Content CDN — required for downloading email log CSV files'
        ));
        results.add(probeEndpoint(
            'ELA_Setup_Domain',
            'Setup Domain',
            'https://' + prefix + '.my.salesforce-setup.com',
            'Setup domain — required for accessing the email log overview page'
        ));
        return results;
    }

    /**
     * Enqueues the Queueable job to deploy missing Remote Site Settings.
     * Takes the UI session ID and passes it to the Queueable job.
     * Takes a list of SiteVerification objects (serialized as JSON or direct map).
     */
    @AuraEnabled
    public static String enqueueRemoteSiteDeployment(List<Map<String, String>> missingSites) {
        // Enqueue the deployment job
        Id jobId = System.enqueueJob(new RemoteSiteDeployQueueable(UserInfo.getSessionId(), missingSites));
        return String.valueOf(jobId);
    }

    /**
     * Returns the Lightning Setup URL for Remote Site Settings so the LWC
     * can open it in a new browser tab.
     */
    @AuraEnabled(cacheable=true)
    public static String getRemoteSiteSetupUrl() {
        return URL.getOrgDomainUrl().toExternalForm()
             + '/lightning/setup/SecurityRemoteProxy/home';
    }

    // ─── Private Helpers ────────────────────────────────────────────

    /**
     * Extracts the org-specific URL prefix from the host name.
     * e.g. "acme-dev-ed.my.salesforce.com" → "acme-dev-ed"
     */
    private static String extractOrgPrefix(String host) {
        String prefix = host.substringBefore('.my.salesforce.com');
        return String.isNotBlank(prefix) ? prefix : host.substringBefore('.');
    }

    /**
     * Probes an endpoint with a lightweight GET request.
     * - If the callout succeeds (any HTTP status) → RSS exists → 'active'
     * - If "Unauthorized endpoint" is thrown     → RSS missing → 'missing'
     * - Any other exception                      → RSS likely exists → 'active'
     */
    private static SiteVerification probeEndpoint(
        String developerName, String name, String url, String description
    ) {
        SiteVerification sv = new SiteVerification();
        sv.developerName = developerName;
        sv.name        = name;
        sv.url         = url;
        sv.description = description;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(url);
            req.setMethod('GET');
            req.setTimeout(5000);
            new Http().send(req);
            sv.status = 'active';
        } catch (System.CalloutException e) {
            sv.status = e.getMessage().containsIgnoreCase('Unauthorized endpoint')
                ? 'missing' : 'active';
        } catch (Exception e) {
            sv.status = 'active';
        }
        return sv;
    }
}
