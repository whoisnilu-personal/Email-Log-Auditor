/**
 * SECURITY: without sharing — operates on trigger.new buffer in-place; no DML;
 * inherits the calling user's session context.
 *
 * Before-insert action for EmailMessage:
 *   1. Initialise DeliveryData__c to '[]' if blank (so consumers can safely
 *      JSON.deserialize without null guards).
 *   2. Extract the RFC Message-Id header from the standard `Headers` field
 *      and copy it to the indexed external-id field MessageId__c when blank.
 *      This is the primary key used by EmailMessageMatcherService for CSV
 *      log row matching (FR-007).
 */
public without sharing class SetDeliveryStatusDefault {
    @TestVisible
    private static final String MESSAGE_ID_HEADER_PREFIX = 'Message-ID:';

    public void beforeInsert(List<EmailMessage> newList) {
        if (newList == null || newList.isEmpty()) {
            return;
        }
        for (EmailMessage em : newList) {
            if (String.isBlank(em.DeliveryData__c)) {
                em.DeliveryData__c = '[]';
            }
            if (String.isBlank(em.MessageId__c)) {
                // Try Headers first (inbound), then MessageIdentifier (outbound)
                if (String.isNotBlank(em.Headers)) {
                    em.MessageId__c = extractMessageId(em.Headers);
                }
                if (String.isBlank(em.MessageId__c) && String.isNotBlank(em.MessageIdentifier)) {
                    em.MessageId__c = stripAngleBrackets(em.MessageIdentifier).left(255);
                }
            }
        }
    }

    private String extractMessageId(String headers) {
        for (String line : headers.split('\n')) {
            String trimmed = line.trim();
            if (trimmed.toLowerCase().startsWith(MESSAGE_ID_HEADER_PREFIX.toLowerCase())) {
                String value = trimmed.substring(MESSAGE_ID_HEADER_PREFIX.length()).trim();
                return stripAngleBrackets(value).left(255);
            }
        }
        return null;
    }

    private String stripAngleBrackets(String s) {
        if (String.isBlank(s)) return s;
        String t = s.trim();
        if (t.startsWith('<') && t.endsWith('>')) return t.substring(1, t.length() - 1);
        return t;
    }
}
