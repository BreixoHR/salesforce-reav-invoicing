@IsTest
private class ReavCalculatorTest {
    private static ReavCalculator.Line line(String cat, Decimal units, Decimal price, Decimal cost, Decimal discount) {
        return new ReavCalculator.Line(cat, units, price, cost, discount);
    }

    @IsTest
    static void adultBlock() {
        // 2 adultos a 50 €, coste 30 € → suplidos 60, margen 40, base 33,06, IVA 6,94
        ReavCalculator.Result r = ReavCalculator.calculate(
            new List<ReavCalculator.Line>{ line('Adulto', 2, 50, 30, null) }
        );
        ReavCalculator.Breakdown b = r.blocks[0];
        Assert.areEqual('Adulto', b.category);
        Assert.areEqual(60.00, b.ticketsTotal);
        Assert.areEqual(40.00, b.margin);
        Assert.areEqual(33.06, b.serviceBase);
        Assert.areEqual(6.94, b.serviceVat);
        Assert.areEqual(100.00, b.total);
        Assert.areEqual(100.00, r.total);
        Assert.isFalse(r.needsReview);
    }

    @IsTest
    static void baseAndVatAlwaysAddUpToMargin() {
        // Márgenes cuya división entre 1,21 no es exacta: base + IVA debe cuadrar al céntimo
        for (Decimal price : new List<Decimal>{ 10.01, 19.99, 33.33, 47.5, 99.99, 123.45 }) {
            ReavCalculator.Result r = ReavCalculator.calculate(
                new List<ReavCalculator.Line>{ line('Adulto', 3, price, 7.77, 0.5) }
            );
            ReavCalculator.Breakdown b = r.blocks[0];
            Assert.areEqual(b.margin, b.serviceBase + b.serviceVat, 'precio ' + price);
            Assert.areEqual(3 * price - 0.5, r.total, 'el total es lo que paga el cliente');
        }
    }

    @IsTest
    static void otherCategoriesAreAccumulatedNotOverwritten() {
        // Niño 30/15 y senior 40/20: el bloque "Varios" debe sumar ambas líneas.
        // (La versión anterior se quedaba con el precio y coste de la última línea.)
        ReavCalculator.Result r = ReavCalculator.calculate(
            new List<ReavCalculator.Line>{
                line('Adulto', 2, 50, 30, null),
                line('Niño', 1, 30, 15, null),
                line('Senior', 1, 40, 20, null)
            }
        );
        Assert.areEqual(2, r.blocks.size());
        ReavCalculator.Breakdown varios = r.blocks[1];
        Assert.areEqual('Varios', varios.category);
        Assert.areEqual(2, varios.units.intValue());
        Assert.areEqual(35.00, varios.ticketsTotal);
        Assert.areEqual(35.00, varios.margin);
        Assert.areEqual(28.93, varios.serviceBase);
        Assert.areEqual(170.00, r.total);
    }

    @IsTest
    static void couponReducesTheMarginOnce() {
        // 2 × 50 con coste 30 y cupón de 10 € (total de la línea) → margen 30, total 90
        ReavCalculator.Result r = ReavCalculator.calculate(
            new List<ReavCalculator.Line>{ line('Adulto', 2, 50, 30, 10) }
        );
        Assert.areEqual(30.00, r.blocks[0].margin);
        Assert.areEqual(24.79, r.blocks[0].serviceBase);
        Assert.areEqual(5.21, r.blocks[0].serviceVat);
        Assert.areEqual(90.00, r.total);
    }

    @IsTest
    static void negativeMarginGoesToReviewInsteadOfBeingZeroed() {
        // Cupón mayor que el margen: antes se forzaba a 0 y la factura no cuadraba con lo cobrado
        ReavCalculator.Result r = ReavCalculator.calculate(
            new List<ReavCalculator.Line>{ line('Adulto', 1, 20, 18, 5) }
        );
        Assert.isTrue(r.needsReview);
        Assert.isTrue(r.issues[0].contains('Margen negativo'), r.issues[0]);
    }

    @IsTest
    static void creditNoteMirrorsTheInvoice() {
        ReavCalculator.Result original = ReavCalculator.calculate(
            new List<ReavCalculator.Line>{ line('Adulto', 2, 50, 30, 10) }
        );
        ReavCalculator.Result credit = ReavCalculator.calculate(
            new List<ReavCalculator.Line>{ line('Adulto', -2, 50, 30, 10) }
        );
        ReavCalculator.Breakdown o = original.blocks[0];
        ReavCalculator.Breakdown c = credit.blocks[0];
        Assert.areEqual(-o.ticketsTotal, c.ticketsTotal);
        Assert.areEqual(-o.margin, c.margin);
        Assert.areEqual(-o.serviceBase, c.serviceBase);
        Assert.areEqual(-o.serviceVat, c.serviceVat);
        Assert.areEqual(-90.00, credit.total);
        Assert.isFalse(credit.needsReview);
    }

    @IsTest
    static void invalidLinesAreReported() {
        ReavCalculator.Result r = ReavCalculator.calculate(
            new List<ReavCalculator.Line>{
                line('Adulto', null, 50, 30, null),
                line('Niño', 0, 10, 5, null),
                line('Senior', 1, -10, 5, null)
            }
        );
        Assert.areEqual(3, r.issues.size());
        Assert.isTrue(r.needsReview);
        Assert.isTrue(r.blocks.isEmpty());
    }
}
