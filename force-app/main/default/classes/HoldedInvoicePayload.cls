/**
 * Construye el documento de Holded (POST /invoicing/v1/documents/{docType}) a partir de una
 * factura de Salesforce y su desglose REAV.
 *
 * Por cada bloque (Adulto / Varios) se generan dos líneas:
 *   - "Entrada … (suplido)": coste del proveedor, impuesto s_iva_nosujeto, cuenta contable de entradas.
 *   - "Servicios turísticos …": base del margen, impuesto s_iva_21, cuenta contable de servicios.
 */
public with sharing class HoldedInvoicePayload {
    public static final Map<String, String> DOC_TYPE_BY_INVOICE_TYPE = new Map<String, String>{
        'Standard' => 'invoice',
        'Simplified' => 'salesreceipt',
        'Credit_Note' => 'creditnote'
    };

    public class Context {
        public Invoice__c invoice;
        public Holded_Account__mdt account;
        public String contactId; // id de contacto en Holded (genérico del canal o del cliente)
        public Contact contact; // si no hay contactId, Holded crea el contacto con estos datos
    }

    public static String docType(Invoice__c invoice) {
        String t = DOC_TYPE_BY_INVOICE_TYPE.get(invoice.Type__c);
        if (t == null) {
            throw new IllegalArgumentException('Tipo de factura sin documento en Holded: ' + invoice.Type__c);
        }
        return t;
    }

    public static Map<String, Object> build(Context ctx, ReavCalculator.Result calc) {
        Invoice__c inv = ctx.invoice;
        Map<String, Object> doc = new Map<String, Object>{
            'date' => unixSeconds(inv.Sale_Date__c != null ? inv.Sale_Date__c : Date.today()),
            'currency' => 'eur',
            'language' => 'es'
        };
        if (String.isNotBlank(ctx.contactId)) {
            doc.put('contactId', ctx.contactId);
        } else if (ctx.contact != null) {
            doc.put('contactName', ctx.contact.Name);
            doc.put('contactEmail', ctx.contact.Email);
            doc.put('contactCode', ctx.contact.Tax_Id__c);
            doc.put('contactAddress', ctx.contact.MailingStreet);
            doc.put('contactCity', ctx.contact.MailingCity);
            doc.put('contactCp', ctx.contact.MailingPostalCode);
            doc.put('contactProvince', ctx.contact.MailingState);
        }

        List<Object> customFields = new List<Object>();
        if (String.isNotBlank(inv.Booking_Reference__c)) {
            customFields.add(new Map<String, Object>{ 'field' => 'Localizador', 'value' => inv.Booking_Reference__c });
        }
        if (
            inv.Type__c == 'Credit_Note' &&
            inv.Source_Invoice__r != null &&
            inv.Source_Invoice__r.Holded_Number__c != null
        ) {
            customFields.add(
                new Map<String, Object>{ 'field' => 'Rectifica a', 'value' => inv.Source_Invoice__r.Holded_Number__c }
            );
        }
        if (!customFields.isEmpty()) {
            doc.put('customFields', customFields);
        }

        String product = String.isBlank(inv.Product_Name__c) ? '' : ' ' + inv.Product_Name__c;
        List<Object> items = new List<Object>();
        for (ReavCalculator.Breakdown b : calc.blocks) {
            items.add(
                item(
                    'Entrada' + product + ' (suplido, sin IVA)',
                    b.category,
                    b.ticketsTotal,
                    's_iva_nosujeto',
                    ctx.account.Tickets_Account_Id__c
                )
            );
            items.add(
                item(
                    'Servicios turísticos prestados' + product,
                    b.category + ' · ' + b.units.intValue().format() + ' pax',
                    b.serviceBase,
                    's_iva_21',
                    ctx.account.Services_Account_Id__c
                )
            );
        }
        doc.put('items', items);
        return doc;
    }

    /** Una línea con unidades = 1 y el importe total del bloque: evita descuadres al redondear por unidad. */
    private static Map<String, Object> item(
        String name,
        String description,
        Decimal amount,
        String tax,
        String accountId
    ) {
        Map<String, Object> m = new Map<String, Object>{
            'name' => name,
            'desc' => description,
            'units' => 1,
            'subtotal' => amount,
            'taxes' => new List<String>{ tax }
        };
        if (String.isNotBlank(accountId)) {
            m.put('accountingAccountId', accountId);
        }
        return m;
    }

    @TestVisible
    private static Long unixSeconds(Date d) {
        return Datetime.newInstanceGmt(d, Time.newInstance(12, 0, 0, 0)).getTime() / 1000;
    }
}
