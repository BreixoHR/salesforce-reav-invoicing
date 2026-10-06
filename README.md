# Salesforce REAV Invoicing

Facturación automática en **Holded** desde **Salesforce** para una agencia de viajes que tributa en el **Régimen Especial de Agencias de Viajes (REAV)**. Cubre facturas completas, simplificadas y **rectificativas**, con varias empresas emisoras según el canal de venta.

![apex](https://img.shields.io/badge/Apex-API%2062-00A1E0) ![holded](https://img.shields.io/badge/Holded-API%20v1-1C1C1C) ![lint](https://img.shields.io/badge/prettier--plugin--apex-checked-informational) ![license](https://img.shields.io/badge/license-MIT-blue)

## El dominio: IVA solo sobre el margen

En el REAV la agencia no repercute IVA sobre el precio completo, solo sobre **su margen**. Cada venta de entradas se desglosa en:

| Concepto | Importe | IVA |
|---|---|---|
| Entradas (coste del proveedor, *suplido*) | unidades × coste | no sujeto |
| Servicios turísticos (margen) | base = margen / 1,21 | 21 % incluido |

```
margen         = unidades × (PVP − coste) − descuento
base imponible = margen / 1,21   → redondeo a céntimos
cuota IVA      = margen − base   → base + cuota = margen, siempre
```

Ejemplo: 2 adultos a 50 € con un coste de 30 € y un cupón de 10 € dan 60,00 € de entradas sin IVA, más 24,79 € de base y 5,21 € de IVA. Total: **90,00 €**, exactamente lo cobrado.

## Arquitectura

```mermaid
flowchart LR
    I[Invoice__c + Invoice_Line__c] --> Q[HoldedSyncQueueable<br/>1 factura por ejecución]
    Q --> C[ReavCalculator<br/>desglose puro]
    C -->|margen negativo / datos incompletos| R[Sync_Status__c = Review<br/>no se envía]
    C --> RT[HoldedRouting<br/>canal → empresa → contacto]
    RT --> P[HoldedInvoicePayload<br/>2 líneas por bloque]
    P -->|callout:Holded_Empresa/…/documents/&#123;invoice|salesreceipt|creditnote&#125;| H[(Holded)]
    H --> S[Holded_Id__c · nº de factura · Sent / Error]
    CN[CreditNoteService<br/>acción invocable] --> I
```

| Clase | Responsabilidad |
|---|---|
| [`ReavCalculator`](force-app/main/default/classes/ReavCalculator.cls) | Desglose REAV. Es una clase pura, sin SOQL ni DML, testeada caso a caso. |
| [`HoldedRouting`](force-app/main/default/classes/HoldedRouting.cls) | Decide la empresa emisora a partir del canal de venta y el contacto: genérico del canal para las simplificadas, el cliente real para las completas. |
| [`HoldedInvoicePayload`](force-app/main/default/classes/HoldedInvoicePayload.cls) | Construye el documento de Holded: líneas, impuestos, cuentas contables y campos personalizados. |
| [`HoldedSyncQueueable`](force-app/main/default/classes/HoldedSyncQueueable.cls) | Envía las facturas una a una con Named Credential. Es idempotente y registra el estado y el error. |
| [`CreditNoteService`](force-app/main/default/classes/CreditNoteService.cls) | Rectificativa total como acción invocable desde Flow. Es idempotente. |

## Origen y qué se ha corregido

La integración base con Holded la desarrolló una consultora. Mis aportaciones en producción fueron:

- los **descuentos por cupón** en el cálculo del margen;
- las **facturas rectificativas** (acción invocable);
- correcciones en la agrupación de categorías;
- la configuración multiempresa.

Esta versión pública es una **reescritura completa**. Al escribir los tests salieron fallos de la versión en producción:

| Fallo | Consecuencia | Corrección |
|---|---|---|
| La rectificativa negaba a la vez el **precio y las unidades** | Los totales calculados como unidades × precio salían **positivos**: la rectificativa sumaba en lugar de restar | Solo cambian de signo las unidades (test `creditNoteMirrorsTheInvoice`) |
| La rectificativa con cupón guardaba la base del margen en el campo del PVP | La fórmula del REAV se aplicaba dos veces | Las líneas se copian tal cual y el calculador aplica el signo |
| En las categorías que no son de adulto, el PVP y el coste **se sobrescribían** con los de la última línea | Con niño y senior a precios distintos, todo se facturaba al precio del último | Los importes se acumulan línea a línea (test `otherCategoriesAreAccumulatedNotOverwritten`) |
| Si el cupón superaba el margen, se **forzaba a 0** | La factura no cuadraba con lo cobrado y nadie se enteraba | Se bloquea con estado `Review` y el motivo: es una decisión fiscal, no del código |
| Importes en `Double` y redondeo por unidad | Descuadres de céntimos | `Decimal`, una línea por bloque e IVA calculado como margen − base |
| Un campo de id de Holded por empresa en `Contact` (`HoldedId_EmpresaA__c`, `…B__c`) y nombres de empresa fijados en el código | Añadir una empresa obligaba a cambiar el modelo de datos y el código | `Holded_Contact_Link__c` (contacto × cuenta) y Custom Metadata |
| API key en Custom Metadata legible | Cualquiera con acceso a Setup podía leerla | Named Credential por cuenta (cabecera `key`) |

## Configuración

- **`Holded_Account__mdt`**, una por empresa emisora: la Named Credential y las cuentas contables de entradas y de servicios.
- **`Holded_Sales_Channel__mdt`**, una por web o canal: la empresa que factura y el contacto genérico para las simplificadas.
- **Named Credential** `Holded_<Empresa>`, que apunta a `https://api.holded.com` y lleva la cabecera `key: {!$Credential.…}`.

```apex
System.enqueueJob(new HoldedSyncQueueable(invoiceIds));
```

## Tests

- **`ReavCalculatorTest`** cubre:
  - el desglose del bloque de adultos;
  - que base + IVA cuadre siempre con el margen, para seis precios con decimales;
  - la acumulación de las categorías;
  - el cupón;
  - el margen negativo, que pasa a revisión;
  - que la rectificativa sea el espejo exacto de la factura;
  - las líneas inválidas.
- **`HoldedSyncTest`** usa mocks HTTP y cubre:
  - la simplificada con contacto genérico y el payload REAV completo;
  - la factura completa, que crea el contacto y recuerda su id;
  - que con margen negativo no se envía nada;
  - los errores de Holded;
  - que no se reenvían facturas ya enviadas;
  - el canal desconocido;
  - la rectificativa: negativa, idempotente, enrutada como la factura original y referenciándola;
  - que no se puede rectificar una factura que aún no se ha emitido.

```bash
sf project deploy start --target-org <alias> --test-level RunLocalTests
npm run lint
```

> Los resultados esperados del calculador se verificaron también con un port independiente de la fórmula.

## Licencia

[MIT](LICENSE)
