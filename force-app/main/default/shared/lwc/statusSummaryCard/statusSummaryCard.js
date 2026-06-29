import { LightningElement, api } from 'lwc';

export default class StatusSummaryCard extends LightningElement {
    @api label;
    @api count = 0;
    @api iconName = 'utility:email';
    @api variant = 'base';
}
