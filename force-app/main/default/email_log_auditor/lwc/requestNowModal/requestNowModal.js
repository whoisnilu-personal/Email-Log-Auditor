import { LightningElement, api, track } from 'lwc';

const MAX_HISTORY_DAYS = 30;

export default class RequestNowModal extends LightningElement {
    /** Pre-selected direction from parent (e.g. 'Outbound') */
    @api defaultDirection = 'Outbound';

    @track startDate    = '';
    @track startTime    = '00:00';
    @track endDate      = '';
    @track endTime      = '00:00';
    @track direction    = 'Outbound';
    @track emailFilter  = '';
    @track validationError = null;

    directionOptions = [
        { label: 'Outbound', value: 'Outbound' },
        { label: 'Inbound',  value: 'Inbound'  },
        { label: 'Both',     value: 'Both'      }
    ];

    connectedCallback() {
        this.direction = this.defaultDirection || 'Outbound';
        // Default end = today, start = yesterday
        const now  = new Date();
        const yest = new Date(now.getTime() - 86400000);
        this.endDate   = this._toDateStr(now);
        this.startDate = this._toDateStr(yest);
        this._validate();
    }

    // ── getters ───────────────────────────────────────────────────────────
    get isConfirmDisabled() {
        return !!this.validationError || !this.startDate || !this.endDate;
    }

    // ── handlers ──────────────────────────────────────────────────────────
    handleStartDateChange(evt)   { this.startDate   = evt.detail.value; this._validate(); }
    handleStartTimeChange(evt)   { this.startTime   = evt.detail.value; this._validate(); }
    handleEndDateChange(evt)     { this.endDate     = evt.detail.value; this._validate(); }
    handleEndTimeChange(evt)     { this.endTime     = evt.detail.value; this._validate(); }
    handleDirectionChange(evt)   { this.direction   = evt.detail.value; }
    handleEmailFilterChange(evt) { this.emailFilter = evt.detail.value; }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleConfirm() {
        this._validate();
        if (this.validationError) return;

        const startIso = this._buildIso(this.startDate, this.startTime);
        const endIso   = this._buildIso(this.endDate,   this.endTime);

        this.dispatchEvent(new CustomEvent('confirm', {
            detail: {
                startIso,
                endIso,
                direction:   this.direction,
                emailFilter: this.emailFilter || null
            }
        }));
    }

    // ── validation ────────────────────────────────────────────────────────
    _validate() {
        if (!this.startDate || !this.endDate) {
            this.validationError = null; // wait until both filled
            return;
        }

        const startDt = new Date(this._buildIso(this.startDate, this.startTime));
        const endDt   = new Date(this._buildIso(this.endDate,   this.endTime));
        const now     = new Date();
        const oldest  = new Date(now.getTime() - MAX_HISTORY_DAYS * 86400000);

        if (startDt < oldest) {
            this.validationError =
                `Start date must be within the last ${MAX_HISTORY_DAYS} days. ` +
                `Email logs are only available for the past ${MAX_HISTORY_DAYS} days.`;
            return;
        }
        if (endDt <= startDt) {
            this.validationError = 'End date/time must be after start date/time.';
            return;
        }
        this.validationError = null;
    }

    // ── helpers ───────────────────────────────────────────────────────────
    _toDateStr(dt) {
        return dt.toISOString().split('T')[0];
    }

    _buildIso(dateStr, timeStr) {
        const t = timeStr && timeStr.length >= 5 ? timeStr : '00:00';
        return `${dateStr}T${t}:00.000Z`;
    }
}
