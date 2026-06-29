import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getScheduleConfig from '@salesforce/apex/ScheduleConfigController.getScheduleConfig';
import getJobHistory from '@salesforce/apex/ScheduleConfigController.getJobHistory';
import saveScheduleConfig from '@salesforce/apex/ScheduleConfigController.saveScheduleConfig';
import applySchedule from '@salesforce/apex/ScheduleConfigController.applySchedule';
import runDownloadNow from '@salesforce/apex/ScheduleConfigController.runDownloadNow';
import requestNow from '@salesforce/apex/ScheduleConfigController.requestNow'; // T048

const FREQUENCY_OPTIONS = [
    { label: 'Minutes', value: 'Minutes' },
    { label: 'Hourly', value: 'Hourly' },
    { label: 'Daily', value: 'Daily' },
    { label: 'Weekly', value: 'Weekly' }
];

const DAY_OPTIONS = [
    { label: 'Monday',    value: 'Monday'    },
    { label: 'Tuesday',   value: 'Tuesday'   },
    { label: 'Wednesday', value: 'Wednesday' },
    { label: 'Thursday',  value: 'Thursday'  },
    { label: 'Friday',    value: 'Friday'    },
    { label: 'Saturday',  value: 'Saturday'  },
    { label: 'Sunday',    value: 'Sunday'    }
];

// Removed unused options

const DIRECTION_OPTIONS = [
    { label: 'Outbound', value: 'Outbound' },
    { label: 'Inbound',  value: 'Inbound'  },
    { label: 'Both',     value: 'Both'     }
];

const HISTORY_COLUMNS = [
    { label: 'Status', fieldName: 'status', type: 'text' },
    { label: 'Started', fieldName: 'createdDate', type: 'date',
      typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
    { label: 'Completed', fieldName: 'completedDate', type: 'date',
      typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
    { label: 'Duration (s)', fieldName: 'durationSeconds', type: 'number' },
    { label: 'Detail', fieldName: 'extendedStatus', type: 'text' }
];

export default class ScheduleConfigPanel extends LightningElement {
    @track config = {};
    @track historyRows = [];
    @track isSaving = false;
    @track isRunning = false;
    @track isRequesting = false;   // T048
    @track showRequestModal = false; // T048

    frequencyOptions = FREQUENCY_OPTIONS;
    dayOptions       = DAY_OPTIONS;
    historyColumns   = HISTORY_COLUMNS;
    directionOptions   = DIRECTION_OPTIONS;

    wiredConfigResult;
    wiredHistoryResult;

    @wire(getScheduleConfig)
    wiredConfig(result) {
        this.wiredConfigResult = result;
        if (result.data) {
            this.config = { ...result.data };
        }
    }

    @wire(getJobHistory, { pageSize: 10 })
    wiredHistory(result) {
        this.wiredHistoryResult = result;
        if (result.data) {
            this.historyRows = result.data;
        }
    }

    get isWeekly() {
        return this.config?.frequency === 'Weekly';
    }

    get isMinutes() {
        return this.config?.frequency === 'Minutes';
    }

    get isDailyOrWeekly() {
        return this.config?.frequency === 'Daily' || this.config?.frequency === 'Weekly';
    }

    // Removed isCustomWindow

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'toggle' || event.target.type === 'checkbox'
            ? event.target.checked
            : event.target.value;
        this.config = { ...this.config, [field]: value };
    }

    async handleSave() {
        this.isSaving = true;
        try {
            await saveScheduleConfig({ configJSON: JSON.stringify(this.config) });
            await applySchedule({ configJSON: JSON.stringify(this.config) });
            this.toast('Saved', 'Schedule configuration saved and jobs scheduled successfully.', 'success');
            await refreshApex(this.wiredConfigResult);
        } catch (err) {
            this.toast('Save failed', this.errorMessage(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDownloadNow() {
        this.isRunning = true;
        try {
            await runDownloadNow();
            this.toast(
                'Download queued',
                `Download job queued successfully. Check job history for progress.`,
                'success'
            );
            // Refresh history after a short delay to catch the queued job
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(async () => {
                await refreshApex(this.wiredHistoryResult);
            }, 3000);
        } catch (err) {
            this.toast('Download failed', this.errorMessage(err), 'error');
        } finally {
            this.isRunning = false;
        }
    }

    // T048 — "Request Now" button opens modal
    handleRequestNow() {
        this.showRequestModal = true;
    }

    handleModalCancel() {
        this.showRequestModal = false;
    }

    async handleModalConfirm(evt) {
        this.showRequestModal = false;
        this.isRequesting = true;
        const { startIso, endIso, direction, emailFilter } = evt.detail;
        const paramsJSON = JSON.stringify({ startIso, endIso, direction, emailFilter });
        try {
            const jobId = await requestNow({ requestParamsJSON: paramsJSON });
            this.toast(
                'Request queued',
                `Log request job queued. Job ID: ${jobId}`,
                'success'
            );
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(async () => {
                await refreshApex(this.wiredHistoryResult);
            }, 3000);
        } catch (err) {
            this.toast('Request failed', this.errorMessage(err), 'error');
        } finally {
            this.isRequesting = false;
        }
    }

    errorMessage(err) {
        return err?.body?.message || err?.message || 'Unknown error';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
