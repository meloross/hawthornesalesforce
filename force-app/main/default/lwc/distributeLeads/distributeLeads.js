import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import scanPool from '@salesforce/apex/LeadDistributionManager.scanPool';
import distribute from '@salesforce/apex/LeadDistributionManager.distribute';

const MODE_NUMBER = 'NUMBER';
const MODE_PERCENT = 'PERCENT';

export default class DistributeLeads extends LightningElement {
    loading = false;
    working = false;
    poolTotal = 0;
    maxPerRun = 0;
    mode = MODE_NUMBER;
    @track offices = []; // { code, label, queueResolved, value }
    error;
    confirming = false;
    @track plan = []; // { code, label, target }
    result; // DistributeResult

    connectedCallback() {
        this.loadScan();
    }

    // ---------- data ----------
    loadScan() {
        this.loading = true;
        this.error = undefined;
        scanPool()
            .then((s) => {
                this.poolTotal = s.total;
                this.maxPerRun = s.maxPerRun;
                this.offices = (s.offices || []).map((o) => ({
                    code: o.code,
                    label: o.label,
                    queueResolved: o.queueResolved,
                    value: ''
                }));
            })
            .catch((e) => {
                this.error = this.reduceError(e);
            })
            .finally(() => {
                this.loading = false;
            });
    }

    handleRefresh() {
        this.confirming = false;
        this.result = undefined;
        this.loadScan();
    }

    // ---------- mode + inputs ----------
    get modeOptions() {
        return [
            { label: 'By number', value: MODE_NUMBER },
            { label: 'By percent', value: MODE_PERCENT }
        ];
    }
    get isPercent() {
        return this.mode === MODE_PERCENT;
    }
    get inputLabel() {
        return this.isPercent ? 'Percent (%)' : 'Number of leads';
    }
    get inputStep() {
        return this.isPercent ? '0.01' : '1';
    }

    handleModeChange(e) {
        this.mode = e.detail.value;
        this.result = undefined;
        this.confirming = false;
    }

    handleValueChange(e) {
        const code = e.target.dataset.code;
        const val = e.target.value;
        this.offices = this.offices.map((o) => (o.code === code ? { ...o, value: val } : o));
        this.result = undefined;
        this.confirming = false;
    }

    // ---------- derived / validation ----------
    targetFor(office) {
        const v = Number(office.value) || 0;
        if (v <= 0) return 0;
        return this.isPercent ? Math.floor((v / 100) * this.poolTotal) : Math.floor(v);
    }

    get officeRows() {
        return this.offices.map((o) => ({
            ...o,
            target: this.targetFor(o),
            showTarget: this.isPercent && this.poolTotal > 0,
            disabled: !o.queueResolved
        }));
    }

    get sumEntered() {
        return this.offices.reduce((acc, o) => acc + (Number(o.value) || 0), 0);
    }
    get plannedTotal() {
        return this.offices.reduce((acc, o) => acc + this.targetFor(o), 0);
    }
    get sumLabel() {
        if (this.isPercent) {
            return `Percent allocated: ${this.round2(this.sumEntered)}% · ${this.plannedTotal} lead(s)`;
        }
        return `Leads allocated: ${this.plannedTotal}`;
    }

    get validationMessage() {
        if (this.isPercent && this.sumEntered > 100) {
            return `Percentages add up to ${this.round2(this.sumEntered)}% — they must total 100% or less.`;
        }
        if (!this.isPercent && this.plannedTotal > this.poolTotal) {
            return `Numbers add up to ${this.plannedTotal}, but only ${this.poolTotal} lead(s) are in the pool.`;
        }
        if (this.plannedTotal > this.maxPerRun) {
            return `This run would assign ${this.plannedTotal} leads; the maximum per run is ${this.maxPerRun}. Lower the amounts or run again.`;
        }
        const badOffice = this.offices.find((o) => Number(o.value) > 0 && !o.queueResolved);
        if (badOffice) {
            return `${badOffice.label} has no destination queue configured.`;
        }
        return undefined;
    }
    get hasValidationError() {
        return !!this.validationMessage;
    }

    get disableDistribute() {
        return (
            this.loading ||
            this.working ||
            this.poolTotal === 0 ||
            this.plannedTotal === 0 ||
            this.hasValidationError
        );
    }

    get poolIsEmpty() {
        return !this.loading && this.poolTotal === 0;
    }

    // ---------- review + confirm ----------
    handleReview() {
        if (this.disableDistribute) return;
        this.plan = this.offices
            .map((o) => ({ code: o.code, label: o.label, target: this.targetFor(o) }))
            .filter((p) => p.target > 0);
        this.confirming = true;
    }

    handleCancel() {
        this.confirming = false;
    }

    handleConfirm() {
        const allocations = this.offices
            .filter((o) => Number(o.value) > 0)
            .map((o) => ({ officeCode: o.code, value: Number(o.value) }));

        this.working = true;
        this.error = undefined;
        distribute({ mode: this.mode, allocations })
            .then((res) => {
                this.result = res;
                this.confirming = false;
                if (res.success) {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Leads distributed',
                            message: res.message,
                            variant: 'success'
                        })
                    );
                    // reset inputs + rescan so the pool count reflects the assignment
                    this.offices = this.offices.map((o) => ({ ...o, value: '' }));
                    this.loadScan();
                } else {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Not distributed',
                            message: res.message,
                            variant: 'warning'
                        })
                    );
                }
            })
            .catch((e) => {
                this.error = this.reduceError(e);
            })
            .finally(() => {
                this.working = false;
            });
    }

    handleDismissResult() {
        this.result = undefined;
    }

    // ---------- helpers ----------
    round2(n) {
        return Math.round((Number(n) || 0) * 100) / 100;
    }

    reduceError(e) {
        if (!e) return 'Unknown error';
        if (e.body && e.body.message) return e.body.message;
        if (e.message) return e.message;
        return JSON.stringify(e);
    }

    get resultIsSuccess() {
        return this.result && this.result.success;
    }
    get resultRows() {
        return (this.result && this.result.offices) || [];
    }
    get resultThemeClass() {
        return this.resultIsSuccess
            ? 'slds-box slds-theme_success'
            : 'slds-box slds-theme_warning';
    }
}
