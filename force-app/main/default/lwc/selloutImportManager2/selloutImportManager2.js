import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSelloutReports from '@salesforce/apex/SLO_SelloutImportController.getSelloutReports';
import parseFile from '@salesforce/apex/SLO_SelloutImportController.parseFile';
import getSelloutItems from '@salesforce/apex/SLO_SelloutImportController.getSelloutItems';
import getSelloutItemPage from '@salesforce/apex/SLO_SelloutImportController.getSelloutItemPage';
import getItemStatusCounts from '@salesforce/apex/SLO_SelloutImportController.getItemStatusCounts';
import updateSelloutItems from '@salesforce/apex/SLO_SelloutImportController.updateSelloutItems';
import applySellout from '@salesforce/apex/SLO_SelloutImportController.applySellout';
import createChildAccount from '@salesforce/apex/SLO_SelloutImportController.createChildAccount';
import skipMatchingForItem from '@salesforce/apex/SLO_SelloutImportController.skipMatchingForItem';
import resetReportStatus from '@salesforce/apex/SLO_SelloutImportController.resetReportStatus';
import activateAccount from '@salesforce/apex/SLO_SelloutImportController.activateAccount';
import createChildAccountWithSuffix from '@salesforce/apex/SLO_SelloutImportController.createChildAccountWithSuffix';
import getSavedColumnMapping from '@salesforce/apex/SLO_SelloutImportController.getSavedColumnMapping';
import getAutomaticSelloutConfig from '@salesforce/apex/SLO_SelloutImportController.getAutomaticSelloutConfig';
import runDailySelloutNow from '@salesforce/apex/SLO_SelloutImportController.runDailySelloutNow';
import saveAutomaticSelloutConfig from '@salesforce/apex/SLO_SelloutImportController.saveAutomaticSelloutConfig';
import saveColumnMapping from '@salesforce/apex/SLO_SelloutImportController.saveColumnMapping';
import saveCsvFile from '@salesforce/apex/SLO_SelloutImportController.saveCsvFile';
import startAsyncImport from '@salesforce/apex/SLO_SelloutImportController.startAsyncImport';
import startAsyncApplySellout from '@salesforce/apex/SLO_SelloutImportController.startAsyncApplySellout';
import reconcileReportStatus from '@salesforce/apex/SLO_SelloutImportController.reconcileReportStatus';
import resumeInvoiceCreation from '@salesforce/apex/SLO_SelloutImportController.resumeInvoiceCreation';
import getUnmatchedAccounts from '@salesforce/apex/SLO_SelloutImportController.getUnmatchedAccounts';
import getHierarchyAccountOptions from '@salesforce/apex/SLO_SelloutImportController.getHierarchyAccountOptions';
import bulkResolveUnmatched from '@salesforce/apex/SLO_SelloutImportController.bulkResolveUnmatched';
import getActionableItemsAfter from '@salesforce/apex/SLO_SelloutImportController.getActionableItemsAfter';
import getReportSummary from '@salesforce/apex/SLO_SelloutImportController.getReportSummary';
import getReportStatus from '@salesforce/apex/SLO_SelloutImportController.getReportStatus';
import canDeleteReports from '@salesforce/apex/SLO_SelloutImportController.canDeleteReports';
import deleteSelloutReport from '@salesforce/apex/SLO_SelloutImportController.deleteSelloutReport';
import skipUncorrectedErrorItems from '@salesforce/apex/SLO_SelloutImportController.skipUncorrectedErrorItems';
import bulkDecideCustomerNames from '@salesforce/apex/SLO_SelloutImportController.bulkDecideCustomerNames';
import bulkEditItemField from '@salesforce/apex/SLO_SelloutImportController.bulkEditItemField';
import getItemIdsByProductCode from '@salesforce/apex/SLO_SelloutImportController.getItemIdsByProductCode';
import enforceSkipItems from '@salesforce/apex/SLO_SelloutImportController.enforceSkipItems';
import enforceSkipDuplicates from '@salesforce/apex/SLO_SelloutImportController.enforceSkipDuplicates';
import getCountryPriceBookOptions from '@salesforce/apex/SLO_SelloutImportController.getCountryPriceBookOptions';
import getImportPreferences from '@salesforce/apex/SLO_SelloutImportController.getImportPreferences';
import saveImportPreferences from '@salesforce/apex/SLO_SelloutImportController.saveImportPreferences';

// Rows dated before this are ignored on import unless the user has saved another start date
const DEFAULT_START_DATE = '2026-01-01';

// The review screen offers exactly three views, each with a single purpose, so a line sits in one
// view only and the count beside a view always means work of that one kind. There is deliberately
// no combined view: a count that mixed finished lines with outstanding work read as a to-do list
// and was not one.
//
// The view that owns the account decisions. It lists the names still awaiting a decision and the
// names already set aside, so every account decision is reviewed in the one place.
const ACCOUNT_DECISION_FILTER = 'Pending_Decision';

// The view that owns the technical data errors - an unknown product code, a quantity contradicting
// a line already recorded. Nothing else reaches it.
const NEEDS_FIX_FILTER = 'Error';

// The view that owns the finished lines: valid, with no decision and no error outstanding. A line
// never checked is valid as far as its data goes, so it is listed here rather than in a fourth view.
const READY_FILTER = 'Ready';

// The view that holds exact duplicates when Skip Duplicates was switched off at upload
const DUPLICATES_FILTER = 'Duplicate';

// The order the views are offered in, and the order a report opens in: the user lands on the first
// view that actually holds something, so the screen opens on the work rather than on an empty list
const VIEW_PRIORITY = [ACCOUNT_DECISION_FILTER, NEEDS_FIX_FILTER, DUPLICATES_FILTER, READY_FILTER];

// Review rows fetched per page. Kept small so the list opens instantly and grows only as the user
// scrolls, whatever the size of the imported file.
const PAGE_SIZE = 50;

// Lines sent per bulk-correction request. A whole selection is corrected as a run of these, so the
// user can tick any number of lines - each request stays inside what one Salesforce transaction may
// read and write, which is what the single all-at-once request could not do.
const BULK_EDIT_BATCH_SIZE = 200;

// The column the review list groups on by default, and the one an edit offers to spread across its
// matching lines. Named once so the sort, the grouping and the suggestion all mean the same column.
const PRODUCT_CODE_FIELD = 'SLO_Product_Code_EAN__c';

// How long typing settles before the rest of the view is fetched for the search, so a term typed
// character by character costs one load rather than one per keystroke
const SEARCH_LOAD_DELAY_MS = 500;

// Only the most recent reports are checked for a stalled run, so opening the component never turns
// into one call per historic report
const STUCK_CHECK_LIMIT = 5;

// While a report is still importing, the list re-checks itself on this interval so the row flips
// to Draft by itself instead of the user guessing when the background run has finished
const PROCESSING_POLL_MS = 10000;
const MAX_PROCESSING_POLLS = 60;

// While the upload window waits for its own import to finish, it re-checks the report more often
// than the list does: the user is sitting in front of it waiting to be taken to the lines, so a
// shorter interval is what makes the hand-off feel automatic rather than delayed.
const AUTO_OPEN_POLL_MS = 3000;
// Roughly ten minutes of waiting. Past that the window stops waiting and says so, rather than
// spinning forever on an import that has stalled.
const MAX_AUTO_OPEN_POLLS = 200;

const APPLYING_MESSAGE = 'Processing sellout items and matching accounts...';

// Statuses whose customer name an account decision can still settle. A tick on one of these lines
// is what the bulk account actions above the list act on. Lines needing a fix and lines never
// checked are included because a line can carry a data error and an unresolved account name at
// once, and lines already set aside are included because leaving a customer out is reversible -
// the account-decision view lists those names for review, so they stay actionable. Anything the
// view shows can be ticked and acted on, and the server reaches exactly the same lines.
const DECISION_STATUSES = ['Pending_Decision', 'Error', 'Pending', 'Skipped'];

// How each processing status reads on screen: the words the user sees and the colour of the
// status cell. Colour carries the meaning - green is ready, red needs a fix, amber needs a
// decision - so a page of a thousand lines can be scanned rather than read. Only the status
// cell is coloured; the rest of the row stays plain so the values remain readable.
const STATUS_DISPLAY = {
    Matched: { label: 'Ready', cellClass: 'slds-theme_success' },
    Error: { label: 'Needs a fix', cellClass: 'slds-theme_error' },
    Pending_Decision: { label: 'Account decision', cellClass: 'slds-theme_warning' },
    // A line whose data is valid but whose account has not been matched yet. It needs nothing from
    // the user - the apply run matches it - so it reads as ready, with the qualifier saying why it
    // is not green yet.
    Pending: { label: 'Ready - to be matched', cellClass: 'slds-theme_shade' },
    Skipped: { label: 'Skipped', cellClass: 'slds-theme_shade slds-text-color_weak' },
    Duplicate: { label: 'Duplicate', cellClass: 'slds-theme_warning' },
    // Set aside on purpose while it still needed a fix - striped so it never reads as a duplicate
    Enforced_Skipped: { label: 'Enforced Skipped', cellClass: 'slds-theme_alert-texture slds-theme_shade' },
    Invoice_Created: { label: 'Invoiced', cellClass: 'slds-theme_inverse' }
};

// Which editable value a processing note is about, so the flag lands on the cell to correct
// rather than on the whole row. Matched by the opening words of the notes the server writes.
const NOTE_TARGETS = [
    { startsWith: 'Product code not found', field: 'product' },
    // The wording the apply run uses for the same problem
    { startsWith: 'Product not found for EAN', field: 'product' },
    { startsWith: 'Already recorded with quantity', field: 'quantity' },
    { startsWith: 'Quantity mismatch', field: 'quantity' },
    { startsWith: 'Account', field: 'name' },
    { startsWith: 'No customer name', field: 'name' }
];

export default class SelloutImportManager2 extends LightningElement {
    @api recordId; // Current Account record ID

    @track reports = [];
    @track items = [];
    @track isLoading = false;
    @track showImportModal = false;
    @track showItemsModal = false;
    @track showAccountCreationModal = false;
    @track showActivationModal = false;
    @track showResolveModal = false;
    @track isApplyingSellout = false;

    // The upload window stays open after Import and waits for the background run, then hands the
    // user straight to the line-level review. These drive that waiting screen.
    @track isAwaitingReview = false;
    @track awaitingReviewMessage = '';
    awaitingReportId = '';
    autoOpenPollTimer = null;
    autoOpenPollCount = 0;

    // Review state: the list only ever shows rows someone can act on - the new lines awaiting
    // processing and the rows that failed - loaded a page at a time so the size of the imported
    // file no longer decides how long the screen takes to open. The status filter narrows what
    // the server sends; the search narrows what is on screen; sorting reorders what is loaded.
    @track statusFilter = ACCOUNT_DECISION_FILTER;
    @track searchTerm = '';
    // What a search is waiting on while the rest of the view is still arriving, so a first result of
    // nothing is never mistaken for "this line is not in the report"
    @track searchLoadNotice = '';
    // Typing waits a moment before the rest of the view is fetched, so a search term typed one
    // character at a time triggers one load rather than one per keystroke
    searchLoadTimer = null;
    // The list is grouped by product code out of the box: identical codes sit together, so a code
    // corrected on one line is seen next to every other line carrying it. The user can still sort on
    // any other column, which simply regroups the list on that column instead.
    @track sortedBy = PRODUCT_CODE_FIELD;
    @track sortedDirection = 'asc';
    // What the last inline save did, shown beside the list instead of as a toast per edit
    @track saveFeedback = '';
    @track isLoadingMore = false;
    @track reviewTotalCount = 0;
    reviewHasMore = false;

    // Every row without an error is ticked as it arrives, so the user confirms a pre-filled list
    // instead of checking hundreds of boxes by hand
    @track selectedRowIds = [];
    @track isLoadingAll = false;

    // Bulk action state for the two views worked line by line. On the account-decision view a tick
    // stands for a customer name and the action reaches every line carrying it; on the needs-a-fix
    // view a tick stands for one line and the action writes the same correction to all of them.
    @track isBulkWorking = false;
    @track bulkFeedback = '';
    // How far a long correction has got, so a selection of thousands of lines reports its progress
    // instead of leaving the user watching a spinner
    @track bulkProgress = '';
    @track bulkRemapAccountId = '';
    @track bulkProductCode = '';
    @track bulkCustomerName = '';

    // A product-code edit is offered to the lines sharing the code that was edited, without the user
    // having to tick them first. The list is grouped by product code, so those lines are the block
    // the edited row sat in and they almost always need the same correction. The prompt opens with
    // the whole block already proposed; declining it leaves the edit on the one line.
    @track showProductSpreadModal = false;
    @track spreadNewValue = '';
    @track spreadOldValue = '';
    @track spreadSiblingIds = [];
    @track spreadAccepted = true;
    // The prompt stays open while its Apply runs, reporting what it is doing: the correction can
    // cover a block of thousands of lines, and a prompt that closed the moment Apply was pressed
    // left that work with nothing on screen to show it was happening
    @track isSpreadApplying = false;
    @track spreadProgress = '';

    // A finished report opens as a read-only result instead of an editable list, so the same sellout
    // cannot be applied twice
    @track summary = null;
    @track showSummaryModal = false;
    @track showLockedLinesModal = false;
    @track lockedItems = [];

    // Recovery is offered only when a report is genuinely stalled
    @track stuckReportIds = [];
    @track stuckReasons = {};

    // Deleting an uploaded report is a testing convenience for system administrators: the button
    // renders only once the server has said the user is one, and the delete runs in passes so a
    // report of thousands of lines is removed without tripping a transaction limit
    @track canDelete = false;
    @track showDeleteModal = false;
    // Asks before Apply Sellout sets aside the lines that still need a fix, naming the exact count
    @track showUncorrectedModal = false;
    @track deleteTarget = null;
    @track isDeleting = false;
    @track deleteProgress = '';
    deletedSoFar = 0;
    @track statusCounts = {
        Pending: 0,
        Pending_Decision: 0,
        Matched: 0,
        Invoice_Created: 0,
        Error: 0,
        Skipped: 0,
        Enforced_Skipped: 0,
        Duplicate: 0,
        // The share of the skipped rows the user set aside on the accounts step. Counted with the
        // account decisions, since those names are reviewed there.
        Skipped_Accounts: 0,
        // Rows read from the uploaded file, taken from the report itself. Survives an import that
        // stored no items, so the screen can still say how much was loaded.
        Rows_Loaded: 0
    };

    // Bulk unmatched resolution state. The same screen serves two flows: 'review' is step one of
    // the review wizard (decisions applied, invoicing waits for Apply Sellout), 'checkStatus' is
    // the recovery path where invoicing starts as soon as the decisions are in.
    @track resolveRows = [];
    @track resolveSearchTerm = '';

    // The account names narrowed by the search box on the accounts step
    get visibleResolveRows() {
        const term = (this.resolveSearchTerm || '').trim().toLowerCase();
        if (!term) {
            return this.resolveRows;
        }
        return this.resolveRows.filter(row =>
            row.customerAccountName && row.customerAccountName.toLowerCase().includes(term)
        );
    }

    get visibleResolveRowCount() {
        return this.visibleResolveRows.length;
    }

    handleResolveSearchChange(event) {
        this.resolveSearchTerm = event.target.value || '';
    }
    @track pendingDecisionCount = 0;
    @track resolveContext = 'checkStatus';
    // Active accounts of the hierarchy, offered when an unresolved name should be pointed at an
    // account that already exists ("you put Agora, but we have Agora_DM")
    @track hierarchyAccountOptions = [];

    // Import wizard state
    @track importStep = 'fileUpload'; // fileUpload, columnMapping, preview
    @track fileContent = '';
    @track fileName = '';
    @track columnHeaders = [];
    @track rawFileData = [];
    @track totalRows = 0;

    @track mappings = {
        itemDate: '',
        productCode: '',
        quantity: '',
        customerAccountName: '',
        csvDelimiter: ','
    };
    @track importStartDate = DEFAULT_START_DATE;
    @track autoAccept = false;
    @track skipDuplicates = true;
    priceMethod = 'Customer_Price_List';
    priceBookId;
    priceBookOptions = [];

    @track previewData = [];
    @track draftValues = [];

    // Current report context
    currentReportId = '';
    currentReportStatus = '';
    applyingMessage = APPLYING_MESSAGE;
    deferredWaitTimer = null;
    currentReportName = '';

    // The review modal is named after the report it shows, so a user working several uploads
    // always knows which one is open
    get itemsModalTitle() {
        return this.currentReportName
            ? 'Review Lines - ' + this.currentReportName
            : 'Review Lines';
    }

    // Account matching context
    unmatchedAccounts = [];
    currentUnmatchedIndex = 0;
    currentUnmatchedAccount = '';
    currentUnmatchedItemCount = 0;
    currentIsInactive = false;
    currentAccountId = '';

    // Item columns for the review table. Fixed starting widths keep the data columns compact so
    // the "What to do" column gets the remaining width. The value a note is about carries a flag
    // icon and red text in its own cell; the status cell is coloured for its state; the note
    // leads with an icon. All of it is the standard datatable - no custom cell types.
    itemColumns = [
        { label: 'Item', fieldName: 'Name', type: 'text', initialWidth: 110 },
        {
            label: 'Item Date', fieldName: 'SLO_Item_Date__c', type: 'date', editable: true, sortable: true, initialWidth: 140,
            typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' },
            cellAttributes: { class: { fieldName: 'dateCellClass' }, iconName: { fieldName: 'dateIcon' }, iconPosition: 'left' }
        },
        {
            label: 'Product Code (EAN)', fieldName: 'SLO_Product_Code_EAN__c', type: 'text', editable: true, sortable: true, initialWidth: 175,
            cellAttributes: { class: { fieldName: 'productCellClass' }, iconName: { fieldName: 'productIcon' }, iconPosition: 'left' }
        },
        {
            label: 'Quantity', fieldName: 'SLO_Quantity__c', type: 'number', editable: true, sortable: true, initialWidth: 115,
            cellAttributes: { class: { fieldName: 'qtyCellClass' }, iconName: { fieldName: 'qtyIcon' }, iconPosition: 'left', alignment: 'left' }
        },
        {
            label: 'Customer Account Name', fieldName: 'SLO_Customer_Account_Name__c', type: 'text', editable: true, sortable: true, initialWidth: 270,
            cellAttributes: { class: { fieldName: 'nameCellClass' }, iconName: { fieldName: 'nameIcon' }, iconPosition: 'left' }
        },
        {
            label: 'Status', fieldName: 'statusLabel', type: 'text', sortable: true, initialWidth: 160,
            cellAttributes: { class: { fieldName: 'statusCellClass' }, alignment: 'center' }
        },
        {
            label: 'What to do', fieldName: 'SLO_Processing_Notes__c', type: 'text', wrapText: true,
            cellAttributes: { class: { fieldName: 'noteClass' }, iconName: { fieldName: 'noteIcon' }, iconPosition: 'left' }
        }
    ];

    // Timer re-checking the list while a report is still importing
    processingPollTimer = null;
    processingPollCount = 0;

    connectedCallback() {
        this.loadReports();
        this.loadDeletePermission();
        this.loadAutomaticConfig();
    }

    automaticSellout = false;
    selloutMethod = null;
    isSavingConfig = false;

    get selloutMethodOptions() {
        return [{ label: 'By linked order details', value: 'By_linked_order_details' }];
    }

    get methodRequired() {
        return this.automaticSellout === true;
    }

    loadAutomaticConfig() {
        getAutomaticSelloutConfig({ accountId: this.recordId })
            .then(config => {
                this.automaticSellout = config.automaticSellout === true;
                this.selloutMethod = config.selloutMethod || null;
                return null;
            })
            .catch(error => {
                this.showToast('Error', this.errorText(error), 'error');
            });
    }

    get runNowDisabled() {
        return this.isSavingConfig || !this.automaticSellout;
    }

    handleRunAutomatedNow() {
        this.isSavingConfig = true;
        runDailySelloutNow({ accountId: this.recordId })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Automated sellout started',
                    message: 'A report will appear on this account once processing completes.',
                    variant: 'success'
                }));
            })
            .catch((error) => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not start automated sellout',
                    message: error && error.body && error.body.message ? error.body.message : 'Unexpected error',
                    variant: 'error'
                }));
            })
            .finally(() => {
                this.isSavingConfig = false;
            });
    }

    handleAutomaticToggle(event) {
        const previousEnabled = this.automaticSellout;
        const previousMethod = this.selloutMethod;
        this.automaticSellout = event.target.checked;
        if (this.automaticSellout && !this.selloutMethod) {
            this.selloutMethod = 'By_linked_order_details';
        }
        this.persistAutomaticConfig(previousEnabled, previousMethod);
    }

    handleMethodChange(event) {
        const previousEnabled = this.automaticSellout;
        const previousMethod = this.selloutMethod;
        this.selloutMethod = event.detail.value || null;
        this.persistAutomaticConfig(previousEnabled, previousMethod);
    }

    persistAutomaticConfig(previousEnabled, previousMethod) {
        this.isSavingConfig = true;
        saveAutomaticSelloutConfig({
            accountId: this.recordId,
            automaticSellout: this.automaticSellout,
            selloutMethod: this.selloutMethod
        })
            .then(config => {
                this.automaticSellout = config.automaticSellout === true;
                this.selloutMethod = config.selloutMethod || null;
                this.showToast('Success', 'Automatic sellout settings saved', 'success');
                return null;
            })
            .catch(error => {
                this.automaticSellout = previousEnabled;
                this.selloutMethod = previousMethod;
                this.showToast('Error', this.errorText(error), 'error');
            })
            .finally(() => {
                this.isSavingConfig = false;
            });
    }

    // Ask once whether the user may delete reports; anything but a clear yes keeps the button hidden
    loadDeletePermission() {
        canDeleteReports()
            .then(allowed => {
                this.canDelete = allowed === true;
                return null;
            })
            .catch(() => {
                this.canDelete = false;
            });
    }

    disconnectedCallback() {
        this.clearDeferredWaitTimer();
        this.clearProcessingPoll();
        this.clearSearchLoadTimer();
        this.clearAutoOpenPoll();
    }

    clearProcessingPoll() {
        if (this.processingPollTimer) {
            clearTimeout(this.processingPollTimer);
            this.processingPollTimer = null;
        }
    }

    // While any report is still importing, quietly refresh the list every few seconds so its row
    // flips to Draft on its own; the poll stops as soon as nothing is processing
    scheduleProcessingPoll() {
        this.clearProcessingPoll();

        const stillProcessing = (this.reports || []).some(report => report.isProcessing);
        if (!stillProcessing) {
            this.processingPollCount = 0;
            return;
        }
        if (this.processingPollCount >= MAX_PROCESSING_POLLS) {
            return;
        }

        this.processingPollCount++;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.processingPollTimer = setTimeout(() => {
            this.processingPollTimer = null;
            this.loadReports(true);
        }, PROCESSING_POLL_MS);
    }

    // Computed properties
    get hasReports() {
        return this.reports && this.reports.length > 0;
    }

    get isStepFileUpload() {
        return this.importStep === 'fileUpload' && !this.isAwaitingReview;
    }

    get isStepColumnMapping() {
        return this.importStep === 'columnMapping' && !this.isAwaitingReview;
    }

    get isStepPreview() {
        return this.importStep === 'preview' && !this.isAwaitingReview;
    }

    get columnOptions() {
        return this.columnHeaders.map(header => ({
            label: header,
            value: header
        }));
    }

    get delimiterOptions() {
        return [
            { label: 'Comma (,)', value: ',' },
            { label: 'Semicolon (;)', value: ';' },
            { label: 'Tab', value: '\\t' }
        ];
    }

    get isMappingIncomplete() {
        return !this.mappings.itemDate ||
               !this.mappings.productCode ||
               !this.mappings.quantity ||
               !this.mappings.customerAccountName;
    }

    // A completed report opens as a read-only summary, so Apply Sellout is only ever offered on a
    // report that has not been applied yet
    get canApplySellout() {
        return this.currentReportStatus === 'Draft' ||
               this.currentReportStatus === 'Error';
    }

    get readyCount() {
        return this.statusCounts.Pending + this.statusCounts.Matched;
    }

    get errorCount() {
        return this.statusCounts.Error;
    }

    // Rows already recorded, whether they were stored as skipped items or - on a report imported
    // before duplicates were kept - simply left out of the report altogether
    get skippedCount() {
        return this.statusCounts.Skipped + this.unstoredRowCount;
    }

    // Rows that were stored against the report and can be listed
    get storedItemCount() {
        return this.statusCounts.Pending +
            this.statusCounts.Pending_Decision +
            this.statusCounts.Matched +
            this.statusCounts.Invoice_Created +
            this.statusCounts.Error +
            this.statusCounts.Skipped +
            this.statusCounts.Enforced_Skipped +
            this.statusCounts.Duplicate;
    }

    // Rows the file contained that produced no item - discarded duplicates on an older import
    get unstoredRowCount() {
        const missing = this.statusCounts.Rows_Loaded - this.storedItemCount;
        return missing > 0 ? missing : 0;
    }

    // Every row loaded from the file, whether it needs action or not
    get totalItemCount() {
        return Math.max(this.statusCounts.Rows_Loaded, this.storedItemCount);
    }

    // Rows that were not already recorded - what the file actually contributed
    get newItemCount() {
        return this.totalItemCount - this.skippedCount;
    }

    // Nothing to act on. Distinguished from "nothing imported" so the user is told which it is.
    get showEmptyState() {
        return !this.isApplyingSellout && this.loadedCount === 0;
    }

    get showItemTable() {
        return !this.isApplyingSellout && this.loadedCount > 0;
    }

    get emptyListMessage() {
        if (this.totalItemCount === 0) {
            return 'No items were imported for this report.';
        }
        if (this.isAccountDecisionView) {
            return 'No lines on this report need an account decision.';
        }
        if (this.isNeedsFixView) {
            return 'No lines on this report have a data error to fix.';
        }
        if (this.isReadyView && this.outstandingCount > 0) {
            return 'No lines are ready yet - there is still work outstanding in the other views.';
        }
        if (this.isReadyView) {
            return 'No lines on this report are ready to invoice.';
        }
        if (this.skippedCount === this.totalItemCount) {
            return 'All ' + this.skippedCount + ' row(s) loaded from this file were already ' +
                'recorded, so there is nothing new to invoice.';
        }
        return 'Every item in this report has already been processed - there is nothing left to act on.';
    }

    // Work still outstanding: the account decisions plus the lines needing a fix. Ready lines are
    // deliberately excluded - they need nothing, so counting them here would overstate the work.
    get outstandingCount() {
        return this.accountDecisionCount + this.statusCounts.Error;
    }

    // The three views, with the live count beside each so the user knows exactly what each holds
    get statusFilterOptions() {
        return [
            // Every account decision - the names still to decide and the ones already set aside
            {
                label: `Account decision (${this.accountDecisionCount})`,
                value: ACCOUNT_DECISION_FILTER
            },
            // Technical data errors only
            { label: `Needs a fix (${this.statusCounts.Error})`, value: NEEDS_FIX_FILTER },
            ...(this.statusCounts.Duplicate > 0
                ? [{ label: `Duplicates (${this.statusCounts.Duplicate})`, value: DUPLICATES_FILTER }]
                : []),
            // Valid lines with nothing outstanding
            { label: `Ready (${this.readyCount})`, value: READY_FILTER }
        ];
    }

    // The view a report opens on: the first of the three that actually holds a line, so the screen
    // lands on the work waiting rather than on an empty list
    get defaultStatusFilter() {
        const heldBy = {
            [ACCOUNT_DECISION_FILTER]: this.accountDecisionCount,
            [NEEDS_FIX_FILTER]: this.statusCounts.Error,
            [DUPLICATES_FILTER]: this.statusCounts.Duplicate,
            [READY_FILTER]: this.readyCount
        };
        return VIEW_PRIORITY.find(view => heldBy[view] > 0) || ACCOUNT_DECISION_FILTER;
    }

    get isNeedsFixView() {
        return this.statusFilter === NEEDS_FIX_FILTER;
    }

    get isDuplicatesView() {
        return this.statusFilter === DUPLICATES_FILTER;
    }

    get showDuplicatesBar() {
        return this.showItemTable && this.isDuplicatesView;
    }

    get isEnforceSkipDuplicatesDisabled() {
        return this.isBulkWorking || this.statusCounts.Duplicate === 0;
    }

    // Mark every duplicate on the report as Enforced Skipped, in bounded server passes
    handleEnforceSkipDuplicates() {
        this.isBulkWorking = true;
        const sweep = () => enforceSkipDuplicates({ reportId: this.currentReportId })
            .then(count => (count > 0 ? sweep().then(next => count + next) : 0));
        sweep()
            .then(total => {
                this.bulkFeedback = `${total} duplicate line(s) set aside as Enforced Skipped.`;
                return this.refreshStatusCounts();
            })
            .then(() => {
                this.statusFilter = this.defaultStatusFilter;
                return this.loadItems();
            })
            .catch(error => {
                this.showToast('Could not skip the duplicates', this.errorText(error), 'error');
            })
            .finally(() => {
                this.isBulkWorking = false;
            });
    }

    // One line saying what the open view is for, so its count is read correctly: two of the views
    // are work to do, and the third is work already finished
    get viewPurposeMessage() {
        if (this.isAccountDecisionView) {
            return 'Lines whose customer still needs an account decision, plus the customers you ' +
                'have already left out - tick any line to decide for that customer.';
        }
        if (this.isNeedsFixView) {
            return 'Lines with a data error to correct - an unrecognised product code, or a ' +
                'quantity that contradicts a line already recorded.';
        }
        if (this.isDuplicatesView) {
            return 'Lines identical to a line already recorded. Edit a line to process it, or ' +
                'use Enforce Skip to set them all aside.';
        }
        return 'Valid lines with nothing outstanding - these are the lines Apply Sellout will ' +
            'invoice. Untick any line you want left out.';
    }

    get isReadyView() {
        return this.statusFilter === READY_FILTER;
    }

    // Whether a line of this status belongs in the view now open. Each view owns one kind of work,
    // so an edit that changes a line's kind moves it out of the current view and into the one that
    // owns it - its count there goes up, and the user finds it where its label says it will be.
    // The account-decision view also keeps the set-aside names, which are its own decisions taken.
    statusBelongsToCurrentView(status) {
        if (this.isAccountDecisionView) {
            return status === 'Pending_Decision' || status === 'Skipped';
        }
        if (this.isNeedsFixView) {
            return status === 'Error';
        }
        if (this.isDuplicatesView) {
            return status === 'Duplicate';
        }
        if (this.isReadyView) {
            return status === 'Pending' || status === 'Matched';
        }
        return false;
    }

    // Names awaiting a decision plus the ones already left out, which this view also lists
    get accountDecisionCount() {
        return this.statusCounts.Pending_Decision + this.statusCounts.Skipped_Accounts;
    }

    // The account-decision view mixes rows to work on with decisions already taken, so it explains
    // that the set-aside names are there for review rather than for editing
    get isAccountDecisionView() {
        return this.statusFilter === ACCOUNT_DECISION_FILTER;
    }

    get hasSetAsideAccounts() {
        return this.statusCounts.Skipped_Accounts > 0;
    }

    // Shown only on the account-decision view, where those names are listed
    get showSetAsideNotice() {
        return this.isAccountDecisionView && this.hasSetAsideAccounts;
    }

    // The rows narrowed by the search box - customer, product code, item number or note. Entering a
    // term also pulls the rest of the view in from the server, so the search covers every line in
    // the view rather than only the page on screen; the filtering itself stays on the client.
    get visibleItems() {
        const term = (this.searchTerm || '').trim().toLowerCase();
        if (!term) {
            return this.items;
        }
        return this.items.filter(item =>
            [
                item.SLO_Customer_Account_Name__c,
                item.SLO_Product_Code_EAN__c,
                item.Name,
                item.SLO_Processing_Notes__c
            ].some(value => value && String(value).toLowerCase().includes(term))
        );
    }

    get visibleCount() {
        return this.visibleItems.length;
    }

    get hasSearchTerm() {
        return (this.searchTerm || '').trim().length > 0;
    }

    get loadedCount() {
        return this.items ? this.items.length : 0;
    }

    get hasMoreToLoad() {
        return this.reviewHasMore;
    }

    get selectedCount() {
        return this.selectedRowIds ? this.selectedRowIds.length : 0;
    }

    // On the account-decision view a tick stands for a customer, so the count is read in names and
    // in the lines those names cover; elsewhere a tick stands for one line
    get selectionLabel() {
        if (this.isAccountDecisionView) {
            return this.selectedCustomerNameCount + ' customer name(s) selected, covering ' +
                this.selectedCount + ' of ' + this.loadedCount + ' loaded line(s)';
        }
        return this.selectedCount + ' of ' + this.loadedCount + ' loaded item(s) selected';
    }

    get isLoadAllDisabled() {
        return this.isLoadingAll || !this.reviewHasMore;
    }

    get loadAllLabel() {
        return this.isLoadingAll ? 'Loading all items...' : 'Load All Items';
    }

    // Summary getters, so the completed view is plain reading rather than a table of statuses
    get hasSummary() {
        return this.summary !== null && this.summary !== undefined;
    }

    // Start fetching the next page a few rows before the user reaches the bottom
    get loadMoreOffset() {
        return 10;
    }

    // Tells the user they are looking at part of a longer list, so a page of 50 is never mistaken
    // for the whole set
    get reviewRangeLabel() {
        if (this.reviewTotalCount === 0) {
            return 'No lines in this view';
        }
        let label = 'Loaded ' + this.loadedCount + ' of ' + this.reviewTotalCount + ' line(s) in this view';
        if (this.hasSearchTerm) {
            label += ' - ' + this.visibleCount + ' match "' + this.searchTerm.trim() + '"';
        }
        return label;
    }

    // Rows deliberately left off the list, so a count that does not match the list is explained
    get noActionCount() {
        return this.skippedCount + this.statusCounts.Invoice_Created;
    }

    get hasNoActionItems() {
        return this.noActionCount > 0;
    }

    // Spells out why those rows are not listed, naming only the reasons that actually apply
    get noActionMessage() {
        const reasons = [];
        const setAside = this.statusCounts.Skipped_Accounts;
        const otherSkipped = this.skippedCount - setAside;
        if (otherSkipped > 0) {
            reasons.push(otherSkipped +
                ' skipped as duplicates of lines already recorded or as lines needing a fix');
        }
        if (setAside > 0) {
            reasons.push(setAside +
                ' set aside on the accounts step, listed on the "Account decision" view above, ' +
                'where the decision can still be changed');
        }
        if (this.statusCounts.Invoice_Created > 0) {
            reasons.push(this.statusCounts.Invoice_Created + ' already invoiced');
        }
        return this.noActionCount + ' item(s) need no action and are not listed: ' +
            reasons.join('; ') + '.';
    }

    // Offered whenever the report holds at least one Ready line, whatever view is open and whatever
    // is ticked - a user looking at the account decisions or the skipped names should not find the
    // button locked when there is work to apply
    get isApplySelloutDisabled() {
        return !this.canApplySellout || this.isApplyingSellout || !this.hasApplicableLines;
    }

    // Ready lines are what Apply Sellout invoices; rows never matched still need a matching run
    get hasApplicableLines() {
        return this.statusCounts.Matched > 0 || this.statusCounts.Pending > 0;
    }

    get applySelloutLabel() {
        return this.isApplyingSellout ? 'Processing...' : 'Apply Sellout';
    }

    get previewRowCount() {
        return this.previewData ? this.previewData.length : 0;
    }

    // Taken from the report-wide counts rather than the loaded page, so the banner is right even
    // when the failing rows sit further down the list
    get hasErrorItems() {
        return this.statusCounts.Error > 0;
    }

    get hasResolveRows() {
        return this.resolveRows && this.resolveRows.length > 0;
    }

    get resolveRowCount() {
        return this.resolveRows ? this.resolveRows.length : 0;
    }

    get errorItemCount() {
        return this.statusCounts.Error;
    }

    // Load sellout reports. A silent load (used by the processing poll) skips the spinner so the
    // screen does not flash every few seconds.
    loadReports(silent) {
        if (!silent) {
            this.isLoading = true;
        }
        return getSelloutReports({ accountId: this.recordId })
            .then(result => {
                this.reports = (result || []).map(report => this.decorateReport(report));
                this.isLoading = false;
                this.scheduleProcessingPoll();
                // Checked afterwards so the list paints immediately and the recovery button simply
                // appears on the rows that turn out to need it
                this.detectStuckReports();
                return null;
            })
            .catch(error => {
                if (!silent) {
                    this.showToast('Error', 'Error loading reports: ' + this.errorText(error), 'error');
                }
                this.isLoading = false;
            });
    }

    // Add the display fields the report table needs, including whether recovery is on offer and
    // whether the report is still being imported in the background
    decorateReport(report) {
        // New is the import itself; In Process is any later background run (matching, decisions,
        // invoicing). Either way the rows are still changing, so the report cannot be opened.
        const isProcessing = report.SLO_Status__c === 'New' || report.SLO_Status__c === 'In_Process';
        const pillByStatus = {
            Completed: 'slds-badge slds-theme_success',
            Error: 'slds-badge slds-theme_error',
            Draft: 'slds-badge slds-theme_warning',
            New: 'slds-badge slds-badge_lightest',
            In_Process: 'slds-badge slds-badge_lightest'
        };
        const displayByStatus = { New: 'Importing…', In_Process: 'In Process', Draft: 'Ready for review' };
        return {
            ...report,
            formattedImportDate: report.SLO_Import_Date__c
                ? new Date(report.SLO_Import_Date__c).toLocaleString()
                : '',
            isProcessing: isProcessing,
            showError: report.SLO_Status__c === 'Error' && !!report.SLO_Error_Message__c,
            displayStatus: displayByStatus[report.SLO_Status__c] || report.SLO_Status__c,
            statusPillClass: pillByStatus[report.SLO_Status__c] || 'slds-badge',
            actionTitle: isProcessing
                ? 'Available once the background run finishes'
                : 'Open this report for review',
            isStuck: this.stuckReportIds.includes(report.Id),
            stuckReason: this.stuckReasons[report.Id] || ''
        };
    }

    // Ask only about the reports whose status could hide a stalled run. Draft is the normal
    // waiting-for-review state, so those rows never need a recovery button.
    detectStuckReports() {
        const candidates = this.reports
            .filter(report => report.SLO_Status__c !== 'Draft')
            .slice(0, STUCK_CHECK_LIMIT);

        if (candidates.length === 0) {
            return;
        }

        Promise.all(
            candidates.map(report =>
                getReportStatus({ reportId: report.Id })
                    .then(status => ({ id: report.Id, status: status }))
                    .catch(() => null)
            )
        ).then(results => {
            const stuckIds = [];
            const reasons = {};
            results.forEach(entry => {
                if (entry && entry.status && entry.status.isStuck) {
                    stuckIds.push(entry.id);
                    reasons[entry.id] = entry.status.stuckReason || '';
                }
            });
            this.stuckReportIds = stuckIds;
            this.stuckReasons = reasons;
            this.reports = this.reports.map(report => this.decorateReport(report));
            return null;
        });
    }

    // Handle import button click
    handleImportClick() {
        this.clearAutoOpenPoll();
        this.isAwaitingReview = false;
        this.awaitingReportId = '';
        this.awaitingReviewMessage = '';
        this.showImportModal = true;
        this.importStep = 'fileUpload';
        this.resetImportWizard();
        this.loadImportPreferences();
    }

    // Pre-fill the start date and delimiter from the user's saved preferences (falling back to the
    // profile or org default). Runs before a file is chosen, so the first parse already uses that
    // delimiter. A delimiter saved in this account's column mapping still overrides it afterwards,
    // in loadSavedMapping.
    loadImportPreferences() {
        return getImportPreferences()
            .then(prefs => {
                if (prefs) {
                    this.importStartDate = prefs.startDate || DEFAULT_START_DATE;
                    this.delimiterSource = prefs.delimiterSource || '';
                    // This response can arrive after a file was chosen and the saved mapping set its
                    // delimiter (reparseWithDelimiter); only apply the preference while no file is
                    // loaded, so it never overwrites that delimiter.
                    if (!this.fileContent) {
                        this.mappings = { ...this.mappings, csvDelimiter: prefs.csvDelimiter || ',' };
                    }
                }
                return null;
            })
            .catch(() => null);
    }

    delimiterSource = '';
    savedMappingCache = null;

    get delimiterHelpText() {
        if (this.delimiterSource === 'COUNTRY') {
            return 'Defaulted from your country setting. Change this if your columns appear merged.';
        }
        if (this.delimiterSource === 'USER') {
            return 'Defaulted from your saved preference. Change this if your columns appear merged.';
        }
        return 'European CSV files often use semicolon (;) instead of comma. Change this if your columns appear merged.';
    }

    handleStartDateChange(event) {
        this.importStartDate = event.detail.value;
    }

    handleAutoAcceptChange(event) {
        this.autoAccept = event.target.checked;
    }

    handleSkipDuplicatesChange(event) {
        this.skipDuplicates = event.target.checked;
    }

    get priceMethodOptions() {
        return [
            { label: 'Customer Price List', value: 'Customer_Price_List' },
            { label: 'Last Item Price', value: 'Last_Item_Price' },
            { label: 'Dedicated Price Book', value: 'Dedicated_Price_Book' }
        ];
    }

    get isDedicatedPriceBook() {
        return this.priceMethod === 'Dedicated_Price_Book';
    }

    handlePriceMethodChange(event) {
        this.priceMethod = event.detail.value;
        if (this.isDedicatedPriceBook && this.priceBookOptions.length === 0) {
            getCountryPriceBookOptions({ accountId: this.recordId })
                .then(result => {
                    this.priceBookOptions = result || [];
                })
                .catch(error => {
                    console.error('Error loading price books:', error);
                });
        }
    }

    handlePriceBookChange(event) {
        this.priceBookId = event.detail.value;
    }

    get hasNoPriceBookOptions() {
        return this.priceBookOptions.length === 0;
    }

    // Remember the start date and delimiter for this user's next import. A failure must not
    // interrupt the import that has just started.
    saveUserPreferences() {
        saveImportPreferences({
            startDate: this.importStartDate || null,
            csvDelimiter: this.mappings.csvDelimiter
        }).catch(error => {
            console.error('Error saving import preferences:', error);
        });
    }

    // Handle file upload
    handleFileUpload(event) {
        const files = event.target.files;
        if (files && files.length > 0) {
            const file = files[0];
            this.fileName = file.name;

            // Validate file extension - only allow CSV files
            const fileExtension = this.fileName.toLowerCase().split('.').pop();
            if (fileExtension !== 'csv') {
                this.showToast(
                    'Error',
                    'Only CSV files are supported. Please export your Excel file as CSV before uploading.',
                    'error'
                );
                // Reset the file input
                event.target.value = '';
                return;
            }

            // Read file content
            const reader = new FileReader();
            reader.onload = () => {
                const base64 = reader.result.split(',')[1];
                this.fileContent = base64;
                this.parseUploadedFile();
            };
            reader.onerror = () => {
                this.showToast('Error', 'Failed to read file', 'error');
                this.isLoading = false;
            };
            reader.readAsDataURL(file);
        }
    }

    // Parse uploaded file
    parseUploadedFile() {
        this.isLoading = true;
        parseFile({
            fileContent: this.fileContent,
            fileName: this.fileName,
            parseAllRows: false,
            csvDelimiter: this.mappings.csvDelimiter
        })
            .then(result => {
                if (result.errorMessage) {
                    this.showToast('Error', result.errorMessage, 'error');
                    this.isLoading = false;
                    return;
                }

                this.columnHeaders = result.columnHeaders;
                this.rawFileData = result.previewRows;
                this.totalRows = result.totalRows;

                // The saved mapping is applied before the step renders, so nothing can change
                // under the user's hands once they start choosing columns
                return this.loadSavedMapping().then(() => {
                    this.importStep = 'columnMapping';
                    this.isLoading = false;
                    return null;
                });
            })
            .catch(error => {
                this.showToast('Error', 'Error parsing file: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // Load the column mapping saved for this account and pre-fill the fields the user has not
    // chosen yet. A saved column name is only used when this file has that exact header, and a
    // choice the user already made is never overwritten. If the saved delimiter differs from the
    // one the file was just parsed with, the file is parsed again so the headers are real.
    loadSavedMapping() {
        return this.fetchSavedMapping().then(() => {
            this.applySavedMapping(true);
            return null;
        });
    }

    normalizeHeader(value) {
        let text = String(value || '');
        if (text.charCodeAt(0) === 65279) {
            text = text.substring(1);
        }
        return text
            .replace(/["']/g, '')
            .replace(/\s+/g, ' ')
            .trim()
            .toLowerCase();
    }

    // The saved mapping is fetched once and kept so later re-parses can re-apply it
    fetchSavedMapping() {
        if (this.savedMappingCache) {
            return Promise.resolve(this.savedMappingCache);
        }
        return getSavedColumnMapping({ accountId: this.recordId })
            .then(mappingJson => {
                if (!mappingJson) {
                    return null;
                }
                try {
                    this.savedMappingCache = JSON.parse(mappingJson);
                } catch (e) {
                    console.error('Error parsing saved mapping:', e);
                    return null;
                }
                return this.savedMappingCache;
            })
            .catch(error => {
                console.error('Error loading saved mapping:', error);
                return null;
            });
    }

    // Fills only unset fields; a choice already made is never overwritten
    applySavedMapping(notify) {
        const saved = this.savedMappingCache;
        if (!saved) {
            return;
        }
        const applied = [];
        const missing = [];
        ['itemDate', 'productCode', 'quantity', 'customerAccountName'].forEach(field => {
            const savedColumn = saved[field];
            if (!savedColumn || this.mappings[field]) {
                return;
            }
            const target = this.normalizeHeader(savedColumn);
            const match = (this.columnHeaders || []).find(h => this.normalizeHeader(h) === target);
            if (match !== undefined) {
                this.mappings[field] = match;
                applied.push(match);
            } else {
                missing.push(savedColumn);
            }
        });
        if (notify && applied.length > 0) {
            this.showToast(
                'Previous column mapping loaded',
                'Pre-filled from your last import: ' + applied.join(', ') + '. Check each field before continuing.',
                'info'
            );
        }
        if (notify && missing.length > 0) {
            this.showToast(
                'Saved columns not found',
                'These saved columns are not in this file: ' + missing.join(', '),
                'warning'
            );
        }
    }

    // Parse the uploaded file again with another delimiter and reset the column choices, since
    // the headers may have changed completely
    reparseWithDelimiter(delimiter) {
        this.mappings.csvDelimiter = delimiter;
        return parseFile({
            fileContent: this.fileContent,
            fileName: this.fileName,
            parseAllRows: false,
            csvDelimiter: delimiter
        }).then(result => {
            if (result.errorMessage) {
                throw new Error(result.errorMessage);
            }
            this.columnHeaders = result.columnHeaders;
            this.rawFileData = result.previewRows;
            this.totalRows = result.totalRows;
            this.mappings.itemDate = '';
            this.mappings.productCode = '';
            this.mappings.quantity = '';
            this.mappings.customerAccountName = '';
            return this.fetchSavedMapping();
        }).then(() => {
            this.applySavedMapping(true);
            return null;
        });
    }

    // Handle column mapping change
    handleMappingChange(event) {
        const field = event.target.dataset.field;
        this.mappings[field] = event.detail.value;
    }

    // Handle delimiter change - re-parse file with new delimiter
    handleDelimiterChange(event) {
        this.isLoading = true;
        this.reparseWithDelimiter(event.detail.value)
            .then(() => {
                this.showToast('Success', 'File re-parsed with new delimiter', 'success');
                this.isLoading = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error re-parsing file: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // What each field will be read from, restated on the preview so a wrong column is caught
    // before thousands of rows are imported with it
    get mappingSummary() {
        return [
            { key: 'itemDate', label: 'Item Date', column: this.mappings.itemDate },
            { key: 'productCode', label: 'Product Code (EAN)', column: this.mappings.productCode },
            { key: 'quantity', label: 'Quantity', column: this.mappings.quantity },
            { key: 'customerAccountName', label: 'Customer Account Name', column: this.mappings.customerAccountName }
        ];
    }

    get previewDistinctDates() {
        return new Set((this.previewData || []).map(row => row.itemDate)).size;
    }

    get previewDistinctCustomers() {
        return new Set((this.previewData || []).map(row => row.customerAccountName)).size;
    }

    get previewDistinctProducts() {
        return new Set((this.previewData || []).map(row => row.productCode)).size;
    }

    // Every preview row carrying one and the same date is the signature of a file-date column
    // mapped in place of the sales date - and thousands of rows would collapse onto that one day
    get previewDateWarning() {
        const rowCount = this.previewData ? this.previewData.length : 0;
        if (rowCount < 5 || this.previewDistinctDates !== 1) {
            return '';
        }
        return `All ${rowCount} preview rows carry the same Item Date (${this.previewData[0].itemDate}). ` +
            'If this file spans several sales dates, go back and map Item Date to the sales-period ' +
            'column rather than the file date.';
    }

    // Handle next to preview
    handleNextToPreview() {
        if (this.isMappingIncomplete) {
            this.showToast('Error', 'Please map all required columns', 'error');
            return;
        }

        // Build preview data
        const itemDateIndex = this.columnHeaders.indexOf(this.mappings.itemDate);
        const productCodeIndex = this.columnHeaders.indexOf(this.mappings.productCode);
        const quantityIndex = this.columnHeaders.indexOf(this.mappings.quantity);
        const customerAccountIndex = this.columnHeaders.indexOf(this.mappings.customerAccountName);

        this.previewData = this.rawFileData.map((row, index) => ({
            id: index,
            itemDate: row[itemDateIndex] || '',
            productCode: row[productCodeIndex] || '',
            quantity: row[quantityIndex] || '0',
            customerAccountName: row[customerAccountIndex] || ''
        }));

        this.importStep = 'preview';
    }

    // Handle back to mapping
    handleBackToMapping() {
        this.importStep = 'columnMapping';
    }

    // Handle cancel import
    handleCancelImport() {
        this.clearAutoOpenPoll();
        this.isAwaitingReview = false;
        this.awaitingReportId = '';
        this.awaitingReviewMessage = '';
        this.showImportModal = false;
        this.resetImportWizard();
    }

    // Handle confirm import - every file, whatever its size, goes through the same background
    // import-then-match run so it ends up in Draft for review
    handleConfirmImport() {
        this.startBackgroundImport();
    }

    // Store the CSV and hand the import to the batch job, then close the modal right away
    startBackgroundImport() {
        this.isLoading = true;

        saveCsvFile({ fileName: this.fileName, base64Content: this.fileContent })
            .then(contentVersionId => {
                const config = {
                    itemDateIndex: this.columnHeaders.indexOf(this.mappings.itemDate),
                    productCodeIndex: this.columnHeaders.indexOf(this.mappings.productCode),
                    quantityIndex: this.columnHeaders.indexOf(this.mappings.quantity),
                    customerAccountIndex: this.columnHeaders.indexOf(this.mappings.customerAccountName),
                    csvDelimiter: this.mappings.csvDelimiter,
                    startDate: this.importStartDate || null,
                    autoAccept: this.autoAccept === true,
                    skipDuplicates: this.skipDuplicates !== false,
                    priceMethod: this.priceMethod,
                    priceBookId: this.isDedicatedPriceBook ? this.priceBookId : null
                };

                const today = new Date().toISOString().split('T')[0];
                return startAsyncImport({
                    accountId: this.recordId,
                    reportDate: today,
                    contentVersionId: contentVersionId,
                    config: config
                });
            })
            .then(result => {
                if (!result.success) {
                    this.showToast('Error', result.errorMessage, 'error');
                    this.isLoading = false;
                    return;
                }

                this.saveMappingToAccount();
                this.saveUserPreferences();
                // The background run creates the accounts, skips the lines needing a fix and applies
                // the sellout, then emails the summary
                if (this.autoAccept) {
                    this.showToast(
                        'Auto Accept running',
                        'Accounts will be created, lines needing a fix skipped and the sellout applied ' +
                            'in the background. You will receive an email when it finishes.',
                        'success'
                    );
                } else {
                    this.showToast(
                        'Import loading',
                        'The import is loading in the background. The report will be ready for review ' +
                            'as a Draft once it finishes.',
                        'success'
                    );
                }
                this.showImportModal = false;
                this.resetImportWizard();
                this.processingPollCount = 0;
                this.loadReports(true);
                this.isLoading = false;
            })
            .catch(error => {
                this.showToast('Error', 'Error starting import: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // Keep the upload window open on a waiting screen tied to the report just created, and start
    // asking whether its background run has finished
    beginAwaitingReview(reportId) {
        if (!reportId) {
            // Without a report to follow there is nothing to open, so fall back to the old
            // behaviour of closing the window and leaving the list to refresh itself
            this.showImportModal = false;
            this.resetImportWizard();
            return;
        }

        this.awaitingReportId = reportId;
        this.autoOpenPollCount = 0;
        this.awaitingReviewMessage =
            `Importing and checking ${this.totalRows} row(s). You will be taken to the lines automatically.`;
        this.isAwaitingReview = true;
        this.scheduleAutoOpenPoll();
    }

    clearAutoOpenPoll() {
        if (this.autoOpenPollTimer) {
            clearTimeout(this.autoOpenPollTimer);
            this.autoOpenPollTimer = null;
        }
    }

    scheduleAutoOpenPoll() {
        this.clearAutoOpenPoll();

        if (!this.isAwaitingReview || !this.awaitingReportId) {
            return;
        }
        if (this.autoOpenPollCount >= MAX_AUTO_OPEN_POLLS) {
            // Stop waiting rather than spin forever: the report stays in the list and can be
            // opened by hand once it finishes
            this.isAwaitingReview = false;
            this.awaitingReportId = '';
            this.showImportModal = false;
            this.resetImportWizard();
            this.showToast(
                'Still importing',
                'The import is taking longer than usual. Its row will change to Ready for review ' +
                    'in the list, and you can open it from there.',
                'info'
            );
            this.loadReports(true);
            return;
        }

        this.autoOpenPollCount++;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.autoOpenPollTimer = setTimeout(() => {
            this.autoOpenPollTimer = null;
            this.checkAwaitingReport();
        }, AUTO_OPEN_POLL_MS);
    }

    // Ask where the new report has got to. Only a report that has left the importing state is
    // worth opening - anything earlier would show a half-loaded list.
    checkAwaitingReport() {
        const reportId = this.awaitingReportId;
        if (!this.isAwaitingReview || !reportId) {
            return;
        }

        getReportStatus({ reportId: reportId })
            .then(status => {
                if (!this.isAwaitingReview || this.awaitingReportId !== reportId) {
                    return null;
                }

                const reportStatus = status ? status.status : '';
                if (reportStatus === 'In_Process' && status.isStuck) {
                    this.stopWaitingForStuckRun();
                    return null;
                }
                if (reportStatus === 'New' || reportStatus === 'In_Process' || !reportStatus) {
                    const imported = status && status.totalItems ? status.totalItems : 0;
                    if (reportStatus === 'In_Process') {
                        this.awaitingReviewMessage =
                            `Checking accounts for ${imported} row(s). You will be taken to the lines automatically.`;
                    } else {
                        this.awaitingReviewMessage = imported
                            ? `Imported ${imported} of ${this.totalRows} row(s) so far. You will be taken to the lines automatically.`
                            : `Importing and checking ${this.totalRows} row(s). You will be taken to the lines automatically.`;
                    }
                    this.scheduleAutoOpenPoll();
                    return null;
                }

                if (reportStatus === 'Error') {
                    this.isAwaitingReview = false;
                    this.awaitingReportId = '';
                    this.showImportModal = false;
                    this.resetImportWizard();
                    this.showToast(
                        'Import failed',
                        status && status.errorMessage
                            ? status.errorMessage
                            : 'The import could not be completed. Check the report row for details.',
                        'error'
                    );
                    this.loadReports(true);
                    return null;
                }

                return this.openReviewForAwaitingReport(reportStatus);
            })
            .catch(() => {
                // A single failed check is not a reason to abandon the wait - ask again
                if (this.isAwaitingReview && this.awaitingReportId === reportId) {
                    this.scheduleAutoOpenPoll();
                }
            });
    }

    // The background run behind the report has died, so waiting longer will not help. Stop and
    // point the user at Check Status on the report row.
    stopWaitingForStuckRun() {
        this.clearAutoOpenPoll();
        this.isAwaitingReview = false;
        this.awaitingReportId = '';
        this.awaitingReviewMessage = '';
        this.showImportModal = false;
        this.resetImportWizard();
        this.loadReports(true);
        this.showStuckRunToast();
    }

    showStuckRunToast() {
        this.showToast(
            'Run stopped',
            'The background run stopped before it finished. Press Check Status on the report row ' +
                'to release it.',
            'info'
        );
    }

    // Hand the user straight to the row-level review of the report just imported. The upload
    // window closes only at this point, as the review screen takes its place.
    openReviewForAwaitingReport(reportStatus) {
        const reportId = this.awaitingReportId;

        this.isAwaitingReview = false;
        this.awaitingReportId = '';
        this.awaitingReviewMessage = '';
        this.showImportModal = false;
        this.resetImportWizard();

        // The refreshed list is what carries the report's name, and it also clears its own
        // spinner - so the review screen opens only once it has landed, otherwise the handover
        // would show an untitled screen and have its spinner switched off underneath it
        return Promise.resolve(this.loadReports(true))
            .catch(() => null)
            .then(() => {
                const matching = (this.reports || []).find(report => report.Id === reportId);
                this.openReportForReview(reportId, reportStatus, matching ? matching.Name : '');
                return null;
            });
    }

    // Leave the waiting screen without opening the lines. The import keeps running in the
    // background, so the report still appears in the list when it finishes.
    handleKeepImportingInBackground() {
        this.clearAutoOpenPoll();
        this.isAwaitingReview = false;
        this.awaitingReportId = '';
        this.awaitingReviewMessage = '';
        this.showImportModal = false;
        this.resetImportWizard();
        this.processingPollCount = 0;
        this.loadReports();
    }

    // Handle view items. A finished report opens as a read-only result. A report still in review
    // opens as a two-step wizard: first confirm the customer names that need a decision - each
    // decision covers every line carrying that name - then work the line list.
    handleViewItems(event) {
        this.openReportForReview(
            event.target.dataset.reportId,
            event.target.dataset.reportStatus,
            event.target.dataset.reportName
        );
    }

    // Open a report at the right screen for its state. Used both by the row's own action and by
    // the automatic hand-off from the upload wizard, so a report opens the same way either way.
    openReportForReview(reportId, reportStatus, reportName) {
        this.currentReportId = reportId;
        this.currentReportStatus = reportStatus;
        this.currentReportName = reportName || '';

        // A report still being imported or processed has rows that are still changing, so any review
        // opened now would show a picture that shifts on the next click
        if (this.currentReportStatus === 'New' || this.currentReportStatus === 'In_Process') {
            this.showToast(
                'Still processing',
                'This report is still being processed in the background. Its row will change to ' +
                    'Ready for review when it can be opened.',
                'info'
            );
            return;
        }

        // An Auto Accepted report is locked whatever its status, so it opens as the read-only result
        const openedReport = (this.reports || []).find(report => report.Id === reportId);
        const lockedByAutoAccept = openedReport && openedReport.SLO_Auto_Accepted__c === true;
        if (this.currentReportStatus === 'Completed' || lockedByAutoAccept) {
            this.loadSummary();
            return;
        }

        this.isLoading = true;
        getUnmatchedAccounts({ reportId: this.currentReportId })
            .then(unmatched => {
                if (unmatched && unmatched.length > 0) {
                    return this.openAccountsStep(unmatched);
                }
                return this.loadItems(true);
            })
            .catch(error => {
                this.showToast('Error', 'Error opening the report: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // Step one of the review wizard: the distinct customer names awaiting a decision, with the
    // hierarchy's accounts on hand so a misspelt name can be pointed at the right account
    openAccountsStep(unmatched) {
        return getHierarchyAccountOptions({ accountId: this.recordId })
            .then(options => {
                this.hierarchyAccountOptions = options || [];
                this.resolveRows = this.buildResolveRows(unmatched);
                this.resolveContext = 'review';
                this.showResolveModal = true;
                this.isLoading = false;
                return null;
            });
    }

    // Open the counts-only record of what a finished sellout actually did
    loadSummary() {
        this.isLoading = true;
        getReportSummary({ reportId: this.currentReportId })
            .then(result => {
                this.summary = result;
                this.showSummaryModal = true;
                this.isLoading = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error loading the summary: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    get isSummaryLocked() {
        return this.hasSummary && this.summary.autoAccepted === true;
    }

    get lockedLinesNotice() {
        const report = (this.reports || []).find(r => r.Id === this.currentReportId);
        if (this.isSummaryLocked || (report && report.SLO_Auto_Accepted__c === true)) {
            return 'Locked: applied with Auto Accept. Its lines can be reviewed but not changed.';
        }
        return 'Every line, including the skipped ones, is shown for review only and cannot be changed.';
    }

    // Same columns as the review table with editing and sorting switched off
    get lockedColumns() {
        return this.itemColumns.map(column => ({ ...column, editable: false, sortable: false }));
    }

    get hasLockedItems() {
        return this.lockedItems.length > 0;
    }

    lockedSearchTerm = '';
    lockedStatusFilter = 'all';

    get lockedStatusOptions() {
        const counts = {};
        this.lockedItems.forEach(item => {
            const label = item.statusLabel || 'Unknown';
            counts[label] = (counts[label] || 0) + 1;
        });
        return [{ label: 'All lines (' + this.lockedItems.length + ')', value: 'all' }].concat(
            Object.keys(counts).sort().map(label => ({ label: label + ' (' + counts[label] + ')', value: label }))
        );
    }

    get filteredLockedItems() {
        const term = (this.lockedSearchTerm || '').trim().toLowerCase();
        return this.lockedItems.filter(item => {
            if (this.lockedStatusFilter !== 'all' && (item.statusLabel || 'Unknown') !== this.lockedStatusFilter) {
                return false;
            }
            if (!term) {
                return true;
            }
            return [item.Name, item.SLO_Product_Code_EAN__c, item.SLO_Customer_Account_Name__c, item.SLO_Processing_Notes__c]
                .some(value => value && String(value).toLowerCase().includes(term));
        });
    }

    get lockedRangeLabel() {
        return 'Showing ' + this.filteredLockedItems.length + ' of ' + this.lockedItems.length + ' lines';
    }

    get hasFilteredLockedItems() {
        return this.filteredLockedItems.length > 0;
    }

    get isLockedExportDisabled() {
        return !this.hasFilteredLockedItems;
    }

    // Download the lines currently shown (respecting the status and search filters) as a CSV file
    handleExportLockedLines() {
        const rows = this.filteredLockedItems;
        if (!rows.length) {
            return;
        }
        const escape = value => {
            const text = value === null || value === undefined ? '' : String(value);
            return '"' + text.replace(/"/g, '""') + '"';
        };
        const header = ['Item', 'Item Date', 'Product Code (EAN)', 'Quantity', 'Customer Account Name', 'Status', 'What to do'];
        const lines = [header.map(escape).join(',')];
        rows.forEach(item => {
            lines.push([
                item.Name,
                item.SLO_Item_Date__c,
                item.SLO_Product_Code_EAN__c,
                item.SLO_Quantity__c,
                item.SLO_Customer_Account_Name__c,
                item.statusLabel,
                item.SLO_Processing_Notes__c
            ].map(escape).join(','));
        });
        // BOM keeps accented customer names readable when the file is opened in Excel
        // A data URI is used because blob URLs and body-attached links are blocked or cancelled in Lightning
        try {
            const csv = '﻿' + lines.join('\r\n');
            const link = document.createElement('a');
            const safeName = (this.currentReportName || 'sellout-lines').replace(/[^\w.-]+/g, '_');
            link.href = 'data:text/csv;charset=utf-8,' + encodeURIComponent(csv);
            link.download = safeName + '-lines.csv';
            link.target = '_self';
            link.click();
        } catch (error) {
            this.showToast('Error', 'Could not export the lines: ' + this.errorText(error), 'error');
        }
    }

    handleLockedSearchChange(event) {
        this.lockedSearchTerm = event.detail.value;
    }

    handleLockedStatusChange(event) {
        this.lockedStatusFilter = event.detail.value;
    }

    // Lines of an Auto Accepted report, listed for reading only
    handleViewLockedLines() {
        this.isLoading = true;
        getSelloutItems({ reportId: this.currentReportId })
            .then(result => {
                this.lockedItems = (result || []).map(item => this.decorateItem(item));
                this.showLockedLinesModal = true;
                this.isLoading = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error loading the lines: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // Read-only line view straight from the report row, without opening the results window
    handleReviewLinesClick(event) {
        this.currentReportId = event.target.dataset.reportId;
        this.currentReportName = event.target.dataset.reportName || '';
        this.currentReportStatus = event.target.dataset.reportStatus || '';
        this.summary = null;
        this.handleViewLockedLines();
    }

    handleCloseLockedLines() {
        this.showLockedLinesModal = false;
        this.lockedItems = [];
        this.lockedSearchTerm = '';
        this.lockedStatusFilter = 'all';
        if (!this.showSummaryModal) {
            this.currentReportId = '';
            this.currentReportName = '';
            this.currentReportStatus = '';
        }
    }

    // Close the read-only summary
    handleCloseSummaryModal() {
        this.showLockedLinesModal = false;
        this.lockedItems = [];
        this.showSummaryModal = false;
        this.summary = null;
        this.currentReportId = '';
        this.currentReportStatus = '';
    }

    // Administrator delete: fetch the report's counts first so the confirmation can say exactly
    // what is about to go - how many lines, and whether invoices were created from it
    handleDeleteClick(event) {
        const reportId = event.target.dataset.reportId;
        const reportName = event.target.dataset.reportName || '';
        this.isLoading = true;

        getReportStatus({ reportId: reportId })
            .then(status => {
                const itemCount =
                    (status.pendingCount || 0) +
                    (status.pendingDecisionCount || 0) +
                    (status.matchedCount || 0) +
                    (status.invoiceCreatedCount || 0) +
                    (status.errorCount || 0) +
                    (status.skippedCount || 0);
                this.deleteTarget = {
                    id: reportId,
                    name: reportName,
                    itemCount: itemCount,
                    invoiceCount: status.invoiceCount || 0,
                    invoiceCreatedCount: status.invoiceCreatedCount || 0
                };
                this.deletedSoFar = 0;
                this.deleteProgress = '';
                this.showDeleteModal = true;
                this.isLoading = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error reading the report: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    get deleteKeepsInvoices() {
        return this.deleteTarget && this.deleteTarget.invoiceCount > 0;
    }

    get deleteLineSummary() {
        if (!this.deleteTarget) {
            return '';
        }
        const count = this.deleteTarget.itemCount;
        return count === 1 ? '1 line' : `${count} lines`;
    }

    get deleteInvoiceWarning() {
        if (!this.deleteTarget) {
            return '';
        }
        const invoices = this.deleteTarget.invoiceCount;
        const lines = this.deleteTarget.invoiceCreatedCount;
        return `${invoices} invoice(s) covering ${lines} line(s) were created from this report. ` +
            'They are kept - delete them separately if they were test data. Once the report is gone, ' +
            'its lines no longer count as recorded, so the same file could be invoiced again.';
    }

    handleDeleteCancel() {
        if (this.isDeleting) {
            return;
        }
        this.showDeleteModal = false;
        this.deleteTarget = null;
        this.deleteProgress = '';
    }

    handleDeleteConfirm() {
        if (!this.deleteTarget || this.isDeleting) {
            return;
        }
        this.isDeleting = true;
        this.deletedSoFar = 0;
        this.deleteProgress = 'Deleting…';
        this.runDeletePass();
    }

    // One server call removes a page of lines; keep calling until the server reports the report
    // itself is gone, telling the user how far along a large delete is
    runDeletePass() {
        const target = this.deleteTarget;
        deleteSelloutReport({ reportId: target.id })
            .then(result => {
                this.deletedSoFar += (result && result.itemsDeleted) || 0;
                if (!result || !result.finished) {
                    this.deleteProgress = `Deleted ${this.deletedSoFar} of ${target.itemCount} lines…`;
                    this.runDeletePass();
                    return null;
                }

                this.isDeleting = false;
                this.showDeleteModal = false;
                this.deleteTarget = null;
                this.deleteProgress = '';
                this.showToast(
                    'Report deleted',
                    `${target.name} and its ${this.deletedSoFar} line(s) were deleted.`,
                    'success'
                );
                this.loadReports();
                return null;
            })
            .catch(error => {
                // A failed pass leaves the report in place with whatever lines remain, so the list
                // is refreshed rather than assumed unchanged
                this.isDeleting = false;
                this.deleteProgress = '';
                this.showToast('Could not delete the report', this.errorText(error), 'error');
                this.loadReports();
            });
    }

    // Switch to another of the three views - reloaded from the server, since the unloaded part of a
    // large report has to be filtered there
    handleStatusFilterChange(event) {
        this.statusFilter = event.detail.value;
        this.resetBulkState();
        // The re-map action offers the hierarchy's accounts, so they are fetched the first time the
        // account-decision view is opened rather than on every report
        if (this.isAccountDecisionView && this.hierarchyAccountOptions.length === 0) {
            this.loadHierarchyAccountOptions();
        }
        this.loadItems();
    }

    // Clear what a bulk action was about to do, so a control left filled in on one view cannot be
    // applied on the next
    resetBulkState() {
        this.bulkFeedback = '';
        this.bulkProgress = '';
        this.bulkRemapAccountId = '';
        this.bulkProductCode = '';
        this.bulkCustomerName = '';
        this.isBulkWorking = false;
    }

    // The hierarchy's active accounts, offered when selected customers should point at an account
    // that already exists. A failure only costs the re-map action, so it never blocks the list.
    loadHierarchyAccountOptions() {
        return getHierarchyAccountOptions({ accountId: this.recordId })
            .then(options => {
                this.hierarchyAccountOptions = options || [];
                return null;
            })
            .catch(() => {
                this.hierarchyAccountOptions = [];
                return null;
            });
    }

    // A search is meant to find a line anywhere in the report, not only in the page on screen, so
    // entering a term pulls the rest of the view in behind it. Until it has all arrived the box says
    // so, and the term keeps filtering whatever is already loaded meanwhile.
    handleSearchChange(event) {
        this.searchTerm = event.target.value || '';
        this.scheduleSearchLoad();
    }

    // Fetch the rest of the view for the term now in the box. Called when the term changes and again
    // after switching view, so a term left in the box keeps searching the whole of the new view.
    scheduleSearchLoad() {
        this.clearSearchLoadTimer();

        if (!this.hasSearchTerm) {
            this.searchLoadNotice = '';
            return;
        }

        if (!this.reviewHasMore || this.isLoadingAll) {
            return;
        }

        this.searchLoadNotice = 'Loading the rest of this view so the search covers every line...';
        this.searchLoadTimer = setTimeout(() => {
            this.searchLoadTimer = null;
            this.loadEveryRow()
                .then(() => {
                    this.searchLoadNotice = this.hasSearchTerm
                        ? 'Searching all ' + this.loadedCount + ' line(s) in this view.'
                        : '';
                    return null;
                })
                .catch(error => {
                    this.searchLoadNotice = '';
                    this.showToast(
                        'Error',
                        'Error loading the rest of the lines to search: ' + this.errorText(error),
                        'error'
                    );
                });
        }, SEARCH_LOAD_DELAY_MS);
    }

    clearSearchLoadTimer() {
        if (this.searchLoadTimer) {
            clearTimeout(this.searchLoadTimer);
            this.searchLoadTimer = null;
        }
    }

    // Sort the loaded rows on the clicked column; rows arriving later slot into the same order
    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
        this.applySort();
    }

    applySort() {
        if (!this.sortedBy) {
            return;
        }
        const field = this.sortedBy;
        const direction = this.sortedDirection === 'desc' ? -1 : 1;
        this.items = [...this.items].sort((first, second) => {
            const a = first[field];
            const b = second[field];
            if (a === b) {
                return 0;
            }
            // Blanks always sink to the bottom, whichever way the column is sorted
            if (a === null || a === undefined || a === '') {
                return 1;
            }
            if (b === null || b === undefined || b === '') {
                return -1;
            }
            if (typeof a === 'number' && typeof b === 'number') {
                return (a - b) * direction;
            }
            return String(a).localeCompare(String(b), undefined, { numeric: true }) * direction;
        });
    }

    // Load the first page of the review list. Only the rows of the view now open are listed; the
    // skipped duplicates and already-invoiced rows stay in the summary counts.
    // @param chooseDefaultView True when the report is being opened, so the screen lands on the
    //        first of the three views that actually holds a line
    loadItems(chooseDefaultView) {
        this.isLoading = true;
        this.items = [];
        this.selectedRowIds = [];
        this.reviewHasMore = false;
        this.reviewTotalCount = 0;
        this.clearSearchLoadTimer();
        this.searchLoadNotice = '';

        // The counts decide which view a report opens on, so they are awaited in that case rather
        // than left to land after the first page
        const counted = this.refreshStatusCounts();
        const ready = chooseDefaultView === true
            ? counted.then(() => {
                this.statusFilter = this.defaultStatusFilter;
                return null;
            })
            : Promise.resolve(null);

        // The account bar is offered from every view, so the accounts it can point lines at are
        // fetched as soon as the list opens rather than only when the decision view is chosen -
        // otherwise "Apply account" would sit there with nothing to choose
        if (this.hierarchyAccountOptions.length === 0) {
            this.loadHierarchyAccountOptions();
        }

        return ready
            .then(() => this.fetchItemPage(0))
            .then(() => {
                this.showItemsModal = true;
                this.isLoading = false;
                // A term left in the box still applies to the view just opened, so the rest of that
                // view is pulled in for it too
                this.scheduleSearchLoad();
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error loading items: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // Refresh the summary counts, which drive the badges, the error banner and the Apply Sellout route
    refreshStatusCounts() {
        return getItemStatusCounts({ reportId: this.currentReportId })
            .then(counts => {
                if (counts) {
                    this.statusCounts = { ...this.statusCounts, ...counts };
                }
                return null;
            })
            .catch(() => {
                // The summary bar is informational, so a failed count must not block the items
                return null;
            });
    }

    // Move the badge counts to match rows that have just changed status, before the server is asked
    // to recount. The re-checked rows carry their new status and the list still holds the old one,
    // so a correction shows up in "Needs a fix" and "Ready" immediately; refreshStatusCounts then
    // confirms the numbers against the report as a whole.
    shiftStatusCounts(rows) {
        if (!rows || rows.length === 0) {
            return;
        }

        const previousById = new Map(this.items.map(item => [item.Id, item.SLO_Processing_Status__c]));
        const counts = { ...this.statusCounts };
        let moved = false;

        for (const row of rows) {
            const before = previousById.get(row.Id);
            const after = row.SLO_Processing_Status__c;
            if (!before || !after || before === after) {
                continue;
            }
            if (counts[before] !== undefined) {
                counts[before] = Math.max(0, counts[before] - 1);
            }
            if (counts[after] !== undefined) {
                counts[after] = counts[after] + 1;
            }
            moved = true;
        }

        if (moved) {
            this.statusCounts = counts;
        }
    }

    // Set the badges straight from the counts the server read back for the whole report. This is
    // what a correction settles on: inferring the move from the rows on screen only ever works when
    // every corrected line happens to be loaded, so on a large report the badges sat frozen at
    // "Needs a fix: 602 / Ready: 0" however many lines had actually been fixed.
    applyReportCounts(counts) {
        if (!counts) {
            return false;
        }
        this.statusCounts = { ...this.statusCounts, ...counts };
        return true;
    }

    // Fetch one page and append it to the rows already on screen
    fetchItemPage(offset) {
        return getSelloutItemPage({
            reportId: this.currentReportId,
            pageSize: PAGE_SIZE,
            rowOffset: offset,
            errorsOnly: this.isNeedsFixView,
            statusFilter: this.statusFilter
        }).then(result => {
            this.appendRows(result, offset === 0);
            this.reviewTotalCount = result ? result.totalCount : 0;
            this.reviewHasMore = result ? result.hasMore === true : false;
            return null;
        });
    }

    // Display decoration for one review row: the status pill, the icon and tone of the note, the
    // flag on the one value the note is about, and the row menu for rows awaiting a decision
    decorateItem(item) {
        const status = item.SLO_Processing_Status__c || 'Pending';
        const display = STATUS_DISPLAY[status] || STATUS_DISPLAY.Pending;
        const note = item.SLO_Processing_Notes__c || '';
        const isError = status === 'Error';
        const needsDecision = status === 'Pending_Decision';

        // Only a row with something wrong points at a value; a ready row is left clean
        const targetEntry = (isError || needsDecision)
            ? NOTE_TARGETS.find(entry => note.startsWith(entry.startsWith))
            : undefined;
        const target = targetEntry ? targetEntry.field : undefined;
        const flagIcon = isError ? 'utility:error' : 'utility:warning';
        const flagClass = isError ? 'slds-text-color_error' : '';

        let noteIcon = 'utility:info';
        let noteClass = 'slds-text-color_weak';
        if (isError) {
            noteIcon = 'utility:error';
            noteClass = 'slds-text-color_error';
        } else if (needsDecision) {
            noteIcon = 'utility:warning';
            noteClass = '';
        } else if (status === 'Matched') {
            noteIcon = 'utility:success';
        }

        return {
            ...item,
            statusLabel: display.label,
            statusCellClass: display.cellClass,
            noteIcon: noteIcon,
            noteClass: noteClass,
            dateIcon: target === 'quantity' ? flagIcon : undefined,
            dateCellClass: target === 'quantity' ? flagClass : '',
            qtyIcon: target === 'quantity' ? flagIcon : undefined,
            qtyCellClass: target === 'quantity' ? flagClass : '',
            productIcon: target === 'product' ? flagIcon : undefined,
            productCellClass: target === 'product' ? flagClass : '',
            nameIcon: target === 'name' ? flagIcon : undefined,
            nameCellClass: target === 'name' ? flagClass : ''
        };
    }

    // Add a batch of rows to the list and tick every one of them that has no error, so the selection
    // stays complete as more of a large file arrives
    appendRows(result, replace) {
        const page = result && result.items ? result.items : [];
        const styled = page.map(item => this.decorateItem(item));

        this.items = replace ? styled : [...this.items, ...styled];
        this.applySort();

        // Only the ready view arrives pre-ticked: there a tick means "include this line in the
        // sellout", and every line it holds is a candidate, so the user confirms a filled list
        // rather than checking hundreds of boxes. The other two views open with nothing ticked -
        // on the account-decision view a tick is a decision about a customer, and on the
        // needs-a-fix view it is a correction, so a pre-filled list would read as work already done.
        const autoTicked = this.isReadyView ? styled.map(item => item.Id) : [];

        this.selectedRowIds = replace
            ? autoTicked
            : [...this.selectedRowIds, ...autoTicked];
    }

    // Pull the next page in as the user scrolls to the bottom of the list. Held off while the whole
    // view is already being fetched for a search, because that rebuilds the list from the start and
    // a page asked for by offset at the same time would land as duplicate rows.
    handleLoadMore() {
        if (this.isLoadingMore || this.isLoadingAll || !this.reviewHasMore) {
            return;
        }

        this.isLoadingMore = true;
        this.fetchItemPage(this.items.length)
            .then(() => {
                this.isLoadingMore = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error loading more items: ' + this.errorText(error), 'error');
                this.isLoadingMore = false;
            });
    }

    // Pull in the whole list in one go, so a big file can be reviewed and ticked as a single set
    // rather than page by page
    handleLoadAll() {
        if (this.isLoadingAll) {
            return;
        }

        this.loadEveryRow()
            .then(() => {
                this.showToast(
                    'All items loaded',
                    `${this.items.length} item(s) are loaded and every item without an error is selected.`,
                    'success'
                );
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error loading all items: ' + this.errorText(error), 'error');
            });
    }

    // Bring the whole view in, whether the user asked for it with the button or a search needs it.
    // The list is rebuilt from the start so the rows arrive in one consistent order, and the ticks
    // the user had are put back on the rows that carried them.
    loadEveryRow() {
        if (this.isLoadingAll) {
            return Promise.resolve(null);
        }

        const previouslyTicked = new Set(this.selectedRowIds || []);
        this.isLoadingAll = true;
        this.items = [];
        this.selectedRowIds = [];

        return this.loadRemainingRows('')
            .then(() => {
                this.isLoadingAll = false;
                this.reviewHasMore = false;
                if (previouslyTicked.size > 0) {
                    const restored = this.items
                        .filter(item => previouslyTicked.has(item.Id))
                        .map(item => item.Id);
                    const merged = new Set([...this.selectedRowIds, ...restored]);
                    this.selectedRowIds = [...merged];
                }
                return null;
            })
            .catch(error => {
                this.isLoadingAll = false;
                throw error;
            });
    }

    // Walk forward through the remaining rows a chunk at a time until the server says there are no
    // more, keeping every call inside its own governor limits
    loadRemainingRows(lastItemId) {
        return getActionableItemsAfter({
            reportId: this.currentReportId,
            lastItemId: lastItemId,
            errorsOnly: this.isNeedsFixView,
            statusFilter: this.statusFilter
        }).then(result => {
            this.appendRows(result, false);
            this.reviewTotalCount = result ? result.totalCount : this.reviewTotalCount;

            const rows = result && result.items ? result.items : [];
            if (result && result.hasMore === true && rows.length > 0) {
                return this.loadRemainingRows(rows[rows.length - 1].Id);
            }
            return null;
        });
    }

    // Track the user's own ticks and unticks. The table only reports the rows it is showing, so
    // rows hidden by the search keep whatever tick they had. On the account-decision view a tick
    // is a decision about a customer, not about one line, so it spreads to every loaded line
    // carrying the same name - and the bulk action then reaches the report's other lines too.
    handleRowSelection(event) {
        const detail = event.detail || {};
        const action = detail.config ? detail.config.action : undefined;
        const visibleIdList = this.visibleItems.map(item => item.Id);
        const visibleIds = new Set(visibleIdList);

        // The header checkbox is answered from the rows actually on screen rather than from the
        // table's own report of what it just selected. On a long streamed list that report can come
        // back covering only part of the rows, which left the user with a handful of ticks after
        // asking for every one - so "select all" now always means every loaded row in the view.
        let selected;
        if (action === 'selectAllRows') {
            selected = visibleIdList;
        } else if (action === 'deselectAllRows') {
            selected = [];
        } else {
            selected = (detail.selectedRows || []).map(row => row.Id);
        }

        const keptHidden = this.selectedRowIds.filter(id => !visibleIds.has(id));
        const combined = [...keptHidden, ...selected];

        this.selectedRowIds = this.isAccountDecisionView
            ? this.expandToNameGroups(combined, new Set(selected), visibleIds)
            : combined;
    }

    // Grow a line-level selection into whole customer names: any name with at least one ticked
    // visible line is ticked entirely, and a name the user has just unticked is released entirely
    expandToNameGroups(selectedIds, visibleSelected, visibleIds) {
        const tickedNames = new Set();
        const untickedNames = new Set();

        for (const item of this.items) {
            const key = this.nameKeyOf(item);
            if (!key) {
                continue;
            }
            if (visibleSelected.has(item.Id)) {
                tickedNames.add(key);
            } else if (visibleIds.has(item.Id)) {
                untickedNames.add(key);
            }
        }

        // A name only survives as untouched if nothing under it was ticked in this pass
        for (const key of tickedNames) {
            untickedNames.delete(key);
        }

        const result = new Set(selectedIds);
        for (const item of this.items) {
            const key = this.nameKeyOf(item);
            if (!key) {
                continue;
            }
            if (tickedNames.has(key)) {
                result.add(item.Id);
            } else if (untickedNames.has(key)) {
                result.delete(item.Id);
            }
        }
        return [...result];
    }

    // The case-insensitive customer key a line groups under, matching how the server groups them
    nameKeyOf(item) {
        const name = item && item.SLO_Customer_Account_Name__c;
        return name ? String(name).trim().toLowerCase() : '';
    }

    // The distinct customer names behind the current selection, in the spelling the lines carry,
    // which is what a bulk account decision is applied to. Only the lines whose customer is still
    // undecided contribute, so an account action taken from a mixed selection cannot disturb the
    // lines that already read as ready.
    get selectedCustomerNames() {
        const selected = new Set(this.selectedRowIds || []);
        const byKey = new Map();
        for (const item of this.items) {
            if (!selected.has(item.Id)) {
                continue;
            }
            if (!DECISION_STATUSES.includes(item.SLO_Processing_Status__c)) {
                continue;
            }
            const key = this.nameKeyOf(item);
            if (key && !byKey.has(key)) {
                byKey.set(key, String(item.SLO_Customer_Account_Name__c).trim());
            }
        }
        return [...byKey.values()];
    }

    get selectedCustomerNameCount() {
        return this.selectedCustomerNames.length;
    }

    // The selected lines a bulk correction would write to: the ones still needing a fix, so the
    // same action bar can be used from any view without touching lines that are already fine
    get selectedFixableItemIds() {
        const selected = new Set(this.selectedRowIds || []);
        return this.items
            .filter(item => selected.has(item.Id) && item.SLO_Processing_Status__c === 'Error')
            .map(item => item.Id);
    }

    get selectedFixableCount() {
        return this.selectedFixableItemIds.length;
    }

    // Each bar belongs to the view whose work it does, so a view only offers the actions that make
    // sense on it: account decisions on the account-decision view, value corrections everywhere
    // else. Mixing the two put product-code boxes above a list of customer decisions. Within its own
    // view the bar always shows, with its buttons enabling themselves from what is ticked, so it
    // reads as the single place to act rather than appearing only once a selection exists.
    get showAccountDecisionBulkBar() {
        return this.showItemTable && this.isAccountDecisionView;
    }

    // The correction bar belongs to the needs-a-fix view alone. On the ready view there is nothing
    // to correct, so offering product-code and customer-name boxes there only invited doubt about
    // whether those lines were really finished.
    get showNeedsFixBulkBar() {
        return this.showItemTable && this.isNeedsFixView;
    }

    get hasBulkSelection() {
        return this.selectedFixableCount > 0;
    }

    get isBulkDecisionDisabled() {
        return this.isBulkWorking || this.selectedCustomerNameCount === 0;
    }

    // Re-mapping additionally needs the account the lines should point at
    get isBulkRemapDisabled() {
        return this.isBulkDecisionDisabled || !this.bulkRemapAccountId;
    }

    get isBulkProductEditDisabled() {
        return this.isBulkWorking || !this.hasBulkSelection ||
            (this.bulkProductCode || '').trim().length === 0;
    }

    get isBulkNameEditDisabled() {
        return this.isBulkWorking || !this.hasBulkSelection ||
            (this.bulkCustomerName || '').trim().length === 0;
    }

    // Says what a bulk action is about to cover: names on the account-decision view, where a tick
    // is a decision about a customer, and lines on the needs-a-fix view, where it is a correction
    get bulkDecisionSelectionLabel() {
        const names = this.selectedCustomerNameCount;
        if (names === 0) {
            return 'Tick a line to select its customer - every line carrying that name is included.';
        }
        const nameText = names === 1 ? '1 customer name' : names + ' customer names';
        const lineText = this.selectedCount === 1 ? '1 loaded line' : this.selectedCount + ' loaded lines';
        return nameText + ' selected, covering ' + lineText +
            ' here and every other line in this report carrying those names.';
    }

    get bulkFixSelectionLabel() {
        if (this.selectedFixableCount === 0) {
            return 'Tick the lines that need the same correction - or just edit one product code ' +
                'and the lines sharing it are offered the same fix.';
        }
        return this.selectedFixableCount === 1
            ? '1 line selected.'
            : this.selectedFixableCount + ' lines selected.';
    }

    handleBulkRemapAccountChange(event) {
        this.bulkRemapAccountId = event.detail.value;
    }

    handleBulkProductCodeChange(event) {
        this.bulkProductCode = event.target.value || '';
    }

    handleBulkCustomerNameChange(event) {
        this.bulkCustomerName = event.target.value || '';
    }

    handleBulkCreateAccounts() {
        this.runBulkDecision('create', null);
    }

    handleBulkLeaveOut() {
        this.runBulkDecision('skip', null);
    }

    handleBulkRemap() {
        this.runBulkDecision('reassign', this.bulkRemapAccountId);
    }

    // Apply one account decision to every selected customer name. The server resolves the decision
    // per name and reaches all of that name's lines, so the outcome is the same whether the user has
    // loaded fifty lines or five thousand.
    runBulkDecision(action, existingAccountId) {
        const names = this.selectedCustomerNames;
        if (names.length === 0) {
            return;
        }

        this.isBulkWorking = true;
        this.bulkFeedback = '';

        bulkDecideCustomerNames({
            reportId: this.currentReportId,
            parentAccountId: this.recordId,
            customerAccountNames: names,
            action: action,
            existingAccountId: existingAccountId
        })
            .then(result => {
                if (!result.success) {
                    this.showToast('Could not apply the bulk action',
                        result.errorMessage || 'The bulk action did not complete.', 'error');
                    this.isBulkWorking = false;
                    return null;
                }
                if (result.warningMessage) {
                    this.showToast('Applied with warnings', result.warningMessage, 'warning');
                }
                this.bulkFeedback = this.describeBulkDecision(result, names.length, action);
                this.bulkRemapAccountId = '';
                this.isBulkWorking = false;
                // Reload so every line carrying a decided name - loaded or not - shows its outcome
                return this.loadItems();
            })
            .catch(error => {
                this.showToast('Error', 'Error applying the bulk action: ' + this.errorText(error), 'error');
                this.isBulkWorking = false;
            });
    }

    // One line saying what the bulk decision did, worded like the single-decision confirmation
    describeBulkDecision(result, nameCount, action) {
        const parts = [nameCount === 1
            ? 'Applied to 1 customer name'
            : 'Applied to ' + nameCount + ' customer names'];

        if (result.rowsDeferred) {
            // Too many lines to update while the user waits: the accounts are in place and a
            // background job is carrying the decision to the lines
            if (result.accountsCreated > 0) {
                parts.push(result.accountsCreated + ' account(s) created');
            }
            parts.push('the lines are being updated in the background - the counts will catch up');
            return parts.join(', ') + '.';
        }

        if (result.accountsCreated > 0) {
            parts.push(result.accountsCreated + ' account(s) created');
        }
        if (result.accountsActivated > 0) {
            parts.push(result.accountsActivated + ' account(s) activated');
        }
        if (result.itemsMatched > 0) {
            parts.push(result.itemsMatched + ' line(s) now ready');
        }
        if (result.itemsReassigned > 0) {
            parts.push(result.itemsReassigned + ' line(s) pointed at the chosen account');
        }
        if (result.itemsSkipped > 0) {
            parts.push(result.itemsSkipped + ' line(s) left out');
        }
        if (result.itemsFlagged > 0) {
            parts.push(result.itemsFlagged + ' line(s) still need a fix');
        }
        if (result.accountsFailed > 0) {
            parts.push(result.accountsFailed + ' account(s) could not be created');
        }
        if (parts.length === 1 && action === 'skip') {
            parts.push('no lines needed changing');
        }
        return parts.join(', ') + '.';
    }

    handleBulkProductCodeApply() {
        this.runBulkEdit('productCode', this.bulkProductCode);
    }

    handleBulkCustomerNameApply() {
        this.runBulkEdit('customerAccountName', this.bulkCustomerName);
    }

    get enforcedSkippedCount() {
        return this.statusCounts.Enforced_Skipped;
    }

    get isEnforceSkipDisabled() {
        return this.isBulkWorking || this.selectedFixableCount === 0;
    }

    // Set the ticked lines that still need a fix aside as Enforced Skipped. They leave the
    // needs-a-fix view without a correction and are never invoiced.
    handleEnforceSkip() {
        const ids = this.selectedFixableItemIds;
        if (ids.length === 0) {
            return;
        }
        this.isBulkWorking = true;
        enforceSkipItems({ itemIds: ids })
            .then(count => {
                this.bulkFeedback = `${count} line(s) set aside as Enforced Skipped.`;
                // None of them is still in error, so every ticked line leaves this view
                this.dropCorrectedRows(ids, []);
                return this.refreshStatusCounts();
            })
            .catch(error => {
                this.showToast('Could not skip the lines', this.errorText(error), 'error');
            })
            .finally(() => {
                this.isBulkWorking = false;
            });
    }

    // Write the same corrected value to every selected line, then let the server re-check them so
    // each line's status, note and badge settle exactly as a single cell edit would leave them.
    // However many lines are ticked, the correction is sent as a run of smaller requests: one
    // request carrying thousands of lines has to read more than a single Salesforce transaction is
    // allowed to, which is what produced "Too many query rows" and lost the whole action. Each
    // request lands on its own, so the rows and the badges advance as the run progresses.
    runBulkEdit(fieldName, newValue) {
        return this.runBulkEditOnIds(this.selectedFixableItemIds, fieldName, newValue);
    }

    // The correction itself, on an explicit set of lines - the ticked ones from the bulk bar, or the
    // matching block proposed after a single edit
    runBulkEditOnIds(itemIds, fieldName, newValue) {
        const ids = itemIds || [];
        if (ids.length === 0 || !(newValue || '').trim()) {
            return Promise.resolve(null);
        }

        const batches = [];
        for (let start = 0; start < ids.length; start += BULK_EDIT_BATCH_SIZE) {
            batches.push(ids.slice(start, start + BULK_EDIT_BATCH_SIZE));
        }

        this.isBulkWorking = true;
        this.bulkFeedback = '';
        this.bulkProgress = batches.length > 1
            ? `Correcting ${ids.length.toLocaleString()} line(s)…`
            : '';

        const totals = {
            rowsUpdated: 0,
            rowsFailed: 0,
            nowReady: 0,
            stillNeedFix: 0,
            needDecision: 0,
            // Corrected lines the re-check set aside as already recorded or zero-quantity. They have
            // left the review, so they are named rather than counted as nothing having happened.
            nowSkipped: 0,
            // True when a pass wrote its lines but sent none of them back, so the list on screen
            // still shows them as they were. The rows are re-read from the server at the end rather
            // than left stale, which is what made a correction look as though it had done nothing.
            needsReload: false
        };

        return this.applyBulkEditBatches(batches, 0, fieldName, newValue.trim(), totals)
            .then(failure => {
                this.bulkProgress = '';
                this.isBulkWorking = false;

                if (failure) {
                    // Whatever the earlier requests corrected is already on screen, so the message
                    // says how far the run got rather than implying nothing happened
                    this.showToast('Could not finish the correction',
                        this.describeBulkEditFailure(failure, totals), 'error');
                } else {
                    if (fieldName === 'productCode') {
                        this.bulkProductCode = '';
                    } else {
                        this.bulkCustomerName = '';
                    }
                }

                this.bulkFeedback = this.describeBulkEdit(totals);
                // A reload re-reads the view from the server, so corrected lines leave the
                // needs-a-fix list for the ready list even when the re-check could not report them
                return totals.needsReload
                    ? this.loadItems()
                    : this.refreshStatusCounts();
            })
            .catch(error => {
                // Nothing below may leave the bar spinning: a correction that cannot finish still
                // has to hand the screen back to the user
                this.bulkProgress = '';
                this.isBulkWorking = false;
                this.showToast('Could not finish the correction', this.errorText(error), 'error');
                return null;
            });
    }

    // Send the corrections one request at a time, applying each result as it lands. Resolves with
    // null when the whole run succeeded, or with the message that stopped it.
    applyBulkEditBatches(batches, index, fieldName, correctedValue, totals) {
        if (index >= batches.length) {
            return Promise.resolve(null);
        }

        if (batches.length > 1) {
            this.bulkProgress =
                `Correcting line(s) ${index * BULK_EDIT_BATCH_SIZE + 1} - ` +
                `${index * BULK_EDIT_BATCH_SIZE + batches[index].length}…`;
        }

        return bulkEditItemField({
            itemIds: batches[index],
            fieldName: fieldName,
            newValue: correctedValue
        })
            .then(result => {
                if (!result || !result.success) {
                    return (result && result.errorMessage) || 'The correction did not complete.';
                }
                if (result.warningMessage) {
                    this.showToast('Applied in part', result.warningMessage, 'warning');
                }
                // The badges move with the rows in the same beat as the correction. They are set
                // from the counts the server read back for the whole report, so "Needs a fix" falls
                // and "Ready" rises the instant the action lands even when the corrected lines sit
                // further down the report than the screen has loaded.
                const rows = result.rows || [];
                if (!this.applyReportCounts(result.reportCounts)) {
                    this.shiftStatusCounts(rows);
                }
                this.mergeRevalidatedRows(rows);
                // Lines the correction wrote but the current view no longer lists are taken off the
                // list even when the re-check could not name them, so a corrected line never sits
                // in "Needs a fix" reading as broken after it has been fixed
                this.dropCorrectedRows(batches[index], rows);
                totals.rowsUpdated += result.rowsUpdated || 0;
                totals.rowsFailed += result.rowsFailed || 0;
                totals.nowReady += result.nowReady || 0;
                totals.stillNeedFix += result.stillNeedFix || 0;
                totals.needDecision += result.needDecision || 0;
                totals.nowSkipped += result.nowSkipped || 0;
                // Lines were written but none came back re-checked: the list cannot be settled from
                // this result, so it is re-read once the whole run is through
                if ((result.rowsUpdated || 0) > 0 && rows.length === 0) {
                    totals.needsReload = true;
                }
                return this.applyBulkEditBatches(
                    batches, index + 1, fieldName, correctedValue, totals
                );
            })
            .catch(error => this.errorText(error));
    }

    // Say how far a stopped run got, so the user knows what to select again rather than repeating
    // the whole correction
    describeBulkEditFailure(failure, totals) {
        if (totals.rowsUpdated === 0) {
            return failure;
        }
        return `${totals.rowsUpdated.toLocaleString()} line(s) were corrected before the run ` +
            `stopped. Select the lines that still need the correction and apply it again. ` +
            `Details: ${failure}`;
    }

    // What the bulk correction did, naming the lines that still need attention rather than only the
    // ones that worked
    describeBulkEdit(result) {
        const parts = ['Corrected ' + result.rowsUpdated + ' line(s)'];
        if (result.nowReady > 0) {
            parts.push(result.nowReady + ' now ready');
        }
        if (result.stillNeedFix > 0) {
            parts.push(result.stillNeedFix + ' still need a fix');
        }
        if (result.needDecision > 0) {
            parts.push(result.needDecision + ' need an account decision');
        }
        if (result.nowSkipped > 0) {
            parts.push(result.nowSkipped + ' already recorded');
        }
        if (result.rowsFailed > 0) {
            parts.push(result.rowsFailed + ' could not be saved and still need attention');
        }
        return parts.join(', ') + '.';
    }

    // Handle close items modal
    handleCloseItemsModal() {
        this.clearDeferredWaitTimer();
        this.isApplyingSellout = false;
        this.applyingMessage = APPLYING_MESSAGE;
        this.showItemsModal = false;
        this.showUncorrectedModal = false;
        this.items = [];
        this.selectedRowIds = [];
        this.isLoadingAll = false;
        this.currentReportId = '';
        this.currentReportStatus = '';
        this.currentReportName = '';
        // The next report opens in the default review view rather than inheriting this one's
        // filter, search, sort or last-save message
        this.statusFilter = ACCOUNT_DECISION_FILTER;
        this.searchTerm = '';
        this.clearSearchLoadTimer();
        this.searchLoadNotice = '';
        this.sortedBy = PRODUCT_CODE_FIELD;
        this.sortedDirection = 'asc';
        this.saveFeedback = '';
        this.draftValues = [];
        this.closeProductSpread();
        this.reviewHasMore = false;
        this.reviewTotalCount = 0;
        this.isLoadingMore = false;
        this.resetBulkState();
    }

    // A cell edit is saved the moment it is committed (Enter, or leaving the cell) - no separate
    // Save step. The server re-validates the edited rows and their same-name siblings and returns
    // them, so the row's pill and note change in place.
    handleCellChange(event) {
        this.saveDraftValues(event.detail.draftValues);
    }

    // Kept for a table showing the standard save bar; it saves the same way
    handleItemSave(event) {
        this.saveDraftValues(event.detail.draftValues);
    }

    saveDraftValues(draftValues) {
        if (!draftValues || draftValues.length === 0) {
            return;
        }
        this.saveFeedback = 'Saving…';

        // Worked out before the save, while the rows still carry the code that was replaced - that
        // old code is what identifies the block the edited line belonged to
        const spread = this.describeProductSpread(draftValues);

        updateSelloutItems({ items: draftValues })
            .then(result => {
                this.draftValues = [];
                const rows = result || [];
                // Same immediate badge move as a bulk correction, so a single edit is confirmed on
                // screen without waiting for the recount
                this.shiftStatusCounts(rows);
                this.mergeRevalidatedRows(rows);
                // The edited line itself leaves the needs-a-fix list as soon as it is no longer in
                // error, even if the re-check could not report it back
                this.dropCorrectedRows(draftValues.map(draft => draft.Id), rows);
                this.saveFeedback = this.describeSave(rows);
                // The edit has landed on its own line; now the lines sharing the code it replaced
                // are offered the same correction, already proposed rather than waiting to be ticked
                if (!spread) {
                    return this.refreshStatusCounts();
                }
                return this.findProductBlock(spread).then(block => {
                    if (block) {
                        this.openProductSpread(block);
                    }
                    return this.refreshStatusCounts();
                });
            })
            .catch(error => {
                this.draftValues = [];
                this.saveFeedback = '';
                this.showToast('Could not save the edit', this.errorText(error), 'error');
            });
    }

    // Does this edit change a product code on exactly one line (which had a code to replace)? If so,
    // describe it so the block sharing the replaced code can be looked up and offered the same
    // correction. Only single-line edits are considered: an edit already covering several lines is
    // the user spreading the value themselves.
    // @param draftValues The committed cell edits
    // @return { newValue, oldValue, siblingIds } whenever exactly one product code changed, where
    //   siblingIds holds only the loaded lines (possibly none); null otherwise
    describeProductSpread(draftValues) {
        const productEdits = draftValues.filter(
            draft => Object.prototype.hasOwnProperty.call(draft, PRODUCT_CODE_FIELD)
        );
        if (productEdits.length !== 1) {
            return null;
        }

        const edit = productEdits[0];
        const newValue = String(edit[PRODUCT_CODE_FIELD] || '').trim();
        if (!newValue) {
            return null;
        }

        const editedRow = this.items.find(item => item.Id === edit.Id);
        const oldValue = this.codeKeyOf(editedRow);
        // Nothing to spread when the line had no code to begin with, or when the "edit" re-typed the
        // value the line already held
        if (!oldValue || oldValue === newValue.toLowerCase()) {
            return null;
        }

        const siblingIds = this.items
            .filter(item =>
                item.Id !== edit.Id &&
                this.codeKeyOf(item) === oldValue &&
                item.SLO_Processing_Status__c === 'Error'
            )
            .map(item => item.Id);

        // The loaded siblings are only a fallback - the report-wide block is looked up after the save
        return {
            newValue: newValue,
            oldValue: editedRow[PRODUCT_CODE_FIELD],
            siblingIds: siblingIds
        };
    }

    // Every line on the report still needing a fix under the code just replaced, not only the ones
    // loaded on screen. The edited line already carries its new code, so it is not among them. If the
    // lookup fails, fall back to the loaded lines.
    findProductBlock(spread) {
        return getItemIdsByProductCode({ reportId: this.currentReportId, productCode: spread.oldValue })
            .then(ids => (ids && ids.length > 0 ? { ...spread, siblingIds: ids } : this.loadedBlockOrNull(spread)))
            .catch(() => this.loadedBlockOrNull(spread));
    }

    // The loaded sibling lines, used when the server returns none or fails; null when none are loaded
    loadedBlockOrNull(spread) {
        return spread.siblingIds.length > 0 ? spread : null;
    }

    // The case-insensitive product code a line groups under, so grouping and matching read a code
    // the same way however it was typed
    codeKeyOf(item) {
        const code = item && item[PRODUCT_CODE_FIELD];
        return code ? String(code).trim().toLowerCase() : '';
    }

    // Open the prompt with the whole matching block already proposed, so accepting it is one click.
    // The same lines are ticked in the table behind the prompt, so "update X selected items" can be
    // read against the rows it means rather than taken on trust.
    openProductSpread(spread) {
        this.spreadNewValue = spread.newValue;
        this.spreadOldValue = spread.oldValue;
        this.spreadSiblingIds = spread.siblingIds;
        this.spreadAccepted = true;
        this.selectedRowIds = [...spread.siblingIds];
        this.showProductSpreadModal = true;
    }

    // The pre-ticked offer on the prompt, named with its count so the user sees the size of what
    // they are about to accept rather than an unqualified "apply to all"
    get productSpreadOptionLabel() {
        const count = this.spreadSiblingIds.length;
        return count === 1
            ? 'Update 1 selected item'
            : 'Update ' + count.toLocaleString() + ' selected items';
    }

    get productSpreadMessage() {
        const count = this.spreadSiblingIds.length;
        const lines = count === 1 ? '1 other line' : count.toLocaleString() + ' other lines';
        return lines + ' still carry product code ' + this.spreadOldValue +
            ' and need a fix. Apply ' + this.spreadNewValue + ' to them as well?';
    }

    handleProductSpreadToggle(event) {
        this.spreadAccepted = event.target.checked === true;
    }

    handleCancelProductSpread() {
        // Declining releases the ticks the prompt put on, so the list is left as the user had it
        this.releaseSpreadSelection();
        this.closeProductSpread();
    }

    // Accepting the offer runs the same correction the bulk bar runs, so the matching lines are
    // written, re-checked and moved out of the needs-a-fix list exactly as a ticked selection would
    // have been. The prompt stays on screen until the correction has actually landed: closing it
    // first left the run with nothing of its own to report, so a correction of a large block looked
    // as though the Apply had done nothing at all.
    handleConfirmProductSpread() {
        // Copied out of the tracked state, which the prompt clears when it closes
        const ids = [...(this.spreadSiblingIds || [])];
        const value = this.spreadNewValue;
        const oldValue = this.spreadOldValue;

        if (this.spreadAccepted !== true || ids.length === 0 || !value) {
            this.releaseSpreadSelection();
            this.closeProductSpread();
            return;
        }

        this.isSpreadApplying = true;
        this.spreadProgress = 'Updating the matching lines…';

        // The block is resolved against the report rather than against the rows that happen to be
        // loaded, so accepting the offer corrects every line carrying the old code - including the
        // ones further down a large report the user has never scrolled to
        this.resolveProductBlockIds(oldValue, ids)
            .then(blockIds => {
                this.spreadSiblingIds = blockIds;
                this.spreadProgress =
                    `Updating ${blockIds.length.toLocaleString()} line(s)…`;
                return this.runBulkEditOnIds(blockIds, 'productCode', value);
            })
            .then(() => {
                this.isSpreadApplying = false;
                this.spreadProgress = '';
                // The corrected lines have left the needs-a-fix list for the ready list, so the
                // ticks the prompt put on them are released and the prompt closes on a finished
                // action rather than on a promise of one
                this.releaseSpreadSelection();
                this.closeProductSpread();
            })
            .catch(error => {
                this.isSpreadApplying = false;
                this.spreadProgress = '';
                this.isBulkWorking = false;
                this.closeProductSpread();
                this.showToast('Could not apply the correction', this.errorText(error), 'error');
            });
    }

    // The whole block carrying the replaced code. Falls back to the lines already on screen if the
    // lookup cannot be made, so Apply always corrects at least what the user was shown.
    resolveProductBlockIds(oldValue, loadedIds) {
        if (!oldValue || !this.currentReportId) {
            return Promise.resolve(loadedIds);
        }
        return getItemIdsByProductCode({
            reportId: this.currentReportId,
            productCode: oldValue
        })
            .then(serverIds => {
                const combined = new Set(loadedIds);
                for (const id of serverIds || []) {
                    combined.add(id);
                }
                return [...combined];
            })
            .catch(() => loadedIds);
    }

    // Drop just the ticks the prompt added, leaving any the user had set themselves
    releaseSpreadSelection() {
        const proposed = new Set(this.spreadSiblingIds || []);
        this.selectedRowIds = (this.selectedRowIds || []).filter(id => !proposed.has(id));
    }

    closeProductSpread() {
        this.showProductSpreadModal = false;
        this.spreadNewValue = '';
        this.spreadOldValue = '';
        this.spreadSiblingIds = [];
        this.spreadAccepted = true;
        this.isSpreadApplying = false;
        this.spreadProgress = '';
    }

    // One line saying what the edit did, so the user need not hunt the list for the outcome. A row
    // that leaves the current view because it is now ready is named here, since the row itself is no
    // longer on screen to say so.
    describeSave(rows) {
        const countOf = status =>
            rows.filter(row => row.SLO_Processing_Status__c === status).length;
        // Both statuses read as ready on the review screen: a Pending line's data is valid and the
        // apply run still has to match its account
        const ready = countOf('Matched') + countOf('Pending');
        const errors = countOf('Error');
        const decisions = countOf('Pending_Decision');
        const skipped = countOf('Skipped');
        const parts = ['Saved - ' + rows.length + ' line(s) re-checked'];
        if (ready > 0) {
            parts.push(ready + ' now ready');
        }
        if (errors > 0) {
            parts.push(errors + ' still need a fix');
        }
        if (decisions > 0) {
            parts.push(decisions + ' need an account decision');
        }
        if (skipped > 0) {
            parts.push(skipped + ' already recorded');
        }
        return parts.join(', ');
    }

    // Fold the re-validated rows back into the list: statuses update in place, rows that stopped
    // being actionable drop out (an edit turned them into exact duplicates), and the selection is
    // kept in step - rows now in error are unticked, fixed rows are ticked again
    mergeRevalidatedRows(rows) {
        const byId = new Map(rows.map(row => [row.Id, row]));
        if (byId.size === 0) {
            return;
        }

        let dropped = 0;
        const merged = [];
        for (const item of this.items) {
            const updated = byId.get(item.Id);
            if (!updated) {
                merged.push(item);
                continue;
            }
            const status = updated.SLO_Processing_Status__c;
            const leavesList = !this.statusBelongsToCurrentView(status);
            if (leavesList) {
                dropped++;
                continue;
            }
            merged.push(this.decorateItem(updated));
        }
        this.items = merged;
        // A corrected code belongs to a different block than the one the row sat in, so the list is
        // regrouped - otherwise the edited row would be left stranded among its old neighbours
        this.applySort();
        this.reviewTotalCount = Math.max(0, this.reviewTotalCount - dropped);

        const selected = new Set(this.selectedRowIds);
        // Only the ready view keeps its ticks in step with the statuses: there a tick means "include
        // this line in the sellout", so a line that arrives valid is ticked and one that no longer
        // is gets released. On the other two views a tick is the user's own choice of what to act
        // on, so it is left exactly as they set it.
        if (this.isReadyView) {
            for (const row of byId.values()) {
                const status = row.SLO_Processing_Status__c;
                if (status === 'Pending' || status === 'Matched') {
                    selected.add(row.Id);
                } else {
                    selected.delete(row.Id);
                }
            }
        }
        const listedIds = new Set(merged.map(item => item.Id));
        this.selectedRowIds = [...selected].filter(id => listedIds.has(id));
    }

    // Take the corrected lines off the needs-a-fix list even when the re-check did not report them
    // back. A line the correction wrote and the re-check did not return as still in error is no
    // longer this view's work, so leaving it on screen was what made a finished correction read as
    // though the rows had never moved. Only the needs-a-fix view drops lines this way: on the other
    // views a line's presence is not a statement that it still needs fixing.
    // @param correctedIds The Ids this pass sent for correction
    // @param rows The re-checked rows the server returned
    dropCorrectedRows(correctedIds, rows) {
        if (!this.isNeedsFixView || !correctedIds || correctedIds.length === 0) {
            return;
        }

        // Lines the server confirmed are still in error stay; everything else this pass wrote has
        // moved on to another view
        const stillInError = new Set(
            (rows || [])
                .filter(row => row.SLO_Processing_Status__c === 'Error')
                .map(row => row.Id)
        );
        const written = new Set(correctedIds);

        const kept = this.items.filter(
            item => !written.has(item.Id) || stillInError.has(item.Id)
        );
        const dropped = this.items.length - kept.length;
        if (dropped === 0) {
            return;
        }

        this.items = kept;
        this.reviewTotalCount = Math.max(0, this.reviewTotalCount - dropped);
        const listedIds = new Set(kept.map(item => item.Id));
        this.selectedRowIds = (this.selectedRowIds || []).filter(id => listedIds.has(id));
    }

    // Apply Sellout, but never silently: a report still holding lines that need a fix asks first,
    // naming the exact count, so the user chooses between correcting them and setting them aside
    handleApplySellout() {
        if (this.statusCounts.Error > 0) {
            this.showUncorrectedModal = true;
            return;
        }
        this.startApplySellout();
    }

    // How many lines still need a fix, spelled out in the confirmation so the user is deciding on a
    // real figure rather than a vague warning
    get uncorrectedConfirmMessage() {
        const count = this.statusCounts.Error;
        const lines = count === 1 ? '1 line' : count.toLocaleString() + ' lines';
        return lines + ' still need a fix and will be skipped. Do you want to continue?';
    }

    handleCancelUncorrected() {
        this.showUncorrectedModal = false;
    }

    // The user has accepted the count, so every line still in error is set aside with a note saying
    // it was left uncorrected, and the sellout then applies to the ready lines
    handleConfirmUncorrected() {
        this.showUncorrectedModal = false;
        this.isLoading = true;
        this.sweepUncorrectedLines()
            .then(() => this.refreshStatusCounts())
            .then(() => {
                this.isLoading = false;
                this.startApplySellout();
                return null;
            })
            .catch(error => {
                this.isLoading = false;
                this.showToast(
                    'Could not set aside the lines needing a fix',
                    this.errorText(error),
                    'error'
                );
            });
    }

    // The server sets aside a bounded block per call so a very large report cannot exceed its limits,
    // so keep calling until a pass finds nothing left to skip
    sweepUncorrectedLines() {
        return skipUncorrectedErrorItems({ reportId: this.currentReportId }).then(skipped =>
            skipped > 0 ? this.sweepUncorrectedLines() : null
        );
    }

    // The apply run itself, once the lines needing a fix have been dealt with
    startApplySellout() {
        // If report is in Error status, reset it first
        if (this.currentReportStatus === 'Error') {
            this.isLoading = true;
            resetReportStatus({ reportId: this.currentReportId })
                .then(() => {
                    this.currentReportStatus = 'Draft';
                    this.proceedWithApplySellout();
                })
                .catch(error => {
                    this.showToast('Error', 'Error resetting report: ' + error.body.message, 'error');
                    this.isLoading = false;
                });
        } else {
            this.excludeUntickedRows().then(() => {
                this.proceedWithApplySellout();
                return null;
            });
        }
    }

    // Anything the user unticked on the full review list is set aside before invoicing, so Apply
    // Sellout does exactly what the ticked list shows. Rows awaiting an account decision are held
    // back, since the accounts step owns those, and rows already skipped need no second decision.
    // Rows further down an unloaded list are untouched.
    excludeUntickedRows() {
        // Only the ready view is read as a decision about what to invoice: it is the one view whose
        // lines are all candidates, and a tick there means "include this line". The other two views
        // hold work in progress, so what is unticked on them says nothing about the sellout.
        if (!this.isReadyView) {
            return Promise.resolve(null);
        }

        const selected = new Set(this.selectedRowIds);
        const unticked = this.items
            .filter(item => !selected.has(item.Id))
            .map(item => item.Id);

        if (unticked.length === 0) {
            return Promise.resolve(null);
        }

        return skipMatchingForItem({ selloutItemIds: unticked })
            .then(() => this.refreshStatusCounts())
            .catch(error => {
                this.showToast(
                    'Error',
                    'Error setting aside the unselected items: ' + this.errorText(error),
                    'error'
                );
                return null;
            });
    }

    // Proceed with apply sellout after status reset
    proceedWithApplySellout() {
        // Rows still at Pending were never matched (an older report, or matching was interrupted).
        // Run matching first - invoicing only reads Matched rows and would silently leave the
        // pending ones behind.
        if (this.statusCounts.Pending > 0) {
            this.startBackgroundApplySellout();
            return;
        }

        // A Draft report has already been imported and matched, so Apply Sellout means "create the
        // invoices for the items I have just reviewed". Re-running matching would find nothing
        // pending and leave the report sitting in Draft, so go straight to invoice creation.
        if (this.statusCounts.Matched > 0) {
            this.isLoading = true;
            this.showToast(
                'Creating invoices',
                'Invoice creation is running in the background. We will email you a summary when it finishes - you can close this window.',
                'success'
            );
            this.resumeInvoicing().then(() => {
                this.handleCloseItemsModal();
                return null;
            });
            return;
        }

        // Every report is matched in the background and the result is emailed, whatever its size,
        // so a small file follows exactly the same review-then-invoice path as a large one
        this.startBackgroundApplySellout();
    }

    // In-page matching. Retained for the one-at-a-time unmatched account prompts, which need the
    // user to stay in the modal; the standard route is now always the background run above.
    runForegroundApplySellout() {
        this.isApplyingSellout = true;
        this.isLoading = true;
        applySellout({ reportId: this.currentReportId, currentAccountId: this.recordId })
            .then(result => {
                if (!result.success && result.errorMessage) {
                    this.showToast('Error', result.errorMessage, 'error');
                    this.isLoading = false;
                    this.isApplyingSellout = false;
                    return;
                }

                // Check if there are unmatched items
                if (result.unmatchedItems && result.unmatchedItems.length > 1) {
                    // Several account names need a decision - show them all in one list
                    // so the user approves the whole set once instead of one prompt each
                    this.resolveRows = this.buildResolveRows(result.unmatchedItems);
                    this.resolveContext = 'checkStatus';
                    this.showResolveModal = true;
                    this.isLoading = false;
                    this.isApplyingSellout = false;
                } else if (result.unmatchedItems && result.unmatchedItems.length === 1) {
                    this.unmatchedAccounts = result.unmatchedItems;
                    this.currentUnmatchedIndex = 0;
                    this.showNextUnmatchedAccount();
                } else {
                    // All items matched and invoices created automatically
                    let successMessage = `Successfully matched ${result.itemsMatched} items`;
                    if (result.itemsSkipped > 0) {
                        successMessage += ` (${result.itemsSkipped} skipped - see the item list for the reason)`;
                    }
                    if (result.invoicesCreated > 0) {
                        if (result.positiveInvoicesCreated && result.negativeInvoicesCreated) {
                            successMessage += ` and created ${result.positiveInvoicesCreated} invoices for matched accounts and ${result.negativeInvoicesCreated} offsetting invoices for parent account with ${result.lineItemsCreated} total line items`;
                        } else {
                            successMessage += ` and created ${result.invoicesCreated} invoices with ${result.lineItemsCreated} line items`;
                        }
                    }
                    if (result.lineItemsAddedToExistingInvoices > 0) {
                        successMessage += `. ${result.lineItemsAddedToExistingInvoices} new product line(s) were added to invoices that already existed`;
                    }
                    if (result.itemsQuantityMismatch > 0) {
                        successMessage += `. ${result.itemsQuantityMismatch} item(s) need review because the quantity differs from the existing invoice`;
                    }
                    this.showToast('Success', successMessage, 'success');
                    if (result.warningMessage) {
                        this.showToast('Items needing attention', result.warningMessage, 'warning');
                    }
                    this.isApplyingSellout = false;
                    this.loadItems();
                }
            })
            .catch(error => {
                this.showToast('Error', 'Error applying sellout: ' + error.body.message, 'error');
                this.isLoading = false;
                this.isApplyingSellout = false;
            });
    }

    // Show next unmatched account prompt
    showNextUnmatchedAccount() {
        if (this.currentUnmatchedIndex < this.unmatchedAccounts.length) {
            const unmatchedItem = this.unmatchedAccounts[this.currentUnmatchedIndex];
            this.currentUnmatchedAccount = unmatchedItem.customerAccountName;
            this.currentUnmatchedItemCount = unmatchedItem.selloutItemIds ? unmatchedItem.selloutItemIds.length : 1;
            this.currentIsInactive = unmatchedItem.isInactive || false;
            this.currentAccountId = unmatchedItem.accountId || '';

            // Show appropriate modal based on whether account is inactive
            if (this.currentIsInactive) {
                this.showActivationModal = true;
            } else {
                this.showAccountCreationModal = true;
            }

            this.isLoading = false;
            // Temporarily hide the spinner while showing modal
            this.isApplyingSellout = false;
        } else {
            // All unmatched items processed - carry straight on to invoice creation. The lines
            // needing a fix were already confirmed before this run started, so the user is not
            // asked about them a second time.
            this.startApplySellout();
        }
    }

    // Handle confirm account creation
    handleConfirmAccountCreation() {
        this.isLoading = true;
        this.showAccountCreationModal = false;
        // Resume showing spinner while processing account creation
        this.isApplyingSellout = true;

        const unmatchedItem = this.unmatchedAccounts[this.currentUnmatchedIndex];

        createChildAccount({
            parentAccountId: this.recordId,
            accountName: this.currentUnmatchedAccount,
            selloutItemIds: unmatchedItem.selloutItemIds
        })
            .then(() => {
                this.currentUnmatchedIndex++;
                this.showNextUnmatchedAccount();
            })
            .catch(error => {
                this.showToast('Error', 'Error creating account: ' + error.body.message, 'error');
                this.isLoading = false;
                this.isApplyingSellout = false;
            });
    }

    // Handle decline account creation
    handleDeclineAccountCreation() {
        this.isLoading = true;
        this.showAccountCreationModal = false;
        // Resume showing spinner while processing skip action
        this.isApplyingSellout = true;

        const unmatchedItem = this.unmatchedAccounts[this.currentUnmatchedIndex];

        skipMatchingForItem({
            selloutItemIds: unmatchedItem.selloutItemIds
        })
            .then(() => {
                this.currentUnmatchedIndex++;
                this.showNextUnmatchedAccount();
            })
            .catch(error => {
                this.showToast('Error', 'Error skipping item: ' + error.body.message, 'error');
                this.isLoading = false;
                this.isApplyingSellout = false;
            });
    }

    // Handle activate account
    handleActivateAccount() {
        this.isLoading = true;
        this.showActivationModal = false;
        // Resume showing spinner while processing activation
        this.isApplyingSellout = true;

        const unmatchedItem = this.unmatchedAccounts[this.currentUnmatchedIndex];

        activateAccount({
            accountId: this.currentAccountId,
            selloutItemIds: unmatchedItem.selloutItemIds
        })
            .then(() => {
                this.currentUnmatchedIndex++;
                this.showNextUnmatchedAccount();
            })
            .catch(error => {
                this.showToast('Error', 'Error activating account: ' + error.body.message, 'error');
                this.isLoading = false;
                this.isApplyingSellout = false;
            });
    }

    // Handle create new account with suffix
    handleCreateNewWithSuffix() {
        this.isLoading = true;
        this.showActivationModal = false;
        // Resume showing spinner while processing account creation
        this.isApplyingSellout = true;

        const unmatchedItem = this.unmatchedAccounts[this.currentUnmatchedIndex];

        createChildAccountWithSuffix({
            parentAccountId: this.recordId,
            accountName: this.currentUnmatchedAccount,
            selloutItemIds: unmatchedItem.selloutItemIds
        })
            .then(() => {
                this.currentUnmatchedIndex++;
                this.showNextUnmatchedAccount();
            })
            .catch(error => {
                this.showToast('Error', 'Error creating account with suffix: ' + error.body.message, 'error');
                this.isLoading = false;
                this.isApplyingSellout = false;
            });
    }


    // Kick off background matching and close the items modal so the user need not wait
    startBackgroundApplySellout() {
        this.isLoading = true;

        startAsyncApplySellout({ reportId: this.currentReportId, currentAccountId: this.recordId })
            .then(result => {
                if (!result.success) {
                    this.showToast('Error', result.errorMessage, 'error');
                    this.isLoading = false;
                    return;
                }

                this.showToast(
                    'Matching started',
                    'Account matching is running in the background. The report row updates to Draft ' +
                        'when the lines are ready for you to review - you can close this window.',
                    'success'
                );
                this.handleCloseItemsModal();
                this.loadReports();
                this.isLoading = false;
            })
            .catch(error => {
                this.showToast('Error', 'Error starting Apply Sellout: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // Refresh the report's status and open the bulk resolution screen if decisions are outstanding
    handleCheckStatus(event) {
        const reportId = event.target.dataset.reportId;
        this.currentReportId = reportId;
        this.currentReportStatus = 'Draft';
        this.isLoading = true;

        // Reconcile first so a report left showing Completed or Error while items were still
        // waiting is corrected before its status is shown
        reconcileReportStatus({ reportId: reportId })
            .then(status => {
                this.pendingDecisionCount = status.pendingDecisionCount;

                if (status.pendingDecisionCount > 0) {
                    return this.loadUnmatchedAccounts();
                }

                // Imported rows sit at Pending until Apply Sellout runs - without this the report
                // looks finished while no accounts are matched and no invoices exist yet
                if (status.pendingCount > 0) {
                    this.showToast(
                        'Invoices not created yet',
                        `${status.pendingCount} imported item(s) have not been processed yet. Starting account matching now - the report moves to Draft for your review when it finishes.`,
                        'info'
                    );
                    this.startBackgroundApplySellout();
                    return null;
                }

                let message = `${status.status}: ${status.matchedCount} matched, ` +
                    `${status.invoiceCreatedCount} invoiced, ${status.skippedCount} skipped, ` +
                    `${status.errorCount} with errors.`;
                if (status.invoiceCount > 0) {
                    message += ` ${status.invoiceCount} invoice(s) exist for this report.`;
                }
                // Matched items are already past the matching stage, so resume the invoice stage
                // directly - a fresh Apply Sellout only looks at Pending items and would skip them
                if (status.matchedCount > 0) {
                    this.showToast(
                        'Resuming invoice creation',
                        `${message} Resuming invoice creation for the ${status.matchedCount} remaining item(s) - we will email you when it finishes.`,
                        'info'
                    );
                    return this.resumeInvoicing();
                }

                this.showToast('Report status', message, 'info');
                this.isLoading = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error loading report status: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // Restart just the invoice stage for items that are matched but not yet invoiced
    resumeInvoicing() {
        return resumeInvoiceCreation({ reportId: this.currentReportId, currentAccountId: this.recordId })
            .then(result => {
                if (!result.success) {
                    this.showToast('Error', result.errorMessage, 'error');
                }
                this.loadReports();
                this.isLoading = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error resuming invoice creation: ' + this.errorText(error), 'error');
                this.isLoading = false;
                return null;
            });
    }

    // Load every unresolved customer name into one bulk decision screen (the recovery path -
    // decisions here start invoicing as soon as they are applied)
    loadUnmatchedAccounts() {
        return Promise.all([
            getUnmatchedAccounts({ reportId: this.currentReportId }),
            getHierarchyAccountOptions({ accountId: this.recordId })
        ]).then(results => {
            this.hierarchyAccountOptions = results[1] || [];
            this.resolveRows = this.buildResolveRows(results[0]);
            this.resolveContext = 'checkStatus';
            this.showResolveModal = true;
            this.isLoading = false;
        });
    }

    // Turn the unmatched account entries into rows for the bulk decision list
    buildResolveRows(entries) {
        return (entries || []).map((entry, index) => ({
            key: `unmatched-${index}`,
            customerAccountName: entry.customerAccountName,
            itemCount: entry.selloutItemIds ? entry.selloutItemIds.length : 0,
            isInactive: entry.isInactive,
            existingAccountId: entry.accountId,
            action: entry.isInactive ? 'activate' : 'create',
            isReassign: false,
            selectedAccountId: '',
            actionOptions: entry.isInactive
                ? [
                    { label: 'Activate existing account', value: 'activate' },
                    { label: 'Create new account', value: 'create' },
                    { label: 'Use a different existing account', value: 'reassign' },
                    { label: 'Skip', value: 'skip' }
                ]
                : [
                    { label: 'Create new account', value: 'create' },
                    { label: 'Use an existing account', value: 'reassign' },
                    { label: 'Skip', value: 'skip' }
                ]
        }));
    }

    // Handle a per-row action change on the bulk resolution screen
    handleResolveActionChange(event) {
        const key = event.target.dataset.key;
        const action = event.detail.value;
        this.resolveRows = this.resolveRows.map(row =>
            row.key === key ? { ...row, action: action, isReassign: action === 'reassign' } : row
        );
    }

    // Record which existing account an unresolved name is being pointed at
    handleResolveAccountChange(event) {
        const key = event.target.dataset.key;
        const accountId = event.detail.value;
        this.resolveRows = this.resolveRows.map(row =>
            row.key === key ? { ...row, selectedAccountId: accountId } : row
        );
    }

    // Set the same action on every row
    handleResolveSetAll(event) {
        const action = event.target.dataset.action;
        this.resolveRows = this.resolveRows.map(row =>
            row.actionOptions.some(option => option.value === action) ? { ...row, action: action } : row
        );
    }

    // Submit the decisions for the unresolved account names. From the review wizard the resolved
    // items then wait for Apply Sellout; from the status check invoice creation starts right away.
    handleResolveSubmit() {
        const missingAccount = this.resolveRows.find(
            row => row.action === 'reassign' && !row.selectedAccountId
        );
        if (missingAccount) {
            this.showToast(
                'Choose an account',
                `Pick the existing account to use for "${missingAccount.customerAccountName}", or choose a different action.`,
                'warning'
            );
            return;
        }

        this.isLoading = true;
        const isReviewStep = this.resolveContext === 'review';

        const decisions = this.resolveRows.map(row => ({
            customerAccountName: row.customerAccountName,
            action: row.action,
            existingAccountId: row.action === 'reassign' ? row.selectedAccountId : row.existingAccountId
        }));

        bulkResolveUnmatched({
            reportId: this.currentReportId,
            parentAccountId: this.recordId,
            decisions: decisions,
            startInvoicing: !isReviewStep
        })
            .then(result => {
                if (!result.success) {
                    this.showToast('Error', result.errorMessage, 'error');
                    this.isLoading = false;
                    return null;
                }

                let msg = `${result.accountsCreated} account(s) created, ${result.accountsActivated} activated, ` +
                    `${result.itemsReassigned} line(s) pointed at existing accounts, ${result.itemsSkipped} item(s) skipped.`;

                if (result.rowsDeferred) {
                    // Too many lines to update while the user waits - the accounts are in place and a
                    // background job is carrying the decisions to the lines
                    msg = `${result.accountsCreated} account(s) created, ${result.accountsActivated} activated. ` +
                        'This report has too many lines to update while you wait, so they are being ' +
                        'updated in the background' +
                        (result.invoicingQueued
                            ? ' and invoices will then be created. You will receive an email when that finishes.'
                            : isReviewStep
                                ? '. The lines open as soon as they are ready.'
                                : '. Reopen the report in a moment to see the updated lines.');
                } else if (result.jobId) {
                    msg += ' Invoice creation is running in the background and you will receive an email when it completes.';
                }

                if (result.warningMessage) {
                    this.showToast('Please note', result.warningMessage, 'warning');
                }

                this.showToast('Decisions applied', msg, 'success');
                this.showResolveModal = false;
                this.resolveRows = [];
                this.pendingDecisionCount = 0;

                // Nothing useful to review until the background job has run
                if (result.rowsDeferred) {
                    if (isReviewStep) {
                        // Step two of the wizard still follows - wait for the job, then open it
                        return this.waitForDeferredDecisions(0);
                    }
                    this.handleCloseItemsModal();
                    this.loadReports();
                    this.isLoading = false;
                    return null;
                }

                if (isReviewStep) {
                    // Step two of the wizard: the line list, now free of the names just resolved,
                    // opening on whichever view still holds work
                    return this.loadItems(true);
                }

                this.loadReports();
                this.isLoading = false;
                return null;
            })
            .catch(error => {
                this.showToast('Error', 'Error applying decisions: ' + this.errorText(error), 'error');
                this.isLoading = false;
            });
    }

    // A large report's account decisions reach its lines through a background job. Stay on the
    // review screen with a spinner and open the line list once that job releases the report,
    // instead of closing and leaving the user to find their way back in.
    waitForDeferredDecisions(pollCount, reportId = this.currentReportId) {
        // A poll for a report that is no longer the open one has nothing to wait for
        if (!this.showItemsModal || this.currentReportId !== reportId) {
            return null;
        }
        this.isLoading = false;
        this.isApplyingSellout = true;
        this.applyingMessage = 'Updating the lines with your account decisions…';

        if (pollCount >= MAX_AUTO_OPEN_POLLS) {
            this.isApplyingSellout = false;
            this.applyingMessage = APPLYING_MESSAGE;
            this.handleCloseItemsModal();
            this.loadReports();
            this.showToast(
                'Still updating',
                'The lines are taking longer than usual to update. Open the report from the list ' +
                    'once its row shows Ready for review.',
                'info'
            );
            return null;
        }

        return getReportStatus({ reportId: reportId })
            .catch(() => null)
            .then(status => {
                if (!this.showItemsModal || this.currentReportId !== reportId) {
                    return null;
                }
                // A dead run will never release the report, so stop rather than keep the user waiting
                if (status && status.status === 'In_Process' && status.isStuck) {
                    this.handleCloseItemsModal();
                    this.loadReports();
                    this.showStuckRunToast();
                    return null;
                }
                // A failed check is not a reason to stop waiting - ask again
                if (!status || status.status === 'In_Process') {
                    this.clearDeferredWaitTimer();
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    this.deferredWaitTimer = setTimeout(() => {
                        this.deferredWaitTimer = null;
                        this.waitForDeferredDecisions(pollCount + 1, reportId);
                    }, AUTO_OPEN_POLL_MS);
                    return null;
                }
                this.isApplyingSellout = false;
                this.applyingMessage = APPLYING_MESSAGE;
                this.currentReportStatus = status.status;
                return this.loadItems(true);
            });
    }

    clearDeferredWaitTimer() {
        if (this.deferredWaitTimer) {
            clearTimeout(this.deferredWaitTimer);
            this.deferredWaitTimer = null;
        }
    }

    // Close the bulk resolution screen without applying anything. From the review wizard this
    // abandons the review; the report row opens it again.
    handleResolveCancel() {
        this.showResolveModal = false;
        this.resolveRows = [];
        if (this.resolveContext === 'review') {
            this.handleCloseItemsModal();
        }
    }

    get isReviewResolveContext() {
        return this.resolveContext === 'review';
    }

    get resolveModalTitle() {
        return this.isReviewResolveContext
            ? 'Confirm New Accounts (Step 1 of 2)'
            : 'Resolve Unmatched Accounts';
    }

    get resolveSubmitLabel() {
        return this.isReviewResolveContext ? 'Confirm Accounts & Continue' : 'Apply Decisions';
    }

    // The same screen carries a different promise in each flow, so the intro says which one applies
    get resolveIntroText() {
        if (this.isReviewResolveContext) {
            return `${this.resolveRowCount} customer name(s) in this report do not match any account in ` +
                'the hierarchy. Decide what to do with each name - every line carrying that name follows ' +
                'the decision. You will review the lines next; invoices are only created when you click ' +
                'Apply Sellout.';
        }
        return `${this.resolveRowCount} account name(s) could not be matched automatically. ` +
            'Choose what to do with each one, then submit. Invoice creation runs in the ' +
            'background and you will receive an email when it completes.';
    }

    // Save column mapping to Account
    saveMappingToAccount() {
        const mappingJson = JSON.stringify({
            itemDate: this.mappings.itemDate,
            productCode: this.mappings.productCode,
            quantity: this.mappings.quantity,
            customerAccountName: this.mappings.customerAccountName
        });

        saveColumnMapping({ accountId: this.recordId, mappingJson: mappingJson })
            .catch(error => {
                // Silently fail - don't interrupt the user flow
                console.error('Error saving column mapping:', error);
            });
    }

    // Reset import wizard
    resetImportWizard() {
        this.importStep = 'fileUpload';
        this.fileContent = '';
        this.fileName = '';
        this.columnHeaders = [];
        this.rawFileData = [];
        this.totalRows = 0;
        this.mappings = {
            itemDate: '',
            productCode: '',
            quantity: '',
            customerAccountName: '',
            csvDelimiter: ','
        };
        this.importStartDate = DEFAULT_START_DATE;
        this.autoAccept = false;
        this.skipDuplicates = true;
        this.priceMethod = 'Customer_Price_List';
        this.previewData = [];
    }

    // Extract a readable message from an Apex error
    errorText(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return error && error.message ? error.message : 'Unknown error';
    }

    // Show toast notification
    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(event);
    }
}