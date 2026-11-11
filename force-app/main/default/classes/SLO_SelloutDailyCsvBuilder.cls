/**
 * @description Builds a per-account sellout CSV from the account's unreviewed customer invoices.
 * Invoices are selected the same way the weekly review batch selects them (not Internal Sellout,
 * SLO_Sellout_Reviewed__c = false); the customer name of every line comes from the original
 * Order (Customer_name_Description__c), and date, SKU and quantity come from the invoice and its
 * line items. The builder only reads data - flagging invoices as reviewed is left to the caller.
 */
public with sharing class SLO_SelloutDailyCsvBuilder {

    public static final String DELIMITER = ',';
    public static final String HEADER = 'PERIODE DE VENTES,EAN PRODUIT,QTY FACTUREE,NOM CLIENT,ID LIGNE FACTURE';
    public static final Integer COLUMN_DATE = 0;
    public static final Integer COLUMN_SKU = 1;
    public static final Integer COLUMN_QUANTITY = 2;
    public static final Integer COLUMN_CUSTOMER = 3;
    public static final Integer COLUMN_SOURCE_LINE = 4;

    private static final Integer MAX_INVOICES_PER_RUN = 500;
    // Invoices dated before this are never picked up by the daily job
    public static final Date START_DATE = Date.newInstance(2026, 1, 1);

    /**
     * @description Outcome of one build
     */
    public class BuildResult {
        public String csv;
        public Integer rowCount = 0;
        public Integer skippedLines = 0;
        // Only invoices that contributed at least one row, so unusable invoices are not flagged
        public List<Id> invoiceIds = new List<Id>();
    }

    /**
     * @description Build the CSV for one account
     * @param accountId Opted-in account whose invoices are scanned
     * @return BuildResult; rowCount is 0 (and csv null) when there is nothing to send
     */
    public static BuildResult build(Id accountId) {
        BuildResult result = new BuildResult();

        List<Invoice__c> invoices = [
            SELECT Id, Invoice_Date__c,
                   (SELECT Id, Order__c, Product_Name__c, Central_Item_Code__c, SKU_Code__c, Quantity__c
                    FROM Invoice_Line_Items__r
                    WHERE Order__c != null)
            FROM Invoice__c
            WHERE Account_Name__c = :accountId
              AND SLO_Sellout_Reviewed__c = false
              AND Invoice_Date__c >= :START_DATE
              AND Status__c = 'Closed'
              AND Transaction_type__c NOT IN ('Internal Sellout', 'Internal Sellout N')
              AND Id IN (
                  SELECT Invoice_Number__c FROM Invoice_Line_Item__c
                  WHERE Order__c != null AND Order__r.Customer_name_Description__c != null
              )
            ORDER BY Invoice_Date__c DESC, Id ASC
            LIMIT :MAX_INVOICES_PER_RUN
        ];
        if (invoices.isEmpty()) {
            return result;
        }

        Set<Id> orderIds = new Set<Id>();
        for (Invoice__c invoice : invoices) {
            for (Invoice_Line_Item__c line : invoice.Invoice_Line_Items__r) {
                orderIds.add(line.Order__c);
            }
        }
        Map<Id, Order> orders = new Map<Id, Order>([
            SELECT Id, Customer_name_Description__c
            FROM Order
            WHERE Id IN :orderIds
        ]);

        List<Account> owners = [SELECT Name FROM Account WHERE Id = :accountId];
        String distributorName = owners.isEmpty() ? '' : normalizeName(owners[0].Name);

        List<String> rows = new List<String>{ HEADER };
        for (Invoice__c invoice : invoices) {
            Boolean contributed = false;
            Boolean selfSale = false;
            for (Invoice_Line_Item__c line : invoice.Invoice_Line_Items__r) {
                Order ord = orders.get(line.Order__c);
                String customer = ord == null ? null : ord.Customer_name_Description__c;
                // SKU_Code__c matches Product2.ProductCode; the central item code does not
                String sku = String.isNotBlank(line.SKU_Code__c) ? line.SKU_Code__c
                    : (String.isNotBlank(line.Central_Item_Code__c)
                        ? line.Central_Item_Code__c : line.Product_Name__c);
                if (String.isBlank(customer) || String.isBlank(sku) || line.Quantity__c == null) {
                    result.skippedLines++;
                    continue;
                }
                // Distributor selling to itself is not a sellout: leave it out of the CSV
                if (normalizeName(customer) == distributorName) {
                    result.skippedLines++;
                    selfSale = true;
                    continue;
                }
                rows.add(String.join(new List<String>{
                    formatDate(invoice.Invoice_Date__c),
                    escape(sku.trim()),
                    formatQuantity(line.Quantity__c),
                    escape(customer.trim()),
                    String.valueOf(line.Id)
                }, DELIMITER));
                result.rowCount++;
                contributed = true;
            }
            // Invoices holding only self-sales are still flagged reviewed so they are not re-read daily
            if (contributed || selfSale) {
                result.invoiceIds.add(invoice.Id);
            }
        }

        if (result.rowCount > 0) {
            result.csv = String.join(rows, '\n');
        }
        return result;
    }

    /**
     * @description Trim, collapse spaces and upper-case a name for case-insensitive comparison
     */
    @TestVisible
    private static String normalizeName(String name) {
        return name == null ? '' : name.normalizeSpace().toUpperCase();
    }

    /**
     * @description Quote a value when it contains the delimiter, a quote or a line break
     */
    @TestVisible
    private static String escape(String value) {
        if (value == null) {
            return '';
        }
        String flat = value.replace('\r', ' ').replace('\n', ' ');
        if (flat.contains(DELIMITER) || flat.contains('"')) {
            return '"' + flat.replace('"', '""') + '"';
        }
        return flat;
    }

    @TestVisible
    private static String formatDate(Date d) {
        return String.valueOf(d.day()).leftPad(2, '0') + '/' + String.valueOf(d.month()).leftPad(2, '0')
            + '/' + String.valueOf(Math.mod(d.year(), 100)).leftPad(2, '0');
    }

    /**
     * @description Plain decimal text with a dot separator and no trailing zeros
     */
    @TestVisible
    private static String formatQuantity(Decimal quantity) {
        Decimal value = quantity.stripTrailingZeros();
        return value.toPlainString();
    }
}
