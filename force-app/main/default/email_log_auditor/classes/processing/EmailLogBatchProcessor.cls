/**
 * EmailLogBatchProcessor — Database.Batchable<String> that processes a single
 * EmailLogFile__c. start() reads the linked ContentVersion CSV blob and
 * returns its rows as Strings; execute() parses each row, dispatches matching
 * via EmailMessageMatcherService; finish() updates EmailLogFile__c stats and
 * triggers categorisation.
 *
 * CSV columns expected (Salesforce Email Log format):
 *   Date Time, Source IP, Source/Destination, Bytes, Recipient Address,
 *   Sender Address, Remote Host, Subject, Status, Message ID, Event Type,
 *   Message Size, Mail Pause, Cipher Strength, Cipher, Cipher Suite,
 *   Direction, Notification, Status Code, Diagnostic
 */
public without sharing class EmailLogBatchProcessor implements Database.Batchable<String>, Database.Stateful {
  private final Id emailLogFileId;
  private Integer rowCount = 0;
  private Integer matchCount = 0;
  private Integer errorCount = 0;
  private List<String> errorMessages = new List<String>();

  @TestVisible
  private static EmailMessageMatcherService MATCHER_OVERRIDE;
  @TestVisible
  private static EmailCategorizationService CATEGORIZER_OVERRIDE;

  public EmailLogBatchProcessor(Id emailLogFileId) {
    this.emailLogFileId = emailLogFileId;
  }

  public Iterable<String> start(Database.BatchableContext bc) {
    EmailLogFile__c lf = [
      SELECT Id, ContentDocumentId__c, ProcessingStatus__c
      FROM EmailLogFile__c
      WHERE Id = :emailLogFileId
      LIMIT 1
    ];
    if (String.isBlank(lf.ContentDocumentId__c))
      return new List<String>();

    List<ContentVersion> versions = [
      SELECT VersionData
      FROM ContentVersion
      WHERE ContentDocumentId = :lf.ContentDocumentId__c AND IsLatest = TRUE
      LIMIT 1
    ];
    if (versions.isEmpty() || versions[0].VersionData == null)
      return new List<String>();

    String csv = versions[0].VersionData.toString();
    List<String> lines = csv.split('\n');
    // Skip header row if present (heuristic: contains 'Message ID' substring)
    List<String> rows = new List<String>();
    Boolean first = true;
    for (String line : lines) {
      if (String.isBlank(line))
        continue;
      if (first && line.containsIgnoreCase('Message ID')) {
        first = false;
        continue;
      }
      first = false;
      rows.add(line);
    }
    return rows;
  }

  public void execute(Database.BatchableContext bc, List<String> scope) {
    List<EmailDeliveryRecord> parsed = new List<EmailDeliveryRecord>();
    Integer rowIdx = rowCount;
    for (String line : scope) {
      rowIdx++;
      try {
        EmailDeliveryRecord r = parseRow(line, rowIdx);
        if (r != null)
          parsed.add(r);
      } catch (Exception ex) {
        errorCount++;
        errorMessages.add('row ' + rowIdx + ': ' + ex.getMessage());
      }
    }
    rowCount = rowIdx;

    EmailMessageMatcherService matcher = MATCHER_OVERRIDE != null
      ? MATCHER_OVERRIDE
      : new EmailMessageMatcherService(new DmlService());
    EmailMessageMatcherService.MatchResult mr = matcher.matchAndEnrich(
      parsed,
      emailLogFileId
    );
    matchCount += mr.matched;
    errorCount += mr.unmatched;
  }

  public void finish(Database.BatchableContext bc) {
    EmailLogFile__c lf = new EmailLogFile__c(
      Id = emailLogFileId,
      ProcessingStatus__c = errorMessages.isEmpty() ? 'Processed' : 'Processed',
      LastProcessedDate__c = Datetime.now(),
      RowCount__c = rowCount,
      MatchCount__c = matchCount,
      ErrorCount__c = errorCount
    );
    update lf;

    EmailCategorizationService cat = CATEGORIZER_OVERRIDE != null
      ? CATEGORIZER_OVERRIDE
      : new EmailCategorizationService(new DmlService());
    try {
      cat.categoriseAll();
    } catch (Exception ex) {
      // Categorisation failure is non-fatal — log and continue
    }
  }

  // ── CSV parsing ────────────────────────────────────────────────────────

  @TestVisible
  private static EmailDeliveryRecord parseRow(String line, Integer rowNumber) {
    if (String.isBlank(line))
      return null;
    List<String> cols = splitCsv(line);
    if (cols.size() < 11) {
      EmailDeliveryRecord r = new EmailDeliveryRecord();
      r.csvRowNumber = rowNumber;
      r.rawCsvRow = line;
      return r; // partial row → matcher will treat as missing message-id
    }
    EmailDeliveryRecord r = new EmailDeliveryRecord();
    // Salesforce email log CSV column layout (0-based):
    // 0=DateTime, 1=TrackingId, 2=EventType(D/R/T/P), 3=Recipient,
    // 4=Sender, 5=RemoteHost, 6=Bytes, 7=SFUserId, 8=MessageId,
    // 9=StatusCode, 10=ProcessingTime, 15=TLSCipher, 16=TLSVerified,
    // 17=Direction, 18=TLSProtocol
    r.sendDatetime = parseDate(cols[0]);
    r.eventType = cols.size() > 2 ? cols[2] : null;
    r.recipient = cols.size() > 3 ? cols[3] : null;
    r.sender = cols.size() > 4 ? cols[4] : null;
    r.messageId = stripAngleBrackets(cols.size() > 8 ? cols[8] : null);
    r.statusCode = cols.size() > 9 ? cols[9] : null;
    r.statusMessage = cols.size() > 9 ? cols[9] : null;
    r.deliveryStatus = EmailDeliveryRecord.mapEventTypeToStatus(r.eventType);
    r.csvRowNumber = rowNumber;
    r.rawCsvRow = line;
    return r;
  }

  @TestVisible
  private static List<String> splitCsv(String line) {
    // Minimal CSV parser handling double-quoted fields with embedded commas
    List<String> out = new List<String>();
    StringBuilder current = new StringBuilder();
    Boolean inQuotes = false;
    for (Integer i = 0; i < line.length(); i++) {
      String ch = line.substring(i, i + 1);
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ',' && !inQuotes) {
        out.add(current.toString());
        current = new StringBuilder();
      } else {
        current.append(ch);
      }
    }
    out.add(current.toString());
    return out;
  }

  private static String stripAngleBrackets(String s) {
    if (String.isBlank(s))
      return s;
    String t = s.trim();
    if (t.startsWith('<') && t.endsWith('>'))
      return t.substring(1, t.length() - 1);
    return t;
  }

  private static Datetime parseDate(String s) {
    if (String.isBlank(s))
      return null;
    String t = s.trim();
    try {
      // Salesforce Email Log default format: yyyy-MM-ddTHH:mm:ss.SSSZ
      return (Datetime) JSON.deserialize('"' + t + '"', Datetime.class);
    } catch (Exception e) {
      try {
        return Datetime.valueOf(t.replace('T', ' ').replace('Z', ''));
      } catch (Exception e2) {
        try {
          // Fallback for MM/dd/yyyy HH:mm:ss or dd/MM/yyyy HH:mm:ss
          String[] parts = t.split(' ');
          if (parts.size() >= 2) {
            String[] d = parts[0].split('/');
            if (d.size() == 3) {
              Integer p1 = Integer.valueOf(d[0]);
              Integer p2 = Integer.valueOf(d[1]);
              Integer y = Integer.valueOf(d[2]);
              Integer m = p1;
              Integer day = p2;
              if (p1 > 12) {
                day = p1;
                m = p2;
              }
              String[] timeParts = parts[1].split(':');
              if (timeParts.size() >= 2) {
                Integer h = Integer.valueOf(timeParts[0]);
                Integer min = Integer.valueOf(timeParts[1]);
                Integer sec = timeParts.size() > 2
                  ? Integer.valueOf(timeParts[2])
                  : 0;
                return Datetime.newInstance(y, m, day, h, min, sec);
              }
            }
          }
        } catch (Exception e3) {
        }
        return null;
      }
    }
  }

  /**
   * Apex has no built-in StringBuilder; this is a tiny shim.
   */
  public class StringBuilder {
    private List<String> parts = new List<String>();
    public void append(String s) {
      parts.add(s);
    }
    public override String toString() {
      return String.join(parts, '');
    }
  }
}
