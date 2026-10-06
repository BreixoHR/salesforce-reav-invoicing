/**
 * Desglose de facturas de agencia de viajes en Régimen Especial (REAV, art. 141 y ss. LIVA).
 *
 * En una venta de entradas/tours, el precio que paga el cliente tiene dos partes:
 *   - el coste de la entrada pagado al proveedor (suplido), que no lleva IVA de la agencia;
 *   - el margen de la agencia (servicio turístico), que lleva un 21 % de IVA incluido.
 *
 *   margen         = unidades × (PVP − coste) − descuento
 *   base imponible = margen / 1,21          (redondeada a céntimos)
 *   cuota IVA      = margen − base          (así base + cuota = margen, sin descuadres de céntimos)
 *
 * Clase pura (sin SOQL ni DML) para poder probar cada caso numérico.
 *
 * Decisión de diseño: si el descuento supera al margen (o se vende por debajo de coste) NO se
 * fuerza nada a cero. La factura se marca para revisión manual: es una decisión fiscal y contable,
 * no algo que deba resolver el código en silencio.
 */
public with sharing class ReavCalculator {
    public static final Decimal VAT_RATE = 0.21;
    public static final String ADULT = 'Adulto';
    public static final String GROUPED = 'Varios';

    public class Line {
        public String category; // Adulto, Niño, Senior...
        public Decimal units;
        public Decimal unitPrice; // PVP unitario, IVA incluido
        public Decimal unitCost; // coste unitario de la entrada (suplido)
        public Decimal discount; // descuento total de la línea (cupón), IVA incluido

        public Line(String category, Decimal units, Decimal unitPrice, Decimal unitCost, Decimal discount) {
            this.category = category;
            this.units = units;
            this.unitPrice = unitPrice;
            this.unitCost = unitCost;
            this.discount = discount == null ? 0 : discount;
        }
    }

    /** Un bloque del desglose: las entradas (suplido) y el servicio turístico de una categoría. */
    public class Breakdown {
        public String category;
        public Decimal units = 0;
        public Decimal ticketsTotal = 0; // suplidos, sin IVA
        public Decimal margin = 0; // margen con IVA incluido
        public Decimal serviceBase = 0; // base imponible del servicio turístico
        public Decimal serviceVat = 0;
        public Decimal total = 0; // lo que paga el cliente por este bloque
    }

    public class Result {
        public List<Breakdown> blocks = new List<Breakdown>();
        public Decimal total = 0;
        public Decimal totalVat = 0;
        public List<String> issues = new List<String>();
        public Boolean needsReview {
            get {
                return !issues.isEmpty();
            }
        }
    }

    /**
     * Agrupa como en la factura publicada: un bloque "Adulto" y un bloque "Varios" con el resto de
     * categorías (niño, senior, colectivos...). Los importes de "Varios" se ACUMULAN por línea.
     */
    public static Result calculate(List<Line> lines) {
        Result result = new Result();
        Map<String, Breakdown> byBlock = new Map<String, Breakdown>();
        List<String> order = new List<String>();

        for (Line l : lines) {
            String problem = validate(l);
            if (problem != null) {
                result.issues.add(problem);
                continue;
            }
            String key = l.category == ADULT ? ADULT : GROUPED;
            if (!byBlock.containsKey(key)) {
                Breakdown b = new Breakdown();
                b.category = key;
                byBlock.put(key, b);
                order.add(key);
            }
            Breakdown b = byBlock.get(key);
            b.units += l.units;
            b.ticketsTotal += l.units * l.unitCost;
            // En una rectificativa (unidades negativas) el descuento también se revierte
            Decimal lineSign = l.units < 0 ? -1 : 1;
            b.margin += l.units * (l.unitPrice - l.unitCost) - lineSign * l.discount;
        }

        for (String key : order) {
            Breakdown b = byBlock.get(key);
            // Rectificativas: unidades negativas → todo negativo. El signo se aplica al final
            Decimal sign = b.units < 0 ? -1 : 1;
            Decimal absMargin = (b.margin * sign).setScale(2, RoundingMode.HALF_UP);
            if (absMargin < 0) {
                result.issues.add(
                    'Margen negativo en "' +
                        key +
                        '" (' +
                        (absMargin * sign) +
                        ' €): descuento superior al margen o venta bajo coste'
                );
            }
            b.ticketsTotal = b.ticketsTotal.setScale(2, RoundingMode.HALF_UP);
            // divide() con escala explícita: el operador "/" de Decimal puede redondear antes de tiempo
            b.serviceBase = sign * absMargin.divide(1 + VAT_RATE, 2, RoundingMode.HALF_UP);
            b.margin = sign * absMargin;
            b.serviceVat = b.margin - b.serviceBase;
            b.total = b.ticketsTotal + b.margin;

            result.blocks.add(b);
            result.total += b.total;
            result.totalVat += b.serviceVat;
        }
        return result;
    }

    private static String validate(Line l) {
        if (l == null || l.units == null || l.unitPrice == null || l.unitCost == null) {
            return 'Línea incompleta: faltan unidades, PVP o coste';
        }
        if (l.units == 0) {
            return 'Línea "' + l.category + '" con 0 unidades';
        }
        if (l.unitPrice < 0 || l.unitCost < 0 || l.discount < 0) {
            return 'Importes negativos en "' + l.category + '": usa unidades negativas para rectificar';
        }
        return null;
    }
}
