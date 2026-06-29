import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCachedLogs from '@salesforce/apex/LogManagementController.getCachedLogs';
import deleteLogFile from '@salesforce/apex/LogManagementController.deleteLogFile';
import retryProcessing from '@salesforce/apex/LogManagementController.retryProcessing';

const COLUMNS = [
    { label: 'Label', fieldName: 'label', type: 'text' },
    { label: 'Direction', fieldName: 'direction', type: 'text' },
    { label: 'Status', fieldName: 'processingStatus', type: 'text' },
    { label: 'Downloaded', fieldName: 'downloadedDate', type: 'date',
      typeAttributes: { year: 'numeric', month: 'short', day: '2-digit',
                        hour: '2-digit', minute: '2-digit' } },
    // T057 — US3: show requested date range for Requested/RequestTimedOut/RequestFailed rows
    { label: 'Req. Start', fieldName: 'requestedStartDate', type: 'date',
      typeAttributes: { year: 'numeric', month: 'short', day: '2-digit',
                        hour: '2-digit', minute: '2-digit' } },
    { label: 'Req. End', fieldName: 'requestedEndDate', type: 'date',
      typeAttributes: { year: 'numeric', month: 'short', day: '2-digit',
                        hour: '2-digit', minute: '2-digit' } },
    { label: 'Rows', fieldName: 'rowCount', type: 'number',
      cellAttributes: { alignment: 'left' } },
    { label: 'Matched', fieldName: 'matchCount', type: 'number',
      cellAttributes: { alignment: 'left' } },
    { label: 'Errors', fieldName: 'errorCount', type: 'number',
      cellAttributes: { alignment: 'left' } },
    {
        type: 'button',
        label: 'Retry',
        typeAttributes: {
            label: 'Retry',
            name: 'retry',
            variant: 'neutral',
            disabled: { fieldName: 'retryDisabled' }
        }
    },
    {
        type: 'button-icon',
        label: 'Delete',
        typeAttributes: {
            iconName: 'utility:delete',
            name: 'delete',
            variant: 'border-filled',
            alternativeText: 'Delete'
        }
    }
];

const PAGE_SIZE = 20;

export default class LogManagementPanel extends LightningElement {
    columns = COLUMNS;
    @track pageOffset = 0;
    pageSize = PAGE_SIZE;
    wiredResult;

    @wire(getCachedLogs, { pageSize: '$pageSize', pageOffset: '$pageOffset' })
    wiredLogs(result) {
        this.wiredResult = result;
    }

    get rows() {
        const data = this.wiredResult && this.wiredResult.data;
        if (!data) return [];
        return data.map((r) => ({ ...r, retryDisabled: !r.canRetry }));
    }

    get isLoading() {
        return !this.wiredResult || (!this.wiredResult.data && !this.wiredResult.error);
    }

    get errorMessage() {
        const err = this.wiredResult && this.wiredResult.error;
        if (!err) return null;
        return (err.body && err.body.message) || err.message || 'Unable to load cached logs';
    }

    get isPrevDisabled() { return this.pageOffset === 0; }
    get isNextDisabled() { return this.rows.length < this.pageSize; }
    get hasNoRows() {
        return !this.isLoading && !this.errorMessage && this.rows.length === 0;
    }

    handlePrev() {
        this.pageOffset = Math.max(0, this.pageOffset - this.pageSize);
    }

    handleNext() {
        this.pageOffset += this.pageSize;
    }

    async handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;
        if (actionName === 'delete') {
            await this.confirmAndDelete(row);
        } else if (actionName === 'retry') {
            await this.retry(row);
        }
    }

    async confirmAndDelete(row) {
        const ok = await LightningConfirm.open({
            message: `Delete cached log "${row.label}"? This removes the file and cannot be undone.`,
            label: 'Confirm delete',
            theme: 'warning'
        });
        if (!ok) return;
        try {
            await deleteLogFile({ logFileId: row.id });
            this.toast('Deleted', `${row.label} removed`, 'success');
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.toast('Delete failed', this.extractMessage(err), 'error');
        }
    }

    async retry(row) {
        try {
            await retryProcessing({ logFileId: row.id });
            this.toast('Retry queued', `${row.label} re-enqueued for processing`, 'success');
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.toast('Retry failed', this.extractMessage(err), 'error');
        }
    }

    extractMessage(err) {
        return (err && err.body && err.body.message) || (err && err.message) || 'Unknown error';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
