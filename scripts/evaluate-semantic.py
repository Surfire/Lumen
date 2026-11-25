from pathlib import Path
import json,statistics,subprocess,tempfile,sys
resource=Path(sys.argv[1]).resolve()
Z=[
("维护自行车链条","清除传动链上的砂粒，晾干后逐节滴润滑剂，转动曲柄后擦去多余的油。","骑车时传动部分摩擦响应该怎样保养？","需要在脚踏车的金属链环上加什么减少磨耗？"),
("记录高山气象","自动站每十分钟上传气温、降水、相对湿度和风向，冬季降雪时加热雨量筒。","如何在山顶持续采集环境变化？","记录户外大气条件需要哪些传感数据？"),
("制作酸面包酵头","用等量面粉和水喂养天然菌种，观察冒泡和体积增长，成熟后留一部分下次继续培养。","不用商业酵母怎样让面团自然发起来？","烤酸种之前如何维持菌群活性？"),
("整理旧账票据","先核发票日期与收款主体，再逐笔和银行流水比对。缺少凭证的交易单列复核。","对账遇到无法解释的支出要如何处理？","年底怎么检查银行扣款与财务记录吻合？"),
("识别候鸟迁飞","用望远镜记录鹤群出现的方向和时间，结合环志颜色估计迁飞路线，不接近筑巢点。","怎么研究冬天鸟群从哪里来？","追踪长距离移动的鸟类时怎样避免惊扰？"),
("剧场灯光安全","调光前核对吊装设备的保险绳和供电负载，换灯时先断电，台下留出隔离区。","演出布置上方照明如何预防坠物或触电？","剧院人员更换高处灯具前应做什么？"),
("收纳高温季药品","将对温度敏感的药物置于符合标示温度的设备中，保存连续温度记录，异常先隔离。","酷暑中如何保管需要冷链的制剂？","发现药库温度超了范围后怎么办？"),
("培训新同事","安排熟悉业务的搭档，让新人先看一遍真实流程再试着独立完成；每周复盘困难。","新员工怎样尽快学会日常工作？","团队如何让刚入职的人平稳上手？"),
("恢复误删数据库","将最近备份恢复到隔离环境，再按事务日志回放到误删发生前一点，核查行数和业务一致性。","生产表被误删后如何找回原来的数据？","怎样利用快照和事务记录做时间点恢复？"),
("安排雨水花园","将屋顶径流导入低洼种植带，配置耐涝植物和透水土层，超过容量的水经溢流口排出。","如何让屋面排水自然渗进绿地？","暴雨时小区怎样靠植物和土壤降低地表积水？"),
("训练儿童专注阅读","按兴趣选取篇幅较短的故事定时阅读，结束后由孩子用自己的话复述，慢慢延长时间。","怎么帮孩子坚持读书而不分心？","给小学生做家庭阅读练习可从哪里开始？"),
("旧照片数字化","将相片灰尘轻轻拭去，按高分辨率扫描，保存无损原件和浏览副本，以年月编目。","如何把纸质家庭影像保存到电脑？","档案馆扫描老相片后怎样防止画质损失？"),
("水培番茄营养液","监控营养液的酸碱度、电导率与液位，高温天补水并检查根部是否缺氧。","无土种西红柿该怎样控制肥水？","根系浸在溶液里时怎样避免缺氧和浓度失衡？"),
("排查视频会议回声","确认只有一台设备开扬声器和话筒，关闭其他终端音频，用耳机复测并检查消回声设置。","多人开线上会听见自己说话重复怎么办？","怎样处理电脑和手机同时入会产生的反馈声？"),
("管理仓库温敏货品","冷库完成收货后记录批次温度，按效期先后出库；超过温控阈值时通知质检。","需要冷藏的货入库并发货时怎么核对质量？","配送低温产品怎样按到期时间安排出货？")]
E=[
("bike maintenance","Wipe particles off the bicycle chain and apply a drop of lubricant to each link before removing the excess.","How can a rider quiet a dry drivetrain?","What prevents wear on the linked metal loop driven by the pedals?"),
("archive photos","Clean dust from prints, scan at high resolution, and keep a lossless master alongside a smaller viewing copy.","What is a good way to preserve old family snapshots on a computer?","How should physical images be digitized without throwing away detail?"),
("bakery starter","Feed a living sourdough culture with water and flour until it bubbles and expands, then reserve a little for the next loaf.","How can bread rise without commercial yeast?","How do I keep the natural fermentation culture alive before baking?"),
("financial records","Match each invoice to the corresponding entry on the bank statement; flag charges that lack documentation.","How should an accountant validate spending at year end?","What do I do when a payment cannot be reconciled with a receipt?"),
("new staff","Pair new hires with an experienced teammate who demonstrates routine tasks, supervises practice, and reviews progress each week.","How can recruits become productive quickly?","What helps someone learn a role after joining the team?"),
("database recovery","Restore the newest snapshot in isolation, replay transaction logs to just before the accidental deletion, and verify consistency.","Can rows from a dropped production table be recovered?","How do I return a data store to its earlier state after a destructive mistake?"),
("stormwater","Route roof runoff to a planted depression with permeable soil and an overflow drain to reduce pooling during storms.","How can landscaping soak up precipitation from a rooftop?","What can a neighborhood build so heavy rainfall does not sit on the pavement?"),
("theatre safety","Before replacing suspended stage lights, cut the electrical supply, inspect safety cables, and keep people out from underneath.","How can technicians prevent falling gear and electrical shock during a show setup?","What precautions are needed when working on lighting above an audience?"),
("conference audio","Allow only one microphone and speaker in the room; mute other devices and test echo cancellation with headphones.","What stops hearing your own voice repeated during a remote meeting?","How can phones and laptops in a call avoid acoustic feedback?"),
("weather station","A mountain instrument station transmits precipitation, air temperature, humidity, and wind direction every ten minutes.","How can changing atmospheric conditions on a summit be observed continually?","What measurements should sensors collect at an exposed high elevation?")]
NEG={
"zh":["火星的两颗卫星分别叫什么？","帝王蝶的染色体有几对？","日本浮世绘在江户时期如何传播？","纯钛在海水中的腐蚀速率是多少？","给我写一篇莎士比亚式十四行诗。","内蒙古草原上的奶茶需要加盐吗？","蒙特卡洛树搜索的探索常数怎么定？","明代青花瓷如何鉴别窑口？","大西洋海底电缆跨洋如何铺设？","立方体有多少个对称操作？"],
"en":["Which moons orbit Neptune?","When did Impressionist painting first appear?","How fast do ocean trenches move?","How can I solve a Rubik's cube blindfolded?","What causes the aurora on Jupiter?","Write a Shakespearean sonnet about a raven.","How is basalt different from granite?","What are the dimensions of a cricket pitch?","When did the first dinosaurs appear?","How are the poles of a bar magnet aligned?"]}
report={}
for lang, data in [('zh',Z),('en',E)]:
 with tempfile.TemporaryDirectory(dir='/tmp',prefix='lumen-sem-') as t:
  p=Path(t);root=p/'data';root.mkdir()
  for subject,body,*qs in data:(root/(subject+'.md')).write_text(body)
  cli=[str(resource/'lumen'),'--db',str(p/'db.sqlite')]
  opt=['--helper',str(resource/'LumenLocalEmbedding'),'--language',lang]
  def run(*args):return json.loads(subprocess.check_output(cli+list(args),timeout=40))
  run('index','--root',str(root),'--documents')
  embedded=run('embed',*opt,'--max','100')
  ranks=[];top=[];best=[];bad=[]
  for subject,_,*qs in data:
   for q in qs:
    hs=run('query','--mode','semantic','--limit','10',*opt,'--',q)
    rank=next((i for i,h in enumerate(hs,1) if h['name']==subject+'.md'),None);ranks.append(rank)
    if rank:best.append(hs[rank-1].get('score'))
  for q in NEG[lang]:
   hs=run('query','--mode','semantic','--limit','5',*opt,'--',q)
   bad.append(hs[0]['score'] if hs else None)
  report[lang]={'positive_cases':len(ranks),'hit_1':sum(x==1 for x in ranks),'hit_5':sum(x is not None and x<=5 for x in ranks),'mrr_10':round(sum(1/x if x else 0 for x in ranks)/len(ranks),3),'negative_cases':len(bad),'false_positive_cases':sum(x is not None for x in bad),'negative_top_scores':bad,'true_answer_scores':best,'embedded':embedded}
print(json.dumps(report,indent=2))
