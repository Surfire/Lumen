import argparse,json,math,os,random,socket,statistics,subprocess,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--lumen',type=Path,required=True);p.add_argument('--legacy',type=Path,required=True);p.add_argument('--entries',type=int,default=100000);a=p.parse_args()
assert 10000<=a.entries<=1000000
rng=random.Random(25112026)
N=a.entries;runs=4
def summary(v):return {k:round(x,3) for k,x in [('p50',statistics.median(v)),('p95',sorted(v)[math.ceil(len(v)*.95)-1]),('max',max(v))]}
with tempfile.TemporaryDirectory(prefix='lcompare-',dir='/tmp') as name:
 b=Path(name);root=b/'corpus';root.mkdir()
 dirs=[root/f'dir-{i:03d}' for i in range(100)]
 for d in dirs:d.mkdir()
 for i in range(N):
  token='清源测试' if i%7==0 else ('market' if i%11 else 'policy')
  (dirs[i%len(dirs)]/f'{token}-{i:07d}.txt').touch()
 def scan(who,cmd):
  t=time.monotonic(); subprocess.run(cmd,check=True,stdout=subprocess.DEVNULL,timeout=240);return round(time.monotonic()-t,3)
 le=[str(a.lumen.resolve()),'--db',str(b/'ln.sqlite')]
 old=[str(a.legacy.resolve()),'--db',str(b/'legacy.sqlite')]
 sk=str(b/'legacy.sock');stats={}
 stats['lumen_scan_s']=scan('lumen',le+['index','--root',str(root)])
 stats['legacy_scan_s']=scan('legacy',old+['scan',str(root)])
 q1=subprocess.Popen(le+['serve'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,stderr=subprocess.DEVNULL)
 q2=subprocess.Popen(old+['serve','--socket',sk],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 try:
  end=time.monotonic()+30
  while not Path(sk).exists() and q2.poll() is None and time.monotonic()<end:time.sleep(.02)
  def query(engine,q):
   request={'query':q,'limit':20}
   t=time.perf_counter_ns()
   if engine==0:
    q1.stdin.write(json.dumps(dict(request,id=1))+'\n');q1.stdin.flush();r=json.loads(q1.stdout.readline());hits=r['hits']
   else:
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
     s.settimeout(10);s.connect(sk);s.sendall(json.dumps(request).encode()+b'\n')
     with s.makefile('rb') as r: hits=json.loads(r.readline())['results']
   return (time.perf_counter_ns()-t)/1e6,hits
  groups={'known_unique':[(f'{i:07d}.txt',f'{i:07d}.txt') for i in rng.sample(range(N),50)],
          'known_missing':[(f'not-present-{i:07d}',None) for i in rng.sample(range(N),50)],
          'broad':[('market',None),('policy',None),('dir-',None),('清源',None),('清源测试',None),('qingyuan',None),('a',None),('00',None)]}
  for label,qs in groups.items():
   for engine in (0,1):
    for text,_ in qs:query(engine,text)
   a0=[];a1=[];valid=[0,0]
   jobs=qs*runs;rng.shuffle(jobs)
   for i,(q,expected) in enumerate(jobs):
    for engine in [i%2,1-i%2]:
     ms,hits=query(engine,q)
     if label=='known_unique': assert any(str(h.get('path','')).endswith(expected) for h in hits),(label,engine,hits[:1])
     if label=='known_missing': assert not hits
     valid[engine]+=bool(hits)
     (a0 if engine==0 else a1).append(ms)
   stats[label]={'samples_per_engine':len(a0),'lumen_ms':summary(a0),'legacy_socket_ms':summary(a1),'with_hits':valid}
  stats['scope']='same synthetic corpus Top 20; Lumen persistent stdio vs Luminator engine Unix socket; not full Tinycast or Spotlight UI'
  stats['entries']=N
  print(json.dumps(stats,indent=2))
 finally:
  q1.stdin.close()
  if q2.poll() is None:q2.terminate()
  for proc in [q1,q2]:
   try:proc.wait(timeout=10)
   except subprocess.TimeoutExpired:proc.kill();proc.wait()
