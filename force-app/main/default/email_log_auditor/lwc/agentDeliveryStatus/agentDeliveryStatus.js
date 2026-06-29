import { LightningElement, api, wire, track } from 'lwc';
import getDeliveryStatusForRecord
    from '@salesforce/apex/AgentDeliveryStatusController.getDeliveryStatusForRecord';

export default class AgentDeliveryStatus extends LightningElement {
    @api recordId;
    @api objectApiName;
    @track expandedKey;

    @wire(getDeliveryStatusForRecord, { recordId: '$recordId', objectApiName: '$objectApiName' })
    wiredRows;

    get rows() {
        const data = this.wiredRows && this.wiredRows.data;
        if (!data) return [];
        return data.map((r) => ({
            ...r,
            entries: (r.deliveryEntries || []).map((e, idx) => ({
                ...e,
                key: `${r.id}-${idx}`,
                isExpanded: this.expandedKey === `${r.id}-${idx}`
            })),
            placeholderText: r.hasDeliveryData ? null : 'Pending — no delivery data yet'
        }));
    }

    get isLoading() {
        return !this.wiredRows || (!this.wiredRows.data && !this.wiredRows.error);
    }

    get errorMessage() {
        const err = this.wiredRows && this.wiredRows.error;
        if (!err) return null;
        return (err.body && err.body.message) || err.message || 'Unable to load delivery status';
    }

    get hasNoRows() {
        return !this.isLoading && !this.errorMessage && this.rows.length === 0;
    }

    handleBadgeClick(event) {
        const key = event.currentTarget.dataset.key;
        this.expandedKey = (this.expandedKey === key) ? null : key;
    }
}
