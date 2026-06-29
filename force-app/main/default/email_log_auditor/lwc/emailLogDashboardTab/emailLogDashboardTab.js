import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import runDownloadNow from '@salesforce/apex/ScheduleConfigController.runDownloadNow';

/**
 * emailLogDashboardTab — Standalone tab wrapper that hosts the
 * email delivery dashboard and log management components.
 */
export default class EmailLogDashboardTab extends LightningElement {
    isRunning = false;

    async handleDownloadNow() {
        if (this.isRunning) return;
        this.isRunning = true;
        try {
            const result = await runDownloadNow();
            this.dispatchEvent(new ShowToastEvent({
                title: 'Download triggered',
                message: result || 'Email log download started',
                variant: 'success'
            }));
        } catch (err) {
            const msg = err?.body?.message || err?.message || 'Unknown error';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Download failed',
                message: msg,
                variant: 'error'
            }));
        } finally {
            this.isRunning = false;
        }
    }
}
