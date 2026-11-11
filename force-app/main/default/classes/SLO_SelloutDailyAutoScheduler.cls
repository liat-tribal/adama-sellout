/**
 * @description Schedulable that starts the daily automated sellout batch, one account per scope.
 *
 * Usage:
 * - System.schedule('SLO Daily Automated Sellout', SLO_SelloutDailyAutoScheduler.CRON_DAILY_0200, new SLO_SelloutDailyAutoScheduler());
 */
public with sharing class SLO_SelloutDailyAutoScheduler implements Schedulable {

    public static final String CRON_DAILY_0200 = '0 0 2 * * ?';

    /**
     * @description Schedule the daily run at 2 AM
     * @return Scheduled job id
     */
    public static Id scheduleDaily() {
        return System.schedule('SLO Daily Automated Sellout', CRON_DAILY_0200, new SLO_SelloutDailyAutoScheduler());
    }

    /**
     * @description Start the daily batch
     * @param sc SchedulableContext
     */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new SLO_SelloutDailyAutoBatch(), SLO_SelloutDailyAutoBatch.SCOPE_SIZE);
    }
}
