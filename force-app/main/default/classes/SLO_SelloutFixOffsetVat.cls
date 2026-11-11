/**
 * One-time batch: negates positive VAT / VAT In Dollars on existing
 * 'Internal Sellout N' invoice lines. Idempotent (only positive values are touched).
 * Run manually: Database.executeBatch(new SLO_SelloutFixOffsetVat(), 200);
 */
public with sharing class SLO_SelloutFixOffsetVat implements Database.Batchable<SObject>, Database.Stateful {

    private Integer linesFixed = 0;
    private Integer linesFailed = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, VAT_In_Original_Price__c, VAT_In_Dollars__c
            FROM Invoice_Line_Item__c
            WHERE Invoice_Number__r.Transaction_type__c = 'Internal Sellout N'
              AND (VAT_In_Original_Price__c > 0 OR VAT_In_Dollars__c > 0)
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Invoice_Line_Item__c> scope) {
        List<Invoice_Line_Item__c> toUpdate = new List<Invoice_Line_Item__c>();
        for (Invoice_Line_Item__c line : scope) {
            Boolean changed = false;
            if (line.VAT_In_Original_Price__c != null && line.VAT_In_Original_Price__c > 0) {
                line.VAT_In_Original_Price__c = -line.VAT_In_Original_Price__c;
                changed = true;
            }
            if (line.VAT_In_Dollars__c != null && line.VAT_In_Dollars__c > 0) {
                line.VAT_In_Dollars__c = -line.VAT_In_Dollars__c;
                changed = true;
            }
            if (changed) {
                toUpdate.add(line);
            }
        }
        if (toUpdate.isEmpty()) {
            return;
        }
        try {
            for (Database.SaveResult sr : Database.update(toUpdate, false)) {
                if (sr.isSuccess()) {
                    linesFixed++;
                } else {
                    linesFailed++;
                }
            }
        } catch (Exception e) {
            linesFailed += toUpdate.size();
            System.debug(LoggingLevel.ERROR, 'SLO_SelloutFixOffsetVat error: ' + e.getMessage());
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('SLO_SelloutFixOffsetVat finished. Fixed: ' + linesFixed + ', failed: ' + linesFailed);
    }
}
