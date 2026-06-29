import { LightningElement, api } from 'lwc';

const STATUS_META = {
    Delivered: { icon: 'utility:success', variant: 'success', label: 'Delivered' },
    Bounced:   { icon: 'utility:close',   variant: 'error',   label: 'Bounced' },
    Deferred:  { icon: 'utility:clock',   variant: 'warning', label: 'Deferred' },
    Pending:   { icon: 'utility:routing_offline', variant: 'inverse', label: 'Pending' }
};

export default class DeliveryStatusBadge extends LightningElement {
    @api status;
    @api recipient;

    get meta() {
        return STATUS_META[this.status] || STATUS_META.Pending;
    }
    get displayLabel() {
        return this.recipient ? `${this.meta.label} — ${this.recipient}` : this.meta.label;
    }
}
