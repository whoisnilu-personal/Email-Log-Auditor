/**
 * EmailMessageMatcherService — bulk-matches parsed delivery records to EmailMessage
 * via MessageId__c and merges recipient delivery events into DeliveryData__c JSON.
 *
 * Idempotency rule (FR-011): for each (messageId, recipient) pair the entry
 * with the MORE RECENT timestamp wins. Older entries are not overwritten.
 */
public without sharing virtual class EmailMessageMatcherService {

    public class DeliveryEntry {
        public String recipient;
        public String status;
        public Datetime timestamp;
        public String failureReason;
        public String failureCode;
    }

    public class MatchResult {
        public Integer matched = 0;
        public Integer unmatched = 0;
        public Integer updated = 0;
        public List<Id> updatedEmailMessageIds = new List<Id>();
    }

    private final IDmlService dmlService;

    public EmailMessageMatcherService(IDmlService dmlService) {
        this.dmlService = dmlService;
    }

    /**
     * @param records  Parsed CSV rows for the current batch chunk
     * @param sourceFileId  EmailLogFile__c.Id (for AuditLogEntry__c.SourceFile__c)
     */
    public virtual MatchResult matchAndEnrich(List<EmailDeliveryRecord> records, Id sourceFileId) {
        MatchResult result = new MatchResult();
        if (records == null || records.isEmpty()) return result;

        // Bucket records by Message-ID
        Map<String, List<EmailDeliveryRecord>> byMessageId = new Map<String, List<EmailDeliveryRecord>>();
        List<EmailDeliveryRecord> orphans = new List<EmailDeliveryRecord>();
        for (EmailDeliveryRecord r : records) {
            if (String.isBlank(r.messageId)) {
                orphans.add(r);
                continue;
            }
            if (!byMessageId.containsKey(r.messageId)) {
                byMessageId.put(r.messageId, new List<EmailDeliveryRecord>());
            }
            byMessageId.get(r.messageId).add(r);
        }

        // Bulk SOQL — all matching EmailMessages in one query
        Map<String, EmailMessage> emByMessageId = new Map<String, EmailMessage>();
        if (!byMessageId.isEmpty()) {
            for (EmailMessage em : [
                SELECT Id, MessageId__c, DeliveryData__c
                FROM EmailMessage
                WHERE MessageId__c IN :byMessageId.keySet()
                WITH USER_MODE
            ]) {
                emByMessageId.put(em.MessageId__c, em);
            }
        }

        List<EmailMessage> toUpdate = new List<EmailMessage>();
        List<AuditLogEntry__c> toInsertAudit = new List<AuditLogEntry__c>();

        for (String messageId : byMessageId.keySet()) {
            List<EmailDeliveryRecord> rows = byMessageId.get(messageId);
            EmailMessage em = emByMessageId.get(messageId);
            if (em == null) {
                // No matching EmailMessage — log every row to audit
                result.unmatched += rows.size();
                for (EmailDeliveryRecord r : rows) {
                    toInsertAudit.add(buildAudit('Unmatched', r, sourceFileId, 'No EmailMessage with MessageId__c=' + messageId));
                }
                continue;
            }
            result.matched += rows.size();

            // Parse existing DeliveryData__c
            List<DeliveryEntry> existing = parseEntries(em.DeliveryData__c);
            Boolean changed = mergeRows(existing, rows);
            if (changed) {
                // Use minimal update object to avoid re-validating unrelated
                // fields like FromAddress when only DeliveryData__c is changing.
                toUpdate.add(new EmailMessage(Id = em.Id, DeliveryData__c = JSON.serialize(existing)));
                result.updatedEmailMessageIds.add(em.Id);
            }
        }

        // Orphans (no Message-ID)
        for (EmailDeliveryRecord r : orphans) {
            result.unmatched++;
            toInsertAudit.add(buildAudit('MissingMessageId', r, sourceFileId, 'CSV row missing Message-ID'));
        }

        if (!toUpdate.isEmpty()) {
            dmlService.updateRecords(toUpdate);
            result.updated = toUpdate.size();
        }
        if (!toInsertAudit.isEmpty()) {
            dmlService.insertRecords(toInsertAudit);
        }
        return result;
    }

    // ── Internals ──────────────────────────────────────────────────────────

    @TestVisible
    private static List<DeliveryEntry> parseEntries(String rawJson) {
        if (String.isBlank(rawJson)) return new List<DeliveryEntry>();
        try {
            return (List<DeliveryEntry>) JSON.deserialize(rawJson, List<DeliveryEntry>.class);
        } catch (Exception ex) {
            return new List<DeliveryEntry>();
        }
    }

    /**
     * @return true if the existing list was mutated.
     */
    @TestVisible
    private static Boolean mergeRows(List<DeliveryEntry> existing, List<EmailDeliveryRecord> rows) {
        Boolean changed = false;
        Map<String, DeliveryEntry> byRecipient = new Map<String, DeliveryEntry>();
        for (DeliveryEntry e : existing) {
            if (e != null && String.isNotBlank(e.recipient)) {
                byRecipient.put(e.recipient.toLowerCase(), e);
            }
        }
        for (EmailDeliveryRecord r : rows) {
            if (String.isBlank(r.recipient)) continue;
            String key = r.recipient.toLowerCase();
            DeliveryEntry incoming = toEntry(r);
            DeliveryEntry current = byRecipient.get(key);
            if (current == null) {
                existing.add(incoming);
                byRecipient.put(key, incoming);
                changed = true;
            } else if (incoming.timestamp != null
                       && (current.timestamp == null || incoming.timestamp > current.timestamp)) {
                current.recipient = incoming.recipient;
                current.status = incoming.status;
                current.timestamp = incoming.timestamp;
                current.failureReason = incoming.failureReason;
                current.failureCode = incoming.failureCode;
                changed = true;
            }
        }
        return changed;
    }

    private static DeliveryEntry toEntry(EmailDeliveryRecord r) {
        DeliveryEntry e = new DeliveryEntry();
        e.recipient = r.recipient;
        e.status = String.isNotBlank(r.deliveryStatus)
            ? r.deliveryStatus
            : EmailDeliveryRecord.mapEventTypeToStatus(r.eventType);
        e.timestamp = r.sendDatetime;
        e.failureReason = r.statusMessage;
        e.failureCode = r.statusCode;
        return e;
    }

    private static AuditLogEntry__c buildAudit(String type, EmailDeliveryRecord r, Id sourceFileId, String reason) {
        return new AuditLogEntry__c(
            EntryType__c = type,
            SourceFile__c = sourceFileId,
            RowNumber__c = r.csvRowNumber,
            MessageId__c = r.messageId,
            Recipient__c = r.recipient,
            SendDate__c = r.sendDatetime,
            FailureReason__c = reason,
            RawCsvRow__c = r.rawCsvRow != null ? r.rawCsvRow.abbreviate(32768) : null
        );
    }
}
