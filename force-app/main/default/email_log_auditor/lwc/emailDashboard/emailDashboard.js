import { LightningElement, wire } from 'lwc';
import getDeliveryMetrics from '@salesforce/apex/AdminDashboardController.getDeliveryMetrics';

const CATEGORIES = [
    { value: 'PasswordReset', label: 'Password Reset' },
    { value: 'CaseMessage', label: 'Case Message' },
    { value: 'FlowError', label: 'Flow Error' },
    { value: 'PaymentReceipt', label: 'Payment Receipt' },
    { value: 'SystemOther', label: 'System / Other' }
];

export default class EmailDashboard extends LightningElement {
    @wire(getDeliveryMetrics) metrics;

    categories = CATEGORIES;

    get summaryTiles() {
        const m = (this.metrics && this.metrics.data) || {};
        return [
            { key: 'total', label: 'Total Emails', count: m.totalEmails || 0,
              iconName: 'utility:email', variant: 'inverse' },
            { key: 'delivered', label: 'Delivered', count: m.delivered || 0,
              iconName: 'utility:success', variant: 'success' },
            { key: 'bounced', label: 'Bounced', count: m.bounced || 0,
              iconName: 'utility:close', variant: 'error' },
            { key: 'pending', label: 'Pending / Deferred',
              count: (m.pending || 0) + (m.deferred || 0),
              iconName: 'utility:clock', variant: 'warning' }
        ];
    }

    get errorMessage() {
        const err = this.metrics && this.metrics.error;
        if (!err) return null;
        return (err.body && err.body.message) || err.message || 'Unknown error loading metrics';
    }
}
