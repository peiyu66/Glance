#!/usr/bin/env python3
"""Validate the single Build47 status file before displaying an allowlisted summary."""
from pathlib import Path
import argparse,json,sys,uuid

REASONS = {'ready','saved-session-missing','selected-account-missing','selected-account-not-found','tokens-missing',
'access-expiry-invalid','access-expired-refresh-disabled','access-expiring-refresh-disabled','plan-scope-missing',
'account-changed','keychain-interaction-unavailable','keychain-access-denied','keychain-entitlement-missing',
'keychain-service-unavailable','keychain-other-status','session-data-missing','session-decode-failed','session-read-failed'}
ROOT = {'diagnosticRevision','appBuild','runID','phase','networkRequests','modelRequests','refreshes','newLogins','credentialExports','historyOpened','modelPermitOpened','diagnostic','recordedUTC'}
DIAG = {'phase','errorCategory','readinessStage','readinessReason','refreshPolicy','keychainStatus','refreshCredentialPresent','planScopePresent','accessLifetimeBand','catalogRequestStarted'}

def validate(raw, expected_run):
    assert len(raw) <= 8192
    value=json.loads(raw)
    assert isinstance(value,dict) and set(value)==ROOT
    assert value['diagnosticRevision']=='readiness-v1' and value['appBuild']=='47'
    assert uuid.UUID(value['runID'])==uuid.UUID(expected_run)
    assert value['phase'] in {'readiness-ready','readiness-failed'}
    for key in ['networkRequests','modelRequests','refreshes','newLogins','credentialExports']:
        assert type(value[key]) is int and value[key]==0
    assert value['historyOpened'] is False and value['modelPermitOpened'] is False
    d=value['diagnostic'];assert isinstance(d,dict) and set(d)<=DIAG
    assert d['readinessStage']=='local-preflight' and d['readinessReason'] in REASONS
    assert (value['phase']=='readiness-ready') == (d['readinessReason']=='ready')
    assert d['refreshPolicy']=='disabled-for-trial' and d['catalogRequestStarted'] is False
    if 'phase' in d:assert d['phase']=='stopped'
    if 'errorCategory' in d:assert d['errorCategory']=='local-readiness'
    if 'keychainStatus' in d:assert type(d['keychainStatus']) is int and -(2**31)<=d['keychainStatus']<2**31
    for key in ['refreshCredentialPresent','planScopePresent']:
        if key in d:assert type(d[key]) is bool
    if 'accessLifetimeBand' in d:assert d['accessLifetimeBand'] in {'expired','within-60-seconds','over-60-seconds'}
    # Do not display arbitrary text, timestamps, paths, identities, or unexpected fields.
    return dict(build='47',runID=str(uuid.UUID(expected_run)).upper(),phase=value['phase'],diagnostic=d,networkRequests=0,modelRequests=0,refreshes=0,newLogins=0,credentialExports=0)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('file',type=Path);parser.add_argument('--run-id',required=True);args=parser.parse_args()
    try:
        assert not args.file.is_symlink() and args.file.is_file() and args.file.stat().st_size<=8192
        result=validate(args.file.read_bytes(),args.run_id)
    except Exception:
        print('Status file rejected or incomplete; no contents displayed.',file=sys.stderr);return 2
    print(json.dumps(result,ensure_ascii=False,indent=2));return 0
if __name__=='__main__':sys.exit(main())
