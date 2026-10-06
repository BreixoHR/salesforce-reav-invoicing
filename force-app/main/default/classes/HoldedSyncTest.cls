@IsTest
private class HoldedSyncTest {
    private class HoldedMock implements HttpCalloutMock {
        final Integer status;
        final String body;
        public List<HttpRequest> requests = new List<HttpRequest>();

        HoldedMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            requests.add(req);
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    private static Object mdt(Type t, Map<String, Object> fields) {
        return JSON.deserialize(JSON.serialize(fields), t);
    }

    private static void configure() {
        HoldedRouting.accountsOverride = new List<Holded_Account__mdt>{
            (Holded_Account__mdt) mdt(
                Holded_Account__mdt.class,
                new Map<String, Object>{
                    'DeveloperName' => 'Empresa_A',
                    'Named_Credential__c' => 'Holded_Empresa_A',
                    'Tickets_Account_Id__c' => 'acc-tickets',
                    'Services_Account_Id__c' => 'acc-services'
                }
            )
        };
        HoldedRouting.channelsOverride = new List<Holded_Sales_Channel__mdt>{
            (Holded_Sales_Channel__mdt) mdt(
                Holded_Sales_Channel__mdt.class,
                new Map<String, Object>{
                    'Sales_Channel__c' => 'web-a',
                    'Holded_Account__c' => 'Empresa_A',
                    'Generic_Contact_Id__c' => 'generic-web-a'
                }
            )
        };
    }

    private static Invoice__c invoice(String type, Id contactId, List<Invoice_Line__c> lines) {
        Invoice__c inv = new Invoice__c(
            Type__c = type,
            Contact__c = contactId,
            Sales_Channel__c = 'web-a',
            Booking_Reference__c = 'LOC-123',
            Product_Name__c = 'Visita guiada',
            Sale_Date__c = Date.newInstance(2026, 5, 20),
            Sync_Status__c = 'Pending'
        );
        insert inv;
        for (Invoice_Line__c l : lines) {
            l.Invoice__c = inv.Id;
        }
        insert lines;
        return inv;
    }

    private static List<Invoice_Line__c> adults(Decimal units, Decimal discount) {
        return new List<Invoice_Line__c>{
            new Invoice_Line__c(
                Category__c = 'Adulto',
                Units__c = units,
                Unit_Price__c = 50,
                Unit_Cost__c = 30,
                Discount__c = discount
            )
        };
    }

    private static Invoice__c reload(Id id) {
        return [
            SELECT Holded_Id__c, Holded_Number__c, Holded_Account__c, Sync_Status__c, Sync_Error__c, Synced_At__c
            FROM Invoice__c
            WHERE Id = :id
        ];
    }

    @IsTest
    static void simplifiedInvoiceGoesToGenericContactWithReavItems() {
        configure();
        Invoice__c inv = invoice('Simplified', null, adults(2, 10));
        HoldedMock mock = new HoldedMock(
            201,
            '{"status":1,"id":"h-1","invoiceNum":"T2026/001","contactId":"generic-web-a"}'
        );
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new HoldedSyncQueueable(new List<Id>{ inv.Id }));
        Test.stopTest();

        HttpRequest req = mock.requests[0];
        Assert.areEqual('callout:Holded_Empresa_A/api/invoicing/v1/documents/salesreceipt', req.getEndpoint());
        Map<String, Object> doc = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
        Assert.areEqual('generic-web-a', doc.get('contactId'));
        List<Object> items = (List<Object>) doc.get('items');
        Assert.areEqual(2, items.size());
        Map<String, Object> tickets = (Map<String, Object>) items[0];
        Map<String, Object> service = (Map<String, Object>) items[1];
        Assert.areEqual(60.00, (Decimal) tickets.get('subtotal'));
        Assert.areEqual('s_iva_nosujeto', ((List<Object>) tickets.get('taxes'))[0]);
        Assert.areEqual('acc-tickets', tickets.get('accountingAccountId'));
        Assert.areEqual(24.79, (Decimal) service.get('subtotal'));
        Assert.areEqual('s_iva_21', ((List<Object>) service.get('taxes'))[0]);

        Invoice__c r = reload(inv.Id);
        Assert.areEqual('Sent', r.Sync_Status__c);
        Assert.areEqual('h-1', r.Holded_Id__c);
        Assert.areEqual('T2026/001', r.Holded_Number__c);
        Assert.areEqual('Empresa_A', r.Holded_Account__c);
    }

    @IsTest
    static void fullInvoiceCreatesContactAndRemembersHoldedId() {
        configure();
        Contact c = new Contact(LastName = 'García', Email = 'ana@example.com', Tax_Id__c = '12345678Z');
        insert c;
        Invoice__c inv = invoice('Standard', c.Id, adults(1, null));
        HoldedMock mock = new HoldedMock(201, '{"status":1,"id":"h-2","invoiceNum":"F2026/010","contactId":"hc-99"}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new HoldedSyncQueueable(new List<Id>{ inv.Id }));
        Test.stopTest();

        Map<String, Object> doc = (Map<String, Object>) JSON.deserializeUntyped(mock.requests[0].getBody());
        Assert.isTrue(mock.requests[0].getEndpoint().endsWith('/documents/invoice'));
        Assert.isNull(doc.get('contactId'));
        Assert.areEqual('12345678Z', doc.get('contactCode'));
        Holded_Contact_Link__c link = [SELECT Holded_Contact_Id__c, Holded_Account__c FROM Holded_Contact_Link__c];
        Assert.areEqual('hc-99', link.Holded_Contact_Id__c);
        Assert.areEqual('Empresa_A', link.Holded_Account__c);
    }

    @IsTest
    static void negativeMarginIsNotSent() {
        configure();
        Invoice__c inv = invoice(
            'Simplified',
            null,
            new List<Invoice_Line__c>{
                new Invoice_Line__c(
                    Category__c = 'Adulto',
                    Units__c = 1,
                    Unit_Price__c = 20,
                    Unit_Cost__c = 18,
                    Discount__c = 5
                )
            }
        );
        HoldedMock mock = new HoldedMock(201, '{"status":1}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new HoldedSyncQueueable(new List<Id>{ inv.Id }));
        Test.stopTest();

        Assert.isTrue(mock.requests.isEmpty(), 'no se llama a Holded');
        Invoice__c r = reload(inv.Id);
        Assert.areEqual('Review', r.Sync_Status__c);
        Assert.isTrue(r.Sync_Error__c.contains('Margen negativo'));
    }

    @IsTest
    static void holdedErrorIsRecorded() {
        configure();
        Invoice__c inv = invoice('Simplified', null, adults(1, null));
        Test.setMock(HttpCalloutMock.class, new HoldedMock(400, '{"status":0,"info":"Invalid contact"}'));

        Test.startTest();
        System.enqueueJob(new HoldedSyncQueueable(new List<Id>{ inv.Id }));
        Test.stopTest();

        Invoice__c r = reload(inv.Id);
        Assert.areEqual('Error', r.Sync_Status__c);
        Assert.isTrue(r.Sync_Error__c.contains('400') && r.Sync_Error__c.contains('Invalid contact'), r.Sync_Error__c);
        Assert.isNull(r.Holded_Id__c);
    }

    @IsTest
    static void alreadySentInvoicesAreSkipped() {
        configure();
        Invoice__c inv = invoice('Simplified', null, adults(1, null));
        update new Invoice__c(Id = inv.Id, Holded_Id__c = 'h-existing', Sync_Status__c = 'Sent');
        HoldedMock mock = new HoldedMock(201, '{"status":1}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new HoldedSyncQueueable(new List<Id>{ inv.Id }));
        Test.stopTest();

        Assert.isTrue(mock.requests.isEmpty());
    }

    @IsTest
    static void unknownSalesChannelIsAnError() {
        configure();
        Invoice__c inv = invoice('Simplified', null, adults(1, null));
        update new Invoice__c(Id = inv.Id, Sales_Channel__c = 'otra-web');
        Test.setMock(HttpCalloutMock.class, new HoldedMock(201, '{"status":1}'));

        Test.startTest();
        System.enqueueJob(new HoldedSyncQueueable(new List<Id>{ inv.Id }));
        Test.stopTest();

        Invoice__c r = reload(inv.Id);
        Assert.areEqual('Error', r.Sync_Status__c);
        Assert.isTrue(r.Sync_Error__c.contains('otra-web'));
    }

    @IsTest
    static void creditNoteIsNegativeIdempotentAndRoutedLikeTheOriginal() {
        configure();
        Contact c = new Contact(LastName = 'Pérez');
        insert c;
        // Simplificada con contacto: su rectificativa debe ir también al contacto genérico
        Invoice__c inv = invoice('Simplified', c.Id, adults(2, 10));
        update new Invoice__c(
            Id = inv.Id,
            Sync_Status__c = 'Sent',
            Holded_Id__c = 'h-orig',
            Holded_Number__c = 'T2026/001'
        );

        CreditNoteService.Request req = new CreditNoteService.Request();
        req.invoiceId = inv.Id;
        CreditNoteService.Response first = CreditNoteService.create(new List<CreditNoteService.Request>{ req })[0];
        CreditNoteService.Response second = CreditNoteService.create(new List<CreditNoteService.Request>{ req })[0];
        Assert.isFalse(first.alreadyExisted);
        Assert.isTrue(second.alreadyExisted);
        Assert.areEqual(first.creditNoteId, second.creditNoteId);

        Invoice_Line__c line = [
            SELECT Units__c, Unit_Price__c, Unit_Cost__c
            FROM Invoice_Line__c
            WHERE Invoice__c = :first.creditNoteId
        ];
        Assert.areEqual(-2, line.Units__c);
        Assert.areEqual(50, line.Unit_Price__c, 'los importes unitarios no cambian de signo');

        HoldedMock mock = new HoldedMock(201, '{"status":1,"id":"h-cn","invoiceNum":"R2026/001"}');
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.enqueueJob(new HoldedSyncQueueable(new List<Id>{ first.creditNoteId }));
        Test.stopTest();

        Assert.isTrue(mock.requests[0].getEndpoint().endsWith('/documents/creditnote'));
        Map<String, Object> doc = (Map<String, Object>) JSON.deserializeUntyped(mock.requests[0].getBody());
        Assert.areEqual('generic-web-a', doc.get('contactId'));
        List<Object> items = (List<Object>) doc.get('items');
        Assert.areEqual(-60.00, (Decimal) ((Map<String, Object>) items[0]).get('subtotal'));
        Assert.areEqual(-24.79, (Decimal) ((Map<String, Object>) items[1]).get('subtotal'));
        List<Object> custom = (List<Object>) doc.get('customFields');
        Assert.areEqual('T2026/001', ((Map<String, Object>) custom[1]).get('value'));
    }

    @IsTest
    static void cannotCreditAnInvoiceNotYetSent() {
        configure();
        Invoice__c inv = invoice('Simplified', null, adults(1, null));
        CreditNoteService.Request req = new CreditNoteService.Request();
        req.invoiceId = inv.Id;
        try {
            CreditNoteService.create(new List<CreditNoteService.Request>{ req });
            Assert.fail('debería exigir que la factura esté emitida');
        } catch (CreditNoteService.CreditNoteException e) {
            Assert.isTrue(e.getMessage().contains('Pending'));
        }
    }
}
