@IsTest
private class RemoteSiteDeployQueueableTest {

    private class MockToolingApiResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            System.assertEquals('POST', req.getMethod(), 'Should use POST');
            System.assert(req.getEndpoint().contains('/services/Soap/m/'), 'Should hit metadata endpoint');
            
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'text/xml');
            res.setBody('<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body><createMetadataResponse><result><success>true</success></result></createMetadataResponse></soapenv:Body></soapenv:Envelope>');
            res.setStatusCode(200);
            return res;
        }
    }

    @IsTest
    static void execute_validSites_makesToolingCallout() {
        Test.setMock(HttpCalloutMock.class, new MockToolingApiResponse());
        
        List<Map<String, String>> missingSites = new List<Map<String, String>>{
            new Map<String, String>{
                'developerName' => 'ELA_Instance_Domain',
                'url' => 'https://example.com',
                'description' => 'Test description'
            }
        };

        RemoteSiteDeployQueueable queueable = new RemoteSiteDeployQueueable('FAKE_SESSION_ID', missingSites);
        
        Test.startTest();
        System.enqueueJob(queueable);
        Test.stopTest();
        
        // Assertions are handled within the mock since DML on Tooling objects is restricted in tests
    }
}
