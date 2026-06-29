import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getOrgInfo         from '@salesforce/apex/ConfiguratorController.getOrgInfo';
import verifyRemoteSites  from '@salesforce/apex/ConfiguratorController.verifyRemoteSites';
import getRemoteSiteSetupUrl from '@salesforce/apex/ConfiguratorController.getRemoteSiteSetupUrl';
import enqueueRemoteSiteDeployment from '@salesforce/apex/ConfiguratorController.enqueueRemoteSiteDeployment';

/**
 * emailLogConfigurator — Two-step setup wizard with Claude-inspired
 * "thinking" streaming analysis UI.
 *
 * Step 1: Detect org environment → verify Remote Site Settings
 * Step 2: Embed the schedule / automation configuration panel
 */
export default class EmailLogConfigurator extends LightningElement {

    // ─── Reactive State ─────────────────────────────────────────
    @track currentStep      = 1;
    @track thinkingLines    = [];
    @track remoteSites      = [];
    @track isAnalyzing      = true;
    @track analysisComplete = false;
    @track allSitesVerified = false;
    @track isDeploying      = false;

    setupUrl = '';
    _lineId  = 0;
    _pollIntervalId;

    // ─── Computed Properties (Stepper) ──────────────────────────

    get currentStepString() {
        return this.currentStep.toString();
    }

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }

    get step1Complete() { return this.currentStep > 1; }

    get step1Class() {
        if (this.currentStep > 1)  return 'step step--complete';
        if (this.currentStep === 1) return 'step step--active';
        return 'step';
    }

    get step2Class() {
        if (this.currentStep === 2) return 'step step--active';
        return 'step';
    }

    get stepperFillStyle() {
        return `width: ${this.currentStep >= 2 ? '100' : '0'}%`;
    }

    get gradientBarClass() {
        if (this.isDeploying) {
            return 'thinking-progress-bar';
        }
        if (!this.isAnalyzing) {
            if (this.allSitesVerified) {
                return 'thinking-progress-bar thinking-progress-bar--done';
            }
            if (this.analysisComplete) {
                return 'thinking-progress-bar thinking-progress-bar--warning';
            }
        }
        return 'thinking-progress-bar';
    }

    get hasMissingSites() {
        return this.remoteSites.some(s => s.status === 'missing');
    }

    get deployButtonLabel() {
        return this.isDeploying ? 'Deploying...' : 'Deploy Missing Settings';
    }

    // ─── Lifecycle ──────────────────────────────────────────────

    connectedCallback() {
        this.runAnalysis();
    }

    disconnectedCallback() {
        if (this._pollIntervalId) {
            clearInterval(this._pollIntervalId);
        }
    }

    // ─── Analysis Pipeline ──────────────────────────────────────

    async runAnalysis(silent = false) {
        if (!silent) {
            this.isAnalyzing      = true;
            this.analysisComplete = false;
            this.allSitesVerified = false;
            this.thinkingLines    = [];
            this._lineId          = 0;

            await this.addLine('info', 'Starting org environment analysis...');
            await this.sleep(400);
        }

        try {
            if (!silent) {
                const info = await getOrgInfo();

                await this.addLine('detail', `Connected to: ${info.orgName}`);
                await this.addLine('detail', `Instance URL: ${info.instanceUrl}`);
                await this.addLine('detail', `Setup Domain: ${info.setupUrl}`);

                await this.addLine('spacer');
                await this.addLine('info', 'Verifying Remote Site Settings...');
                await this.addLine('detail', 'Probing endpoints for authorization status...');
            }

            const results = await verifyRemoteSites();

            // Map results to UI model
            this.remoteSites = results.map(r => ({
                ...r,
                cardClass:   `site-card site-card--${r.status}`,
                statusLabel: r.status === 'active' ? 'Verified' : 'Not Configured',
                badgeClass:  r.status === 'active' ? 'slds-badge slds-theme_success' : 'slds-badge slds-theme_error',
                iconName:    r.status === 'active' ? 'utility:success' : 'utility:warning',
                iconVariant: r.status === 'active' ? 'success' : 'warning'
            }));

            // Stream verification results one by one
            let verified = 0;
            for (const site of results) {
                if (!silent) await this.sleep(300);
                if (site.status === 'active') {
                    verified++;
                    if (!silent) await this.addLine('success', `${site.name} — Verified`);
                } else {
                    if (!silent) await this.addLine('error', `${site.name} — Not Configured`);
                }
            }

            this.allSitesVerified = verified === results.length;

            if (!silent) {
                await this.addLine('spacer');
                if (this.allSitesVerified) {
                    await this.addLine('summary-success', `All ${results.length} Remote Site Settings verified successfully.`);
                    await this.addLine('action', 'Ready to proceed to schedule configuration.');
                } else {
                    await this.addLine('summary-warning', `${verified}/${results.length} Remote Site Settings verified. Action required.`);
                    await this.addLine('action', 'Click Deploy Missing Settings to automatically create them.');
                }
            }

            // If polling and we just verified everything, stop polling
            if (silent && this.allSitesVerified && this.isDeploying) {
                this.stopPollingAndCompleteDeploy();
            }

        } catch (err) {
            if (!silent) {
                const msg = err?.body?.message || err?.message || 'Unknown error';
                await this.addLine('error', `Analysis failed: ${msg}`);
            }
        }

        if (!silent) {
            this.isAnalyzing      = false;
            this.analysisComplete = true;
        }

        // Pre-fetch setup URL
        try {
            this.setupUrl = await getRemoteSiteSetupUrl();
        } catch (_e) { /* non-critical */ }
    }

    // ─── Deployment & Polling ───────────────────────────────────

    async handleDeploySettings() {
        this.isDeploying = true;
        await this.addLine('spacer');
        await this.addLine('info', 'Enqueueing deployment of missing Remote Site Settings...');
        
        try {
            // Get missing sites to pass to the queueable
            const missing = this.remoteSites.filter(s => s.status === 'missing');
            const jobId = await enqueueRemoteSiteDeployment({ missingSites: missing });
            
            await this.addLine('detail', `Queueable Job ID: ${jobId}`);
            await this.addLine('action', 'Polling for deployment completion...');
            
            this.startPolling();
        } catch (err) {
            this.isDeploying = false;
            const msg = err?.body?.message || err?.message || 'Unknown error';
            await this.addLine('error', `Deployment failed to enqueue: ${msg}`);
            this.toast('Deployment Error', msg, 'error');
        }
    }

    startPolling() {
        if (this._pollIntervalId) clearInterval(this._pollIntervalId);
        
        this._pollIntervalId = setInterval(() => {
            this.runAnalysis(true); // silent run
        }, 3000);
    }

    async stopPollingAndCompleteDeploy() {
        clearInterval(this._pollIntervalId);
        this._pollIntervalId = null;
        this.isDeploying = false;
        
        await this.addLine('success', 'Deployment successful. All remote sites are active.');
        await this.addLine('action', 'Proceeding to Schedule setup...');
        this.toast('Success', 'Remote Site Settings deployed successfully.', 'success');
        
        await this.sleep(1500);
        this.handleNextStep();
    }

    // ─── Line Helpers ───────────────────────────────────────────

    async addLine(type, text) {
        this._lineId++;
        const isSpacer = type === 'spacer';

        let iconName = '';
        let iconVariant = '';
        switch(type) {
            case 'info': iconName = 'utility:info'; iconVariant = 'info'; break;
            case 'detail': iconName = 'utility:chevronright'; iconVariant = 'base'; break;
            case 'success': iconName = 'utility:success'; iconVariant = 'success'; break;
            case 'error': iconName = 'utility:error'; iconVariant = 'error'; break;
            case 'summary-success': iconName = 'utility:check'; iconVariant = 'success'; break;
            case 'summary-warning': iconName = 'utility:warning'; iconVariant = 'warning'; break;
            case 'action': iconName = 'utility:forward'; iconVariant = 'base'; break;
            default: iconName = 'utility:info'; iconVariant = 'base';
        }

        this.thinkingLines = [
            ...this.thinkingLines,
            {
                id:        `ln-${this._lineId}`,
                text:      text || '',
                type,
                isSpacer,
                lineClass: isSpacer ? '' : `thinking-line thinking-line--${type}`,
                iconClass: isSpacer ? '' : `line-icon line-icon--${type}`,
                iconName:  isSpacer ? '' : iconName,
                iconVariant: isSpacer ? '' : iconVariant
            }
        ];

        // Give the DOM a paint frame, then auto-scroll
        await this.sleep(30);
        this.scrollThinkingBody();
    }

    scrollThinkingBody() {
        const body = this.template.querySelector('.thinking-body');
        if (body) {
            body.scrollTop = body.scrollHeight;
        }
    }

    // ─── Navigation ─────────────────────────────────────────────

    handleNextStep() {
        this.currentStep = 2;
    }

    handleBackStep() {
        this.currentStep = 1;
    }

    handleOpenSetup() {
        if (this.setupUrl) {
            window.open(this.setupUrl, '_blank', 'noopener');
        }
    }

    handleRecheck() {
        this.runAnalysis();
    }

    // ─── Utilities ──────────────────────────────────────────────

    sleep(ms) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
