/**
 * Envía facturas a Holded de una en una, encadenando Queueables (cada factura tiene sus propios
 * límites de callout y un fallo no bloquea al resto).
 *
 * - Idempotente: una factura que ya tiene Holded_Id__c no se reenvía.
 * - Las facturas cuyo desglose necesita revisión (margen negativo, líneas incompletas) no se envían:
 *   quedan en Sync_Status__c = 'Review' con el motivo.
 * - La autenticación va en una Named Credential por cuenta de Holded (cabecera "key"): la API key
 *   no está en metadatos legibles ni en el código.
 *
 *   System.enqueueJob(new HoldedSyncQueueable(invoiceIds));
 */
public with sharing class HoldedSyncQueueable implements Queueable, Database.AllowsCallouts {
    private final List<Id> pending;

    public HoldedSyncQueueable(List<Id> invoiceIds) {
        this.pending = invoiceIds == null ? new List<Id>() : invoiceIds.clone();
    }

    public void execute(QueueableContext ctx) {
        if (pending.isEmpty()) {
            return;
        }
        Id current = pending.remove(0);
        sync(current);
        if (!pending.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new HoldedSyncQueueable(pending));
        }
    }

    @TestVisible
    private static void sync(Id invoiceId) {
        Invoice__c inv = [
            SELECT
                Id,
                Type__c,
                Contact__c,
                Sales_Channel__c,
                Booking_Reference__c,
                Sale_Date__c,
                Product_Name__c,
                Holded_Id__c,
                Source_Invoice__r.Holded_Number__c,
                Source_Invoice__r.Type__c,
                (SELECT Category__c, Units__c, Unit_Price__c, Unit_Cost__c, Discount__c FROM Lines__r ORDER BY Name)
            FROM Invoice__c
            WHERE Id = :invoiceId
        ];
        if (String.isNotBlank(inv.Holded_Id__c)) {
            return;
        }

        Invoice__c result = new Invoice__c(Id = inv.Id);
        try {
            ReavCalculator.Result calc = ReavCalculator.calculate(toLines(inv.Lines__r));
            if (inv.Lines__r.isEmpty()) {
                calc.issues.add('Factura sin líneas');
            }
            if (calc.needsReview) {
                markReview(result, String.join(calc.issues, '\n'));
                return;
            }

            HoldedRouting.Route route = HoldedRouting.resolve(inv);
            HoldedInvoicePayload.Context pctx = new HoldedInvoicePayload.Context();
            pctx.invoice = inv;
            pctx.account = route.account;
            pctx.contactId = route.contactId;
            pctx.contact = route.contact;

            HttpRequest req = new HttpRequest();
            req.setEndpoint(
                'callout:' +
                    route.account.Named_Credential__c +
                    '/api/invoicing/v1/documents/' +
                    HoldedInvoicePayload.docType(inv)
            );
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(60000);
            req.setBody(JSON.serialize(HoldedInvoicePayload.build(pctx, calc)));
            HttpResponse res = new Http().send(req);

            Map<String, Object> body = parse(res.getBody());
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300 && body.get('status') == 1) {
                result.Holded_Id__c = (String) body.get('id');
                result.Holded_Number__c = (String) body.get('invoiceNum');
                result.Holded_Account__c = route.account.DeveloperName;
                result.Sync_Status__c = 'Sent';
                result.Sync_Error__c = null;
                result.Synced_At__c = System.now();
                if (route.contact != null && body.get('contactId') != null) {
                    HoldedRouting.rememberContact(
                        route.contact.Id,
                        route.account.DeveloperName,
                        (String) body.get('contactId')
                    );
                }
            } else {
                markError(result, 'HTTP ' + res.getStatusCode() + ': ' + String.valueOf(body.get('info')));
            }
        } catch (Exception e) {
            markError(result, e.getTypeName() + ': ' + e.getMessage());
        }
        update result;
    }

    private static List<ReavCalculator.Line> toLines(List<Invoice_Line__c> rows) {
        List<ReavCalculator.Line> lines = new List<ReavCalculator.Line>();
        for (Invoice_Line__c r : rows) {
            lines.add(
                new ReavCalculator.Line(r.Category__c, r.Units__c, r.Unit_Price__c, r.Unit_Cost__c, r.Discount__c)
            );
        }
        return lines;
    }

    private static Map<String, Object> parse(String body) {
        try {
            Object o = JSON.deserializeUntyped(body);
            return o instanceof Map<String, Object> ? (Map<String, Object>) o : new Map<String, Object>();
        } catch (Exception e) {
            return new Map<String, Object>{ 'info' => String.isBlank(body) ? 'respuesta vacía' : body.left(500) };
        }
    }

    private static void markReview(Invoice__c result, String reason) {
        result.Sync_Status__c = 'Review';
        result.Sync_Error__c = reason.left(32000);
        update result;
    }

    private static void markError(Invoice__c result, String reason) {
        result.Sync_Status__c = 'Error';
        result.Sync_Error__c = reason.left(32000);
    }
}
