import { createElement } from 'lwc';
import ScheduleConfigPanel from 'c/scheduleConfigPanel';
import getScheduleConfig from '@salesforce/apex/ScheduleConfigController.getScheduleConfig';
import getJobHistory from '@salesforce/apex/ScheduleConfigController.getJobHistory';
import saveScheduleConfig from '@salesforce/apex/ScheduleConfigController.saveScheduleConfig';
import runDownloadNow from '@salesforce/apex/ScheduleConfigController.runDownloadNow';
import requestNow from '@salesforce/apex/ScheduleConfigController.requestNow';

// Mock all Apex imports
jest.mock('@salesforce/apex/ScheduleConfigController.getScheduleConfig',
    () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ScheduleConfigController.getJobHistory',
    () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ScheduleConfigController.saveScheduleConfig',
    () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ScheduleConfigController.runDownloadNow',
    () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ScheduleConfigController.requestNow',
    () => ({ default: jest.fn() }), { virtual: true });

// Config with PreviousDay request mode
const MOCK_CONFIG_PREVIOUS_DAY = {
    isEnabled: true,
    frequency: 'Daily',
    runTime: '02:00',
    dayOfWeek: 'Monday',
    batchSize: 200,
    lastRunDatetime: null,
    nextRunDatetime: null,
    requestMode: 'PreviousDay',
    requestWindowHours: 24,
    requestDirection: 'Outbound',
    requestEmailFilter: null,
    requestTimeoutHours: 2
};

describe('c-schedule-config-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // T039 — Auto-Request section renders when config includes requestMode ─
    it('T039: renders Auto-Request accordion section and Request Now button', async () => {
        getScheduleConfig.mockResolvedValue(MOCK_CONFIG_PREVIOUS_DAY);
        getJobHistory.mockResolvedValue([]);

        const element = createElement('c-schedule-config-panel', { is: ScheduleConfigPanel });
        document.body.appendChild(element);

        // Allow wire adapter to resolve
        await Promise.resolve();
        await Promise.resolve();

        // Auto-Request section must exist (any container with the label or data-id)
        const autoRequestSection =
            element.shadowRoot.querySelector('[data-section="auto-request"]') ||
            element.shadowRoot.querySelector('lightning-accordion-section[name="autoRequest"]');
        expect(autoRequestSection).not.toBeNull();

        // Request Now button must be present
        const requestNowBtn =
            element.shadowRoot.querySelector('[data-id="request-now-btn"]') ||
            element.shadowRoot.querySelector('lightning-button[data-action="requestNow"]');
        expect(requestNowBtn).not.toBeNull();
    });
});
