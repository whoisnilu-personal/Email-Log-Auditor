/**
 * AgentDeliveryStatusController — `with sharing`. Surfaces per-recipient delivery
 * data on a record page (Case via ParentId; Contact/Lead/etc via RelatedToId).
 */
public with sharing class AgentDeliveryStatusController {
  public class DeliveryEntryDto {
    @AuraEnabled
    public String recipient;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Datetime timestamp;
    @AuraEnabled
    public String failureReason;
    @AuraEnabled
    public String failureCode;
  }

  public class DeliveryStatusRow {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String subject;
    @AuraEnabled
    public String fromAddress;
    @AuraEnabled
    public Datetime messageDate;
    @AuraEnabled
    public String category;
    @AuraEnabled
    public List<DeliveryEntryDto> deliveryEntries;
    @AuraEnabled
    public Boolean hasDeliveryData;
  }

  @AuraEnabled(cacheable=true)
  public static List<DeliveryStatusRow> getDeliveryStatusForRecord(
    Id recordId,
    String objectApiName
  ) {
    if (recordId == null) {
      throw new AuraHandledException('recordId is required');
    }
    List<EmailMessage> messages;
    try {
      if (objectApiName == 'Case') {
        messages = [
          SELECT
            Id,
            Subject,
            FromAddress,
            MessageDate,
            Category__c,
            DeliveryData__c
          FROM EmailMessage
          WHERE ParentId = :recordId
          WITH USER_MODE
          ORDER BY MessageDate DESC NULLS LAST
          LIMIT 200
        ];
      } else if (
        objectApiName == 'Contact' ||
        objectApiName == 'Lead' ||
        objectApiName == 'User'
      ) {
        messages = [
          SELECT
            Id,
            Subject,
            FromAddress,
            MessageDate,
            Category__c,
            DeliveryData__c
          FROM EmailMessage
          WHERE
            Id IN (
              SELECT EmailMessageId
              FROM EmailMessageRelation
              WHERE RelationId = :recordId
            )
          WITH USER_MODE
          ORDER BY MessageDate DESC NULLS LAST
          LIMIT 200
        ];
      } else {
        messages = [
          SELECT
            Id,
            Subject,
            FromAddress,
            MessageDate,
            Category__c,
            DeliveryData__c
          FROM EmailMessage
          WHERE RelatedToId = :recordId
          WITH USER_MODE
          ORDER BY MessageDate DESC NULLS LAST
          LIMIT 200
        ];
      }
    } catch (System.QueryException qe) {
      // Sharing/FLS denial — return empty list, do not raise
      return new List<DeliveryStatusRow>();
    }

    List<DeliveryStatusRow> out = new List<DeliveryStatusRow>();
    for (EmailMessage em : messages) {
      DeliveryStatusRow row = new DeliveryStatusRow();
      row.id = em.Id;
      row.subject = em.Subject;
      row.fromAddress = em.FromAddress;
      row.messageDate = em.MessageDate;
      row.category = em.Category__c;
      row.deliveryEntries = parseDeliveryData(em.DeliveryData__c);
      row.hasDeliveryData = !row.deliveryEntries.isEmpty();
      out.add(row);
    }
    return out;
  }

  @TestVisible
  private static List<DeliveryEntryDto> parseDeliveryData(String rawJson) {
    if (String.isBlank(rawJson))
      return new List<DeliveryEntryDto>();
    try {
      return (List<DeliveryEntryDto>) JSON.deserialize(
        rawJson,
        List<DeliveryEntryDto>.class
      );
    } catch (Exception ex) {
      return new List<DeliveryEntryDto>();
    }
  }
}
