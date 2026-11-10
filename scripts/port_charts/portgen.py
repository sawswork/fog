# 港の海図を作る：国土地理院の航空写真＋地図 → Gemini → 海岸線の一致を数字で確かめる
import json, sys, base64, subprocess, io, os
import numpy as np
from PIL import Image, ImageFilter
PROMPT=open(os.path.join(os.path.dirname(__file__),'p_port2.txt')).read()
def true_water(pale):
    a=np.asarray(pale.convert('RGB')).astype(int); r,g,b=a[...,0],a[...,1],a[...,2]
    w=(b>220)&(r<215)&(g<230)&(b-r>25)
    return Image.fromarray((w*255).astype(np.uint8)).filter(ImageFilter.MedianFilter(9))
def art_water(art):
    a=np.asarray(art.convert('RGB').filter(ImageFilter.GaussianBlur(3))).astype(int); r,g,b=a[...,0],a[...,1],a[...,2]
    w=((b-r)>22)&((g-r)>6)
    return Image.fromarray((w*255).astype(np.uint8)).filter(ImageFilter.MedianFilter(9))
def iou(pale, art, size=(300,400)):
    t=np.asarray(true_water(pale).resize(size))>127; g=np.asarray(art_water(art).resize(size))>127
    inter=(t&g).sum(); union=(t|g).sum()
    return float(inter)/float(max(1,union)), float(t.mean()), float(g.mean())
def generate(model, photo_path, pale_path, style_path, size="1K", timeout=420):
    parts=[{"text":PROMPT}]
    for p in (photo_path,pale_path,style_path):
        parts.append({"inline_data":{"mime_type":"image/jpeg","data":base64.b64encode(open(p,'rb').read()).decode()}})
    cfg={"responseModalities":["IMAGE"],"imageConfig":{"aspectRatio":"3:4"}}
    if size: cfg["imageConfig"]["imageSize"]=size
    req={"contents":[{"role":"user","parts":parts}],"generationConfig":cfg}
    import uuid
    rq=f"/tmp/portgen_{os.getpid()}_{uuid.uuid4().hex}.json"; open(rq,"w").write(json.dumps(req))
    r=subprocess.run(["curl","-sS","-m",str(timeout),"-H","Content-Type: application/json","-d","@"+rq,
                      f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"],capture_output=True,text=True)
    try: os.remove(rq)
    except OSError: pass
    try: d=json.loads(r.stdout)
    except Exception: return None, "nojson "+r.stdout[:120]
    if "error" in d: return None, f'{d["error"].get("code")} {d["error"].get("status")} {d["error"].get("message","")[:160]}'
    for c in d.get("candidates",[]):
        for p in c.get("content",{}).get("parts",[]):
            if "inlineData" in p:
                return Image.open(io.BytesIO(base64.b64decode(p["inlineData"]["data"]))).convert('RGB'), "ok"
    return None, "noimage "+str(d)[:160]
if __name__=="__main__":
    model,name=sys.argv[1],sys.argv[2]; size=sys.argv[3] if len(sys.argv)>3 else "1K"
    art,msg=generate(model,f"{name}_seamlessphoto.jpg",f"{name}_pale.jpg","style.jpg",None if size=="none" else size)
    if art is None: print(model,name,"FAIL",msg); sys.exit(0)
    out=f"t_{name}_{model.replace('.','').replace('-','_')}.jpg"; art.save(out,quality=90)
    print(model,name,art.size,"IoU %.3f true %.2f art %.2f"%iou(Image.open(f"{name}_pale.jpg"),art))
