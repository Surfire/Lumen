import argparse,json,math,random,statistics,subprocess,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--lumen',type=Path,required=True);p.add_argument('--entries',type=int,default=120);p.add_argument("--wait",type=int,default=50);a=p.parse_args()
N=a.entries
root_base=Path(__file__).resolve().parents[1]/"benchmarks"/"local-results"
root_base.mkdir(parents=True,exist_ok=True)
rng=random.Random(25112026)
with tempfile.TemporaryDirectory(prefix='LumenSpotlightVerification',dir=str(root_base)) as nm, tempfile.TemporaryDirectory(prefix='spot-db-',dir='/tmp') as dn:
 root=Path(nm);folder=root/'synthetic';folder.mkdir()
 of=[folder/f'Folder{i:02d}' for i in range(30)]
 for f in of:f.mkdir()
 name=lambda i:f'lumen-validation-filename-{i:06d}.txt'
 for i in range(N):(of[i%30]/name(i)).write_text('Synthetic generated local benchmark\n')
 lu=[str(a.lumen.resolve()),'--db',str(Path(dn)/'lumen.sqlite')]
 subprocess.run(lu+['index','--root',str(folder)],check=True,stdout=subprocess.DEVNULL,timeout=60)
 def st(query):
  return ['/usr/bin/mdfind','-onlyin',str(folder),f'kMDItemFSName == "{query}"cd']
 ncmd=['/usr/bin/mdfind','-count','-onlyin',str(folder),'kMDItemFSName == "lumen-validation-filename-*.txt"cd']
 end=time.monotonic()+a.wait
 count=0
 while time.monotonic()<end:
  try: count=int(subprocess.check_output(ncmd,timeout=8))
  except ValueError: break
  if count==N:break
  time.sleep(1)
 if count!=N:
  print(json.dumps({'status':'Spotlight_not_fully_ready','metadata_matches':count,'expected':N,'no_comparison':True}));raise SystemExit(0)
 picked=rng.sample(range(N),40)
 results={'lumen_name_cli_ms':[], 'spotlight_mdfind_cli_ms':[]}
 for i in picked:
  q=name(i)
  commands=((lu+['query','--mode','name','--',q],'lumen_name_cli_ms'),(st(q),'spotlight_mdfind_cli_ms'))
  if i%2:commands=commands[::-1]
  for cmd,key in commands:
   t=time.perf_counter_ns(); r=subprocess.check_output(cmd,timeout=8);results[key].append((time.perf_counter_ns()-t)/1e6)
   if key.startswith('lumen'): assert any(h['name']==q for h in json.loads(r))
   else: assert len(r.splitlines())==1 and r.decode().strip().endswith(q)
 print(json.dumps({'status':'ok','synthetic_files':N,'distinct_exact_queries':len(picked),'both_correct':True,'cached_system_index':True,'scope':'command invocation through validated file result, not the UI',**{k:{'p50_ms':round(statistics.median(v),3),'p95_ms':round(sorted(v)[math.ceil(len(v)*.95)-1],3)} for k,v in results.items()}},indent=2))
