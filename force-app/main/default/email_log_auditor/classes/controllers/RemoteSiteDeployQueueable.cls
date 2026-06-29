public without sharing class RemoteSiteDeployQueueable implements Queueable, Database.AllowsCallouts {
  private String sessionId;
  private List<Map<String, String>> sitesToDeploy;

  public RemoteSiteDeployQueueable(
    String sessionId,
    List<Map<String, String>> sitesToDeploy
  ) {
    this.sessionId = sessionId;
    this.sitesToDeploy = sitesToDeploy;
  }

  public void execute(QueueableContext context) {
    if (sitesToDeploy == null || sitesToDeploy.isEmpty()) {
      return;
    }

    String baseUrl = URL.getOrgDomainUrl().toExternalForm();
    String metadataEndpoint = baseUrl + '/services/Soap/m/60.0';

    // Use the "sessionId hack" to construct an API-capable session ID from the LWC session ID
    //String apiSessionId = UserInfo.getOrganizationId() + '' + this.sessionId.substring(15);
    String apiSessionId = Page.SessionIDHack.getContent().toString();
    for (Map<String, String> site : sitesToDeploy) {
      String developerName = site.get('developerName');
      String url = site.get('url');
      String description = site.get('description');

      if (String.isBlank(developerName) || String.isBlank(url)) {
        continue;
      }

      String safeDesc = description != null ? description.escapeXml() : '';
      String descriptionNode = String.isNotBlank(safeDesc)
        ? '<md:description>' + safeDesc + '</md:description>'
        : '';

      String soapBody =
        '<?xml version="1.0" encoding="utf-8"?>' +
        '<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:md="http://soap.sforce.com/2006/04/metadata">' +
        '<env:Header>' +
        '<md:SessionHeader>' +
        '<md:sessionId>' +
        apiSessionId +
        '</md:sessionId>' +
        '</md:SessionHeader>' +
        '</env:Header>' +
        '<env:Body>' +
        '<md:createMetadata>' +
        '<md:metadata xsi:type="md:RemoteSiteSetting">' +
        '<md:fullName>' +
        developerName +
        '</md:fullName>' +
        descriptionNode +
        '<md:disableProtocolSecurity>false</md:disableProtocolSecurity>' +
        '<md:isActive>true</md:isActive>' +
        '<md:url>' +
        url.escapeXml() +
        '</md:url>' +
        '</md:metadata>' +
        '</md:createMetadata>' +
        '</env:Body>' +
        '</env:Envelope>';

      HttpRequest req = new HttpRequest();
      req.setEndpoint(metadataEndpoint);
      req.setMethod('POST');
      req.setHeader('Content-Type', 'text/xml');
      req.setHeader('SOAPAction', '""');
      req.setBody(soapBody);

      try {
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() >= 400) {
          System.debug(
            LoggingLevel.ERROR,
            'Metadata API Error: ' + res.getBody()
          );
        }
      } catch (Exception e) {
        System.debug(
          LoggingLevel.ERROR,
          'Callout Exception: ' + e.getMessage()
        );
      }
    }
  }
}
