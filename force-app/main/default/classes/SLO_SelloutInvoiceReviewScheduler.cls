/**
 * @description Schedulable Apex class that runs weekly (every Friday at 10 PM) to execute
 * SLO_SelloutInvoiceReviewBatch for the current week's invoices.
 *
 * Calculates the current week's date range (Monday to Sunday) and executes the batch with
 * those dates. Can also be executed manually via Developer Console for historical backfill
 * with custom date ranges.
 *
 * Usage:
 * - Schedule weekly: System.schedule('SLO Weekly Invoice Review', '0 0 22 ? * FRI', new SLO_SelloutInvoiceReviewScheduler());
 * - Manual execution: System.schedule('SLO Invoice Review', '0 0 22 ? * FRI', new SLO_SelloutInvoiceReviewScheduler());
 */
public class SLO_SelloutInvoiceReviewScheduler implements Schedulable {

    /**
     * @description Execute method called by the scheduler
     * @param sc SchedulableContext
     */
    public void execute(SchedulableContext sc) {
        // Calculate current week's date range (Monday to Sunday)
        Date today = Date.today();

        // Get the day of week (1 = Sunday, 2 = Monday, ..., 7 = Saturday)
        Integer dayOfWeek = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(today), 7);

        // Calculate Monday of current week (if today is Sunday, get Monday of previous week)
        Date monday;
        if (dayOfWeek == 1) {
            // Sunday - get Monday of previous week
            monday = today.addDays(-6);
        } else {
            // Monday to Saturday - get Monday of current week
            monday = today.addDays(-(dayOfWeek - 2));
        }

        // Calculate Sunday of current week
        Date sunday = monday.addDays(6);

        // Execute the batch for the current week; the batch shrinks its own scope size if it retries
        SLO_SelloutInvoiceReviewBatch batch = new SLO_SelloutInvoiceReviewBatch(monday, sunday);
        Database.executeBatch(batch, SLO_SelloutInvoiceReviewBatch.scopeSizeForAttempt(1));
    }
}