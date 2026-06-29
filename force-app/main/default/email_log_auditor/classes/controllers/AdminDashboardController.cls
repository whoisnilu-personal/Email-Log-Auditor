/**
 * AdminDashboardController — Aura-enabled controller backing emailDashboard +
 * emailCategoryView. Aggregates DeliveryData__c JSON across EmailMessages and
 * returns paged category-filtered email rows.
 */
public without sharing class AdminDashboardController {

    public class DeliveryEntryDto {
        @AuraEnabled public String recipient;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime timestamp;
        @AuraEnabled public String failureReason;
        @AuraEnabled public String failureCode;
    }

    public class DeliveryMetrics {
        @AuraEnabled public Integer totalEmails = 0;
        @AuraEnabled public Integer delivered = 0;
        @AuraEnabled public Integer bounced = 0;
        @AuraEnabled public Integer deferred = 0;
        @AuraEnabled public Integer pending = 0;
    }

    public class EmailRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public String fromAddress;
        @AuraEnabled public Datetime messageDate;
        @AuraEnabled public String category;
        @AuraEnabled public Id parentId;
        @AuraEnabled public Id relatedToId;
        @AuraEnabled public List<DeliveryEntryDto> deliveryEntries;
        @AuraEnabled public String worstStatus;
    }

    @AuraEnabled(cacheable=true)
    public static DeliveryMetrics getDeliveryMetrics() {
        DeliveryMetrics m = new DeliveryMetrics();
        for (EmailMessage em : [
            SELECT Id, DeliveryData__c
            FROM EmailMessage
            WITH USER_MODE
            LIMIT 50000
        ]) {
            if (String.isBlank(em.DeliveryData__c)) continue;
            m.totalEmails++;
            for (DeliveryEntryDto e : parseDeliveryData(em.DeliveryData__c)) {
                if (e.status == 'Delivered') m.delivered++;
                else if (e.status == 'Bounced') m.bounced++;
                else if (e.status == 'Deferred') m.deferred++;
                else m.pending++;
            }
        }
        return m;
    }

    @AuraEnabled(cacheable=true)
    public static List<EmailRow> getEmailsByCategory(
        String category, Datetime startDate, Datetime endDate, Integer pageSize, Integer pageOffset
    ) {
        Integer ps = (pageSize == null || pageSize <= 0) ? 50 : Math.min(pageSize, 200);
        Integer po = (pageOffset == null || pageOffset < 0) ? 0 : pageOffset;
        Datetime sd = startDate;
        Datetime ed = endDate;
        String catFilter = category;

        String soql =
            'SELECT Id, Subject, FromAddress, MessageDate, Category__c, ParentId, RelatedToId, DeliveryData__c '
            + 'FROM EmailMessage '
            + 'WHERE Category__c = :catFilter ';
        if (sd != null) soql += 'AND MessageDate >= :sd ';
        if (ed != null) soql += 'AND MessageDate <= :ed ';
        soql += 'WITH USER_MODE ORDER BY MessageDate DESC NULLS LAST LIMIT :ps OFFSET :po';

        List<EmailRow> out = new List<EmailRow>();
        for (EmailMessage em : Database.query(soql)) {
            EmailRow row = new EmailRow();
            row.id = em.Id;
            row.subject = em.Subject;
            row.fromAddress = em.FromAddress;
            row.messageDate = em.MessageDate;
            row.category = em.Category__c;
            row.parentId = em.ParentId;
            row.relatedToId = em.RelatedToId;
            row.deliveryEntries = parseDeliveryData(em.DeliveryData__c);
            row.worstStatus = computeWorstStatus(row.deliveryEntries);
            out.add(row);
        }
        return out;
    }

    @TestVisible
    private static List<DeliveryEntryDto> parseDeliveryData(String rawJson) {
        if (String.isBlank(rawJson)) return new List<DeliveryEntryDto>();
        try {
            return (List<DeliveryEntryDto>) JSON.deserialize(rawJson, List<DeliveryEntryDto>.class);
        } catch (Exception ex) {
            return new List<DeliveryEntryDto>();
        }
    }

    private static String computeWorstStatus(List<DeliveryEntryDto> entries) {
        if (entries == null || entries.isEmpty()) return 'Pending';
        // Severity: Bounced > Deferred > Pending > Delivered
        Boolean hasBounced = false, hasDeferred = false, hasPending = false, hasDelivered = false;
        for (DeliveryEntryDto e : entries) {
            if (e.status == 'Bounced') hasBounced = true;
            else if (e.status == 'Deferred') hasDeferred = true;
            else if (e.status == 'Delivered') hasDelivered = true;
            else hasPending = true;
        }
        if (hasBounced) return 'Bounced';
        if (hasDeferred) return 'Deferred';
        if (hasPending) return 'Pending';
        if (hasDelivered) return 'Delivered';
        return 'Pending';
    }
}
