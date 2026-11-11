/**
 * @description Batch Apex for async CSV import of sellout items with email notification on completion.
 * Processes CSV rows in 200-row scopes, skips exact 4-column duplicates, flags unknown product
 * codes and quantity conflicts as review-time errors, and emails the running user a summary when
 * the job finishes so the LWC does not have to stay open.
 */
public with sharing class SLO_SelloutItemImportBatch
        implements Database.Batchable<String>, Database.Stateful {

    private final Id accountId;
    private final Id reportId;
    private final Id contentVersionId;
    private final String userLocale;
    private final String delimiter;
    private final Integer itemDateIndex;
    private final Integer productCodeIndex;
    private final Integer quantityIndex;
    private final Integer customerAccountIndex;
    private final Integer sourceLineIndex;
    private final String notificationEmail;
    private final Date startDate;
    private final Boolean autoAccept;
    private final String duplicateMode;
    private final Boolean processDuplicates;
    private final Boolean skipDuplicatesInFile;
    // Duplicate rows diverted to the Duplicates section for the user to decide on
    private Integer duplicatesForReview = 0;

    private Integer totalProcessed = 0;
    private Integer totalErrors = 0;
    private Integer duplicatesRemoved = 0;
    // Rows stored at status Error because their product code is unknown or their quantity conflicts
    // with a line already recorded - imported, but named in the review list as needing a fix
    private Integer rowsFlaggedForReview = 0;
    // Every data row read from the file, whatever became of it, so the review screen can always say
    // how much of the upload was loaded - even when nothing new was created
    private Integer rowsRead = 0;
    // Rows dated before the chosen start date - read from the file but deliberately left out
    private Integer rowsBeforeStartDate = 0;
    private List<String> errorSamples = new List<String>();

    /**
     * @description Constructor
     * @param accountId Account the sellout report belongs to
     * @param reportId Pre-created sellout report to populate
     * @param contentVersionId ContentVersion holding the uploaded CSV
     * @param config Column mapping and delimiter configuration
     * @param userLocale LocaleSidKey used for date/number parsing
     * @param runDuplicateCheck Kept for signature compatibility - the duplicate check now always runs
     */
    public SLO_SelloutItemImportBatch(Id accountId, Id reportId, Id contentVersionId,
                                     SLO_SelloutImportController.ImportMappingConfig config,
                                     String userLocale, Boolean runDuplicateCheck) {
        this.accountId = accountId;
        this.reportId = reportId;
        this.contentVersionId = contentVersionId;
        this.userLocale = userLocale;
        this.delimiter = String.isBlank(config.csvDelimiter) ? ',' : config.csvDelimiter;
        this.itemDateIndex = config.itemDateIndex;
        this.productCodeIndex = config.productCodeIndex;
        this.quantityIndex = config.quantityIndex;
        this.customerAccountIndex = config.customerAccountIndex;
        this.sourceLineIndex = config.sourceLineIndex;
        this.startDate = config.startDate;
        this.autoAccept = config.autoAccept == true;
        // Only the daily automated run (Auto Accept with a source line column) processes duplicates;
        // manual runs, Auto Accept or not, follow the Skip Duplicates toggle
        this.processDuplicates = this.autoAccept && config.sourceLineIndex != null;
        this.duplicateMode = this.processDuplicates
            ? SLO_SelloutImportController.DUP_MODE_PROCESS
            : (config.skipDuplicates == false
                ? SLO_SelloutImportController.DUP_MODE_SECTION
                : SLO_SelloutImportController.DUP_MODE_SKIP);
        this.skipDuplicatesInFile = this.duplicateMode == SLO_SelloutImportController.DUP_MODE_SKIP;
        this.notificationEmail = UserInfo.getUserEmail();
    }

    /**
     * @description Read the stored CSV and return its data rows so each scope handles 200 rows
     */
    public Iterable<String> start(Database.BatchableContext context) {
        List<String> dataRows = new List<String>();

        List<ContentVersion> versions = [
            SELECT Id, VersionData
            FROM ContentVersion
            WHERE Id = :contentVersionId
            LIMIT 1
        ];

        if (versions.isEmpty()) {
            return dataRows;
        }

        // Split without a regex - String.split throws "Regex too complicated" on large files. The
        // byte order mark Excel writes is stripped first, exactly as the preview parser does, so
        // the header row here is the header row the user mapped against.
        List<String> lines = SLO_SelloutImportController.splitLines(
            SLO_SelloutImportController.stripBom(versions[0].VersionData.toString()),
            null
        );
        // Skip the header row
        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i].trim();
            if (String.isNotBlank(line)) {
                dataRows.add(line);
            }
        }
        return dataRows;
    }

    /**
     * @description Parse the scope's rows, flag duplicates, unknown product codes and quantity
     * conflicts, and insert with partial success
     */
    public void execute(Database.BatchableContext context, List<String> scope) {
        List<SLO_Sellout_Item__c> itemsToInsert = new List<SLO_Sellout_Item__c>();
        Set<String> seenKeys = new Set<String>();

        rowsRead += scope.size();

        for (String line : scope) {
            try {
                List<String> row = SLO_SelloutImportController.parseCsvRow(line, delimiter);

                Date itemDate = parseItemDate(valueAt(row, itemDateIndex));
                if (isBeforeStartDate(itemDate)) {
                    rowsBeforeStartDate++;
                    continue;
                }
                Decimal quantity = SLO_SelloutImportController.parseNumberForLocale(valueAt(row, quantityIndex), userLocale);

                SLO_Sellout_Item__c item = new SLO_Sellout_Item__c(
                    SLO_Sellout_Report__c = reportId,
                    SLO_Item_Date__c = itemDate,
                    SLO_Product_Code_EAN__c = valueAt(row, productCodeIndex),
                    SLO_Quantity__c = quantity,
                    SLO_Customer_Account_Name__c = valueAt(row, customerAccountIndex),
                    SLO_Processing_Status__c = 'Pending'
                );

                // Exact duplicates inside one scope collapse to their first occurrence; duplicates
                // of rows already recorded are handled by the validator below
                String sourceId = valueAt(row, sourceLineIndex);
                if (String.isNotBlank(sourceId) && sourceId.trim().length() >= 15) {
                    item.SLO_Source_Line_Item__c = Id.valueOf(sourceId.trim());
                }
                // Distinct source lines are distinct sales even when customer, product, date and quantity match
                String key = item.SLO_Source_Line_Item__c != null
                    ? 'SRC|' + item.SLO_Source_Line_Item__c
                    : SLO_SelloutImportController.buildDuplicateKey(item);
                if (!skipDuplicatesInFile || !seenKeys.contains(key)) {
                    seenKeys.add(key);
                    itemsToInsert.add(item);
                }
            } catch (Exception e) {
                totalErrors++;
                if (errorSamples.size() < 10) {
                    errorSamples.add(e.getMessage());
                }
            }
        }

        if (itemsToInsert.isEmpty()) {
            return;
        }

        // Rows already recorded become Skipped but are inserted too, so the review screen can
        // account for every row of the file; unknown product codes and quantity conflicts become
        // Errors so they are named on their rows at review time instead of failing at invoice time
        SLO_SelloutImportController.validateItemsForAccount(
            itemsToInsert, accountId, null, duplicateMode
        );

        List<Database.SaveResult> results = Database.insert(itemsToInsert, false);
        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult saveResult = results[i];
            if (saveResult.isSuccess()) {
                // A duplicate row is stored for the record but is not a newly imported line
                if (itemsToInsert[i].SLO_Processing_Status__c == 'Skipped') {
                    duplicatesRemoved++;
                } else if (itemsToInsert[i].SLO_Processing_Status__c == SLO_SelloutImportController.STATUS_DUPLICATE) {
                    duplicatesForReview++;
                } else {
                    totalProcessed++;
                    if (itemsToInsert[i].SLO_Processing_Status__c == 'Error') {
                        rowsFlaggedForReview++;
                    }
                }
            } else {
                totalErrors++;
                if (errorSamples.size() < 10 && !saveResult.getErrors().isEmpty()) {
                    errorSamples.add(saveResult.getErrors()[0].getMessage());
                }
            }
        }
    }

    /**
     * @description Finalise the report and hand the import totals to the account matching job, which
     * carries them through the rest of the chain so the user receives exactly one summary email
     */
    public void finish(Database.BatchableContext context) {
        // A successful import leaves the report in Draft, not Completed: the user reviews the new
        // items and any errors before Apply Sellout creates invoices.
        String status = (totalProcessed == 0 && totalErrors > 0) ? 'Error' : 'Draft';

        SLO_Sellout_Report__c report = new SLO_Sellout_Report__c(
            Id = reportId,
            SLO_Status__c = status,
            SLO_Import_Date__c = DateTime.now(),
            // Total is every data row read from the file - new, duplicate or in error - so the figure
            // on the list always matches what was uploaded
            SLO_Total_Items__c = Math.max(rowsRead - rowsBeforeStartDate, totalProcessed + duplicatesRemoved)
        );
        if (!errorSamples.isEmpty()) {
            report.SLO_Error_Message__c = String.join(errorSamples, '\n').abbreviate(32000);
        }

        try {
            update report;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Unable to update sellout report: ' + e.getMessage());
        }

        // Imported items are only 'Pending' - account matching and invoice creation must run before
        // any invoices exist. Chain straight into matching, passing the import totals along so the
        // final link of the chain can send one email covering import, matching and invoicing.
        SLO_SelloutApplyBatch.RunContext runContext = new SLO_SelloutApplyBatch.RunContext();
        runContext.importRan = true;
        runContext.itemsImported = totalProcessed;
        runContext.importErrors = totalErrors;
        runContext.duplicatesRemoved = duplicatesRemoved;
        runContext.importFlaggedForReview = rowsFlaggedForReview;
        runContext.autoAccept = autoAccept;
        runContext.processDuplicates = processDuplicates;
        for (String sample : errorSamples) {
            runContext.addError(sample);
        }

        Boolean matchingStarted = false;
        if (totalProcessed > 0 && !Test.isRunningTest()) {
            try {
                Database.executeBatch(
                    new SLO_SelloutApplyBatch(
                        reportId, accountId, SLO_SelloutApplyBatch.MODE_MATCH, runContext
                    ),
                    SLO_SelloutApplyBatch.scopeSizeForAttempt(1)
                );
                matchingStarted = true;
                // Matching is now changing the rows, so the review must wait for it
                SLO_SelloutApplyBatch.markInProcess(reportId);
            } catch (Exception e) {
                runContext.addError(e.getMessage());
            }
        }

        // An Auto Accept run promised an email, so an import that yields nothing or cannot hand over
        // to matching must still end the run and say so
        if (autoAccept && (totalProcessed == 0 || (!matchingStarted && !Test.isRunningTest()))) {
            reportAutoAcceptStopped(runContext);
            return;
        }

        // No email for an import. The user is watching the upload and the review list shows the
        // outcome, so the only run that notifies by email is Apply Sellout. An import that could
        // not chain on to matching is logged instead.
        if (!matchingStarted && totalProcessed > 0) {
            System.debug(LoggingLevel.ERROR, 'Sellout import did not start account matching for report ' +
                reportId + (errorSamples.isEmpty() ? '' : ': ' + String.join(errorSamples, '; ')));
        }
    }

    /**
     * @description End an Auto Accept run that never reached matching: release the report and email
     * the user why nothing was invoiced
     * @param runContext Totals and errors collected by the import
     */
    private void reportAutoAcceptStopped(SLO_SelloutApplyBatch.RunContext runContext) {
        try {
            SLO_SelloutApplyBatch.releaseReport(reportId);
        } catch (Exception e) {
            runContext.addError(e.getMessage());
        }

        String reason = totalProcessed == 0
            ? 'The import produced no new items, so there was nothing to match or invoice.'
            : 'The import finished but account matching could not be started, so nothing was invoiced.';
        String body = 'Your sellout Auto Accept run has stopped.\n\n' + reason +
            '\n\nItems imported: ' + totalProcessed +
            '\nRows with errors: ' + totalErrors +
            '\nDuplicate rows skipped: ' + duplicatesRemoved;
        if (!runContext.errorSamples.isEmpty()) {
            body += '\n\nFirst errors:\n  ' + String.join(runContext.errorSamples, '\n  ');
        }
        SLO_SelloutImportController.sendCompletionEmail(
            UserInfo.getUserEmail(), 'Sellout Auto Accept stopped - nothing was invoiced', body
        );
    }

    /**
     * @description Reads dd/mm/yy (two-digit year as 20yy) and dd/mm/yyyy day-first whatever the user
     * locale; every other format goes through the locale-aware parser unchanged.
     */
    @TestVisible
    private Date parseItemDate(String raw) {
        String value = raw == null ? null : raw.trim();
        if (value != null && Pattern.matches('^\\d{1,2}/\\d{1,2}/(\\d{2}|\\d{4})$', value)) {
            List<String> parts = value.split('/');
            Integer year = Integer.valueOf(parts[2]);
            if (parts[2].length() == 2) {
                year += 2000;
            }
            try {
                return Date.newInstance(year, Integer.valueOf(parts[1]), Integer.valueOf(parts[0]));
            } catch (Exception e) {
                throw new IllegalArgumentException('Invalid date: ' + value);
            }
        }
        return SLO_SelloutImportController.parseDateForLocale(raw, userLocale);
    }

    /**
     * @description Whether a row falls before the start date the user chose. The date parser throws on
     * an unreadable date, so such a row never gets here and is counted as an import error instead.
     */
    private Boolean isBeforeStartDate(Date itemDate) {
        return startDate != null && itemDate != null && itemDate < startDate;
    }

    /**
     * @description Safe positional read from a parsed CSV row
     */
    private String valueAt(List<String> row, Integer index) {
        if (index == null || index < 0 || index >= row.size()) {
            return null;
        }
        return row[index];
    }
}