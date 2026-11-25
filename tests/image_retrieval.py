#!/usr/bin/env python3
"""Runs the real offline text-to-image CLI against the synthetic handoff fixtures."""

import argparse
import json
import os
import select
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("engine", type=Path)
parser.add_argument("fixtures", type=Path)
parser.add_argument("projector", type=Path)
args = parser.parse_args()
engine, fixtures, projector = (p.resolve() for p in (args.engine, args.fixtures, args.projector))
cases = json.loads((fixtures/'expected.json').read_text())['image_queries']
with tempfile.TemporaryDirectory(dir='/private/tmp',prefix='lumen-vision-fixture-') as t:
    sandbox=Path(t)
    names = sandbox/'names'
    allowed = names/'allowed'
    outside = names/'outside'
    provider = allowed/'OneDrive'
    denied = allowed/'blocked'
    for directory in (outside,provider,denied):
        directory.mkdir(parents=True)
    for case in cases:
        shutil.copyfile(fixtures/case['file'], allowed/case['file'])
    # One JPEG with identical paint to its PNG sibling temporarily gets its own scope to avoid a legitimate tie.
    jpg = outside/'88aa.jpg'
    subprocess.run(['/usr/bin/sips','-s','format','jpeg',str(fixtures/'93a2.png'),'--out',str(jpg)],check=True,stdout=subprocess.DEVNULL)
    for directory in (provider,denied):
        shutil.copyfile(fixtures/'93a2.png', directory/'456a.png')
    (allowed/'9ff0.png').write_bytes(b'not image pixels')
    (allowed/'900f.png').symlink_to(fixtures/'93a2.png')
    base=[str(engine),'--db',str(sandbox/'private.sqlite3')]
    def run(*args):
        return json.loads(subprocess.check_output(base+list(args),timeout=45))
    def serve():
        return subprocess.Popen(base+['image-serve','--projector',str(projector)],stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE,text=True)
    def query(server,key,q):
        t=time.perf_counter_ns()
        server.stdin.write(json.dumps({'id':key,'query':q,'limit':5},ensure_ascii=False)+'\n')
        server.stdin.flush()
        if not select.select([server.stdout], [], [], 25)[0]:
            raise TimeoutError("image-serve timed out")
        j=json.loads(server.stdout.readline())
        assert j['id']==key and 'hits' in j, j
        return j['hits'],(time.perf_counter_ns()-t)/1e6
    def validate(hit):
        form=run('validate-hit','--kind',hit['kind'],'--availability',hit['availability'],
                 '--document-stamp',hit['document_stamp'],'--matched-by',hit['matched_by'],hit['path'])
        return form['valid']
    run('index','--root',str(names),'--deny',str(denied).upper().replace('/PRIVATE/TMP/', '/private/tmp/'))
    name_before=run('query','88aa.jpg')
    assert name_before[0]['name']=='88aa.jpg'
    assert run('image-scope',str(allowed))['vectors']==0
    batches=[]
    after=[]
    while True:
        b=run('image-index','--projector',str(projector),'--max','2',*after)
        batches.append(b)
        if not b['next_after']: break
        after=['--after',b['next_after']]
    assert sum(b['indexed'] for b in batches)==4, batches
    assert sum(b['skipped'] for b in batches)==1, batches
    reused=run('image-index','--projector',str(projector))
    assert reused['reused']==4,reused
    failed = subprocess.check_output(
        base + ['image-serve', '--projector', str(sandbox / 'missing.gguf')],
        input='{"id":1,"query":"red sailboat","limit":5}\n',
        text=True,
        timeout=25,
    )
    assert json.loads(failed).get('error') and run('query','88aa.jpg')==name_before
    server=serve()
    results=[]
    try:
        def check(key,text,target):
            hs,elapsed=query(server,key,text)
            if target:
                assert hs and hs[0]['name']==target and validate(hs[0]),(text,hs)
            else:
                assert not hs,(text,hs)
            results.append({'query':text,'target':target,'hits':[{'name':h['name'],'match_evidence':h['matched_by'],
                             'score':h['score']} for h in hs],'request_ms':elapsed})
            return hs
        for i,case in enumerate(cases):
            check(i*2,case['en'],case['file'])
            check(i*2+1,case['zh'],case['file'])
        for i,negative in enumerate(('snow covered mountains beside a waterfall','瀑布旁边有一座被雪覆盖的大山',
                    'a close up photograph of a smiling golden retriever','一只微笑的金毛犬的特写')):
            check(10+i,negative,None)
        hit=check(15,cases[0]['en'],cases[0]['file'])[0]
        temp=allowed/'replacement'
        shutil.copyfile(fixtures/'93a2.png', temp)
        os.replace(temp,allowed/cases[0]['file'])
        assert not validate(hit)
        hs,_=query(server,16,cases[0]['en'])
        assert not any(h['name']==cases[0]['file'] for h in hs),hs
        assert run('image-index','--projector',str(projector))['indexed']==1
        check(17,cases[0]['en'],None)
        run('image-scope',str(outside))
        check(18,'red sailboat on the water',None)
        assert run('image-index','--projector',str(projector))['indexed']==1
        check(19,'red sailboat on the water','88aa.jpg')
        run('image-scope','--clear')
        check(20,'red sailboat on the water',None)
        assert run('query','88aa.jpg')==name_before
    finally:
        server.stdin.close()
        try:
            server.wait(timeout=8)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=4)
        finally:
            server.stdout.close()
    report={'model_id':batches[0]['model_id'],'tests':results,'pixel_vectors':4,'negative_queries':4,
             'data_tests_passed':['scope','deny','provider','symlink','bad PNG','incremental cursor','exact-stamp replacement','revoke','JPEG','missing model','lexical isolation']}
    print(json.dumps(report, ensure_ascii=False, indent=2))
