/**
 * @description Batch Apex for async Apply Sellout. Runs in one of two modes:
 * MODE_MATCH matches each sellout item to an account in the current account hierarchy, and
 * MODE_INVOICE creates grouped invoices and line items with pricebook price lookup.
 *
 * The whole import -> match -> invoice pipeline is a chain of these jobs. Progress is carried
 * from one link to the next in a RunContext so that exactly one email is sent to the user, at the
 * very end of the chain, summarising every stage. Links that hit errors are retried automatically
 * with a smaller scope size and no email, so a transient limit or lock failure resolves itself.
 */
public with sharing class SLO_SelloutApplyBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    public static final String MODE_MATCH = 'match';
    public static final String MODE_INVOICE = 'invoice';
    // Applies the user's bulk Create/Activate/Reassign/Skip decisions to the report's rows. A report
    // with thousands of rows behind a single unresolved name cannot be updated in one transaction,
    // so the decisions are carried into this mode and applied a scope at a time.
    public static final String MODE_DECISION = 'decision';
    // One Auto Accept step per job so no single transaction does all of it
    public static final String MODE_AUTO_STEP = 'autostep';

    // Scope sizes used as the chain retries. Each retry halves the work per transaction.
    private static final List<Integer> RETRY_SCOPE_SIZES = new List<Integer>{ 200, 100, 50 };
    private static final Integer MAX_ATTEMPTS = 3;
    // Invoice passes one job may run back to back while the transaction has headroom
    private static final Integer MAX_PASSES_PER_JOB = 25;
    // Guard against an unexpectedly long invoice chain looping forever
    private static final Integer MAX_INVOICE_PASSES = 1000;
    // Stop the chain after this many consecutive passes that resolved nothing
    private static final Integer MAX_ZERO_PROGRESS_PASSES = 2;

    private final Id reportId;
    private final Id currentAccountId;
    private final String mode;
    private final String notificationEmail;
    private final RunContext runContext;
    // Only populated for MODE_DECISION
    private final DecisionPlan decisionPlan;

    private Integer itemsMatched = 0;
    private Integer itemsSkipped = 0;
    private Integer itemsPendingDecision = 0;
    @TestVisible private static String lastSummarySubject;
    private Integer totalErrors = 0;
    private Set<String> unmatchedNames = new Set<String>();
    private List<String> errorSamples = new List<String>();

    // Hierarchy lookup maps, built once in start() and reused across scopes
    private Map<String, Id> accountNameToId = new Map<String, Id>();
    private Map<String, String> accountNameToStatus = new Map<String, String>();

    /**
     * @description The already-resolved outcome of the user's account decisions, keyed by normalised
     * customer name. The accounts themselves are created or activated up front by the controller -
     * there are only ever as many of those as there are distinct names - and this plan carries the
     * result to the rows, which is the part that has to be spread over several transactions.
     */
    public class DecisionPlan {
        // Normalised customer name to the account its rows must be pointed at
        public Map<String, Id> keyToAccountId = new Map<String, Id>();
        // Normalised customer name to the account name its rows must be renamed to (reassign only)
        public Map<String, String> keyToNewName = new Map<String, String>();
        // Normalised customer names whose rows the user chose to skip
        public Set<String> skipKeys = new Set<String>();
        // Normalised customer names the user reassigned, counted separately for the summary
        public Set<String> reassignedKeys = new Set<String>();
        // True to start invoice creation once every row has been decided
        public Boolean startInvoicing = false;
    }

    /**
     * @description Running totals carried across every link of the import/match/invoice chain so
     * the final link can email one complete summary instead of one email per stage
     */
    public class RunContext {
        public Boolean decisionRan = false;
        public Integer autoSetAside = 0;
        public Integer decisionItemsMatched = 0;
        public Integer decisionItemsSkipped = 0;
        public Integer decisionItemsReassigned = 0;
        public Integer decisionItemsFlagged = 0;
        public Integer decisionDuplicates = 0;
        public Integer decisionQuantityConflicts = 0;
        public Integer decisionProductErrors = 0;

        public Integer itemsImported = 0;
        public Integer importErrors = 0;
        public Integer duplicatesRemoved = 0;
        // Rows imported at status Error because their product code is unknown or their quantity
        // conflicts with a line already recorded
        public Integer importFlaggedForReview = 0;
        public Boolean importRan = false;

        public Integer itemsMatched = 0;
        public Integer itemsSkipped = 0;
        public Integer itemsPendingDecision = 0;
        public Integer unmatchedNameCount = 0;
        public Boolean matchRan = false;

        public Integer invoicesCreated = 0;
        public Integer negativeInvoicesCreated = 0;
        public Integer lineItemsCreated = 0;
        public Integer duplicateGroupsSkipped = 0;
        // Items whose product was already invoiced for that customer and date with a different quantity
        public Integer itemsQuantityMismatch = 0;
        // Lines added to invoices that already existed, for products not previously invoiced
        public Integer lineItemsAddedToExistingInvoices = 0;
        public Integer invoicePasses = 0;
        public Boolean invoiceRan = false;
        // Highest sellout item Id already examined by the invoice chain. Each pass resumes above it,
        // which is what guarantees the chain advances even when a pass skips everything it reads.
        public String invoiceCursorId = null;
        // Consecutive passes that resolved no items. Two in a row means the chain cannot progress,
        // so it stops and reports instead of burning through its pass ceiling.
        public Integer zeroProgressPasses = 0;

        // Attempt number for the link currently running; drives the retry scope size
        public Integer attempt = 1;
        // Chosen at upload: the chain decides everything itself and runs straight on to invoicing
        public Boolean autoAccept = false;
        // Daily automated run only: duplicates are processed instead of skipped or sectioned
        public Boolean processDuplicates = false;
        // Next Auto Accept step: 0 set aside lines, 1 resolve accounts, 2 set aside again and invoice
        public Integer autoStage = 0;
        // Retries and per-stage problems are collected here and reported once, at the end
        public Integer silentRetries = 0;
        public List<String> errorSamples = new List<String>();
        public List<String> warnings = new List<String>();

        /**
         * @description Record an error sample, keeping only the first few to bound heap usage
         * @param message Error text to record
         */
        public void addError(String message) {
            if (errorSamples.size() < 10 && String.isNotBlank(message)) {
                errorSamples.add(message);
            }
        }

        /**
         * @description Record a stage-level warning shown in the final email
         * @param message Warning text to record
         */
        public void addWarning(String message) {
            if (warnings.size() < 10 && String.isNotBlank(message)) {
                warnings.add(message);
            }
        }
    }

    /**
     * @description Constructor for a fresh run
     * @param reportId Sellout report being applied
     * @param currentAccountId Parent (main) account whose hierarchy is searched
     * @param mode MODE_MATCH or MODE_INVOICE
     */
    public SLO_SelloutApplyBatch(Id reportId, Id currentAccountId, String mode) {
        this(reportId, currentAccountId, mode, new RunContext());
    }

    /**
     * @description Constructor that continues an existing chain, preserving its running totals
     * @param reportId Sellout report being applied
     * @param currentAccountId Parent (main) account whose hierarchy is searched
     * @param mode MODE_MATCH or MODE_INVOICE
     * @param context Running totals from the earlier links of the chain
     */
    public SLO_SelloutApplyBatch(Id reportId, Id currentAccountId, String mode, RunContext context) {
        this(reportId, currentAccountId, mode, context, null);
    }

    /**
     * @description Constructor for the decision mode, carrying the plan the controller resolved
     * @param reportId Sellout report being applied
     * @param currentAccountId Parent (main) account whose hierarchy is searched
     * @param mode MODE_MATCH, MODE_INVOICE or MODE_DECISION
     * @param context Running totals from the earlier links of the chain
     * @param plan Resolved account decisions to apply to the report's rows
     */
    public SLO_SelloutApplyBatch(Id reportId, Id currentAccountId, String mode, RunContext context,
                                 DecisionPlan plan) {
        this.reportId = reportId;
        this.currentAccountId = currentAccountId;
        this.mode = String.isBlank(mode) ? MODE_MATCH : mode;
        this.notificationEmail = UserInfo.getUserEmail();
        this.runContext = context == null ? new RunContext() : context;
        this.decisionPlan = plan;
    }

    /**
     * @description Scope size to use for a given attempt, shrinking on each silent retry
     * @param attempt 1-based attempt number
     * @return Records per execute() call
     */
    public static Integer scopeSizeForAttempt(Integer attempt) {
        Integer index = (attempt == null ? 1 : attempt) - 1;
        if (index < 0) {
            index = 0;
        }
        if (index >= RETRY_SCOPE_SIZES.size()) {
            index = RETRY_SCOPE_SIZES.size() - 1;
        }
        return RETRY_SCOPE_SIZES[index];
    }

    public static final String STATUS_IN_PROCESS = 'In_Process';

    /**
     * @description Mark a report In Process so the screen will not open it while a background run is
     * changing its rows. Never throws: the flag guards the screen and must not stop the run.
     * @param reportId Sellout report the run works on
     */
    public static void markInProcess(Id reportId) {
        try {
            update new SLO_Sellout_Report__c(Id = reportId, SLO_Status__c = STATUS_IN_PROCESS);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Unable to mark sellout report in process: ' + e.getMessage());
        }
    }

    /**
     * @description The chain is ending. If no link set a final status (Draft, Completed, Error), hand
     * the report back to the user as Draft so it can be opened again.
     */
    private void releaseInProcess() {
        try {
            releaseReport(reportId);
        } catch (Exception e) {
            runContext.addError(e.getMessage());
        }
    }

    /**
     * @description Hand a report left In Process back to the user as Draft; any other status is kept
     * @param reportId Sellout report to release
     */
    public static void releaseReport(Id reportId) {
        List<SLO_Sellout_Report__c> reports = [
            SELECT Id
            FROM SLO_Sellout_Report__c
            WHERE Id = :reportId
            AND SLO_Status__c = :STATUS_IN_PROCESS
            LIMIT 1
        ];
        if (!reports.isEmpty()) {
            reports[0].SLO_Status__c = 'Draft';
            update reports;
        }
    }

    /**
     * @description Selective locator over the report's items, filtered by the mode's starting status
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        Database.QueryLocator locator;
        try {
            locator = buildQueryLocator();
        } catch (Exception e) {
            // A failing start() never reaches finish(), so record the reason here or the report would
            // stay In Process with no explanation
            SLO_SelloutImportController.failStuckReport(reportId, 'Sellout processing could not start: ' + e.getMessage());
            throw e;
        }
        // Marked only once the work that can throw has succeeded: a start() that fails never reaches
        // finish(), so nothing would release a report marked earlier
        markInProcess(reportId);
        return locator;
    }

    private Database.QueryLocator buildQueryLocator() {
        if (mode == MODE_MATCH) {
            buildHierarchyMaps();
            return Database.getQueryLocator([
                SELECT Id, SLO_Customer_Account_Name__c, SLO_Item_Date__c,
                       SLO_Product_Code_EAN__c, SLO_Quantity__c,
                       SLO_Matched_Account__c, SLO_Processing_Status__c
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c = 'Pending'
            ]);
        }

        if (mode == MODE_AUTO_STEP) {
            // The work happens in finish(); one row is enough to let the job run
            return Database.getQueryLocator([
                SELECT Id FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId LIMIT 1
            ]);
        }

        if (mode == MODE_DECISION) {
            // Every row a decision can still settle, whatever the reason it is waiting. Error rows
            // are included because a row can carry a data error AND an unresolved account name, and
            // the rows set aside by an earlier account decision are included so a customer left out
            // can be brought back - execute() filters out any other skipped row.
            return Database.getQueryLocator([
                SELECT Id, SLO_Customer_Account_Name__c, SLO_Item_Date__c,
                       SLO_Product_Code_EAN__c, SLO_Quantity__c, SLO_Matched_Account__c,
                       SLO_Processing_Status__c, SLO_Processing_Notes__c, SLO_Sellout_Report__c
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c IN :SLO_SelloutImportController.DECISION_DECIDABLE_STATUSES
            ]);
        }

        // Invoice mode is driven from the controller's grouped logic, so only matched items qualify
        return Database.getQueryLocator([
            SELECT Id, SLO_Matched_Account__c, SLO_Item_Date__c,
                   SLO_Product_Code_EAN__c, SLO_Quantity__c, SLO_Processing_Status__c
            FROM SLO_Sellout_Item__c
            WHERE SLO_Sellout_Report__c = :reportId
            AND SLO_Processing_Status__c = 'Matched'
            AND SLO_Matched_Account__c != null
        ]);
    }

    /**
     * @description Match or flag each item in the scope; invoice mode defers to the controller helper
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        if (mode == MODE_MATCH) {
            matchScope((List<SLO_Sellout_Item__c>) scope);
        } else if (mode == MODE_DECISION) {
            decisionScope((List<SLO_Sellout_Item__c>) scope);
        }
        // MODE_INVOICE performs its grouped work in finish(), one bounded pass per chained job,
        // so invoice grouping is never split across scopes of the same job
    }

    /**
     * @description Advance the chain: match hands over to invoicing, invoicing chains further passes
     * while items remain, and only the last link emails the user
     */
    public void finish(Database.BatchableContext context) {
        // The user must always hear how the run ended. An exception anywhere in finish() previously
        // exited without an email, leaving a stalled chain completely silent, so any failure here
        // falls back to a plain notification instead of propagating.
        try {
            if (mode == MODE_MATCH) {
                finishMatch();
            } else if (mode == MODE_AUTO_STEP) {
                finishAutoStep();
            } else if (mode == MODE_DECISION) {
                finishDecision();
            } else {
                finishInvoice();
            }
        } catch (Exception e) {
            SLO_SelloutImportController.failStuckReport(reportId, 'Sellout processing stopped: ' + e.getMessage());
            releaseInProcess();
            // Only an Apply Sellout run emails the user; other stages surface their state on screen
            if (!isApplyRun()) {
                System.debug(LoggingLevel.ERROR, 'Sellout chain stopped: ' + e.getMessage());
                return;
            }
            try {
                SLO_SelloutImportController.sendCompletionEmail(
                    notificationEmail,
                    'Sellout processing stopped unexpectedly',
                    'Your sellout processing stopped before it finished.\n\n' +
                        'Reason: ' + e.getMessage() + '\n\n' +
                        'Any items that were not invoiced are still matched, so running Apply Sellout ' +
                        'again will resume them.'
                );
            } catch (Exception emailEx) {
                System.debug('Unable to send sellout failure email: ' + emailEx.getMessage());
            }
        }
    }

    /**
     * @description Roll matching results into the shared context, then either hand over to invoice
     * creation or finish the chain when the user still has decisions to make
     */
    private void finishMatch() {
        runContext.matchRan = true;
        runContext.itemsMatched += itemsMatched;
        runContext.itemsSkipped += itemsSkipped;
        runContext.itemsPendingDecision += itemsPendingDecision;
        runContext.unmatchedNameCount += unmatchedNames.size();
        for (String sample : errorSamples) {
            runContext.addError(sample);
        }

        if (runContext.autoAccept == true) {
            runContext.autoStage = 0;
            if (!startNextLink(MODE_AUTO_STEP, 1)) {
                setReportStatusToDraft();
                sendChainSummary();
            }
            return;
        }

        // Items awaiting a decision block invoicing - end the chain and tell the user once
        if (itemsPendingDecision > 0) {
            sendChainSummary();
            return;
        }

        // Matching no longer runs straight into invoicing. The report stops at Draft so the user can
        // review the new items and fix any errors before invoices are created, which is what makes a
        // 12,000 row file workable - they act on the handful of rows that need attention, not all of
        // them. Apply Sellout in the UI starts invoice mode when they are ready.
        setReportStatusToDraft();
        sendChainSummary();
    }

    /**
     * @description Auto Accept, chosen at upload: set aside every line still needing a fix, create or
     * activate an account for every unresolved customer name, then go straight on to invoicing. It
     * reuses the controller paths the review screen calls, so the outcome matches a manual review.
     */
    private void finishAutoStep() {
        Integer stage = runContext.autoStage;
        runContext.autoStage = stage + 1;
        if (stage == 0) {
            Integer setAside = SLO_SelloutImportController.skipUncorrectedErrorItems(reportId);
            runContext.autoSetAside += setAside;
            try {
                update new SLO_Sellout_Report__c(Id = reportId, SLO_Lines_Need_Fix__c = runContext.autoSetAside);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Could not record lines needing a fix: ' + e.getMessage());
            }
            if (setAside >= SLO_SelloutImportController.UNCORRECTED_SKIP_LIMIT) {
                runContext.addWarning('Auto Accept set aside the first ' + setAside + ' lines needing a fix. ' +
                    'More lines needing a fix may remain; they were not invoiced.');
            }
            runContext.itemsPendingDecision = 0;
            runContext.unmatchedNameCount = 0;
            if (startNextLink(MODE_AUTO_STEP, 1)) {
                return;
            }
        } else if (stage == 1) {
            List<SLO_SelloutImportController.UnmatchedDecision> decisions = buildAutoAcceptDecisions();
            if (!decisions.isEmpty()) {
                SLO_SelloutImportController.BulkResolveResult result =
                    SLO_SelloutImportController.bulkResolveUnmatchedForRun(reportId, currentAccountId, decisions, true, runContext);
                if (result.success != true) {
                    runContext.addError(result.errorMessage);
                } else if (String.isNotBlank(result.jobId)) {
                    return;
                }
            }
            if (startNextLink(MODE_AUTO_STEP, 1)) {
                return;
            }
        } else {
            runContext.autoSetAside += SLO_SelloutImportController.skipUncorrectedErrorItems(reportId);
            if (countItemsStillWaiting() > 0 && startNextLink(MODE_INVOICE, 1)) {
                return;
            }
        }
        if (stage < 2) {
            runContext.addWarning('Auto Accept could not queue its next step.');
        }
        setReportStatusToDraft();
        sendChainSummary();
    }

    private void runAutoAccept() {
        // ponytail: one sweep of up to 5,000 lines; any remainder stays in Needs a fix and is not
        // invoiced - loop the sweep in a chained job if reports that large appear
        Integer setAside = SLO_SelloutImportController.skipUncorrectedErrorItems(reportId);
        if (setAside >= SLO_SelloutImportController.UNCORRECTED_SKIP_LIMIT) {
            runContext.addWarning('Auto Accept set aside the first ' + setAside + ' lines needing a fix. ' +
                'More lines needing a fix may remain; they were not invoiced.');
        }

        // The decisions are applied here, so nothing is left awaiting the user; without this the summary
        // would ask for a decision that was already made
        runContext.itemsPendingDecision = 0;
        runContext.unmatchedNameCount = 0;

        List<SLO_SelloutImportController.UnmatchedDecision> decisions = buildAutoAcceptDecisions();
        if (!decisions.isEmpty()) {
            SLO_SelloutImportController.BulkResolveResult result =
                SLO_SelloutImportController.bulkResolveUnmatchedForRun(reportId, currentAccountId, decisions, true, runContext);
            if (result.success != true) {
                runContext.addError(result.errorMessage);
            } else if (String.isNotBlank(result.jobId)) {
                // The decision job (large report) or the invoice job it queued carries on from here
                return;
            }
        }

        // Rows the account step flagged are lines needing a fix too, so set them aside as well
        SLO_SelloutImportController.skipUncorrectedErrorItems(reportId);

        // Nothing was queued by the decisions, so invoice what matching already matched
        if (countItemsStillWaiting() > 0 && startNextLink(MODE_INVOICE, 1)) {
            return;
        }
        sendChainSummary();
    }

    /**
     * @description One decision per unresolved customer name: activate the inactive account that
     * answers to it, otherwise create a new child account
     */
    private List<SLO_SelloutImportController.UnmatchedDecision> buildAutoAcceptDecisions() {
        List<SLO_SelloutImportController.UnmatchedDecision> decisions =
            new List<SLO_SelloutImportController.UnmatchedDecision>();
        for (SLO_SelloutImportController.AccountMatchResult unmatched
                : SLO_SelloutImportController.getUnmatchedAccounts(reportId)) {
            SLO_SelloutImportController.UnmatchedDecision decision =
                new SLO_SelloutImportController.UnmatchedDecision();
            decision.customerAccountName = unmatched.customerAccountName;
            decision.action = unmatched.isInactive == true ? 'activate' : 'create';
            decision.existingAccountId = unmatched.accountId;
            decisions.add(decision);
        }
        return decisions;
    }

    /**
     * @description Apply the user's account decisions to one scope of rows. A row pointed at an
     * account is re-validated, so a decision that resolves the account still surfaces a row whose
     * data is wrong (unknown product code, quantity conflict, duplicate under the corrected name).
     * @param items One scope of rows awaiting a decision
     */
    private void decisionScope(List<SLO_Sellout_Item__c> items) {
        if (decisionPlan == null) {
            return;
        }

        List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();
        List<SLO_Sellout_Item__c> decidedRows = new List<SLO_Sellout_Item__c>();
        Set<Id> decidedIds = new Set<Id>();

        for (SLO_Sellout_Item__c item : items) {
            // A row skipped for its own reasons - a duplicate, a zero quantity - is not revived by
            // an account decision; only the rows set aside by an earlier account decision are
            if (!SLO_SelloutImportController.isDecidableRow(item)) {
                continue;
            }

            String key = SLO_SelloutImportController.nameKey(item.SLO_Customer_Account_Name__c);

            if (decisionPlan.skipKeys.contains(key)) {
                item.SLO_Processing_Status__c = 'Skipped';
                item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_ACCOUNT_DECLINED;
                itemsToUpdate.add(item);
                itemsSkipped++;
                continue;
            }

            Id decidedAccountId = decisionPlan.keyToAccountId.get(key);
            if (decidedAccountId == null) {
                // A name the user left undecided keeps its menu in the review list
                continue;
            }

            if (item.SLO_Quantity__c == null || item.SLO_Quantity__c == 0) {
                item.SLO_Processing_Status__c = 'Skipped';
                item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_ZERO_QUANTITY;
                itemsToUpdate.add(item);
                itemsSkipped++;
                continue;
            }

            if (decisionPlan.keyToNewName.containsKey(key)) {
                item.SLO_Customer_Account_Name__c = decisionPlan.keyToNewName.get(key);
            }
            if (decisionPlan.reassignedKeys.contains(key)) {
                runContext.decisionItemsReassigned++;
            }
            item.SLO_Matched_Account__c = decidedAccountId;
            item.SLO_Processing_Status__c = 'Matched';
            item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_READY;
            decidedRows.add(item);
            decidedIds.add(item.Id);
        }

        if (!decidedRows.isEmpty()) {
            SLO_SelloutImportController.ValidationCounts flagged =
                SLO_SelloutImportController.validateItemsForAccount(
                    decidedRows, currentAccountId, decidedIds,
                    runContext.processDuplicates == true
                        ? SLO_SelloutImportController.DUP_MODE_PROCESS : null
                );
            runContext.decisionDuplicates += flagged.duplicates;
            runContext.decisionQuantityConflicts += flagged.quantityConflicts;
            runContext.decisionProductErrors += flagged.productErrors;

            for (SLO_Sellout_Item__c row : decidedRows) {
                if (row.SLO_Processing_Status__c == 'Matched') {
                    itemsMatched++;
                } else if (row.SLO_Processing_Status__c == 'Error') {
                    runContext.decisionItemsFlagged++;
                }
                itemsToUpdate.add(row);
            }
        }

        if (itemsToUpdate.isEmpty()) {
            return;
        }

        for (Database.SaveResult saveResult : Database.update(itemsToUpdate, false)) {
            if (!saveResult.isSuccess()) {
                totalErrors++;
                if (errorSamples.size() < 10 && !saveResult.getErrors().isEmpty()) {
                    errorSamples.add(saveResult.getErrors()[0].getMessage());
                }
            }
        }
    }

    /**
     * @description Roll the decision results into the shared context, then either hand over to
     * invoice creation or park the report in Draft for the user's review
     */
    private void finishDecision() {
        runContext.decisionRan = true;
        runContext.decisionItemsMatched += itemsMatched;
        runContext.decisionItemsSkipped += itemsSkipped;
        for (String sample : errorSamples) {
            runContext.addError(sample);
        }

        if (runContext.autoAccept == true) {
            SLO_SelloutImportController.skipUncorrectedErrorItems(reportId);
        }

        Boolean invoiceNext = decisionPlan != null
            && decisionPlan.startInvoicing == true
            && (itemsMatched > 0 || (runContext.autoAccept == true && countItemsStillWaiting() > 0))
            && !Test.isRunningTest();

        if (invoiceNext && startNextLink(MODE_INVOICE, 1)) {
            return;
        }

        // Nothing further to run, so the report waits in Draft for the user's Apply Sellout
        setReportStatusToDraft();
        sendChainSummary();
    }

    /**
     * @description Move the report to Draft so the UI opens it in review mode with Apply Sellout
     * available. Failures are recorded rather than thrown so the summary email is still sent.
     */
    private void setReportStatusToDraft() {
        try {
            update new SLO_Sellout_Report__c(
                Id = reportId,
                SLO_Status__c = 'Draft',
                SLO_Error_Message__c = null
            );
        } catch (Exception e) {
            runContext.addError(e.getMessage());
        }
    }

    /**
     * @description Run one bounded invoicing pass, then chain the next pass, retry silently on
     * failure, or send the single completion email when the report is fully invoiced
     */
    private void finishInvoice() {
        runContext.invoiceRan = true;
        runContext.invoicePasses++;

        SLO_SelloutImportController.ApplySelloutResult result;
        try {
            result = runPassesWithinLimits();
        } catch (Exception e) {
            result = null;
            runContext.addError(e.getMessage());
        }

        Boolean passFailed = (result == null || result.success != true);

        if (passFailed) {
            if (result != null && String.isNotBlank(result.errorMessage)) {
                runContext.addError(result.errorMessage);
            }

            // Retry silently with a smaller scope - transient limit and lock errors usually clear
            if (runContext.attempt < MAX_ATTEMPTS && !Test.isRunningTest()) {
                Integer nextAttempt = runContext.attempt + 1;
                runContext.silentRetries++;
                if (startNextLink(MODE_INVOICE, nextAttempt)) {
                    return;
                }
            }

            // Out of retries - report the failure once
            runContext.addWarning('Invoice creation did not complete. ' +
                'The items that were not invoiced are still matched, so running Apply Sellout again will resume them.');
            sendChainSummary();
            return;
        }

        // The pass succeeded, so reset the retry budget for the next one
        runContext.attempt = 1;
        runContext.invoicesCreated += nullToZero(result.invoicesCreated);
        runContext.negativeInvoicesCreated += nullToZero(result.negativeInvoicesCreated);
        runContext.lineItemsCreated += nullToZero(result.lineItemsCreated);
        runContext.duplicateGroupsSkipped += nullToZero(result.duplicateGroupsSkipped);
        runContext.itemsQuantityMismatch += nullToZero(result.itemsQuantityMismatch);
        runContext.lineItemsAddedToExistingInvoices += nullToZero(result.lineItemsAddedToExistingInvoices);
        runContext.itemsSkipped += nullToZero(result.itemsSkipped);
        if (String.isNotBlank(result.warningMessage)) {
            runContext.addWarning(result.warningMessage);
        }

        // Advance the cursor so the next pass reads only items this one has not seen. A null cursor
        // means the pass ran off the end of the report, so the next one sweeps again from the start.
        runContext.invoiceCursorId = result.lastItemIdExamined;

        // A pass that resolved nothing has made no forward progress. Rather than let the chain grind
        // through its pass ceiling and die silently, stop after a couple of such passes and say so.
        if (nullToZero(result.itemsResolved) == 0) {
            runContext.zeroProgressPasses++;
        } else {
            runContext.zeroProgressPasses = 0;
        }

        Boolean moreToDo = (result.moreItemsRemaining == true);

        if (moreToDo && runContext.zeroProgressPasses >= MAX_ZERO_PROGRESS_PASSES) {
            runContext.addWarning('Invoice creation stopped because the last ' +
                runContext.zeroProgressPasses + ' passes invoiced no items while ' +
                nullToZero(result.matchedItemsRemaining) +
                ' item(s) were still waiting. Those items remain matched and need review.');
            sendChainSummary();
            return;
        }

        // More matched items are waiting - chain another pass rather than exceeding limits here
        if (moreToDo && runContext.invoicePasses < MAX_INVOICE_PASSES && !Test.isRunningTest()) {
            if (startNextLink(MODE_INVOICE, 1)) {
                return;
            }
            runContext.addWarning('Some items could not be invoiced in this run. ' +
                'Run Apply Sellout again to process the remainder.');
        } else if (moreToDo) {
            runContext.addWarning(nullToZero(result.matchedItemsRemaining) +
                ' item(s) could not be invoiced in this run. ' +
                'Run Apply Sellout again to process the remainder.');
        }

        sendChainSummary();
    }

    /**
     * @description Run invoice passes back to back in this one job for as long as the transaction
     * has headroom, instead of queuing a separate job per pass. Headroom is judged from what the
     * previous pass actually consumed (triggers included), so the loop stops before a limit is hit.
     * @return Combined result of every pass run; counters are summed, cursor and remaining counts
     *         come from the last successful pass
     */
    private SLO_SelloutImportController.ApplySelloutResult runPassesWithinLimits() {
        SLO_SelloutImportController.ApplySelloutResult total = null;
        String cursor = runContext.invoiceCursorId;
        Integer maxQueries = 0;
        Integer maxDmlRows = 0;
        Integer maxDmlStatements = 0;
        Integer maxCpu = 0;

        for (Integer pass = 0; pass < MAX_PASSES_PER_JOB; pass++) {
            Integer queriesBefore = Limits.getQueries();
            Integer rowsBefore = Limits.getDmlRows();
            Integer statementsBefore = Limits.getDmlStatements();
            Integer cpuBefore = Limits.getCpuTime();

            SLO_SelloutImportController.ApplySelloutResult next =
                SLO_SelloutImportController.createInvoicePass(reportId, cursor);

            if (total == null) {
                total = next;
            } else {
                total.invoicesCreated += nullToZero(next.invoicesCreated);
                total.negativeInvoicesCreated += nullToZero(next.negativeInvoicesCreated);
                total.lineItemsCreated += nullToZero(next.lineItemsCreated);
                total.duplicateGroupsSkipped += nullToZero(next.duplicateGroupsSkipped);
                total.itemsQuantityMismatch += nullToZero(next.itemsQuantityMismatch);
                total.lineItemsAddedToExistingInvoices += nullToZero(next.lineItemsAddedToExistingInvoices);
                total.itemsSkipped += nullToZero(next.itemsSkipped);
                total.itemsResolved += nullToZero(next.itemsResolved);
                total.itemsWithErrors += nullToZero(next.itemsWithErrors);
                if (String.isNotBlank(next.warningMessage)) {
                    total.warningMessage = String.isBlank(total.warningMessage)
                        ? next.warningMessage
                        : total.warningMessage + ' | ' + next.warningMessage;
                }
                total.success = next.success;
                total.errorMessage = next.errorMessage;
                total.moreItemsRemaining = next.moreItemsRemaining;
                total.matchedItemsRemaining = next.matchedItemsRemaining;
                total.lastItemIdExamined = next.lastItemIdExamined;
            }

            if (next.success != true || next.moreItemsRemaining != true ||
                nullToZero(next.itemsResolved) == 0 || Test.isRunningTest()) {
                break;
            }

            maxQueries = Math.max(maxQueries, Limits.getQueries() - queriesBefore);
            maxDmlRows = Math.max(maxDmlRows, Limits.getDmlRows() - rowsBefore);
            maxDmlStatements = Math.max(maxDmlStatements, Limits.getDmlStatements() - statementsBefore);
            maxCpu = Math.max(maxCpu, Limits.getCpuTime() - cpuBefore);

            // Room for two more passes of the heaviest size seen so far, otherwise hand over
            Boolean roomLeft =
                Limits.getLimitQueries() - Limits.getQueries() > 2 * maxQueries + 5 &&
                Limits.getLimitDmlRows() - Limits.getDmlRows() > 2 * maxDmlRows + 100 &&
                Limits.getLimitDmlStatements() - Limits.getDmlStatements() > 2 * maxDmlStatements + 5 &&
                Limits.getLimitCpuTime() - Limits.getCpuTime() > 2 * maxCpu + 2000 &&
                Limits.getLimitHeapSize() - Limits.getHeapSize() > 1000000;
            if (!roomLeft) {
                break;
            }
            cursor = next.lastItemIdExamined;
        }
        return total;
    }

    /**
     * @description Queue the next link of the chain, carrying the running totals forward
     * @param nextMode Mode for the next job
     * @param attempt Attempt number, which sets the scope size
     * @return True when the job was queued
     */
    private Boolean startNextLink(String nextMode, Integer attempt) {
        try {
            runContext.attempt = attempt;
            Database.executeBatch(
                new SLO_SelloutApplyBatch(reportId, currentAccountId, nextMode, runContext),
                scopeSizeForAttempt(attempt)
            );
            return true;
        } catch (Exception e) {
            runContext.addError(e.getMessage());
            return false;
        }
    }

    /**
     * @description Send the one and only email for the whole chain, summarising every stage that ran
     */
    private void sendChainSummary() {
        releaseInProcess();
        // Users only want to hear from the run they asked for: Apply Sellout. Import, account
        // matching and the account-decision pass all leave their results on screen, so they end
        // silently. Anything that reached invoice creation - or was asked to reach it - still
        // reports, so a failed or partial Apply Sellout is never silent.
        if (!isApplyRun()) {
            return;
        }

        List<String> sections = new List<String>();
        String subject;

        // The chain is ending, so make the report's status agree with what was actually invoiced
        // before the user reads the email and compares the two
        if (runContext.autoAccept == true) {
            completeAutoAcceptReport();
        }
        if (runContext.invoiceRan) {
            try {
                SLO_SelloutImportController.reconcileReportStatus(reportId);
            } catch (Exception e) {
                runContext.addError(e.getMessage());
            }
        }

        if (runContext.autoAccept == true) {
            sections.add('Auto Accept\n  Lines needing a fix set aside (not invoiced): ' + runContext.autoSetAside);
        }

        if (runContext.importRan) {
            String importSection = 'Import\n' +
                '  Items imported: ' + runContext.itemsImported + '\n' +
                '  Rows with errors: ' + runContext.importErrors;
            if (runContext.duplicatesRemoved > 0) {
                importSection += '\n  Duplicate rows skipped: ' + runContext.duplicatesRemoved;
            }
            if (runContext.importFlaggedForReview > 0) {
                importSection += '\n  Rows flagged for review (unknown product code or quantity conflict): ' +
                    runContext.importFlaggedForReview;
            }
            sections.add(importSection);
        }

        if (runContext.matchRan) {
            String matchSection = 'Account matching\n' +
                '  Items matched: ' + runContext.itemsMatched + '\n' +
                '  Items skipped (zero quantity): ' + runContext.itemsSkipped;
            if (runContext.itemsPendingDecision > 0) {
                matchSection += '\n  Items awaiting your decision: ' + runContext.itemsPendingDecision +
                    '\n  Unresolved account names: ' + runContext.unmatchedNameCount;
            }
            sections.add(matchSection);
        }

        if (runContext.decisionRan) {
            String decisionSection = 'Your account decisions\n' +
                '  Lines now ready for invoicing: ' + runContext.decisionItemsMatched + '\n' +
                '  Lines skipped: ' + runContext.decisionItemsSkipped;
            if (runContext.decisionItemsReassigned > 0) {
                decisionSection += '\n  Lines pointed at an existing account: ' +
                    runContext.decisionItemsReassigned;
            }
            if (runContext.decisionDuplicates > 0) {
                decisionSection += '\n  Lines already recorded and skipped as duplicates: ' +
                    runContext.decisionDuplicates;
            }
            if (runContext.decisionQuantityConflicts > 0) {
                decisionSection += '\n  Lines conflicting on quantity with a recorded line: ' +
                    runContext.decisionQuantityConflicts;
            }
            if (runContext.decisionProductErrors > 0) {
                decisionSection += '\n  Lines with an unknown product code: ' +
                    runContext.decisionProductErrors;
            }
            sections.add(decisionSection);
        }

        // Live item counts, so the review figures in the email match what the user will see on screen
        if (runContext.importRan || runContext.matchRan || runContext.decisionRan) {
            Map<String, Integer> reviewCounts =
                SLO_SelloutImportController.getItemStatusCounts(reportId);
            sections.add('Review\n' +
                '  Items ready for invoicing: ' + reviewCounts.get('Matched') + '\n' +
                '  Duplicate items (skipped): ' + reviewCounts.get('Skipped') + '\n' +
                '  Items needing review (errors): ' + reviewCounts.get('Error'));
        }

        if (runContext.decisionRan || runContext.invoiceRan || runContext.autoAccept == true) {
            Decimal accountsCreated = 0;
            try {
                for (SLO_Sellout_Report__c rpt : [
                    SELECT SLO_Accounts_Created__c FROM SLO_Sellout_Report__c WHERE Id = :reportId LIMIT 1
                ]) {
                    accountsCreated = rpt.SLO_Accounts_Created__c != null ? rpt.SLO_Accounts_Created__c : 0;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Could not read accounts created: ' + e.getMessage());
            }
            sections.add('Accounts\n  New accounts created: ' + accountsCreated.intValue());
        }

        if (runContext.invoiceRan) {
            String invoiceSection = 'Invoice creation\n' +
                '  Invoices created: ' + runContext.invoicesCreated + '\n' +
                '  Offsetting invoices for the parent account: ' + runContext.negativeInvoicesCreated + '\n' +
                '  Line items created: ' + runContext.lineItemsCreated;
            if (runContext.lineItemsAddedToExistingInvoices > 0) {
                invoiceSection += '\n  New products added to invoices that already existed: ' +
                    runContext.lineItemsAddedToExistingInvoices;
            }
            if (runContext.duplicateGroupsSkipped > 0) {
                invoiceSection += '\n  Customer and date combinations that were already partly invoiced: ' +
                    runContext.duplicateGroupsSkipped;
            }
            if (runContext.itemsQuantityMismatch > 0) {
                invoiceSection += '\n  Items set aside as Enforced Skipped because the quantity differs from the ' +
                    'existing invoice: ' + runContext.itemsQuantityMismatch;
            }
            // A live count, so the email never claims completion while items are still waiting
            Integer stillWaiting = countItemsStillWaiting();
            if (stillWaiting > 0) {
                invoiceSection += '\n  Items still waiting to be invoiced: ' + stillWaiting;
            }
            sections.add(invoiceSection);
        }

        if (runContext.itemsPendingDecision > 0) {
            subject = 'Sellout processing needs your decision - ' +
                runContext.itemsPendingDecision + ' items';
            sections.add('Next step\n' +
                '  Open the account and choose Resolve Unmatched to create or skip the remaining accounts. ' +
                'Invoices will then be created automatically.');
        } else if (runContext.decisionRan && !runContext.invoiceRan) {
            subject = 'Sellout account decisions applied - ready for review';
            sections.add('Next step\n' +
                '  Open the account to review the lines, then click Apply Sellout to create invoices.');
        } else if (runContext.matchRan && !runContext.invoiceRan) {
            // Matching finished and the report is parked in Draft awaiting the user's review
            subject = 'Sellout import ready for review';
            sections.add('Next step\n' +
                '  Open the account to review new items and errors, then click Apply Sellout to ' +
                'create invoices.');
        } else if (runContext.invoiceRan && countItemsStillWaiting() > 0) {
            // Never call the run complete while items are outstanding, however much it invoiced
            subject = 'Sellout processing incomplete - ' + countItemsStillWaiting() +
                ' items still waiting to be invoiced';
        } else if (runContext.invoiceRan && runContext.invoicesCreated > 0) {
            subject = 'Sellout processing complete - ' + runContext.invoicesCreated + ' invoices created';
        } else if (!runContext.warnings.isEmpty()) {
            subject = 'Sellout processing finished with issues';
        } else {
            subject = 'Sellout processing complete';
        }

        String body = 'Your sellout processing has finished.\n\n' + String.join(sections, '\n\n');

        if (!runContext.warnings.isEmpty()) {
            body += '\n\nPlease note:\n  ' + String.join(runContext.warnings, '\n  ');
        }
        if (!runContext.errorSamples.isEmpty()) {
            body += '\n\nFirst errors:\n  ' + String.join(runContext.errorSamples, '\n  ');
        }

        lastSummarySubject = subject;
        SLO_SelloutImportController.sendCompletionEmail(notificationEmail, subject, body);
    }

    /**
     * @description An Auto Accept run decides everything itself, so once nothing is waiting for
     * invoicing or a decision the report is marked Completed instead of staying in Draft
     */
    private void completeAutoAcceptReport() {
        try {
            Integer open = [
                SELECT COUNT()
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c IN ('Matched', 'Pending', 'Pending_Decision')
            ];
            if (open == 0) {
                update new SLO_Sellout_Report__c(
                    Id = reportId,
                    SLO_Status__c = 'Completed',
                    SLO_Error_Message__c = null
                );
            } else {
                // Work is still outstanding: record why on the report instead of leaving it in
                // Draft/In Process with no explanation
                List<String> reasons = new List<String>();
                reasons.addAll(runContext.warnings);
                reasons.addAll(runContext.errorSamples);
                String detail = reasons.isEmpty() ? '' : ' ' + String.join(reasons, ' | ');
                update new SLO_Sellout_Report__c(
                    Id = reportId,
                    SLO_Status__c = 'Error',
                    SLO_Error_Message__c = ('Automatic sellout stopped with ' + open +
                        ' item(s) not invoiced.' + detail +
                        ' Run Apply Sellout again to resume the remaining items.').abbreviate(32000)
                );
            }
        } catch (Exception e) {
            runContext.addError(e.getMessage());
        }
    }

    /**
     * @description True when this chain belongs to an Apply Sellout run, which is the only run the
     * user is emailed about. Import, account matching and account decisions report on screen.
     * @return True when invoice creation ran, or is the job currently finishing
     */
    private Boolean isApplyRun() {
        if (runContext.autoAccept == true) {
            return true;
        }
        if (runContext.invoiceRan == true || MODE_INVOICE.equals(mode)) {
            return true;
        }
        // A decision pass asked to run straight on into invoicing is part of an Apply Sellout, so it
        // still reports - otherwise a failure to hand over to invoicing would go unnoticed
        return decisionPlan != null && decisionPlan.startInvoicing == true;
    }

    /**
     * @description Count this report's items still at status Matched, so the summary email reports
     * what is genuinely outstanding rather than what the last pass happened to see
     * @return Number of items awaiting invoicing
     */
    private Integer countItemsStillWaiting() {
        try {
            return [
                SELECT COUNT()
                FROM SLO_Sellout_Item__c
                WHERE SLO_Sellout_Report__c = :reportId
                AND SLO_Processing_Status__c = 'Matched'
            ];
        } catch (Exception e) {
            return 0;
        }
    }

    /**
     * @description Null-safe integer read used when accumulating result counts
     * @param value Possibly null count
     * @return The value, or zero when null
     */
    private static Integer nullToZero(Integer value) {
        return value == null ? 0 : value;
    }

    /**
     * @description Build the case-insensitive name maps for the account, its children and grandchildren.
     * Each name is matched exactly first and as its "_Sellout" variant second, so accounts created by
     * this process are found again on later imports without breaking older, unsuffixed accounts.
     */
    private void buildHierarchyMaps() {
        SLO_SelloutImportController.buildAccountNameMaps(
            SLO_SelloutImportController.getHierarchyAccounts(currentAccountId),
            accountNameToId,
            accountNameToStatus
        );
    }

    /**
     * @description Match one scope of items against the hierarchy maps and save with partial success
     */
    private void matchScope(List<SLO_Sellout_Item__c> items) {
        List<SLO_Sellout_Item__c> itemsToUpdate = new List<SLO_Sellout_Item__c>();

        for (SLO_Sellout_Item__c item : items) {
            if (item.SLO_Quantity__c == null || item.SLO_Quantity__c == 0) {
                item.SLO_Processing_Status__c = 'Skipped';
                item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_ZERO_QUANTITY;
                itemsToUpdate.add(item);
                itemsSkipped++;
                continue;
            }

            if (String.isBlank(item.SLO_Customer_Account_Name__c)) {
                item.SLO_Processing_Status__c = 'Error';
                item.SLO_Processing_Notes__c = 'No customer name on this row - fill it in to continue';
                itemsToUpdate.add(item);
                totalErrors++;
                continue;
            }

            String customerKey = SLO_SelloutImportController.nameKey(item.SLO_Customer_Account_Name__c);

            if (accountNameToId.containsKey(customerKey) && accountNameToStatus.get(customerKey) != 'N') {
                item.SLO_Matched_Account__c = accountNameToId.get(customerKey);
                item.SLO_Processing_Status__c = 'Matched';
                // Says plainly that nothing is wrong with this row, so the review list reads as a
                // checklist rather than a page of blank notes
                item.SLO_Processing_Notes__c = SLO_SelloutImportController.NOTE_READY;
                itemsMatched++;
            } else {
                // Either no match at all, or the match is an inactive account - the user decides
                item.SLO_Processing_Status__c = 'Pending_Decision';
                item.SLO_Processing_Notes__c = accountNameToId.containsKey(customerKey)
                    ? SLO_SelloutImportController.NOTE_ACCOUNT_INACTIVE
                    : SLO_SelloutImportController.NOTE_ACCOUNT_NOT_FOUND;
                unmatchedNames.add(customerKey);
                itemsPendingDecision++;
            }
            itemsToUpdate.add(item);
        }

        if (itemsToUpdate.isEmpty()) {
            return;
        }

        for (Database.SaveResult saveResult : Database.update(itemsToUpdate, false)) {
            if (!saveResult.isSuccess()) {
                totalErrors++;
                if (errorSamples.size() < 10 && !saveResult.getErrors().isEmpty()) {
                    errorSamples.add(saveResult.getErrors()[0].getMessage());
                }
            }
        }
    }
}