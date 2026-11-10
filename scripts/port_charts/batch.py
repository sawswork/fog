# 道南の港の海図を一括で作る。優先：函館・鹿部・森・八雲に近い順。安いモデルで作り、海岸線が合わなければ作り直す。
# 予算切れ（クォータのエラーが続く）なら止める。残りの港はアプリ側で Apple の地図に落ちる。
import json, math, os, sys, time, base64, threading
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
import tiles, portgen
portgen.PROMPT=open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'p_port2.txt')).read()
D=os.path.dirname(os.path.abspath(__file__))+'/'
MODEL="gemini-3.1-flash-image"; PASS=0.68
ports=json.load(open(D+'donan_ports.json'))
anchors=[(41.77,140.73),(42.03,140.82),(42.10,140.57),(42.25,140.27)]   # 函館・鹿部・森・八雲
def dist(a,b): return math.hypot((a[0]-b[0])*111.0,(a[1]-b[1])*111.0*math.cos(math.radians(a[0])))
ports.sort(key=lambda p: min(dist((p['lat'],p['lon']),a) for a in anchors))
WIDTH={'函館港':2400,'森港':1400,'江差港':1500,'松前港':1200,'瀬棚港':1400,'奧尻港':1300,'椴法華港':900,'函館漁港':1000,'臼尻漁港':1000,'砂原漁港':1000}
def pid(p): return f"p{int(round(p['lat']*10000))}_{int(round(p['lon']*10000))}"
state={'quota':0,'stop':False}; lock=threading.Lock()
log=open(D+'batch.log','a')
def say(*a):
    with lock: print(*a,file=log,flush=True)
def one(p):
    if state['stop']: return
    i=pid(p); meta=D+f'out/{i}.json'
    if os.path.exists(meta): return
    w=WIDTH.get(p['name'], 1800 if p['kind']=='harbor' else 800); z=17 if w<=1100 else 16
    ph,pa=D+f'src/{i}_photo.jpg',D+f'src/{i}_pale.jpg'
    try:
        if not (os.path.exists(ph) and os.path.exists(pa)):
            out,mpp=tiles.area(p['lat'],p['lon'],z,w,w*4/3)
            if out['seamlessphoto'][1]>0 or out['pale'][1]>0: say(p['name'],'tiles missing',out['seamlessphoto'][1],out['pale'][1])
            out['seamlessphoto'][0].resize((1200,1600),Image.LANCZOS).save(ph,quality=88); out['pale'][0].resize((1200,1600),Image.LANCZOS).save(pa,quality=88)
        pale=Image.open(pa)
        tw=np.asarray(portgen.true_water(pale).resize((300,400)))>127
        if tw.mean()<0.04: say(p['name'],'no water in frame, skip'); json.dump({'id':i,'name':p['name'],'skip':'nowater'},open(meta,'w'),ensure_ascii=False); return
        best=None
        # 前回の実行で絵だけ出来ていたら作り直さない
        if os.path.exists(D+f'out/{i}.jpg'):
            prev=Image.open(D+f'out/{i}.jpg').convert('RGB'); best=(float(portgen.iou(pale,prev)[0]),prev)
        for attempt in range(3 if best is None else 0):
            if state['stop']: return
            art,msg=portgen.generate(MODEL,ph,pa,D+'style_swatch.jpg',"1K")
            if art is None:
                q=('429' in msg) or ('RESOURCE_EXHAUSTED' in msg) or ('quota' in msg.lower()) or ('billing' in msg.lower())
                say(p['name'],'gen fail',msg[:140])
                if q:
                    with lock: state['quota']+=1
                    if state['quota']>=6: state['stop']=True; say('STOP: quota exhausted'); return
                    time.sleep(40)
                else: time.sleep(5)
                continue
            with lock: state['quota']=0
            sc=portgen.iou(pale,art)[0]
            if best is None or sc>best[0]: best=(sc,art)
            if sc>=PASS: break
        if best is None: return
        sc,art=best; sc=float(sc)
        ok=bool(sc>=PASS)
        art=art.resize((900,1200),Image.LANCZOS)
        if ok: art.save(D+f'out/{i}.jpg',quality=84,optimize=True)
        else: art.save(D+f'out/{i}_rejected.jpg',quality=80)
        # 水面の網目（60×80）：予測を水の上だけに置くため
        m=(np.asarray(portgen.true_water(pale).resize((60,80)))>127)
        bits=np.packbits(m.flatten()).tobytes()
        json.dump({'id':i,'name':p['name'],'kind':p['kind'],'lat':p['lat'],'lon':p['lon'],'widthM':w,'heightM':round(w*4/3,1),'score':round(sc,3),'ok':ok,
                   'water':base64.b64encode(bits).decode(),'cols':60,'rows':80},open(meta,'w'),ensure_ascii=False)
        say(p['name'],i,'ok' if ok else 'REJECT','%.3f'%sc)
    except Exception as e:
        say(p['name'],'error',repr(e)[:200])
with ThreadPoolExecutor(3) as ex: list(ex.map(one,ports))
say('DONE' if not state['stop'] else 'STOPPED')
