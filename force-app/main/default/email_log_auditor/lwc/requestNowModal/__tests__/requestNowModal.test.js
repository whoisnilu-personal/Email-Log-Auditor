import { createElement } from 'lwc';
import RequestNowModal from 'c/requestNowModal';

// Helper: create and mount the component
function mountModal(props = {}) {
    const element = createElement('c-request-now-modal', { is: RequestNowModal });
    Object.assign(element, props);
    document.body.appendChild(element);
    return element;
}

// Helper: set a lightning-input value and fire the change event
async function setInputValue(element, dataField, value) {
    const input = element.shadowRoot.querySelector(`lightning-input[data-field="${dataField}"]`);
    if (!input) throw new Error(`lightning-input[data-field="${dataField}"] not found`);
    input.value = value;
    input.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    await Promise.resolve();
}

// Helper: set a lightning-combobox value
async function setComboboxValue(element, dataField, value) {
    const cb = element.shadowRoot.querySelector(`lightning-combobox[data-field="${dataField}"]`);
    if (!cb) throw new Error(`lightning-combobox[data-field="${dataField}"] not found`);
    cb.value = value;
    cb.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    await Promise.resolve();
}

describe('c-request-now-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // T036 — end before start shows validation error and disables Confirm ──
    it('T036: shows validation error and disables Confirm when end is before start', async () => {
        const element = mountModal({ defaultDirection: 'Outbound' });
        await Promise.resolve();

        const todayIso   = new Date().toISOString().split('T')[0];          // today
        const yesterdayIso = new Date(Date.now() - 86400000).toISOString().split('T')[0]; // yesterday

        // Set start = today, end = yesterday (end < start)
        await setInputValue(element, 'startDate', todayIso);
        await setInputValue(element, 'endDate', yesterdayIso);
        await Promise.resolve();

        const confirmBtn = element.shadowRoot.querySelector('[data-id="confirm-btn"]');
        const errorEl    = element.shadowRoot.querySelector('[data-id="validation-error"]');

        expect(confirmBtn.disabled).toBe(true);
        expect(errorEl).not.toBeNull();
        expect(errorEl.textContent.length).toBeGreaterThan(0);
    });

    // T037 — start > 30 days ago shows validation error ───────────────────
    it('T037: shows validation error when start date is more than 30 days ago', async () => {
        const element = mountModal({ defaultDirection: 'Outbound' });
        await Promise.resolve();

        const staleDate = new Date(Date.now() - 35 * 86400000).toISOString().split('T')[0]; // 35 days ago
        const todayIso  = new Date().toISOString().split('T')[0];

        await setInputValue(element, 'startDate', staleDate);
        await setInputValue(element, 'endDate', todayIso);
        await Promise.resolve();

        const confirmBtn = element.shadowRoot.querySelector('[data-id="confirm-btn"]');
        const errorEl    = element.shadowRoot.querySelector('[data-id="validation-error"]');

        expect(confirmBtn.disabled).toBe(true);
        expect(errorEl).not.toBeNull();
        expect(errorEl.textContent.toLowerCase()).toMatch(/30/);
    });

    // T038 — valid inputs fire confirm event with correct payload ──────────
    it('T038: fires confirm event with {startIso, endIso, direction} on valid submit', async () => {
        const element = mountModal({ defaultDirection: 'Outbound' });
        await Promise.resolve();

        const yesterdayIso = new Date(Date.now() - 86400000).toISOString().split('T')[0];
        const todayIso     = new Date().toISOString().split('T')[0];

        await setInputValue(element, 'startDate', yesterdayIso);
        await setInputValue(element, 'startTime', '00:00');
        await setInputValue(element, 'endDate', todayIso);
        await setInputValue(element, 'endTime', '00:00');
        await setComboboxValue(element, 'direction', 'Outbound');
        await Promise.resolve();

        const confirmHandler = jest.fn();
        element.addEventListener('confirm', confirmHandler);

        const confirmBtn = element.shadowRoot.querySelector('[data-id="confirm-btn"]');
        expect(confirmBtn.disabled).toBe(false);
        confirmBtn.click();
        await Promise.resolve();

        expect(confirmHandler).toHaveBeenCalledTimes(1);
        const detail = confirmHandler.mock.calls[0][0].detail;
        expect(detail).toHaveProperty('startIso');
        expect(detail).toHaveProperty('endIso');
        expect(detail).toHaveProperty('direction', 'Outbound');
        // startIso must be before endIso
        expect(new Date(detail.startIso).getTime()).toBeLessThan(new Date(detail.endIso).getTime());
    });
});
