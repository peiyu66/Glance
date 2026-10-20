#!/usr/bin/env python3
"""Inspect fixed Build48 inputs, or stage one short-lived permit after explicit approval.
This tool never contacts a device, a network service, or credential storage.
"""
from pathlib import Path
import argparse, hashlib, json, re, shutil, time, uuid
ROOT = Path(__file__).resolve().parent.parent

def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()

def catalog():
    source = (ROOT / 'App/FixedTextTrialCatalog.swift').read_text()
    assert 'static let build = "48"' in source
    rows = [dict(sequence=int(n), bodySHA256=h, byteCount=int(size)) for n,h,size in re.findall(r'\.init\(sequence: (\d+), bodySHA256: "([0-9a-f]{64})", byteCount: (\d+)\)', source)]
    assert [row['sequence'] for row in rows] == [152,153,149,147]
    return rows

def inspect(folder):
    rows = catalog()
    assert folder.is_dir() and not folder.is_symlink()
    for row in rows:
        path = folder / (str(row['sequence']) + '.json')
        assert path.is_file() and not path.is_symlink()
        raw = path.read_bytes()
        assert len(raw) == row['byteCount'] and hashlib.sha256(raw).hexdigest() == row['bodySHA256'], 'Frozen input changed'
        body = json.loads(raw)
        assert body['max_output_tokens'] == 8192 and body['model'] == 'gpt-6-luna'
        assert body['reasoning'] == {'effort':'none'} and body['stream'] is True and body['store'] is False
        assert all(part['type'] == 'input_text' for item in body['input'] for part in item['content'])
    return rows, hashlib.sha256(encode(rows)).hexdigest()

def make_permit(digest, now):
    return dict(schemaVersion=2, runID=str(uuid.uuid4()).upper(), appBuild='48', catalogSHA256=digest,
                issuedAt=now, expiresAt=now+900, consentRevision='W1-text-trial-refresh-v2',
                allowsFourTextRequests=True, allowsExistingGrantRefresh=True, maximumRefreshRequests=1, maximumRequests=4, maximumOutputTokens=8192)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input-directory', type=Path, required=True)
    p.add_argument('--expected-catalog-sha', required=True, help='Digest from the verified delivery manifest')
    p.add_argument('--approved-four-text-requests', action='store_true', help='Use only after the human approves this exact four-request device run')
    p.add_argument('--approved-existing-grant-refresh', action='store_true', help='Human also approved at most one existing-grant refresh and in-place secure save')
    p.add_argument('--output-directory', type=Path, help='New private local staging folder; never an app container')
    args = p.parse_args()
    rows,digest = inspect(args.input_directory)
    if digest != args.expected_catalog_sha: p.error('Catalog differs from the reviewed delivery')
    if not args.approved_four_text_requests:
        if args.output_directory: p.error('Writing a permit requires approval of this exact run')
        print(json.dumps(dict(inspected=True, catalogSHA256=digest, caseIDs=[r['sequence'] for r in rows], bytes=sum(r['byteCount'] for r in rows), permitCreated=False)))
        return
    if not args.approved_existing_grant_refresh: p.error('The exact run also requires existing-grant refresh approval')
    if not args.output_directory: p.error('Choose a new private staging folder')
    out = args.output_directory
    if out.exists() or out.is_symlink(): p.error('Staging folder already exists; never replace or resume a permit')
    out.mkdir(mode=0o700)
    base = out / 'GlanceTextTrial48'; (base / 'input').mkdir(parents=True, mode=0o700)
    for row in rows: shutil.copyfile(args.input_directory / (str(row['sequence'])+'.json'), base / 'input' / (str(row['sequence'])+'.json'))
    permit = make_permit(digest, time.time()); raw = encode(permit)
    with (base/'permit.json').open('xb') as f: f.write(raw)
    receipt = dict(runID=permit['runID'], permitSHA256=hashlib.sha256(raw).hexdigest(), expiresAt=permit['expiresAt'], catalogSHA256=digest,
                   launchArguments=['--text-trial-run='+permit['runID'], '--text-trial-permit-sha='+hashlib.sha256(raw).hexdigest()], maximumRequests=4,
                   maximumRefreshRequests=1, maximumNetworkRequests=8, maximumOutputTokensPerRequest=8192, model='gpt-6-luna', automaticRetries=0, deviceCommandsExecuted=0)
    with (out/'launch-receipt.json').open('xb') as f: f.write(encode(receipt))
    print(json.dumps(receipt,indent=2))
if __name__ == '__main__': main()
