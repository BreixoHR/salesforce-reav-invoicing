/**
 * Decide a qué cuenta de Holded (empresa/razón social) va cada factura y con qué contacto.
 *
 * - El canal de venta (web) determina la empresa emisora: Holded_Sales_Channel__mdt.
 * - Las simplificadas y las rectificativas de simplificadas van al contacto genérico del canal.
 * - Las facturas completas van al contacto real; su id en Holded se recuerda por cuenta en
 *   Holded_Contact_Link__c, en lugar de un campo por empresa en Contact (HoldedId_EmpresaA__c,
 *   HoldedId_EmpresaB__c…) que obliga a cambiar el modelo de datos al añadir una empresa.
 */
public with sharing class HoldedRouting {
    public class Route {
        public Holded_Account__mdt account;
        public String contactId;
        public Contact contact;
    }

    public class RoutingException extends Exception {
    }

    @TestVisible
    private static List<Holded_Sales_Channel__mdt> channelsOverride;
    @TestVisible
    private static List<Holded_Account__mdt> accountsOverride;

    public static Route resolve(Invoice__c inv) {
        Holded_Sales_Channel__mdt channel = channel(inv.Sales_Channel__c);
        if (channel == null) {
            throw new RoutingException('Canal de venta sin empresa de facturación: ' + inv.Sales_Channel__c);
        }
        Route r = new Route();
        r.account = account(channel.Holded_Account__c);
        if (r.account == null) {
            throw new RoutingException('Cuenta de Holded no configurada: ' + channel.Holded_Account__c);
        }

        // Una rectificativa va al mismo tipo de contacto que la factura que rectifica
        String effectiveType = inv.Type__c == 'Credit_Note' &&
            inv.Source_Invoice__r != null
            ? inv.Source_Invoice__r.Type__c
            : inv.Type__c;
        Boolean simplified = effectiveType == 'Simplified';
        if (simplified && String.isNotBlank(channel.Generic_Contact_Id__c)) {
            r.contactId = channel.Generic_Contact_Id__c;
            return r;
        }
        if (inv.Contact__c == null) {
            throw new RoutingException('Factura completa sin contacto');
        }
        r.contact = [
            SELECT Id, Name, Email, Tax_Id__c, MailingStreet, MailingCity, MailingPostalCode, MailingState
            FROM Contact
            WHERE Id = :inv.Contact__c
        ];
        for (Holded_Contact_Link__c link : [
            SELECT Holded_Contact_Id__c
            FROM Holded_Contact_Link__c
            WHERE Contact__c = :inv.Contact__c AND Holded_Account__c = :r.account.DeveloperName
            LIMIT 1
        ]) {
            r.contactId = link.Holded_Contact_Id__c;
        }
        return r;
    }

    public static void rememberContact(Id contactId, String accountName, String holdedContactId) {
        upsert new Holded_Contact_Link__c(
            Key__c = contactId + '|' + accountName,
            Contact__c = contactId,
            Holded_Account__c = accountName,
            Holded_Contact_Id__c = holdedContactId
        )
            Key__c;
    }

    private static Holded_Sales_Channel__mdt channel(String salesChannel) {
        List<Holded_Sales_Channel__mdt> all = channelsOverride != null
            ? channelsOverride
            : Holded_Sales_Channel__mdt.getAll().values();
        for (Holded_Sales_Channel__mdt c : all) {
            if (c.Sales_Channel__c == salesChannel) {
                return c;
            }
        }
        return null;
    }

    private static Holded_Account__mdt account(String developerName) {
        List<Holded_Account__mdt> all = accountsOverride != null
            ? accountsOverride
            : Holded_Account__mdt.getAll().values();
        for (Holded_Account__mdt a : all) {
            if (a.DeveloperName == developerName) {
                return a;
            }
        }
        return null;
    }
}
