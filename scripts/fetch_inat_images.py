"""iNaturalist から種の写真を 1 枚ずつ集める（F-60 の画像の第 2 の出典）。
対象: fish.json の種で画像がまだ無いもの。順番: 釣りの分類あり → 和名あり → その他。
ライセンス: cc0 / cc-by / cc-by-sa / cc-by-nc / cc-by-nc-sa（ND は使わない）。出典・作者・ライセンスを image_credits.json に残す。
API の礼儀: 1 秒に 1 回未満。再開可。
"""
import json, os, sys, time, io, requests
from PIL import Image
UA="FogFishGuide/1.0 (personal fishing app, https://github.com/sawswork/fog)"
S=requests.Session(); S.headers["User-Agent"]=UA
OUT="/home/user/fog/App/Resources/Fish"
OK={"cc0","cc-by","cc-by-sa","cc-by-nc","cc-by-nc-sa"}
fish=json.load(open('/home/user/fog/Packages/Core/Sources/Core/Data/fish.json'))['entries']
credits=json.load(open("image_credits.json")) if os.path.exists("image_credits.json") else {}
def rank(e):
    if e.get("groups"): return 0
    if e.get("name")!=e.get("scientificName") and not e.get("nameEstimated"): return 1
    return 2
queue=[e for e in fish if e.get("scientificName") and not (credits.get(e["id"],{}).get("file"))]
queue.sort(key=rank)
print("queue",len(queue),flush=True)
last=0.0
def get(url,**kw):
    global last
    for attempt in range(5):
        wait=1.1-(time.time()-last)
        if wait>0: time.sleep(wait)
        last=time.time()
        try:
            r=S.get(url,timeout=60,**kw)
        except Exception as ex:
            print("exc",str(ex)[:60],flush=True); time.sleep(10); continue
        if r.status_code==429 or r.status_code>=500:
            time.sleep(30*(attempt+1)); continue
        return r
    return None
def pick_photo(sci):
    r=get("https://api.inaturalist.org/v1/taxa",params={"q":sci,"rank":"species,subspecies","per_page":5})
    if not r or r.status_code!=200: return None
    res=[t for t in r.json().get("results",[]) if t.get("name","").lower()==sci.lower()] or []
    if not res: return None
    t=res[0]
    dp=t.get("default_photo") or {}
    if dp.get("license_code") in OK and dp.get("medium_url"):
        return {"url":dp["medium_url"].replace("medium","large"),"license":dp["license_code"],"attribution":dp.get("attribution",""),"page":f"https://www.inaturalist.org/taxa/{t['id']}","taxon":t["id"]}
    r=get("https://api.inaturalist.org/v1/observations",params={"taxon_id":t["id"],"quality_grade":"research","photo_license":",".join(sorted(OK)),"per_page":3,"order_by":"votes"})
    if not r or r.status_code!=200: return None
    for o in r.json().get("results",[]):
        for p in o.get("photos",[]):
            if p.get("license_code") in OK and p.get("url"):
                return {"url":p["url"].replace("square","large"),"license":p["license_code"],"attribution":p.get("attribution",""),"page":f"https://www.inaturalist.org/observations/{o['id']}","taxon":t["id"]}
    return None
n=0; miss=0
for i,e in enumerate(queue):
    sid=e["id"]
    if credits.get(sid,{}).get("file"): continue
    try:
        ph=pick_photo(e["scientificName"])
    except Exception as ex:
        print(sid,"error",str(ex)[:60],flush=True); ph=None
    if not ph:
        miss+=1; credits.setdefault(sid,{"skipped":"inat:none"})
        if i%50==0: json.dump(credits,open("image_credits.json","w",encoding="utf-8"),ensure_ascii=False)
        continue
    r=get(ph["url"])
    if not r or r.status_code!=200:
        r=get(ph["url"].replace("large","medium"))
    if not r or r.status_code!=200:
        credits[sid]={"skipped":"inat:download"}; continue
    try:
        # 容量：釣りの分類のある種は 640 px、それ以外は 480 px（4,000 種で 100 MB を超えないように）
        side = 640 if e.get("groups") else 480
        im=Image.open(io.BytesIO(r.content)).convert("RGB"); im.thumbnail((side,side))
        im.save(os.path.join(OUT,sid+".jpg"),"JPEG",quality=76 if e.get("groups") else 72,optimize=True)
    except Exception as ex:
        credits[sid]={"skipped":"inat:image"}; continue
    lic=ph["license"].upper().replace("CC-","CC ").replace("CC0","CC0")
    credits[sid]={"file":ph["url"].rsplit("/photos/",1)[-1].split("/")[0],"license":lic,"artist":ph["attribution"].replace("(c) ","").split(", some rights")[0][:80],"url":ph["page"],"licenseURL":"","source":"iNaturalist"}
    n+=1
    if n%10==0:
        json.dump(credits,open("image_credits.json","w",encoding="utf-8"),ensure_ascii=False); print(f"inat images {n} (miss {miss}) at {i+1}/{len(queue)}",flush=True)
json.dump(credits,open("image_credits.json","w",encoding="utf-8"),ensure_ascii=False)
print("done",n,"miss",miss)
