import { LightningElement, api, wire, track } from 'lwc';
import getEmailsByCategory from '@salesforce/apex/AdminDashboardController.getEmailsByCategory';

const COLUMNS = [
    { label: 'Subject', fieldName: 'subject', type: 'text', wrapText: true },
    { label: 'From', fieldName: 'fromAddress', type: 'text' },
    { label: 'Date', fieldName: 'messageDate', type: 'date',
      typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
    { label: 'Status', fieldName: 'worstStatus', type: 'text' },
    { label: 'Recipients', fieldName: 'recipientCount', type: 'number',
      cellAttributes: { alignment: 'left' } }
];

export default class EmailCategoryView extends LightningElement {
    @api category;
    @track startDate = null;
    @track endDate = null;
    @track recipient = null;
    pageSize = 50;
    pageOffset = 0;

    columns = COLUMNS;

    @wire(getEmailsByCategory, {
        category: '$category',
        startDate: '$startDate',
        endDate: '$endDate',
        pageSize: '$pageSize',
        pageOffset: '$pageOffset'
    })
    wiredRows;

    get rows() {
        const data = this.wiredRows && this.wiredRows.data;
        if (!data) return [];
        const filter = (this.recipient || '').trim().toLowerCase();
        return data
            .filter((r) => {
                if (!filter) return true;
                return (r.deliveryEntries || []).some(
                    (d) => d.recipient && d.recipient.toLowerCase().includes(filter)
                );
            })
            .map((r) => ({
                ...r,
                recipientCount: (r.deliveryEntries || []).length
            }));
    }

    get isLoading() {
        return !this.wiredRows || (!this.wiredRows.data && !this.wiredRows.error);
    }

    get errorMessage() {
        const err = this.wiredRows && this.wiredRows.error;
        if (!err) return null;
        return (err.body && err.body.message) || err.message || 'Unknown error loading emails';
    }

    get hasNoRows() {
        return !this.isLoading && !this.errorMessage && this.rows.length === 0;
    }

    handleFilterChange(event) {
        const detail = event.detail || {};
        this.startDate = detail.startDate || null;
        this.endDate = detail.endDate || null;
        this.recipient = detail.recipient || null;
        this.pageOffset = 0;
    }
}
