import { LightningElement, api, track } from 'lwc';

const STATUS_OPTIONS = [
    { label: 'All', value: '' },
    { label: 'Delivered', value: 'Delivered' },
    { label: 'Bounced', value: 'Bounced' },
    { label: 'Deferred', value: 'Deferred' },
    { label: 'Pending', value: 'Pending' }
];

export default class FilterBar extends LightningElement {
    @api startDate;
    @api endDate;
    @api recipient;
    @api status = '';

    statusOptions = STATUS_OPTIONS;

    handleChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        this[field] = value;
        this.dispatchEvent(new CustomEvent('filterchange', {
            detail: {
                startDate: this.startDate,
                endDate: this.endDate,
                recipient: this.recipient,
                status: this.status
            }
        }));
    }
}
