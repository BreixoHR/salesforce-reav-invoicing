/**
 * Rectificativa total de una factura (acción invocable desde Flow o un botón).
 *
 * Copia la factura y sus líneas con las UNIDADES en negativo y los importes unitarios en positivo.
 * Así todos los totales derivados (unidades × precio, unidades × coste) salen negativos.
 *
 * (En la versión anterior se negaban a la vez precio y unidades: negativo × negativo daba totales
 * positivos y la rectificativa sumaba en lugar de restar.)
 *
 * Idempotente: si la factura ya tiene rectificativa se devuelve la existente.
 */
public with sharing class CreditNoteService {
    public class Request {
        @InvocableVariable(required=true label='Factura original')
        public Id invoiceId;
    }

    public class Response {
        @InvocableVariable(label='Rectificativa')
        public Id creditNoteId;
        @InvocableVariable(label='Ya existía')
        public Boolean alreadyExisted;
    }

    public class CreditNoteException extends Exception {
    }

    @InvocableMethod(
        label='Crear rectificativa total'
        description='Crea la factura rectificativa de una factura enviada'
    )
    public static List<Response> create(List<Request> requests) {
        Set<Id> ids = new Set<Id>();
        for (Request r : requests) {
            ids.add(r.invoiceId);
        }

        Map<Id, Invoice__c> originals = new Map<Id, Invoice__c>(
            [
                SELECT
                    Id,
                    Type__c,
                    Contact__c,
                    Sales_Channel__c,
                    Booking_Reference__c,
                    Product_Name__c,
                    Sync_Status__c,
                    (SELECT Category__c, Units__c, Unit_Price__c, Unit_Cost__c, Discount__c FROM Lines__r)
                FROM Invoice__c
                WHERE Id IN :ids
            ]
        );
        Map<Id, Id> existing = new Map<Id, Id>();
        for (Invoice__c cn : [
            SELECT Id, Source_Invoice__c
            FROM Invoice__c
            WHERE Source_Invoice__c IN :ids AND Type__c = 'Credit_Note'
        ]) {
            existing.put(cn.Source_Invoice__c, cn.Id);
        }

        List<Invoice__c> toInsert = new List<Invoice__c>();
        for (Id id : ids) {
            Invoice__c o = originals.get(id);
            if (o == null) {
                throw new CreditNoteException('No existe la factura ' + id);
            }
            if (o.Type__c == 'Credit_Note') {
                throw new CreditNoteException('No se puede rectificar una rectificativa');
            }
            if (o.Sync_Status__c != 'Sent') {
                throw new CreditNoteException(
                    'Solo se rectifican facturas ya emitidas en Holded; esta está en ' + o.Sync_Status__c
                );
            }
            if (existing.containsKey(id)) {
                continue;
            }
            toInsert.add(
                new Invoice__c(
                    Type__c = 'Credit_Note',
                    Source_Invoice__c = o.Id,
                    Contact__c = o.Contact__c,
                    Sales_Channel__c = o.Sales_Channel__c,
                    Booking_Reference__c = o.Booking_Reference__c,
                    Product_Name__c = o.Product_Name__c,
                    Sale_Date__c = Date.today(),
                    Sync_Status__c = 'Pending'
                )
            );
        }
        insert toInsert;

        List<Invoice_Line__c> lines = new List<Invoice_Line__c>();
        for (Invoice__c cn : toInsert) {
            existing.put(cn.Source_Invoice__c, cn.Id);
            for (Invoice_Line__c l : originals.get(cn.Source_Invoice__c).Lines__r) {
                lines.add(
                    new Invoice_Line__c(
                        Invoice__c = cn.Id,
                        Category__c = l.Category__c,
                        Units__c = -l.Units__c, // solo las unidades cambian de signo
                        Unit_Price__c = l.Unit_Price__c,
                        Unit_Cost__c = l.Unit_Cost__c,
                        Discount__c = l.Discount__c
                    )
                );
            }
        }
        insert lines;

        Set<Id> created = new Map<Id, Invoice__c>(toInsert).keySet();
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            Response res = new Response();
            res.creditNoteId = existing.get(r.invoiceId);
            res.alreadyExisted = !created.contains(res.creditNoteId);
            out.add(res);
        }
        return out;
    }
}
