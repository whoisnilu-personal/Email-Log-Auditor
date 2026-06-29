/**
 * EmailDeliveryRecord — transient value object representing one parsed CSV row
 * from an Email Log file. Not persisted; lives only in memory during batch
 * processing (Constitution: stateless functional core).
 */
public without sharing class EmailDeliveryRecord {
    public String   messageId;        // RFC Message-ID
    public String   recipient;        // To address
    public String   sender;           // From address
    public Datetime sendDatetime;     // Parsed CSV "Date" column
    public String   eventType;        // R, D, T, P
    public String   deliveryStatus;   // D→Delivered, P→Bounced, T→Deferred, R→Pending
    public String   statusCode;       // SMTP code string
    public String   statusMessage;    // Diagnostic text
    public Integer  csvRowNumber;     // 1-based row index
    public String   rawCsvRow;        // Original line for audit

    public static String mapEventTypeToStatus(String eventType) {
        if (String.isBlank(eventType)) return 'Pending';
        String t = eventType.trim().toUpperCase();
        if (t == 'D') return 'Delivered';
        if (t == 'P') return 'Bounced';
        if (t == 'T') return 'Deferred';
        return 'Pending';
    }
}
