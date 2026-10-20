#!/usr/bin/env python3
"""Display only fixed Build48 progress and safe causes from one approved run."""
from pathlib import Path
import argparse,json,sys,uuid
IDS=[152,153,149,147]
PHASES={'permit','account','request','completed','failed','cancelled','timeout','background'}
STAGES={'readiness','discovery','claim','refresh','decode','jwks','identity','save','ready'}
READINESS={'checking','ready','saved-session-missing','selected-account-missing','selected-account-not-found','tokens-missing','access-expiry-invalid','access-expired-after-session-update','access-expiring-after-session-update','plan-scope-missing','account-changed','keychain-interaction-unavailable','keychain-access-denied','keychain-entitlement-missing','keychain-service-unavailable','keychain-other-status','session-data-missing','session-decode-failed','session-read-failed'}
UPDATE={'refresh-credential-missing','refresh-not-yet-allowed','replacement-refresh-missing','session-save-failed','cancelled'}|{'session-update-'+s+'-failed' for s in STAGES}
CODES={'invalid_grant','invalid_refresh_token','token_expired','refresh_token_expired','refresh_token_invalidated','refresh_token_reused','invalid_client','invalid_request_error','unsupported_parameter','invalid_value','unsupported_value','rate_limit_exceeded','insufficient_quota','model_not_found','invalid_api_key','server_error','subscription_sharing_usage_limit_exceeded','unrecognized_error'}

def validate(raw,run):
    assert len(raw)<=131072
    v=json.loads(raw);assert v['appBuild']=='48' and v['trialRevision']=='W1-text-trial-refresh-v2'
    assert uuid.UUID(v['runID'])==uuid.UUID(run) and v['phase'] in PHASES
    for k,n in [('maximumRequests',4),('maximumOutputTokensPerRequest',8192),('maximumRefreshRequests',1),('automaticRetries',0),('imageRequests',0),('cameraStarts',0),('credentialExports',0),('newLogins',0)]:assert type(v[k]) is int and v[k]==n
    assert v['ordinaryHistoryOpened'] is False and v['globalConsentChanged'] is False
    for k in ['claims','submitted','finished']:
        assert type(v[k]) is list and len(v[k])<=4 and v[k]==IDS[:len(v[k])]
    assert len(v['finished'])<=len(v['submitted'])<=len(v['claims'])
    assert type(v['refreshClaimed']) is bool
    assert type(v['refreshRequests']) is int and 0<=v['refreshRequests']<=1
    assert type(v['refreshes']) is int and 0<=v['refreshes']<=v['refreshRequests']
    assert not v['refreshRequests'] or v['refreshClaimed']
    assert type(v['completed']) is bool and v['completed']==(v['phase']=='completed')
    if v['completed']:assert v['finished']==IDS
    d=v['diagnostic'];assert type(d) is dict
    safe={}
    for k,allowed in [('readinessReason',READINESS),('sessionUpdateStage',STAGES),('sessionUpdateReason',UPDATE)]:
        if k in d:assert d[k] in allowed;safe[k]=d[k]
    for k in ['catalogRequestStarted','sessionUpdateFailed','rotatedSessionPersisted','refreshOutcomeMayBeUncertain']:
        if k in d:assert type(d[k]) is bool;safe[k]=d[k]
    for k in ['keychainStatus','keychainWriteStatus']:
        if k in d:assert type(d[k]) is int and -(2**31)<=d[k]<2**31;safe[k]=d[k]
    if 'httpStatus' in d:assert type(d['httpStatus']) is int and 100<=d['httpStatus']<=599;safe['httpStatus']=d['httpStatus']
    if 'errorCode' in d:safe['errorCode']=d['errorCode'] if d['errorCode'] in CODES else 'unrecognized_error'
    if 'errorParameter' in d:safe['errorParameter']=d['errorParameter'] if d['errorParameter'] in {'max_output_tokens','model','input'} else 'unrecognized_parameter'
    # Never emit arbitrary fields/text, identities, URLs, response contents or timestamps.
    return {'build':'48','runID':str(uuid.UUID(run)).upper(),'phase':v['phase'],'final':v['phase'] in {'completed','failed','cancelled','timeout','background'},'submitted':v['submitted'],'finished':v['finished'],'refreshRequests':v['refreshRequests'],'refreshes':v['refreshes'],'diagnostic':safe}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('file',type=Path);p.add_argument('--run-id',required=True);a=p.parse_args()
    try:
        assert a.file.is_file() and not a.file.is_symlink() and a.file.stat().st_size<=131072
        result=validate(a.file.read_bytes(),a.run_id)
    except Exception:print('Summary rejected or incomplete; no contents displayed.',file=sys.stderr);return 2
    print(json.dumps(result,ensure_ascii=False,indent=2));return 0
if __name__=='__main__':sys.exit(main())
