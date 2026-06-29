import { createElement } from 'lwc';
import LogManagementPanel from 'c/logManagementPanel';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import getCachedLogs from '@salesforce/apex/LogManagementController.getCachedLogs';
import deleteLogFile from '@salesforce/apex/LogManagementController.deleteLogFile';
import retryProcessing from '@salesforce/apex/LogManagementController.retryProcessing';

jest.mock('@salesforce/apex/LogManagementController.deleteLogFile',
    () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/LogManagementController.retryProcessing',
    () => ({ default: jest.fn() }), { virtual: true });

const getCachedLogsAdapter = registerApexTestWireAdapter(getCachedLogs);

// T052 — row with processingStatus = 'Requested'
const ROWS_WITH_REQUESTED = [
    {
        id: '001',
        label: 'ReqLog',
        direction: 'Outbound',
        processingStatus: 'Requested',
        downloadedDate: null,
        rowCount: null,
        matchCount: null,
        errorCount: null,
        canRetry: false,
        requestedStartDate: '2025-01-01',
        requestedEndDate: '2025-01-02'
    }
];

// T053 — row with processingStatus = 'RequestTimedOut'
const ROWS_WITH_TIMED_OUT = [
    {
        id: '002',
        label: 'TimedOutLog',
        direction: 'Outbound',
        processingStatus: 'RequestTimedOut',
        downloadedDate: null,
        rowCount: null,
        matchCount: null,
        errorCount: null,
        canRetry: true,
        requestedStartDate: '2025-01-01',
        requestedEndDate: '2025-01-02'
    }
];

describe('c-log-management-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    // T052 — Requested row renders and has no Retry action ──────────────
    it('T052: renders Requested status and Retry is disabled for Requested rows', async () => {
        const element = createElement('c-log-management-panel', { is: LogManagementPanel });
        document.body.appendChild(element);

        // Emit wire data
        getCachedLogsAdapter.emit(ROWS_WITH_REQUESTED);
        await Promise.resolve();

        // The datatable should exist and carry the data
        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        expect(datatable).not.toBeNull();

        const rows = datatable.data;
        expect(rows).toBeDefined();
        const reqRow = rows.find(r => r.processingStatus === 'Requested');
        expect(reqRow).toBeDefined();

        // canRetry = false → retryDisabled = true for Requested row
        expect(reqRow.retryDisabled).toBe(true);
    });

    // T053 — RequestTimedOut row renders and Retry is enabled ────────────
    it('T053: renders RequestTimedOut status and Retry is enabled for timed-out rows', async () => {
        const element = createElement('c-log-management-panel', { is: LogManagementPanel });
        document.body.appendChild(element);

        getCachedLogsAdapter.emit(ROWS_WITH_TIMED_OUT);
        await Promise.resolve();

        const datatable = element.shadowRoot.querySelector('lightning-datatable');
        expect(datatable).not.toBeNull();

        const rows = datatable.data;
        const timedOutRow = rows.find(r => r.processingStatus === 'RequestTimedOut');
        expect(timedOutRow).toBeDefined();

        // canRetry = true → retryDisabled = false
        expect(timedOutRow.retryDisabled).toBe(false);

        // requestedStartDate must propagate through
        expect(timedOutRow.requestedStartDate).toBe('2025-01-01');
    });
});
